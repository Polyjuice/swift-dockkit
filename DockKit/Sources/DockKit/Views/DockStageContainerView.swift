import AppKit

/// Protocol for handling swipe gestures that bubble up from nested stage hosts.
/// When a nested stage host is at the edge of its stages, the gesture bubbles
/// up to the parent stage host.
public protocol SwipeGestureDelegate: AnyObject {
    /// Called when a nested container wants to pass a scroll event up the hierarchy.
    /// The container is at the edge of its stages and cannot handle the gesture.
    /// - Parameters:
    ///   - event: The scroll wheel event
    ///   - container: The container that is passing the event up
    /// - Returns: true if the parent handled the event, false otherwise
    func handleBubbledScrollEvent(_ event: NSEvent, from container: DockStageContainerView) -> Bool

    /// Called when a nested container's gesture ends and it was bubbling events.
    /// The parent should finalize any gesture state.
    func nestedContainerDidEndGesture(_ container: DockStageContainerView)
}

/// Delegate for stage container events
public protocol DockStageContainerViewDelegate: AnyObject {
    /// Called immediately when a horizontal swipe gesture begins.
    /// Use this to pause expensive rendering (games, animations) during swipe.
    func stageContainerDidBeginSwipeGesture(_ container: DockStageContainerView)

    /// Called when swipe gesture and animation complete.
    /// Use this to resume expensive rendering after swipe finishes.
    func stageContainerDidEndSwipeGesture(_ container: DockStageContainerView)

    /// Called when stage index changes during swipe (for UI feedback)
    func stageContainer(_ container: DockStageContainerView, didBeginSwipingTo index: Int)

    /// Called when stage switch animation completes
    func stageContainer(_ container: DockStageContainerView, didSwitchTo index: Int)

    /// Called when a panel needs to be looked up by ID
    func stageContainer(_ container: DockStageContainerView, panelForId id: UUID) -> (any DockablePanel)?

    /// Called when a tab is dropped in a tab group
    func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called when a panel wants to detach (tear off)
    func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint)

    /// Called when a split is requested
    func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockStageContainerViewDelegate {
    func stageContainerDidBeginSwipeGesture(_ container: DockStageContainerView) {}
    func stageContainerDidEndSwipeGesture(_ container: DockStageContainerView) {}
    func stageContainer(_ container: DockStageContainerView, didBeginSwipingTo index: Int) {}
    func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {}
    func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A container view that hosts multiple stages with swipe gesture navigation
/// Each stage has its own independent layout tree
public class DockStageContainerView: NSView {

    // MARK: - Properties

    public weak var delegate: DockStageContainerViewDelegate?

    /// Delegate for bubbling swipe gestures to parent stage host
    public weak var swipeGestureDelegate: SwipeGestureDelegate?

    /// Whether this container is currently bubbling gestures to parent
    private var isBubblingToParent: Bool = false

    /// The stage layouts this container displays
    private var stages: [Stage] = []

    /// Current active stage index
    public private(set) var activeStageIndex: Int = 0

    /// View controllers for each stage (lazily created)
    private var stageViewControllers: [UUID: NSViewController] = [:]

    /// The clip view that contains all stage views
    private var clipView: NSView!

    /// The content view that slides horizontally
    private var contentView: NSView!

    /// Individual stage container views
    private var stageViews: [NSView] = []

    /// Constraint for contentView leading position (for sliding animation)
    private var contentViewLeadingConstraint: NSLayoutConstraint?

    /// Constraint for contentView width (multiplied by stage count)
    private var contentViewWidthConstraint: NSLayoutConstraint?

    // MARK: - Gesture State

    /// Current offset during swipe (0 = centered on active stage)
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
    public var displayMode: StageDisplayMode = .tabs {
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
        // Update all stage view controllers
        for (_, viewController) in stageViewControllers {
            updateTabGroupDisplayMode(in: viewController, to: displayMode)
        }
    }

    /// Recursively update display mode in a view controller hierarchy
    private func updateTabGroupDisplayMode(in viewController: NSViewController, to mode: StageDisplayMode) {
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

    /// Local event monitor for intercepting horizontal scroll gestures
    private var scrollEventMonitor: Any?

    /// Whether we're intercepting a horizontal gesture via event monitor
    private var isInterceptingHorizontalGesture = false

    deinit {
        stopDisplayLink()
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupScrollEventMonitor()
        } else {
            if let monitor = scrollEventMonitor {
                NSEvent.removeMonitor(monitor)
                scrollEventMonitor = nil
            }
        }
    }

    /// Set up local event monitor to intercept horizontal scroll gestures before child views
    private func setupScrollEventMonitor() {
        guard scrollEventMonitor == nil else { return }

        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }

            // Only intercept if event is within our bounds
            guard let eventWindow = event.window, eventWindow == self.window else { return event }
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInSelf) else { return event }

            // VERSION 3 FIX: Check if there's a nested DockStageContainerView under the mouse
            // If so, let the event pass through so the nested container handles it first.
            // The nested container will bubble events up to us when it's at its edge.
            if self.hasNestedContainerAt(point: locationInSelf) {
                // Don't intercept - let the nested container handle it via its own event monitor
                return event
            }

            // Check if this is a gesture event (trackpad, not mouse wheel)
            let isGestureEvent = event.phase != [] || event.momentumPhase != []
            guard isGestureEvent else { return event }

            // On gesture begin, decide if this is horizontal-dominant
            if event.phase == .began {
                let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.5
                self.isInterceptingHorizontalGesture = isHorizontalDominant
            }

            // If intercepting horizontal gesture, process it ourselves
            if self.isInterceptingHorizontalGesture {
                self.scrollWheel(with: event)

                // End interception when gesture ends
                if event.phase == .ended || event.phase == .cancelled ||
                   event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    self.isInterceptingHorizontalGesture = false
                }

                // Return nil to consume the event
                return nil
            }

            // Let vertical gestures pass through
            return event
        }
    }

    /// Check if there's a nested DockStageContainerView at the given point (in self's coordinates)
    /// Returns true if a nested container exists and contains the point
    private func hasNestedContainerAt(point: NSPoint) -> Bool {
        return findNestedContainerAt(point: point, in: self) != nil
    }

    /// Recursively search for a nested DockStageContainerView at the given point
    private func findNestedContainerAt(point: NSPoint, in view: NSView) -> DockStageContainerView? {
        for subview in view.subviews {
            // Convert point to subview's coordinate system
            let pointInSubview = subview.convert(point, from: self)

            // Check if point is within subview bounds
            guard subview.bounds.contains(pointInSubview) else { continue }

            // If this subview is a DockStageContainerView (and not self), we found a nested one
            if let nestedContainer = subview as? DockStageContainerView, nestedContainer !== self {
                return nestedContainer
            }

            // Recursively check subviews
            if let found = findNestedContainerAt(point: point, in: subview) {
                return found
            }
        }
        return nil
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

    /// Set the stages to display
    public func setStages(_ newStages: [Stage], activeIndex: Int) {
        stages = newStages
        activeStageIndex = max(0, min(activeIndex, stages.count - 1))

        rebuildStageViews()
        updateContentPosition(animated: false)
    }

    /// Switch to a specific stage with animation
    public func switchToStage(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < stages.count else { return }

        if animated {
            animateToStage(at: index)
        } else {
            activeStageIndex = index
            updateContentPosition(animated: false)
            delegate?.stageContainer(self, didSwitchTo: activeStageIndex)
        }
    }

    /// Get the view controller for the active stage
    public var activeStageViewController: NSViewController? {
        guard activeStageIndex >= 0 && activeStageIndex < stages.count else { return nil }
        let stageId = stages[activeStageIndex].id
        return stageViewControllers[stageId]
    }

    /// Update a specific stage's layout
    public func updateStageLayout(_ layout: DockLayoutNode, forStageAt index: Int) {
        guard index >= 0 && index < stages.count else { return }

        let stageId = stages[index].id
        stages[index].layout = layout

        // Rebuild the view controller for this stage
        if let existingVC = stageViewControllers[stageId],
           index < stageViews.count {
            // Remove old view
            existingVC.view.removeFromSuperview()

            // Create new view controller
            let newVC = createViewController(for: stages[index].layout)
            stageViewControllers[stageId] = newVC

            // Add to stage view
            let stageView = stageViews[index]
            newVC.view.translatesAutoresizingMaskIntoConstraints = false
            stageView.addSubview(newVC.view)

            NSLayoutConstraint.activate([
                newVC.view.leadingAnchor.constraint(equalTo: stageView.leadingAnchor),
                newVC.view.trailingAnchor.constraint(equalTo: stageView.trailingAnchor),
                newVC.view.topAnchor.constraint(equalTo: stageView.topAnchor),
                newVC.view.bottomAnchor.constraint(equalTo: stageView.bottomAnchor)
            ])
        }
    }

    /// Capture thumbnails for all stages
    public func captureStageThumbnails() -> [NSImage?] {
        var thumbnails: [NSImage?] = []

        for (index, stageView) in stageViews.enumerated() {
            guard index < stages.count else {
                thumbnails.append(nil)
                continue
            }

            // Capture the stage view
            let targetSize = NSSize(width: 112, height: 68) // Fit in thumbnail area

            guard stageView.bounds.width > 0, stageView.bounds.height > 0,
                  let bitmapRep = stageView.bitmapImageRepForCachingDisplay(in: stageView.bounds) else {
                thumbnails.append(nil)
                continue
            }

            stageView.cacheDisplay(in: stageView.bounds, to: bitmapRep)

            let image = NSImage(size: targetSize)
            image.lockFocus()

            // Draw scaled to fit
            let sourceSize = stageView.bounds.size
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

    // MARK: - Stage View Management

    private func rebuildStageViews() {
        // Remove old views
        for view in stageViews {
            view.removeFromSuperview()
        }
        stageViews.removeAll()
        stageViewControllers.removeAll()

        // Remove old width constraint
        if let oldWidthConstraint = contentViewWidthConstraint {
            oldWidthConstraint.isActive = false
            contentViewWidthConstraint = nil
        }

        guard !stages.isEmpty else {
            return
        }

        // Create new stage views - use frame-based layout for horizontal positioning
        for (_, stage) in stages.enumerated() {
            let stageView = NSView()
            stageView.wantsLayer = true
            // Use frame-based layout for stage views (positioned in layout())
            stageView.translatesAutoresizingMaskIntoConstraints = true
            contentView.addSubview(stageView)
            stageViews.append(stageView)

            // Create view controller for stage layout
            let vc = createViewController(for: stage.layout)
            stageViewControllers[stage.id] = vc

            // VC view uses auto layout to fill its container
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            stageView.addSubview(vc.view)

            NSLayoutConstraint.activate([
                vc.view.leadingAnchor.constraint(equalTo: stageView.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: stageView.trailingAnchor),
                vc.view.topAnchor.constraint(equalTo: stageView.topAnchor),
                vc.view.bottomAnchor.constraint(equalTo: stageView.bottomAnchor)
            ])
        }

        // Set content view width (track the constraint so we can remove it later)
        contentViewWidthConstraint = contentView.widthAnchor.constraint(equalTo: clipView.widthAnchor, multiplier: CGFloat(stages.count))
        contentViewWidthConstraint?.isActive = true

        // Reset leading constraint for new stage count
        contentViewLeadingConstraint?.constant = -CGFloat(activeStageIndex) * clipView.bounds.width

        // Force layout
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()

        // Position stage views using frame-based layout
        let stageWidth = clipView.bounds.width
        let stageHeight = clipView.bounds.height

        for (index, stageView) in stageViews.enumerated() {
            stageView.frame = NSRect(
                x: CGFloat(index) * stageWidth,
                y: 0,
                width: stageWidth,
                height: stageHeight
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
            // Pass swipe gesture delegate for nested stage hosts (Version 3)
            splitVC.swipeGestureDelegate = self
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: createTabGroupNode(from: tabGroupNode))
            tabGroupVC.delegate = self
            return tabGroupVC

        case .stageHost(let stageHostNode):
            // Create a nested stage host view controller (Version 3 feature)
            let hostVC = DockStageHostViewController(
                layoutNode: stageHostNode,
                panelProvider: { [weak self] id in
                    self?.delegate?.stageContainer(self!, panelForId: id)
                }
            )
            // Connect gesture bubbling - nested host bubbles to this container
            hostVC.swipeGestureDelegate = self
            return hostVC
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
            if let panel = delegate?.stageContainer(self, panelForId: tabState.id) {
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
        case .stageHost(let stageHostNode):
            return .stageHost(StageHostNode(from: stageHostNode))
        }
    }

    // MARK: - Content Positioning

    private func updateContentPosition(animated: Bool) {
        let stageWidth = clipView.bounds.width > 0 ? clipView.bounds.width : bounds.width
        let targetX = -CGFloat(activeStageIndex) * stageWidth + swipeOffset

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

    /// Position threshold for drag-based switching (fraction of stage width)
    /// Apple uses 50% (halfway) for slow drags
    private let dragPositionThreshold: CGFloat = 0.5

    // MARK: - Scroll Event Handling (Two-Finger Swipe)
    //
    // Manual implementation with momentum support.
    // Slow motion only affects spring animation - gesture input is always real-time.
    //
    // NESTED DESKTOP GESTURE BUBBLING (Version 3):
    // When this container is at the edge of its stages and the user continues
    // swiping in that direction, the gesture "bubbles up" to the parent stage host.
    // This allows nested stage hosts to work naturally - the innermost one handles
    // gestures first, then passes them up the hierarchy when at the edge.

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
            isBubblingToParent = false
            stopSpringAnimation()
            // Notify delegate immediately so host can pause expensive rendering
            delegate?.stageContainerDidBeginSwipeGesture(self)
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
            let stageWidth = bounds.width
            guard stageWidth > 0 else { return }

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

            // Check for gesture bubbling to parent (Version 3 nested stages)
            // If we're at an edge and user is swiping beyond, bubble to parent
            let isAtLeftEdge = activeStageIndex == 0 && gestureAmount >= 0
            let isAtRightEdge = activeStageIndex == stages.count - 1 && gestureAmount <= 0
            let swipingBeyondLeft = isAtLeftEdge && deltaX > 0
            let swipingBeyondRight = isAtRightEdge && deltaX < 0

            if (swipingBeyondLeft || swipingBeyondRight) && swipeGestureDelegate != nil {
                // We're at an edge and swiping beyond - bubble to parent
                if !isBubblingToParent {
                    // First time bubbling - reset our visual state to edge position
                    isBubblingToParent = true
                    gestureAmount = 0
                    swipeOffset = 0
                    updateContentPosition(animated: false)
                }
                // Pass event to parent
                _ = swipeGestureDelegate?.handleBubbledScrollEvent(event, from: self)
                return
            }

            // If we were bubbling but direction changed back, stop bubbling
            if isBubblingToParent {
                let stoppedBubbling: Bool
                if isAtLeftEdge && deltaX < 0 {
                    stoppedBubbling = true
                } else if isAtRightEdge && deltaX > 0 {
                    stoppedBubbling = true
                } else {
                    stoppedBubbling = false
                }

                if stoppedBubbling {
                    isBubblingToParent = false
                    swipeGestureDelegate?.nestedContainerDidEndGesture(self)
                    // Continue processing this event locally
                }
            }

            // NO time scaling on input - gesture feels normal
            gestureAmount += deltaX / stageWidth

            // Calculate visual offset with rubber band effect at edges
            let maxLeft = CGFloat(activeStageIndex)
            let maxRight = CGFloat(stages.count - 1 - activeStageIndex)

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
            swipeOffset = visualAmount * stageWidth
            let targetX = -CGFloat(activeStageIndex) * stageWidth + swipeOffset
            contentViewLeadingConstraint?.constant = targetX

            // Update header indicator
            updateIndicatorForGestureAmount(gestureAmount)
        }

        // Handle momentum end
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            isGestureActive = false
            if isBubblingToParent {
                isBubblingToParent = false
                swipeGestureDelegate?.nestedContainerDidEndGesture(self)
            }
            finalizeGesture()
        }

        // Handle case where gesture ends without momentum
        if event.phase == .ended && event.momentumPhase == [] {
            // Give a tiny window for momentum to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self = self, self.isGestureActive else { return }
                // Still active means no momentum came
                self.isGestureActive = false
                if self.isBubblingToParent {
                    self.isBubblingToParent = false
                    self.swipeGestureDelegate?.nestedContainerDidEndGesture(self)
                }
                self.finalizeGesture()
            }
        }
    }

    private func updateIndicatorForGestureAmount(_ gestureAmount: CGFloat) {
        // Indicator uses POSITION-ONLY during gesture (no velocity)
        // This prevents flickering when velocity fluctuates during slow swipes
        // Velocity is only considered at finalization (when user releases)
        let target: Int

        if gestureAmount >= dragPositionThreshold && activeStageIndex > 0 {
            target = activeStageIndex - 1
        } else if gestureAmount <= -dragPositionThreshold && activeStageIndex < stages.count - 1 {
            target = activeStageIndex + 1
        } else {
            target = activeStageIndex
        }

        if target != lastIndicatorTarget {
            lastIndicatorTarget = target
            delegate?.stageContainer(self, didBeginSwipingTo: target)
        }
    }

    private func finalizeGesture() {
        lastIndicatorTarget = -1

        // Calculate bounds for gesture amount
        let maxLeft = CGFloat(activeStageIndex)
        let maxRight = CGFloat(stages.count - 1 - activeStageIndex)

        // Clamp gestureAmount to valid bounds for decision making
        // (rubber band overshoot shouldn't trigger stage switches)
        let clampedAmount = max(-maxRight, min(maxLeft, gestureAmount))

        // Check velocity-based switching (flick) - takes priority
        let velocityBasedSwitch = abs(gestureVelocity) > flickVelocityThreshold

        // Determine target based on velocity OR position
        if velocityBasedSwitch {
            // Flick: velocity determines direction
            if gestureVelocity > 0 && activeStageIndex > 0 {
                activeStageIndex -= 1
                gestureAmount -= 1.0
            } else if gestureVelocity < 0 && activeStageIndex < stages.count - 1 {
                activeStageIndex += 1
                gestureAmount += 1.0
            }
        } else if clampedAmount >= dragPositionThreshold && activeStageIndex > 0 {
            // Drag: position determines switch
            activeStageIndex -= 1
            gestureAmount -= 1.0
        } else if clampedAmount <= -dragPositionThreshold && activeStageIndex < stages.count - 1 {
            activeStageIndex += 1
            gestureAmount += 1.0
        }

        // Calculate visual offset (with rubber band effect if past edges)
        let visualAmount: CGFloat
        let newMaxLeft = CGFloat(activeStageIndex)
        let newMaxRight = CGFloat(stages.count - 1 - activeStageIndex)

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
        animateToStage(at: activeStageIndex)
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

    private func animateToStage(at index: Int) {
        let targetPosition: CGFloat = 0
        let oldIndex = activeStageIndex

        // Adjust swipeOffset to maintain visual continuity when changing stage index
        // Position formula: targetX = -activeStageIndex * width + swipeOffset
        // To keep same visual position after index change:
        // -oldIndex * width + swipeOffset = -index * width + newSwipeOffset
        // newSwipeOffset = swipeOffset + (index - oldIndex) * width
        if index != oldIndex {
            swipeOffset += CGFloat(index - oldIndex) * bounds.width
        }

        let currentPosition = swipeOffset
        activeStageIndex = index

        // IMMEDIATELY notify delegate of committed switch
        // This updates the header indicator without waiting for animation to complete
        // Provides faster visual feedback to the user
        delegate?.stageContainer(self, didSwitchTo: index)

        // If we're already at target, just snap
        if abs(currentPosition - targetPosition) < 1 {
            swipeOffset = 0
            updateContentPosition(animated: false)
            // Notify delegate that swipe gesture is complete - host can resume rendering
            delegate?.stageContainerDidEndSwipeGesture(self)
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
            let container = Unmanaged<DockStageContainerView>.fromOpaque(displayLinkContext!).takeUnretainedValue()

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
        let stageWidth = clipView.bounds.width > 0 ? clipView.bounds.width : bounds.width
        let targetX = -CGFloat(activeStageIndex) * stageWidth + swipeOffset
        contentViewLeadingConstraint?.constant = targetX

        // Check if animation is done
        if abs(state.position - state.target) < 0.5 && abs(state.velocity) < 10 {
            // Snap to final position
            swipeOffset = 0
            updateContentPosition(animated: false)
            springState = nil
            stopDisplayLink()
            // Note: didSwitchTo already called at animation start for faster feedback
            // Notify delegate that swipe gesture is complete - host can resume rendering
            delegate?.stageContainerDidEndSwipeGesture(self)
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

extension DockStageContainerView: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        delegate?.stageContainer(self, didReceiveTab: tabInfo, in: tabGroup, at: index)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachTab tab: DockTab, at screenPoint: NSPoint) {
        delegate?.stageContainer(self, wantsToDetachTab: tab, from: tabGroup, at: screenPoint)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab) {
        delegate?.stageContainer(self, wantsToSplit: direction, withTab: tab, in: tabGroup)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastTab: Bool) {
        // Handle last tab closure - could remove the tab group from layout
    }

    public func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {
        // Handle new tab request - could create a new panel
    }
}

// MARK: - SwipeGestureDelegate (Version 3: Nested Stage Support)

extension DockStageContainerView: SwipeGestureDelegate {
    /// Handle a scroll event bubbled up from a nested stage container.
    /// The nested container is at the edge of its stages and cannot handle the gesture.
    public func handleBubbledScrollEvent(_ event: NSEvent, from container: DockStageContainerView) -> Bool {
        // Process the event as if it came directly to us
        // We need to simulate the gesture lifecycle since the nested container
        // is forwarding mid-gesture events

        // Handle gesture begin if needed
        if event.phase == .began || (!isGestureActive && (event.phase == .changed || event.momentumPhase == .changed)) {
            isGestureActive = true
            isBubblingToParent = false
            stopSpringAnimation()
            delegate?.stageContainerDidBeginSwipeGesture(self)
            gestureVelocity = 0
            lastScrollTime = CACurrentMediaTime()
        }

        guard isGestureActive && springState == nil else {
            return false
        }

        // Apply scroll delta
        if event.phase == .changed || event.momentumPhase == .changed {
            let stageWidth = bounds.width
            guard stageWidth > 0 else { return false }

            let deltaX = event.scrollingDeltaX

            // Track velocity
            if event.phase == .changed {
                let currentTime = CACurrentMediaTime()
                let dt = currentTime - lastScrollTime
                if dt > 0 {
                    let instantVelocity = deltaX / CGFloat(dt)
                    gestureVelocity = gestureVelocity * 0.7 + instantVelocity * 0.3
                }
                lastScrollTime = currentTime
            }

            // Check if we also need to bubble (recursive nesting)
            let isAtLeftEdge = activeStageIndex == 0 && gestureAmount >= 0
            let isAtRightEdge = activeStageIndex == stages.count - 1 && gestureAmount <= 0
            let swipingBeyondLeft = isAtLeftEdge && deltaX > 0
            let swipingBeyondRight = isAtRightEdge && deltaX < 0

            if (swipingBeyondLeft || swipingBeyondRight) && swipeGestureDelegate != nil {
                if !isBubblingToParent {
                    isBubblingToParent = true
                    gestureAmount = 0
                    swipeOffset = 0
                    updateContentPosition(animated: false)
                }
                return swipeGestureDelegate?.handleBubbledScrollEvent(event, from: self) ?? false
            }

            // Process locally
            gestureAmount += deltaX / stageWidth

            let maxLeft = CGFloat(activeStageIndex)
            let maxRight = CGFloat(stages.count - 1 - activeStageIndex)

            let visualAmount: CGFloat
            if gestureAmount > maxLeft {
                let overshoot = gestureAmount - maxLeft
                visualAmount = maxLeft + rubberBand(overshoot, dimension: 1.0)
            } else if gestureAmount < -maxRight {
                let overshoot = -maxRight - gestureAmount
                visualAmount = -maxRight - rubberBand(overshoot, dimension: 1.0)
            } else {
                visualAmount = gestureAmount
            }

            swipeOffset = visualAmount * stageWidth
            let targetX = -CGFloat(activeStageIndex) * stageWidth + swipeOffset
            contentViewLeadingConstraint?.constant = targetX

            updateIndicatorForGestureAmount(gestureAmount)
        }

        return true
    }

    /// Called when a nested container's gesture ends.
    public func nestedContainerDidEndGesture(_ container: DockStageContainerView) {
        // Finalize our gesture state
        guard isGestureActive else { return }
        isGestureActive = false
        if isBubblingToParent {
            isBubblingToParent = false
            swipeGestureDelegate?.nestedContainerDidEndGesture(self)
        }
        finalizeGesture()
    }
}
