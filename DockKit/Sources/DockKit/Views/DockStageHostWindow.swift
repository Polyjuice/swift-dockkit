import AppKit

/// Delegate for stage host window events.
///
/// All `didRequest*` methods are **proposals**: DockKit detects a user gesture and asks the
/// delegate what to do. Default implementations apply the change directly, which is suitable
/// for demos. In production, the delegate routes through an external controller.
public protocol DockStageHostWindowDelegate: AnyObject {
    /// Called when the window is closed
    func stageHostWindow(_ window: DockStageHostWindow, didClose: Void)

    /// Called when the active stage changes
    func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int)

    /// Called before a panel is torn off. Return false to prevent tearing.
    func stageHostWindow(_ window: DockStageHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool

    /// Called after a panel was torn off into a new window
    func stageHostWindow(_ window: DockStageHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow)

    // MARK: - Proposals (UI-initiated actions)

    /// User dropped a tab into a group. The delegate should apply the move or ignore to cancel.
    func stageHostWindow(_ window: DockStageHostWindow, didRequestMovePanel panelId: UUID,
                         toGroup targetGroupId: UUID, at index: Int)

    /// User dropped a tab on a split zone. The delegate should apply the split or ignore to cancel.
    func stageHostWindow(_ window: DockStageHostWindow, didRequestSplit direction: DockSplitDirection,
                         withPanelId panelId: UUID, in groupId: UUID)

    /// User clicked the close button on a stage. The delegate should handle cleanup and update state.
    func stageHostWindow(_ window: DockStageHostWindow, didRequestCloseStageAt index: Int)

    /// User clicked the close button on a tab. The delegate should handle cleanup and update state.
    func stageHostWindow(_ window: DockStageHostWindow, didRequestClosePanel panelId: UUID)

    /// User clicked the "+" button on the stage header. The delegate should create a new stage.
    func stageHostWindowDidRequestNewStage(_ window: DockStageHostWindow)

    /// User clicked the "+" button in a tab bar. The delegate should create a new panel.
    func stageHostWindow(_ window: DockStageHostWindow, didRequestNewPanelIn groupId: UUID)

    /// Called during drag to check if a panel can be dropped in a target group/zone.
    /// Must be fast (called on every mouse move). Return false to hide the drop zone.
    func stageHostWindow(_ window: DockStageHostWindow, canMovePanel panelId: UUID,
                         toGroup targetGroupId: UUID, at zone: DockDropZone) -> Bool

    /// Splitter proportions changed (user dragged a divider). High-frequency — debounce before syncing.
    func stageHostWindowDidUpdateProportions(_ window: DockStageHostWindow)

    /// Tab was reordered within its group.
    func stageHostWindowDidReorderTab(_ window: DockStageHostWindow)

    // MARK: - Legacy (kept for backward compatibility)

    /// Called when a tab is received via drag. Deprecated — use didRequestMovePanel instead.
    func stageHostWindow(_ window: DockStageHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called when a split is requested. Deprecated — use didRequestSplit instead.
    func stageHostWindow(_ window: DockStageHostWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController)
}

/// Default implementations — apply changes directly for demos and simple apps.
public extension DockStageHostWindowDelegate {
    func stageHostWindow(_ window: DockStageHostWindow, didClose: Void) {}
    func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int) {}
    func stageHostWindow(_ window: DockStageHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool { true }
    func stageHostWindow(_ window: DockStageHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow) {}

    func stageHostWindow(_ window: DockStageHostWindow, didRequestMovePanel panelId: UUID, toGroup targetGroupId: UUID, at index: Int) {
        window.controller.handleChildReceived(panelId, in: targetGroupId, at: index)
    }

    func stageHostWindow(_ window: DockStageHostWindow, didRequestSplit direction: DockSplitDirection, withPanelId panelId: UUID, in groupId: UUID) {
        window.controller.handleSplit(groupId: groupId, direction: direction, withPanelId: panelId)
    }

    func stageHostWindow(_ window: DockStageHostWindow, didRequestCloseStageAt index: Int) {
        window.controller.removeStage(at: index)
    }

    func stageHostWindow(_ window: DockStageHostWindow, didRequestClosePanel panelId: UUID) {
        window.controller.handleChildClosed(panelId)
    }

    func stageHostWindowDidRequestNewStage(_ window: DockStageHostWindow) {
        window.addNewStage()
    }

    func stageHostWindow(_ window: DockStageHostWindow, didRequestNewPanelIn groupId: UUID) {
        // No-op — host app must implement to create panels
    }

    func stageHostWindow(_ window: DockStageHostWindow, canMovePanel panelId: UUID, toGroup targetGroupId: UUID, at zone: DockDropZone) -> Bool {
        true
    }

    func stageHostWindowDidUpdateProportions(_ window: DockStageHostWindow) {}
    func stageHostWindowDidReorderTab(_ window: DockStageHostWindow) {}

    // Legacy defaults
    func stageHostWindow(_ window: DockStageHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func stageHostWindow(_ window: DockStageHostWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {}
}

/// A window that hosts multiple stages with swipe gesture navigation
///
/// Structure:
/// ┌─────────────────────────────────────────┐
/// │  Stage Header (selection UI)          │  ← Fixed height, shows stage icons/titles
/// ├─────────────────────────────────────────┤
/// │                                         │
/// │       Stage Container                 │  ← Shows active stage's layout
/// │       (animated transitions)            │
/// │                                         │
/// └─────────────────────────────────────────┘
///
/// Accepts a `Panel` with `.group(PanelGroup)` content where `style == .stages`.
/// The panel should have `isTopLevelWindow == true` and a `frame`.
public class DockStageHostWindow: NSWindow {

    // MARK: - Properties

    /// Window ID for tracking
    public let windowId: UUID

    /// Controller that manages state and operations
    public let controller: StageHostController

    /// Reference to the layout manager
    public weak var layoutManager: DockLayoutManager?

    /// Delegate for window events
    public weak var stageDelegate: DockStageHostWindowDelegate?

    /// Flag to suppress auto-close during reconciliation
    internal var suppressAutoClose: Bool = false

    // MARK: - Forwarding Properties

    /// The root panel (forwarded from controller)
    public var stageHostPanel: Panel { controller.panel }

    /// Panel provider for looking up panels by ID (forwarded to controller)
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        get { controller.panelProvider }
        set { controller.panelProvider = newValue }
    }

    /// Group style for tabs and stage indicators
    public var groupStyle: PanelGroupStyle {
        get { controller.groupStyle }
        set {
            controller.groupStyle = newValue
            headerView?.groupStyle = newValue
            containerView?.groupStyle = newValue
        }
    }

    /// Apply group style to header and container views during initialization
    private func applyGroupStyle(_ style: PanelGroupStyle) {
        headerView?.groupStyle = style
        containerView?.groupStyle = style

        let useThumbnails = (style == .thumbnails)
        let headerHeight = headerView.setThumbnailMode(useThumbnails)
        headerHeightConstraint?.constant = headerHeight
    }

    /// Check if window is empty (all stages have no panels)
    public var isEmpty: Bool { controller.isEmpty }

    // MARK: - Child Window Tracking

    /// Child windows spawned from panel tearing
    public private(set) var spawnedWindows: [DockStageHostWindow] = []

    /// Parent window (if this window was spawned from tearing)
    public private(set) weak var spawnerWindow: DockStageHostWindow?

    // MARK: - Views

    /// The header view showing stage tabs
    private var headerView: DockStageHeaderView!

    /// The container view holding stage content
    private var containerView: DockStageContainerView!

    /// Content view that holds header + container
    private var rootView: NSView!

    /// Header height constraint (changes in thumbnail mode)
    private var headerHeightConstraint: NSLayoutConstraint!

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        panel: Panel,
        frame: NSRect,
        layoutManager: DockLayoutManager? = nil,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.windowId = id
        self.controller = StageHostController(panel: panel)
        self.layoutManager = layoutManager

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        controller.panelProvider = panelProvider
        controller.delegate = self

        setupWindow()
        setupViews()
        applyGroupStyle(panel.group?.style ?? .stages)
        loadStages()
    }

    /// Convenience initializer for creating a window with a single panel
    /// Used when tearing a panel off to create a new stage host
    public convenience init(
        singlePanel panel: any DockablePanel,
        at screenPoint: NSPoint,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        // Create a content panel for the dockable panel
        let contentPanel = Panel.contentPanel(
            id: panel.panelId,
            title: panel.panelTitle,
            iconName: panel.panelIcon != nil ? "doc" : nil
        )

        // Create a stage containing a tabs group with the content panel
        let stagePanel = Panel(
            title: panel.panelTitle,
            content: .group(PanelGroup(
                children: [contentPanel],
                activeIndex: 0,
                style: .tabs
            ))
        )

        // Create frame centered at screen point
        let size = NSSize(width: 600, height: 400)
        let frame = NSRect(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        // Create the root stages panel
        let rootPanel = Panel(
            content: .group(PanelGroup(
                children: [stagePanel],
                activeIndex: 0,
                style: .stages
            )),
            isTopLevelWindow: true,
            frame: frame,
            isFullScreen: false
        )

        self.init(
            panel: rootPanel,
            frame: frame,
            panelProvider: panelProvider
        )
    }

    // MARK: - Setup

    private func setupWindow() {
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none

        // Extend content under title bar - header view becomes the title bar area
        styleMask.insert(.fullSizeContentView)

        // Enable full screen support
        collectionBehavior = [.fullScreenPrimary, .managed]

        // No toolbar - the header view contains all controls
        self.toolbar = nil

        minSize = NSSize(width: 400, height: 300)

        updateTitle()
    }

    private func setupViews() {
        // Root view
        rootView = NSView()
        rootView.wantsLayer = true
        contentView = rootView

        // Header view
        headerView = DockStageHeaderView()
        headerView.delegate = self
        headerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(headerView)

        // Container view
        containerView = DockStageContainerView()
        containerView.delegate = self
        containerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(containerView)

        // Default to normal tab mode height
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockStageHeaderView.headerHeight)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            headerHeightConstraint,

            containerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            containerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func loadStages() {
        headerView.setStages(controller.stages, activeIndex: controller.activeStageIndex)
        containerView.setStages(controller.stages, activeIndex: controller.activeStageIndex)

        // Apply header style from model
        if controller.effectiveHeaderStyle == .thumbnails {
            let newHeight = headerView.setThumbnailMode(true)
            headerHeightConstraint.constant = newHeight
        }

        // Capture thumbnails after a brief delay (for initial thumbnail mode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let thumbnails = self.containerView.captureStageThumbnails()
            self.headerView.setThumbnails(thumbnails)
        }
    }

    // MARK: - Public API

    /// Switch to a specific stage
    public func switchToStage(at index: Int, animated: Bool = true) {
        controller.switchToStage(at: index)
        containerView.switchToStage(at: index, animated: animated)
        headerView.setActiveIndex(index)
        updateTitle()
    }

    /// Update the root panel (for reconciliation)
    public func updateStageHostPanel(_ newPanel: Panel) {
        let stageCountChanged = controller.stages.count != (newPanel.group?.children.count ?? 0)
        controller.updatePanel(newPanel)

        if stageCountChanged && (newPanel.group?.style == .thumbnails) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    /// Check if window contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        controller.containsPanel(panelId)
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Panel {
        controller.addNewStage(title: title, iconName: iconName)
    }

    // MARK: - Title

    public func updateTitle() {
        let stages = controller.stages
        let activeIndex = controller.activeStageIndex
        guard activeIndex >= 0 && activeIndex < stages.count else {
            title = "Stage"
            return
        }

        let stage = stages[activeIndex]
        if let stageTitle = stage.title {
            title = stageTitle
        } else {
            title = "Stage \(activeIndex + 1)"
        }
    }

    // MARK: - Panel Removal

    /// Remove a panel from any stage in this window
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        controller.removePanel(panelId)
    }

    // MARK: - Child Window Management

    /// Add a spawned child window (called internally during tearing)
    private func addSpawnedWindow(_ child: DockStageHostWindow) {
        spawnedWindows.append(child)
        child.spawnerWindow = self
    }

    /// Remove a spawned child window (called when child closes)
    internal func removeSpawnedWindow(_ child: DockStageHostWindow) {
        spawnedWindows.removeAll { $0.windowId == child.windowId }
    }

    // MARK: - NSWindow Overrides

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }


    /// Toggle slow motion for debugging swipe gestures
    public var slowMotionEnabled: Bool {
        get { containerView.slowMotionEnabled }
        set { containerView.slowMotionEnabled = newValue }
    }

    /// Toggle thumbnail mode for all tab groups
    public var thumbnailModeEnabled: Bool {
        get { containerView.thumbnailModeEnabled }
        set { containerView.thumbnailModeEnabled = newValue }
    }

    /// Whether to show debug controls (Thumbs/Slow toggles) in the header
    public var showDebugControls: Bool {
        get { headerView?.showDebugControls ?? true }
        set { headerView?.showDebugControls = newValue }
    }

    /// Set custom trailing items (buttons/controls) in the stage header
    /// These appear to the right of the stage thumbnails/tabs
    public func setHeaderTrailingItems(_ views: [NSView]) {
        headerView?.setTrailingItems(views)
    }

    /// Add a single trailing item to the stage header
    public func addHeaderTrailingItem(_ view: NSView) {
        headerView?.addTrailingItem(view)
    }

    /// Remove all custom trailing items from the stage header
    public func clearHeaderTrailingItems() {
        headerView?.clearTrailingItems()
    }

    public override func close() {
        // Remove from spawner's child tracking
        spawnerWindow?.removeSpawnedWindow(self)

        // Close all spawned child windows
        for child in spawnedWindows {
            child.close()
        }
        spawnedWindows.removeAll()

        stageDelegate?.stageHostWindow(self, didClose: ())
        layoutManager?.windowDidClose(self)
        super.close()
    }
}

// MARK: - DockStageHeaderViewDelegate

extension DockStageHostWindow: DockStageHeaderViewDelegate {
    public func stageHeader(_ header: DockStageHeaderView, didSelectStageAt index: Int) {
        switchToStage(at: index, animated: true)
        stageDelegate?.stageHostWindow(self, didSwitchToStageAt: index)
    }

    public func stageHeader(_ header: DockStageHeaderView, didToggleSlowMotion enabled: Bool) {
        containerView.slowMotionEnabled = enabled
    }

    public func stageHeader(_ header: DockStageHeaderView, didToggleThumbnailMode enabled: Bool) {
        // Propagate to tab groups so they switch between text tabs and thumbnail buttons
        self.groupStyle = enabled ? .thumbnails : .tabs

        // Set thumbnail mode on header and get new height
        let newHeight = headerView.setThumbnailMode(enabled)

        // Capture and set thumbnails if enabling
        if enabled {
            let thumbnails = containerView.captureStageThumbnails()
            headerView.setThumbnails(thumbnails)
        }

        // Animate header height change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            headerHeightConstraint.constant = newHeight
            rootView.layoutSubtreeIfNeeded()
        }
    }

    public func stageHeaderDidRequestNewStage(_ header: DockStageHeaderView) {
        stageDelegate?.stageHostWindowDidRequestNewStage(self)
    }

    public func stageHeader(_ header: DockStageHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onStageAt targetIndex: Int) {
        controller.handleChildMovedToStage(tabInfo.tabId, targetStageIndex: targetIndex)
    }

    public func stageHeader(_ header: DockStageHeaderView, didCloseStageAt index: Int) {
        stageDelegate?.stageHostWindow(self, didRequestCloseStageAt: index)
    }
}

// MARK: - DockStageContainerViewDelegate

extension DockStageHostWindow: DockStageContainerViewDelegate {
    public func stageContainerDidBeginSwipeGesture(_ container: DockStageContainerView) {
        // Optional: notify delegate
    }

    public func stageContainerDidEndSwipeGesture(_ container: DockStageContainerView) {
        // Optional: notify delegate
    }

    public func stageContainer(_ container: DockStageContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightStage(at: index)
    }

    public func stageContainer(_ container: DockStageContainerView, didSwitchTo index: Int) {
        controller.completeStageSwitch(to: index)
        headerView.clearSwipeHighlight()
        headerView.setActiveIndex(index)
        updateTitle()
        stageDelegate?.stageHostWindow(self, didSwitchToStageAt: index)
    }

    public func stageContainer(_ container: DockStageContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        panelProvider?(id)
    }

    public func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Route through proposal — delegate decides whether to apply
        if let stageDelegate = stageDelegate {
            stageDelegate.stageHostWindow(self, didRequestMovePanel: tabInfo.tabId,
                                          toGroup: tabGroup.panel.id, at: index)
        } else {
            // Default: apply directly
            controller.handleChildReceived(tabInfo.tabId, in: tabGroup.panel.id, at: index)
        }
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToDetachPanel panelId: UUID, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        guard let panel = panelProvider?(panelId) else { return }

        let allowTear = stageDelegate?.stageHostWindow(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        // Use controller's handleDetach which removes the panel from layout
        controller.handleDetach(panelId: panelId, at: screenPoint)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {
        // Route through proposal — delegate decides whether to apply
        if let stageDelegate = stageDelegate {
            stageDelegate.stageHostWindow(self, didRequestSplit: direction,
                                          withPanelId: panelId, in: tabGroup.panel.id)
        } else {
            // Default: apply directly
            controller.handleSplit(groupId: tabGroup.panel.id, direction: direction, withPanelId: panelId)
        }
    }

    public func stageContainer(_ container: DockStageContainerView, didClosePanel panelId: UUID) {
        stageDelegate?.stageHostWindow(self, didRequestClosePanel: panelId)
    }

    public func stageContainer(_ container: DockStageContainerView, didRequestNewPanelIn groupId: UUID) {
        stageDelegate?.stageHostWindow(self, didRequestNewPanelIn: groupId)
    }

    public func stageContainer(_ container: DockStageContainerView, canAcceptPanel panelId: UUID, in tabGroup: DockTabGroupViewController, at zone: DockDropZone) -> Bool {
        stageDelegate?.stageHostWindow(self, canMovePanel: panelId, toGroup: tabGroup.panel.id, at: zone) ?? true
    }

    public func stageContainer(_ container: DockStageContainerView, didUpdateProportions proportions: [CGFloat], forGroup groupId: UUID) {
        controller.updateProportions(groupId: groupId, proportions: proportions)
        stageDelegate?.stageHostWindowDidUpdateProportions(self)
    }

    public func stageContainerDidReorderTab(_ container: DockStageContainerView) {
        stageDelegate?.stageHostWindowDidReorderTab(self)
    }
}

// MARK: - StageHostControllerDelegate

extension DockStageHostWindow: StageHostControllerDelegate {
    public func controller(_ controller: StageHostController, didUpdateLayout layout: Panel, forStageAt index: Int) {
        containerView.updateStageLayout(layout, forStageAt: index)

        // Recapture thumbnails after layout changes
        if controller.groupStyle == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    public func controller(_ controller: StageHostController, didUpdateStages stages: [Panel], activeIndex: Int) {
        headerView.setStages(stages, activeIndex: activeIndex)
        containerView.setStages(stages, activeIndex: activeIndex)
        updateTitle()

        if controller.groupStyle == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    public func controller(_ controller: StageHostController, didSwitchToStage index: Int) {
        stageDelegate?.stageHostWindow(self, didSwitchToStageAt: index)
    }

    public func controller(_ controller: StageHostController, didDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        // Create new stage host window with the panel
        let childWindow = DockStageHostWindow(
            singlePanel: panel,
            at: screenPoint,
            panelProvider: panelProvider
        )

        // Track as spawned child
        addSpawnedWindow(childWindow)

        // Show the new window
        childWindow.makeKeyAndOrderFront(nil)

        // Notify panel it's now in a floating window
        panel.panelDidDock(at: .floating)

        // Notify delegate
        stageDelegate?.stageHostWindow(self, didTearPanel: panel, to: childWindow)
    }
}
