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

    /// Velocity from last scroll event
    private var swipeVelocity: CGFloat = 0

    /// Whether we're currently in a swipe gesture
    private var isSwipeActive: Bool = false

    /// Display link for spring animation
    private var displayLink: CVDisplayLink?

    /// Spring animation state
    private var springState: SpringState?

    // MARK: - Constants

    /// Minimum velocity to trigger momentum switch
    private let minimumSwitchVelocity: CGFloat = 300

    /// Spring stiffness for bounce back
    private let springStiffness: CGFloat = 300

    /// Spring damping
    private let springDamping: CGFloat = 25

    /// Spring mass
    private let springMass: CGFloat = 1.0

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

    // MARK: - Scroll Event Handling (Two-Finger Swipe)

    public override func scrollWheel(with event: NSEvent) {
        // Only handle horizontal scroll (two-finger horizontal swipe)
        guard event.phase != [] || event.momentumPhase != [] else {
            super.scrollWheel(with: event)
            return
        }

        // Check if this is a horizontal scroll
        let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.5

        if !isHorizontalDominant && !isSwipeActive {
            super.scrollWheel(with: event)
            return
        }

        switch event.phase {
        case .began:
            handleSwipeBegan(event)

        case .changed:
            handleSwipeChanged(event)

        case .ended, .cancelled:
            handleSwipeEnded(event)

        default:
            break
        }
    }

    private func handleSwipeBegan(_ event: NSEvent) {
        isSwipeActive = true

        // Stop any running spring animation but preserve current swipeOffset
        // (swipeOffset is kept in sync by updateSpringAnimation, so it already has the current position)
        stopSpringAnimation()

        // Only reset velocity, not position - fingers pick up from current position
        swipeVelocity = 0
    }

    private func handleSwipeChanged(_ event: NSEvent) {
        guard isSwipeActive else { return }

        // Update offset based on scroll delta
        let delta = event.scrollingDeltaX
        swipeOffset += delta
        swipeVelocity = delta * 60 // Approximate velocity from delta

        // Apply offset to content view
        let targetX = -CGFloat(activeDesktopIndex) * bounds.width + swipeOffset
        contentView.frame.origin.x = targetX

        // Update header indicator based on position threshold only (not velocity)
        // This provides stable feedback during swipe
        let desktopWidth = bounds.width
        if desktopWidth > 0 {
            let offsetInDesktops = swipeOffset / desktopWidth
            if abs(offsetInDesktops) > 0.3 {
                let potentialTarget: Int
                if offsetInDesktops > 0 {
                    potentialTarget = max(0, activeDesktopIndex - 1)
                } else {
                    potentialTarget = min(desktops.count - 1, activeDesktopIndex + 1)
                }
                delegate?.desktopContainer(self, didBeginSwipingTo: potentialTarget)
            } else {
                // Back below threshold - show current desktop's indicator
                delegate?.desktopContainer(self, didBeginSwipingTo: activeDesktopIndex)
            }
        }
    }

    private func handleSwipeEnded(_ event: NSEvent) {
        guard isSwipeActive else { return }
        isSwipeActive = false

        // Calculate target desktop based on position and velocity
        let targetIndex = calculateTargetDesktop()
        animateToDesktop(at: targetIndex)
    }

    private func calculateTargetDesktop() -> Int {
        let desktopWidth = bounds.width
        guard desktopWidth > 0 else { return activeDesktopIndex }

        // Position-based decision
        let offsetInDesktops = swipeOffset / desktopWidth

        // Velocity-based adjustment
        let velocityThreshold = minimumSwitchVelocity

        var target = activeDesktopIndex

        if swipeVelocity > velocityThreshold {
            // Swiping right (going to previous desktop)
            target = activeDesktopIndex - 1
        } else if swipeVelocity < -velocityThreshold {
            // Swiping left (going to next desktop)
            target = activeDesktopIndex + 1
        } else if abs(offsetInDesktops) > 0.15 {
            // Position-based switch
            if offsetInDesktops > 0 {
                target = activeDesktopIndex - 1
            } else {
                target = activeDesktopIndex + 1
            }
        }

        // Clamp to valid range
        return max(0, min(target, desktops.count - 1))
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
        if abs(currentPosition - targetPosition) < 1 && abs(swipeVelocity) < 10 {
            swipeOffset = 0
            updateContentPosition(animated: false)
            if oldIndex != index {
                delegate?.desktopContainer(self, didSwitchTo: index)
            }
            return
        }

        // Start spring animation
        springState = SpringState(
            position: currentPosition,
            velocity: swipeVelocity,
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

        let dt: CGFloat = 1.0 / 60.0

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

        // Update content position
        if !isSwipeActive && springState == nil {
            updateContentPosition(animated: false)
        }
    }
}
