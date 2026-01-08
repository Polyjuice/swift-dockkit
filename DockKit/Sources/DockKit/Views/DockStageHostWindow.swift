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

    /// The stage host state
    public private(set) var stageHostState: StageHostWindowState

    /// Reference to the layout manager
    public weak var layoutManager: DockLayoutManager?

    /// Delegate for window events
    public weak var stageDelegate: DockStageHostWindowDelegate?

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Flag to suppress auto-close during reconciliation
    internal var suppressAutoClose: Bool = false

    /// Display mode for tabs and stage indicators
    public var displayMode: StageDisplayMode {
        get { stageHostState.displayMode }
        set {
            stageHostState.displayMode = newValue
            headerView?.displayMode = newValue
            // Update tab bars in container if needed
            containerView?.displayMode = newValue
        }
    }

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
        self.stageHostState = stageHostState
        self.layoutManager = layoutManager
        self.panelProvider = panelProvider

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

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
        headerView.setStages(stageHostState.stages, activeIndex: stageHostState.activeStageIndex)
        containerView.setStages(stageHostState.stages, activeIndex: stageHostState.activeStageIndex)

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
        guard stageHostState.activeStageIndex >= 0 &&
              stageHostState.activeStageIndex < stageHostState.stages.count else {
            return nil
        }

        let layout = stageHostState.stages[stageHostState.activeStageIndex].layout
        return convertLayoutNodeToDockNode(layout)
    }

    /// Switch to a specific stage
    /// Note: This is a local view state change, not a layout mutation.
    /// We update the state directly since switching doesn't add/remove panels.
    public func switchToStage(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < stageHostState.stages.count else { return }
        guard index != stageHostState.activeStageIndex else { return }

        stageHostState.activeStageIndex = index
        containerView.switchToStage(at: index, animated: animated)
        headerView.setActiveIndex(index)
        updateTitle()
    }

    /// Update the stage state (for reconciliation)
    public func updateStageHostState(_ state: StageHostWindowState) {
        let activeIndexChanged = stageHostState.activeStageIndex != state.activeStageIndex
        let stageCountChanged = stageHostState.stages.count != state.stages.count

        stageHostState = state
        headerView.setStages(state.stages, activeIndex: state.activeStageIndex)
        containerView.setStages(state.stages, activeIndex: state.activeStageIndex)

        if activeIndexChanged || stageCountChanged {
            updateTitle()
        }

        // Recapture thumbnails after views are rebuilt (if in thumbnail mode)
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
        for stage in stageHostState.stages {
            if containsPanel(panelId, in: stage.layout) {
                return true
            }
        }
        return false
    }

    /// Check if window is empty (all stages have no panels)
    public var isEmpty: Bool {
        return stageHostState.stages.allSatisfy { $0.layout.isEmpty }
    }

    /// Add a new empty stage
    /// This creates a new state and sends it through the reconciler
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        let stageNumber = stageHostState.stages.count + 1
        let stage = Stage(
            title: title ?? "Stage \(stageNumber)",
            iconName: iconName,
            layout: .tabGroup(TabGroupLayoutNode())  // Empty tab group
        )

        // Create new state (immutable update pattern)
        var newState = stageHostState
        newState.stages.append(stage)
        newState.activeStageIndex = newState.stages.count - 1

        // Send through reconciler
        updateStageHostState(newState)

        return stage
    }

    // MARK: - Title

    public func updateTitle() {
        guard stageHostState.activeStageIndex >= 0 &&
              stageHostState.activeStageIndex < stageHostState.stages.count else {
            title = "Stage"
            return
        }

        let stage = stageHostState.stages[stageHostState.activeStageIndex]
        if let stageTitle = stage.title {
            title = stageTitle
        } else {
            title = "Stage \(stageHostState.activeStageIndex + 1)"
        }
    }

    // MARK: - Panel Removal

    /// Remove a panel from any stage in this window
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        for i in 0..<stageHostState.stages.count {
            var stage = stageHostState.stages[i]
            var modified = false
            stage.layout = stage.layout.removingTab(panelId, modified: &modified)
            if modified {
                stageHostState.stages[i] = stage
                if i == stageHostState.activeStageIndex {
                    containerView.updateStageLayout(stage.layout, forStageAt: i)
                }
                return true
            }
        }
        return false
    }

    /// Remove a tab from the currently active stage
    private func removeTabFromCurrentStage(_ tabId: UUID) {
        guard stageHostState.activeStageIndex < stageHostState.stages.count else { return }

        var stage = stageHostState.stages[stageHostState.activeStageIndex]
        var modified = false
        stage.layout = stage.layout.removingTab(tabId, modified: &modified)

        if modified {
            stageHostState.stages[stageHostState.activeStageIndex] = stage
            containerView.updateStageLayout(stage.layout, forStageAt: stageHostState.activeStageIndex)
        }
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

    private func containsPanel(_ panelId: UUID, in node: DockLayoutNode) -> Bool {
        switch node {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.contains { $0.id == panelId }
        case .split(let split):
            return split.children.contains { containsPanel(panelId, in: $0) }
        case .stageHost(let stageHost):
            return stageHost.stages.contains { containsPanel(panelId, in: $0.layout) }
        }
    }

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
        // Find which stage contains the source tab
        var sourceStageIndex: Int? = nil
        for (index, stage) in stageHostState.stages.enumerated() {
            if containsTab(tabInfo.tabId, in: stage.layout) {
                sourceStageIndex = index
                break
            }
        }

        guard let srcIndex = sourceStageIndex else {
            return
        }

        // Don't drop on the same stage
        guard srcIndex != targetIndex else {
            return
        }

        // Create new state with tab moved
        var newState = stageHostState

        // Remove tab from source stage
        guard let (tabState, newSourceLayout) = removeTab(tabInfo.tabId, from: newState.stages[srcIndex].layout) else {
            return
        }
        newState.stages[srcIndex].layout = newSourceLayout

        // Add tab to target stage
        newState.stages[targetIndex].layout = addTab(tabState, to: newState.stages[targetIndex].layout)

        // Switch to target stage
        newState.activeStageIndex = targetIndex

        // Update through reconciler
        updateStageHostState(newState)
    }

    // MARK: - Layout Helpers

    private func containsTab(_ tabId: UUID, in layout: DockLayoutNode) -> Bool {
        switch layout {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.contains { $0.id == tabId }
        case .split(let split):
            return split.children.contains { containsTab(tabId, in: $0) }
        case .stageHost(let stageHost):
            return stageHost.stages.contains { containsTab(tabId, in: $0.layout) }
        }
    }

    private func removeTab(_ tabId: UUID, from layout: DockLayoutNode) -> (TabLayoutState, DockLayoutNode)? {
        switch layout {
        case .tabGroup(var tabGroup):
            if let index = tabGroup.tabs.firstIndex(where: { $0.id == tabId }) {
                let tab = tabGroup.tabs.remove(at: index)
                // Adjust active tab index if needed
                if tabGroup.activeTabIndex >= tabGroup.tabs.count {
                    tabGroup.activeTabIndex = max(0, tabGroup.tabs.count - 1)
                }
                return (tab, .tabGroup(tabGroup))
            }
            return nil
        case .split(var split):
            for (i, child) in split.children.enumerated() {
                if let (tab, newChild) = removeTab(tabId, from: child) {
                    split.children[i] = newChild
                    return (tab, .split(split))
                }
            }
            return nil
        case .stageHost(var stageHost):
            for (i, stage) in stageHost.stages.enumerated() {
                if let (tab, newLayout) = removeTab(tabId, from: stage.layout) {
                    stageHost.stages[i].layout = newLayout
                    return (tab, .stageHost(stageHost))
                }
            }
            return nil
        }
    }

    private func addTab(_ tab: TabLayoutState, to layout: DockLayoutNode) -> DockLayoutNode {
        switch layout {
        case .tabGroup(var tabGroup):
            tabGroup.tabs.append(tab)
            tabGroup.activeTabIndex = tabGroup.tabs.count - 1
            return .tabGroup(tabGroup)
        case .split(var split):
            // Add to first tab group found
            if !split.children.isEmpty {
                split.children[0] = addTab(tab, to: split.children[0])
            }
            return .split(split)
        case .stageHost(var stageHost):
            // Add to the active stage
            if !stageHost.stages.isEmpty {
                let activeIndex = min(stageHost.activeStageIndex, stageHost.stages.count - 1)
                stageHost.stages[activeIndex].layout = addTab(tab, to: stageHost.stages[activeIndex].layout)
            }
            return .stageHost(stageHost)
        }
    }
}

// MARK: - DockStageContainerViewDelegate

extension DockStageHostWindow: DockStageContainerViewDelegate {
    public func stageContainer(_ container: DockStageContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightStage(at: index)
    }

    public func stageContainer(_ container: DockStageContainerView, didSwitchTo index: Int) {
        // This is a user gesture completing - update state to reflect the new active stage.
        // This is a view state sync, not a layout mutation requiring reconciliation.
        stageHostState.activeStageIndex = index
        headerView.clearSwipeHighlight()
        headerView.setActiveIndex(index)
        updateTitle()
        stageDelegate?.stageHostWindow(self, didSwitchToStageAt: index)
    }

    public func stageContainer(_ container: DockStageContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        return panelProvider?(id)
    }

    public func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Get the current stage's layout
        guard stageHostState.activeStageIndex < stageHostState.stages.count else { return }

        var stage = stageHostState.stages[stageHostState.activeStageIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        // Use layout mutation to move the tab
        let newLayout = stage.layout.movingTab(tabInfo.tabId, toGroupId: targetGroupId, at: index)
        stage.layout = newLayout
        stageHostState.stages[stageHostState.activeStageIndex] = stage

        // Rebuild the stage view
        containerView.updateStageLayout(newLayout, forStageAt: stageHostState.activeStageIndex)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        // Get the panel
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        // Check if delegate allows tearing (default: yes)
        let allowTear = stageDelegate?.stageHostWindow(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        // Notify panel it's about to detach
        panel.panelWillDetach()

        // Remove from current stage
        removeTabFromCurrentStage(tab.id)

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

    public func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Get the current stage's layout
        guard stageHostState.activeStageIndex < stageHostState.stages.count else { return }

        var stage = stageHostState.stages[stageHostState.activeStageIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        // Create tab state from DockTab
        let tabState = TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )

        // Use layout mutation to perform the split
        let newLayout = stage.layout.splitting(
            groupId: targetGroupId,
            direction: direction,
            withTab: tabState
        )
        stage.layout = newLayout
        stageHostState.stages[stageHostState.activeStageIndex] = stage

        // Rebuild the stage view
        containerView.updateStageLayout(newLayout, forStageAt: stageHostState.activeStageIndex)
    }
}
