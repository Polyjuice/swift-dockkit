import AppKit

/// Delegate for desktop container events
public protocol DockDesktopContainerViewDelegate: AnyObject {
    /// Called when desktop index changes during swipe (for UI feedback)
    func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int)

    /// Called when desktop switch animation completes
    func desktopContainer(_ container: DockDesktopContainerView, didSwitchTo index: Int)

    /// Called when a panel needs to be looked up by ID
    func desktopContainer(_ container: DockDesktopContainerView, panelForId id: UUID) -> (any DockablePanel)?

    /// Called when a tab is dropped in a tab group
    func desktopContainer(_ container: DockDesktopContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called when a panel wants to detach (tear off)
    func desktopContainer(_ container: DockDesktopContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint)

    /// Called when a split is requested
    func desktopContainer(_ container: DockDesktopContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockDesktopContainerViewDelegate {
    func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int) {}
    func desktopContainer(_ container: DockDesktopContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func desktopContainer(_ container: DockDesktopContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {}
    func desktopContainer(_ container: DockDesktopContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A container view that hosts multiple desktops with swipe gesture navigation
/// Each desktop has its own independent layout tree
public class DockDesktopContainerView: NSView {

    // MARK: - Properties

    public weak var delegate: DockDesktopContainerViewDelegate?

    /// The desktop layouts this container displays
    private var desktops: [Desktop] = []

    /// Current active desktop index
    public private(set) var activeDesktopIndex: Int = 0

    /// View controllers for each desktop (lazily created)
    private var desktopViewControllers: [UUID: NSViewController] = [:]

    /// The clip view that contains all desktop views
    private var clipView: NSView!

    /// The content view that slides horizontally
    private var contentView: NSView!

    /// Individual desktop container views
    private var desktopViews: [NSView] = []

    /// Constraint for contentView leading position (for sliding animation)
    private var contentViewLeadingConstraint: NSLayoutConstraint?

    /// Constraint for contentView width (multiplied by desktop count)
    private var contentViewWidthConstraint: NSLayoutConstraint?

    // MARK: - Gesture State

    /// Current offset during swipe (0 = centered on active desktop)
    private var swipeOffset: CGFloat = 0

    /// Display link for spring animation
    private var displayLink: CVDisplayLink?

    /// Spring animation state
    private var springState: SpringState?

    /// Track the last indicator target to avoid redundant delegate calls
    private var lastIndicatorTarget: Int = -1

    // MARK: - Configuration

    /// Slow motion for debugging (only affects spring animation, not gesture input)
    /// When enabled, spring animations run 10x slower but gesture response remains instant
    public var slowMotionEnabled: Bool = false
    private var timeScale: CGFloat { slowMotionEnabled ? 0.1 : 1.0 }

    /// Thumbnail mode - when enabled, all tab groups show thumbnails instead of tabs
    @available(*, deprecated, message: "Use displayMode instead")
    public var thumbnailModeEnabled: Bool {
        get { displayMode == .thumbnails }
        set { displayMode = newValue ? .thumbnails : .tabs }
    }

    /// Display mode for tabs in this container
    public var displayMode: DesktopDisplayMode = .tabs {
        didSet {
            if displayMode != oldValue {
                updateAllTabGroupDisplayModes()
            }
        }
    }

    /// Spring stiffness for bounce back
    private let springStiffness: CGFloat = 300

    /// Spring damping
    private let springDamping: CGFloat = 25

    /// Spring mass
    private let springMass: CGFloat = 1.0

    /// Rubber band coefficient (Apple uses 0.55)
    private let rubberBandCoefficient: CGFloat = 0.55

    /// Update display mode on all tab group view controllers
    private func updateAllTabGroupDisplayModes() {
        // Update all desktop view controllers
        for (_, viewController) in desktopViewControllers {
            updateTabGroupDisplayMode(in: viewController, to: displayMode)
        }
    }

    /// Recursively update display mode in a view controller hierarchy
    private func updateTabGroupDisplayMode(in viewController: NSViewController, to mode: DesktopDisplayMode) {
        if let tabGroupVC = viewController as? DockTabGroupViewController {
            tabGroupVC.setDisplayMode(mode)
        } else if let splitVC = viewController as? DockSplitViewController {
            for child in splitVC.children {
                updateTabGroupDisplayMode(in: child, to: mode)
            }
        } else {
            for child in viewController.children {
                updateTabGroupDisplayMode(in: child, to: mode)
            }
        }
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        stopDisplayLink()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.masksToBounds = true

        // Create clip view
        clipView = NSView()
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)

        // Create content view (will slide horizontally)
        contentView = NSView()
        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(contentView)

        // ContentView leading constraint (will be updated for sliding animation)
        contentViewLeadingConstraint = contentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor)

        NSLayoutConstraint.activate([
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
            contentViewLeadingConstraint!
        ])
    }

    // MARK: - Public API

    /// Set the desktops to display
    public func setDesktops(_ newDesktops: [Desktop], activeIndex: Int) {
        desktops = newDesktops
        activeDesktopIndex = max(0, min(activeIndex, desktops.count - 1))

        rebuildDesktopViews()
        updateContentPosition(animated: false)
    }

    /// Switch to a specific desktop with animation
    public func switchToDesktop(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < desktops.count else { return }

        if animated {
            animateToDesktop(at: index)
        } else {
            activeDesktopIndex = index
            updateContentPosition(animated: false)
            delegate?.desktopContainer(self, didSwitchTo: activeDesktopIndex)
        }
    }

    /// Get the view controller for the active desktop
    public var activeDesktopViewController: NSViewController? {
        guard activeDesktopIndex >= 0 && activeDesktopIndex < desktops.count else { return nil }
        let desktopId = desktops[activeDesktopIndex].id
        return desktopViewControllers[desktopId]
    }

    /// Update a specific desktop's layout
    public func updateDesktopLayout(_ layout: DockLayoutNode, forDesktopAt index: Int) {
        guard index >= 0 && index < desktops.count else { return }

        let desktopId = desktops[index].id
        desktops[index].layout = layout

        // Rebuild the view controller for this desktop
        if let existingVC = desktopViewControllers[desktopId],
           index < desktopViews.count {
            // Remove old view
            existingVC.view.removeFromSuperview()

            // Create new view controller
            let newVC = createViewController(for: desktops[index].layout)
            desktopViewControllers[desktopId] = newVC

            // Add to desktop view
            let desktopView = desktopViews[index]
            newVC.view.translatesAutoresizingMaskIntoConstraints = false
            desktopView.addSubview(newVC.view)

            NSLayoutConstraint.activate([
                newVC.view.leadingAnchor.constraint(equalTo: desktopView.leadingAnchor),
                newVC.view.trailingAnchor.constraint(equalTo: desktopView.trailingAnchor),
                newVC.view.topAnchor.constraint(equalTo: desktopView.topAnchor),
                newVC.view.bottomAnchor.constraint(equalTo: desktopView.bottomAnchor)
            ])
        }
    }

    /// Capture thumbnails for all desktops
    public func captureDesktopThumbnails() -> [NSImage?] {
        var thumbnails: [NSImage?] = []

        for (index, desktopView) in desktopViews.enumerated() {
            guard index < desktops.count else {
                thumbnails.append(nil)
                continue
            }

            // Capture the desktop view
            let targetSize = NSSize(width: 112, height: 68) // Fit in thumbnail area

            guard desktopView.bounds.width > 0, desktopView.bounds.height > 0,
                  let bitmapRep = desktopView.bitmapImageRepForCachingDisplay(in: desktopView.bounds) else {
                thumbnails.append(nil)
                continue
            }

            desktopView.cacheDisplay(in: desktopView.bounds, to: bitmapRep)

            let image = NSImage(size: targetSize)
            image.lockFocus()

            // Draw scaled to fit
            let sourceSize = desktopView.bounds.size
            let scaleFactor = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
            let scaledWidth = sourceSize.width * scaleFactor
            let scaledHeight = sourceSize.height * scaleFactor
            let x = (targetSize.width - scaledWidth) / 2
            let y = (targetSize.height - scaledHeight) / 2

            bitmapRep.draw(in: NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight))

            image.unlockFocus()
            thumbnails.append(image)
        }

        return thumbnails
    }

    // MARK: - Desktop View Management

    private func rebuildDesktopViews() {
        // Remove old views
        for view in desktopViews {
            view.removeFromSuperview()
        }
        desktopViews.removeAll()
        desktopViewControllers.removeAll()

        // Remove old width constraint
        if let oldWidthConstraint = contentViewWidthConstraint {
            oldWidthConstraint.isActive = false
            contentViewWidthConstraint = nil
        }

        guard !desktops.isEmpty else {
            return
        }

        // Create new desktop views - use frame-based layout for horizontal positioning
        for (_, desktop) in desktops.enumerated() {
            let desktopView = NSView()
            desktopView.wantsLayer = true
            // Use frame-based layout for desktop views (positioned in layout())
            desktopView.translatesAutoresizingMaskIntoConstraints = true
            contentView.addSubview(desktopView)
            desktopViews.append(desktopView)

            // Create view controller for desktop layout
            let vc = createViewController(for: desktop.layout)
            desktopViewControllers[desktop.id] = vc

            // VC view uses auto layout to fill its container
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            desktopView.addSubview(vc.view)

            NSLayoutConstraint.activate([
                vc.view.leadingAnchor.constraint(equalTo: desktopView.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: desktopView.trailingAnchor),
                vc.view.topAnchor.constraint(equalTo: desktopView.topAnchor),
                vc.view.bottomAnchor.constraint(equalTo: desktopView.bottomAnchor)
            ])
        }

        // Set content view width (track the constraint so we can remove it later)
        contentViewWidthConstraint = contentView.widthAnchor.constraint(equalTo: clipView.widthAnchor, multiplier: CGFloat(desktops.count))
        contentViewWidthConstraint?.isActive = true

        // Reset leading constraint for new desktop count
        contentViewLeadingConstraint?.constant = -CGFloat(activeDesktopIndex) * clipView.bounds.width

        // Force layout
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()

        // Position desktop views using frame-based layout
        let desktopWidth = clipView.bounds.width
        let desktopHeight = clipView.bounds.height

        for (index, desktopView) in desktopViews.enumerated() {
            desktopView.frame = NSRect(
                x: CGFloat(index) * desktopWidth,
                y: 0,
                width: desktopWidth,
                height: desktopHeight
            )
        }

        // Update content position if not animating
        if springState == nil {
            updateContentPosition(animated: false)
        }
    }

    private func createViewController(for layoutNode: DockLayoutNode) -> NSViewController {
        switch layoutNode {
        case .split(let splitNode):
            let splitVC = DockSplitViewController(splitNode: createSplitNode(from: splitNode))
            splitVC.tabGroupDelegate = self
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: createTabGroupNode(from: tabGroupNode))
            tabGroupVC.delegate = self
            return tabGroupVC
        }
    }

    private func createSplitNode(from layout: SplitLayoutNode) -> SplitNode {
        let children = layout.children.map { createDockNode(from: $0) }
        return SplitNode(
            id: layout.id,
            axis: layout.axis,
            children: children,
            proportions: layout.proportions
        )
    }

    private func createTabGroupNode(from layout: TabGroupLayoutNode) -> TabGroupNode {
        let tabs = layout.tabs.compactMap { tabState -> DockTab? in
            if let panel = delegate?.desktopContainer(self, panelForId: tabState.id) {
                return DockTab(from: panel, cargo: tabState.cargo)
            }
            return DockTab(
                id: tabState.id,
                title: tabState.title,
                iconName: tabState.iconName,
                panel: nil,
                cargo: tabState.cargo
            )
        }
        return TabGroupNode(
            id: layout.id,
            tabs: tabs,
            activeTabIndex: layout.activeTabIndex,
            displayMode: layout.displayMode
        )
    }

    private func createDockNode(from layoutNode: DockLayoutNode) -> DockNode {
        switch layoutNode {
        case .split(let splitNode):
            return .split(createSplitNode(from: splitNode))
        case .tabGroup(let tabGroupNode):
            return .tabGroup(createTabGroupNode(from: tabGroupNode))
        }
    }

    // MARK: - Content Positioning

    private func updateContentPosition(animated: Bool) {
        let desktopWidth = clipView.bounds.width > 0 ? clipView.bounds.width : bounds.width
        let targetX = -CGFloat(activeDesktopIndex) * desktopWidth + swipeOffset

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentViewLeadingConstraint?.animator().constant = targetX
            }
        } else {
            contentViewLeadingConstraint?.constant = targetX
        }
    }

    // MARK: - Gesture State (for manual handling with slow motion)

    /// Whether we're in a gesture
    private var isGestureActive: Bool = false

    /// Accumulated gesture amount (0 to ±1 representing full swipe)
    private var gestureAmount: CGFloat = 0

    /// Velocity tracking for flick detection (pixels per second)
    private var gestureVelocity: CGFloat = 0
    private var lastScrollTime: CFTimeInterval = 0

    /// Velocity threshold for flick-based switching (pixels per second)
    private let flickVelocityThreshold: CGFloat = 500

    /// Position threshold for drag-based switching (fraction of desktop width)
    /// Apple uses 50% (halfway) for slow drags
    private let dragPositionThreshold: CGFloat = 0.5

    // MARK: - Scroll Event Handling (Two-Finger Swipe)
    //
    // Manual implementation with momentum support.
    // Slow motion only affects spring animation - gesture input is always real-time.

    public override func scrollWheel(with event: NSEvent) {
        // Only handle gesture scroll events (not legacy mouse wheel)
        guard event.phase != [] || event.momentumPhase != [] else {
            super.scrollWheel(with: event)
            return
        }

        // Only track horizontal-dominant gestures
        let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.5
        if !isHorizontalDominant && !isGestureActive {
            super.scrollWheel(with: event)
            return
        }

        // Handle physical gesture phases
        if event.phase == .began {
            // New gesture starting - stop any animation and take over
            isGestureActive = true
            stopSpringAnimation()
            // Don't reset gestureAmount - preserve current position if interrupting
            // Reset velocity tracking
            gestureVelocity = 0
            lastScrollTime = CACurrentMediaTime()
        }

        // CRITICAL: Only process scroll deltas if gesture is active AND no spring animation
        // This prevents late momentum events from fighting with spring animation
        guard isGestureActive && springState == nil else {
            // If spring is running, ignore scroll events (let spring finish)
            // If gesture not active, ignore stray events
            return
        }

        // Apply scroll delta (from physical gesture or momentum)
        // NOTE: Gesture input is NOT scaled for slow motion - physical movement = visual movement
        // Only spring animation time is scaled for slow motion debugging
        if event.phase == .changed || event.momentumPhase == .changed {
            let desktopWidth = bounds.width
            guard desktopWidth > 0 else { return }

            let deltaX = event.scrollingDeltaX

            // Track velocity (only during physical gesture, not momentum)
            if event.phase == .changed {
                let currentTime = CACurrentMediaTime()
                let dt = currentTime - lastScrollTime
                if dt > 0 {
                    // Smooth velocity with exponential moving average
                    let instantVelocity = deltaX / CGFloat(dt)
                    gestureVelocity = gestureVelocity * 0.7 + instantVelocity * 0.3
                }
                lastScrollTime = currentTime
            }

            // NO time scaling on input - gesture feels normal
            gestureAmount += deltaX / desktopWidth

            // Calculate visual offset with rubber band effect at edges
            let maxLeft = CGFloat(activeDesktopIndex)
            let maxRight = CGFloat(desktops.count - 1 - activeDesktopIndex)

            let visualAmount: CGFloat
            if gestureAmount > maxLeft {
                // Past left edge - apply rubber band
                let overshoot = gestureAmount - maxLeft
                visualAmount = maxLeft + rubberBand(overshoot, dimension: 1.0)
            } else if gestureAmount < -maxRight {
                // Past right edge - apply rubber band
                let overshoot = -maxRight - gestureAmount
                visualAmount = -maxRight - rubberBand(overshoot, dimension: 1.0)
            } else {
                // Within bounds - normal movement
                visualAmount = gestureAmount
            }

            // Update visual position
            swipeOffset = visualAmount * desktopWidth
            let targetX = -CGFloat(activeDesktopIndex) * desktopWidth + swipeOffset
            contentViewLeadingConstraint?.constant = targetX

            // Update header indicator
            updateIndicatorForGestureAmount(gestureAmount)
        }

        // Handle momentum end
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            isGestureActive = false
            finalizeGesture()
        }

        // Handle case where gesture ends without momentum
        if event.phase == .ended && event.momentumPhase == [] {
            // Give a tiny window for momentum to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self = self, self.isGestureActive else { return }
                // Still active means no momentum came
                self.isGestureActive = false
                self.finalizeGesture()
            }
        }
    }

    private func updateIndicatorForGestureAmount(_ gestureAmount: CGFloat) {
        // Indicator uses POSITION-ONLY during gesture (no velocity)
        // This prevents flickering when velocity fluctuates during slow swipes
        // Velocity is only considered at finalization (when user releases)
        let target: Int

        if gestureAmount >= dragPositionThreshold && activeDesktopIndex > 0 {
            target = activeDesktopIndex - 1
        } else if gestureAmount <= -dragPositionThreshold && activeDesktopIndex < desktops.count - 1 {
            target = activeDesktopIndex + 1
        } else {
            target = activeDesktopIndex
        }

        if target != lastIndicatorTarget {
            lastIndicatorTarget = target
            delegate?.desktopContainer(self, didBeginSwipingTo: target)
        }
    }

    private func finalizeGesture() {
        lastIndicatorTarget = -1

        // Calculate bounds for gesture amount
        let maxLeft = CGFloat(activeDesktopIndex)
        let maxRight = CGFloat(desktops.count - 1 - activeDesktopIndex)

        // Clamp gestureAmount to valid bounds for decision making
        // (rubber band overshoot shouldn't trigger desktop switches)
        let clampedAmount = max(-maxRight, min(maxLeft, gestureAmount))

        // Check velocity-based switching (flick) - takes priority
        let velocityBasedSwitch = abs(gestureVelocity) > flickVelocityThreshold

        // Determine target based on velocity OR position
        if velocityBasedSwitch {
            // Flick: velocity determines direction
            if gestureVelocity > 0 && activeDesktopIndex > 0 {
                activeDesktopIndex -= 1
                gestureAmount -= 1.0
            } else if gestureVelocity < 0 && activeDesktopIndex < desktops.count - 1 {
                activeDesktopIndex += 1
                gestureAmount += 1.0
            }
        } else if clampedAmount >= dragPositionThreshold && activeDesktopIndex > 0 {
            // Drag: position determines switch
            activeDesktopIndex -= 1
            gestureAmount -= 1.0
        } else if clampedAmount <= -dragPositionThreshold && activeDesktopIndex < desktops.count - 1 {
            activeDesktopIndex += 1
            gestureAmount += 1.0
        }

        // Calculate visual offset (with rubber band effect if past edges)
        let visualAmount: CGFloat
        let newMaxLeft = CGFloat(activeDesktopIndex)
        let newMaxRight = CGFloat(desktops.count - 1 - activeDesktopIndex)

        if gestureAmount > newMaxLeft {
            let overshoot = gestureAmount - newMaxLeft
            visualAmount = newMaxLeft + rubberBand(overshoot, dimension: 1.0)
        } else if gestureAmount < -newMaxRight {
            let overshoot = -newMaxRight - gestureAmount
            visualAmount = -newMaxRight - rubberBand(overshoot, dimension: 1.0)
        } else {
            visualAmount = gestureAmount
        }

        // Animate to final position from current visual position
        swipeOffset = visualAmount * bounds.width
        animateToDesktop(at: activeDesktopIndex)
        gestureAmount = 0
        gestureVelocity = 0
    }

    // MARK: - Rubber Band Effect

    /// Apple's rubber band formula: f(x, d, c) = (x * d * c) / (d + c * x)
    /// Creates diminishing returns - harder you push, less it moves
    private func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        let c = rubberBandCoefficient
        return (x * d * c) / (d + c * x)
    }

    // MARK: - Spring Animation

    private struct SpringState {
        var position: CGFloat
        var velocity: CGFloat
        var target: CGFloat
    }

    private func animateToDesktop(at index: Int) {
        let targetPosition: CGFloat = 0
        let oldIndex = activeDesktopIndex

        // Adjust swipeOffset to maintain visual continuity when changing desktop index
        // Position formula: targetX = -activeDesktopIndex * width + swipeOffset
        // To keep same visual position after index change:
        // -oldIndex * width + swipeOffset = -index * width + newSwipeOffset
        // newSwipeOffset = swipeOffset + (index - oldIndex) * width
        if index != oldIndex {
            swipeOffset += CGFloat(index - oldIndex) * bounds.width
        }

        let currentPosition = swipeOffset
        activeDesktopIndex = index

        // IMMEDIATELY notify delegate of committed switch
        // This updates the header indicator without waiting for animation to complete
        // Provides faster visual feedback to the user
        delegate?.desktopContainer(self, didSwitchTo: index)

        // If we're already at target, just snap
        if abs(currentPosition - targetPosition) < 1 {
            swipeOffset = 0
            updateContentPosition(animated: false)
            return
        }

        // Start spring animation (velocity is 0 since momentum already stopped)
        springState = SpringState(
            position: currentPosition,
            velocity: 0,
            target: targetPosition
        )

        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let link = link else { return }

        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext in
            let container = Unmanaged<DockDesktopContainerView>.fromOpaque(displayLinkContext!).takeUnretainedValue()

            DispatchQueue.main.async {
                container.updateSpringAnimation()
            }

            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)

        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    private func updateSpringAnimation() {
        guard var state = springState else {
            stopDisplayLink()
            return
        }

        // Apply time scale for slow motion (THIS is the only place time scaling applies)
        let dt: CGFloat = (1.0 / 60.0) * timeScale

        // Spring physics
        let displacement = state.position - state.target
        let springForce = -springStiffness * displacement
        let dampingForce = -springDamping * state.velocity
        let acceleration = (springForce + dampingForce) / springMass

        state.velocity += acceleration * dt
        state.position += state.velocity * dt

        // Update position
        swipeOffset = state.position
        let desktopWidth = clipView.bounds.width > 0 ? clipView.bounds.width : bounds.width
        let targetX = -CGFloat(activeDesktopIndex) * desktopWidth + swipeOffset
        contentViewLeadingConstraint?.constant = targetX

        // Check if animation is done
        if abs(state.position - state.target) < 0.5 && abs(state.velocity) < 10 {
            // Snap to final position
            swipeOffset = 0
            updateContentPosition(animated: false)
            springState = nil
            stopDisplayLink()
            // Note: didSwitchTo already called at animation start for faster feedback
        } else {
            springState = state
        }
    }

    private func stopSpringAnimation() {
        springState = nil
        stopDisplayLink()
    }

}

// MARK: - DockTabGroupViewControllerDelegate

extension DockDesktopContainerView: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        delegate?.desktopContainer(self, didReceiveTab: tabInfo, in: tabGroup, at: index)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachTab tab: DockTab, at screenPoint: NSPoint) {
        delegate?.desktopContainer(self, wantsToDetachTab: tab, from: tabGroup, at: screenPoint)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab) {
        delegate?.desktopContainer(self, wantsToSplit: direction, withTab: tab, in: tabGroup)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastTab: Bool) {
        // Handle last tab closure - could remove the tab group from layout
    }

    public func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {
        // Handle new tab request - could create a new panel
    }
}
