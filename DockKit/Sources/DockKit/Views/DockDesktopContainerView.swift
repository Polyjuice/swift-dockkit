import AppKit

/// Delegate for desktop container events
public protocol DockDesktopContainerViewDelegate: AnyObject {
    /// Called when desktop index changes during swipe (for UI feedback)
    func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int)

    /// Called when desktop switch animation completes
    func desktopContainer(_ container: DockDesktopContainerView, didSwitchTo index: Int)

    /// Called when a panel needs to be looked up by ID
    func desktopContainer(_ container: DockDesktopContainerView, panelForId id: UUID) -> (any DockablePanel)?
}

/// Default implementations
public extension DockDesktopContainerViewDelegate {
    func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int) {}
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

    /// Spring stiffness for bounce back
    private let springStiffness: CGFloat = 300

    /// Spring damping
    private let springDamping: CGFloat = 25

    /// Spring mass
    private let springMass: CGFloat = 1.0

    /// Rubber band coefficient (Apple uses 0.55)
    private let rubberBandCoefficient: CGFloat = 0.55

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

        NSLayoutConstraint.activate([
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: clipView.heightAnchor)
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

    // MARK: - Desktop View Management

    private func rebuildDesktopViews() {
        // Remove old views
        for view in desktopViews {
            view.removeFromSuperview()
        }
        desktopViews.removeAll()
        desktopViewControllers.removeAll()

        // Remove old width constraint if any
        contentView.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }

        guard !desktops.isEmpty else { return }

        // Create new desktop views
        let desktopWidth = bounds.width

        for (index, desktop) in desktops.enumerated() {
            let desktopView = NSView()
            desktopView.wantsLayer = true
            desktopView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(desktopView)
            desktopViews.append(desktopView)

            // Position within content view
            NSLayoutConstraint.activate([
                desktopView.topAnchor.constraint(equalTo: contentView.topAnchor),
                desktopView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                desktopView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
                desktopView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: CGFloat(index) * desktopWidth)
            ])

            // Create view controller for desktop layout
            let vc = createViewController(for: desktop.layout)
            desktopViewControllers[desktop.id] = vc

            vc.view.translatesAutoresizingMaskIntoConstraints = false
            desktopView.addSubview(vc.view)

            NSLayoutConstraint.activate([
                vc.view.leadingAnchor.constraint(equalTo: desktopView.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: desktopView.trailingAnchor),
                vc.view.topAnchor.constraint(equalTo: desktopView.topAnchor),
                vc.view.bottomAnchor.constraint(equalTo: desktopView.bottomAnchor)
            ])
        }

        // Set content view width
        contentView.widthAnchor.constraint(equalTo: clipView.widthAnchor, multiplier: CGFloat(desktops.count)).isActive = true
    }

    private func createViewController(for layoutNode: DockLayoutNode) -> NSViewController {
        switch layoutNode {
        case .split(let splitNode):
            let splitVC = DockSplitViewController(splitNode: createSplitNode(from: splitNode))
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: createTabGroupNode(from: tabGroupNode))
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
            activeTabIndex: layout.activeTabIndex
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
        let targetX = -CGFloat(activeDesktopIndex) * bounds.width + swipeOffset

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().frame.origin.x = targetX
            }
        } else {
            contentView.frame.origin.x = targetX
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
            contentView.frame.origin.x = targetX

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
        let target: Int

        // Check velocity-based switching (flick)
        let velocityBasedSwitch = abs(gestureVelocity) > flickVelocityThreshold

        if velocityBasedSwitch {
            // Velocity determines direction
            if gestureVelocity > 0 && activeDesktopIndex > 0 {
                target = activeDesktopIndex - 1
            } else if gestureVelocity < 0 && activeDesktopIndex < desktops.count - 1 {
                target = activeDesktopIndex + 1
            } else {
                target = activeDesktopIndex
            }
        } else if gestureAmount >= dragPositionThreshold && activeDesktopIndex > 0 {
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

        // If we're already at target, just snap
        if abs(currentPosition - targetPosition) < 1 {
            swipeOffset = 0
            updateContentPosition(animated: false)
            if oldIndex != index {
                delegate?.desktopContainer(self, didSwitchTo: index)
            }
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
        let targetX = -CGFloat(activeDesktopIndex) * bounds.width + swipeOffset
        contentView.frame.origin.x = targetX

        // Check if animation is done
        if abs(state.position - state.target) < 0.5 && abs(state.velocity) < 10 {
            // Snap to final position
            swipeOffset = 0
            updateContentPosition(animated: false)
            springState = nil
            stopDisplayLink()

            delegate?.desktopContainer(self, didSwitchTo: activeDesktopIndex)
        } else {
            springState = state
        }
    }

    private func stopSpringAnimation() {
        springState = nil
        stopDisplayLink()
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()

        // Update desktop view widths when bounds change
        for (index, desktopView) in desktopViews.enumerated() {
            // Update leading constraint
            for constraint in contentView.constraints {
                if constraint.firstItem as? NSView == desktopView && constraint.firstAttribute == .leading {
                    constraint.constant = CGFloat(index) * bounds.width
                }
            }
        }

        // Update content position if not animating
        if springState == nil {
            updateContentPosition(animated: false)
        }
    }
}
