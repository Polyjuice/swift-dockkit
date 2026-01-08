import AppKit

/// Delegate for stage host window events
public protocol DockStageHostWindowDelegate: AnyObject {
    /// Called when the window is closed
    func stageHostWindow(_ window: DockStageHostWindow, didClose: Void)

    /// Called when the active stage changes
    func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int)

    /// Called when a tab is received via drag
    func stageHostWindow(_ window: DockStageHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called before a panel is torn off. Return false to prevent tearing.
    func stageHostWindow(_ window: DockStageHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool

    /// Called after a panel was torn off into a new window
    func stageHostWindow(_ window: DockStageHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow)

    /// Called when a split is requested
    func stageHostWindow(_ window: DockStageHostWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockStageHostWindowDelegate {
    func stageHostWindow(_ window: DockStageHostWindow, didClose: Void) {}
    func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int) {}
    func stageHostWindow(_ window: DockStageHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func stageHostWindow(_ window: DockStageHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool { true }
    func stageHostWindow(_ window: DockStageHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow) {}
    func stageHostWindow(_ window: DockStageHostWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A window that hosts multiple stages with swipe gesture navigation
/// Structure:
/// ┌─────────────────────────────────────────┐
/// │  Stage Header (selection UI)          │  ← Fixed height, shows stage icons/titles
/// ├─────────────────────────────────────────┤
/// │                                         │
/// │       Stage Container                 │  ← Shows active stage's layout
/// │       (animated transitions)            │
/// │                                         │
/// └─────────────────────────────────────────┘
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

    /// The stage host state (forwarded from controller)
    public var stageHostState: StageHostWindowState { controller.state }

    /// Panel provider for looking up panels by ID (forwarded to controller)
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        get { controller.panelProvider }
        set { controller.panelProvider = newValue }
    }

    /// Display mode for tabs and stage indicators
    public var displayMode: StageDisplayMode {
        get { controller.displayMode }
        set {
            controller.displayMode = newValue
            headerView?.displayMode = newValue
            containerView?.displayMode = newValue
        }
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
        stageHostState: StageHostWindowState,
        frame: NSRect,
        layoutManager: DockLayoutManager? = nil,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.windowId = id
        self.controller = StageHostController(state: stageHostState)
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
        loadStages()
    }

    /// Convenience initializer for creating a window with a single panel
    /// Used when tearing a panel off to create a new stage host
    public convenience init(
        singlePanel panel: any DockablePanel,
        at screenPoint: NSPoint,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        // Create a single stage with the panel
        let tabState = TabLayoutState(
            id: panel.panelId,
            title: panel.panelTitle,
            iconName: panel.panelIcon != nil ? "doc" : nil
        )
        let tabGroup = TabGroupLayoutNode(
            tabs: [tabState],
            activeTabIndex: 0
        )
        let stage = Stage(
            title: panel.panelTitle,
            iconName: nil,
            layout: .tabGroup(tabGroup)
        )

        // Create frame centered at screen point
        let size = NSSize(width: 600, height: 400)
        let frame = NSRect(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        let state = StageHostWindowState(
            frame: frame,
            activeStageIndex: 0,
            stages: [stage]
        )

        self.init(
            stageHostState: state,
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

        // Default to thumbnail mode height
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockStageHeaderView.thumbnailHeaderHeight)

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

        // Capture thumbnails after a brief delay (for initial thumbnail mode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let thumbnails = self.containerView.captureStageThumbnails()
            self.headerView.setThumbnails(thumbnails)
        }
    }

    // MARK: - Public API

    /// Get the active stage's root node
    public var activeStageRootNode: DockNode? {
        guard controller.activeStageIndex >= 0 &&
              controller.activeStageIndex < controller.stages.count else {
            return nil
        }

        let layout = controller.stages[controller.activeStageIndex].layout
        return convertLayoutNodeToDockNode(layout)
    }

    /// Switch to a specific stage
    public func switchToStage(at index: Int, animated: Bool = true) {
        controller.switchToStage(at: index)
        containerView.switchToStage(at: index, animated: animated)
        headerView.setActiveIndex(index)
        updateTitle()
    }

    /// Update the stage state (for reconciliation)
    public func updateStageHostState(_ state: StageHostWindowState) {
        let stageCountChanged = controller.stages.count != state.stages.count
        controller.updateState(state)

        if stageCountChanged && state.displayMode == .thumbnails {
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
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        controller.addNewStage(title: title, iconName: iconName)
    }

    // MARK: - Title

    public func updateTitle() {
        guard controller.activeStageIndex >= 0 &&
              controller.activeStageIndex < controller.stages.count else {
            title = "Stage"
            return
        }

        let stage = controller.stages[controller.activeStageIndex]
        if let stageTitle = stage.title {
            title = stageTitle
        } else {
            title = "Stage \(controller.activeStageIndex + 1)"
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

    // MARK: - Private Helpers

    private func convertLayoutNodeToDockNode(_ layoutNode: DockLayoutNode) -> DockNode {
        switch layoutNode {
        case .split(let splitLayout):
            let children = splitLayout.children.map { convertLayoutNodeToDockNode($0) }
            return .split(SplitNode(
                id: splitLayout.id,
                axis: splitLayout.axis,
                children: children,
                proportions: splitLayout.proportions
            ))

        case .tabGroup(let tabGroupLayout):
            let tabs = tabGroupLayout.tabs.compactMap { tabState -> DockTab? in
                if let panel = panelProvider?(tabState.id) {
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

            return .tabGroup(TabGroupNode(
                id: tabGroupLayout.id,
                tabs: tabs,
                activeTabIndex: tabGroupLayout.activeTabIndex,
                displayMode: tabGroupLayout.displayMode
            ))

        case .stageHost(let stageHostLayout):
            return .stageHost(StageHostNode(from: stageHostLayout))
        }
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
        addNewStage()
    }

    public func stageHeader(_ header: DockStageHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onStageAt targetIndex: Int) {
        controller.handleTabMovedToStage(tabInfo.tabId, targetStageIndex: targetIndex)
    }

    public func stageHeader(_ header: DockStageHeaderView, didCloseStageAt index: Int) {
        controller.removeStage(at: index)
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
        controller.handleTabReceived(tabInfo.tabId, in: tabGroup.tabGroupNode.id, at: index)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        let allowTear = stageDelegate?.stageHostWindow(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        // Use controller's handleDetach which removes the tab from layout
        controller.handleDetach(tab: tab, at: screenPoint)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        controller.handleSplit(groupId: tabGroup.tabGroupNode.id, direction: direction, withTab: tab)
    }

    public func stageContainer(_ container: DockStageContainerView, didCloseTab tabId: UUID) {
        controller.handleTabClosed(tabId)
    }
}

// MARK: - StageHostControllerDelegate

extension DockStageHostWindow: StageHostControllerDelegate {
    public func controller(_ controller: StageHostController, didUpdateLayout layout: DockLayoutNode, forStageAt index: Int) {
        containerView.updateStageLayout(layout, forStageAt: index)

        // Recapture thumbnails after layout changes
        if controller.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    public func controller(_ controller: StageHostController, didUpdateStages stages: [Stage], activeIndex: Int) {
        headerView.setStages(stages, activeIndex: activeIndex)
        containerView.setStages(stages, activeIndex: activeIndex)
        updateTitle()

        if controller.displayMode == .thumbnails {
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
