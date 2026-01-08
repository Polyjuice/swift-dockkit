import AppKit

/// Delegate for stage host view events
public protocol DockStageHostViewDelegate: AnyObject {
    /// Called when the active stage changes
    func stageHostView(_ view: DockStageHostView, didSwitchToStageAt index: Int)

    /// Called when a tab is received via drag
    func stageHostView(_ view: DockStageHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called before a panel is torn off. Return false to prevent tearing.
    func stageHostView(_ view: DockStageHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool

    /// Called after a panel was torn off into a new window
    func stageHostView(_ view: DockStageHostView, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow)

    /// Called when a split is requested
    func stageHostView(_ view: DockStageHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockStageHostViewDelegate {
    func stageHostView(_ view: DockStageHostView, didSwitchToStageAt index: Int) {}
    func stageHostView(_ view: DockStageHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func stageHostView(_ view: DockStageHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool { true }
    func stageHostView(_ view: DockStageHostView, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow) {}
    func stageHostView(_ view: DockStageHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A view that hosts multiple stages with swipe gesture navigation.
/// This is the view-based equivalent of DockStageHostWindow, allowing stage hosts
/// to be nested inside other layouts (Version 3 feature).
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
public class DockStageHostView: NSView {

    // MARK: - Properties

    /// Unique identifier for this host
    public let hostId: UUID

    /// The stage host state
    public private(set) var stageHostState: StageHostWindowState

    /// Delegate for host view events
    public weak var delegate: DockStageHostViewDelegate?

    /// Delegate for bubbling swipe gestures to parent stage host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            containerView?.swipeGestureDelegate = swipeGestureDelegate
        }
    }

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Display mode for tabs and stage indicators
    public var displayMode: StageDisplayMode {
        get { stageHostState.displayMode }
        set {
            stageHostState.displayMode = newValue
            headerView?.displayMode = newValue
            containerView?.displayMode = newValue
        }
    }

    // MARK: - Views

    /// The header view showing stage tabs
    private var headerView: DockStageHeaderView!

    /// The container view holding stage content
    private var containerView: DockStageContainerView!

    /// Header height constraint (changes in thumbnail mode)
    private var headerHeightConstraint: NSLayoutConstraint!

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        stageHostState: StageHostWindowState,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.hostId = id
        self.stageHostState = stageHostState
        self.panelProvider = panelProvider

        super.init(frame: .zero)

        setupViews()
        loadStages()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        // Header view
        headerView = DockStageHeaderView()
        headerView.delegate = self
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Container view
        containerView = DockStageContainerView()
        containerView.delegate = self
        containerView.swipeGestureDelegate = swipeGestureDelegate
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        // Default to thumbnail mode height
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockStageHeaderView.thumbnailHeaderHeight)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerHeightConstraint,

            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
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
    public func switchToStage(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < stageHostState.stages.count else { return }
        guard index != stageHostState.activeStageIndex else { return }

        stageHostState.activeStageIndex = index
        containerView.switchToStage(at: index, animated: animated)
        headerView.setActiveIndex(index)
    }

    /// Update the stage state
    public func updateStageHostState(_ state: StageHostWindowState) {
        let activeIndexChanged = stageHostState.activeStageIndex != state.activeStageIndex
        let stageCountChanged = stageHostState.stages.count != state.stages.count

        stageHostState = state
        headerView.setStages(state.stages, activeIndex: state.activeStageIndex)
        containerView.setStages(state.stages, activeIndex: state.activeStageIndex)

        // Recapture thumbnails after views are rebuilt (if in thumbnail mode)
        if stageCountChanged && state.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    /// Check if view contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        for stage in stageHostState.stages {
            if containsPanel(panelId, in: stage.layout) {
                return true
            }
        }
        return false
    }

    /// Check if view is empty (all stages have no panels)
    public var isEmpty: Bool {
        return stageHostState.stages.allSatisfy { $0.layout.isEmpty }
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        let stageNumber = stageHostState.stages.count + 1
        let stage = Stage(
            title: title ?? "Stage \(stageNumber)",
            iconName: iconName,
            layout: .tabGroup(TabGroupLayoutNode())
        )

        var newState = stageHostState
        newState.stages.append(stage)
        newState.activeStageIndex = newState.stages.count - 1

        updateStageHostState(newState)

        return stage
    }

    /// Toggle slow motion for debugging swipe gestures
    public var slowMotionEnabled: Bool {
        get { containerView.slowMotionEnabled }
        set { containerView.slowMotionEnabled = newValue }
    }

    /// Toggle thumbnail mode for all tab groups
    public var thumbnailModeEnabled: Bool {
        get { containerView.displayMode == .thumbnails }
        set { containerView.displayMode = newValue ? .thumbnails : .tabs }
    }

    // MARK: - Panel Removal

    /// Remove a panel from any stage in this view
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

extension DockStageHostView: DockStageHeaderViewDelegate {
    public func stageHeader(_ header: DockStageHeaderView, didSelectStageAt index: Int) {
        switchToStage(at: index, animated: true)
        delegate?.stageHostView(self, didSwitchToStageAt: index)
    }

    public func stageHeader(_ header: DockStageHeaderView, didToggleSlowMotion enabled: Bool) {
        containerView.slowMotionEnabled = enabled
    }

    public func stageHeader(_ header: DockStageHeaderView, didToggleThumbnailMode enabled: Bool) {
        let newHeight = headerView.setThumbnailMode(enabled)

        if enabled {
            let thumbnails = containerView.captureStageThumbnails()
            headerView.setThumbnails(thumbnails)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            headerHeightConstraint.constant = newHeight
            self.layoutSubtreeIfNeeded()
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

        guard let srcIndex = sourceStageIndex else { return }
        guard srcIndex != targetIndex else { return }

        var newState = stageHostState

        guard let (tabState, newSourceLayout) = removeTab(tabInfo.tabId, from: newState.stages[srcIndex].layout) else {
            return
        }
        newState.stages[srcIndex].layout = newSourceLayout
        newState.stages[targetIndex].layout = addTab(tabState, to: newState.stages[targetIndex].layout)
        newState.activeStageIndex = targetIndex

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
            if !split.children.isEmpty {
                split.children[0] = addTab(tab, to: split.children[0])
            }
            return .split(split)
        case .stageHost(var stageHost):
            // Add to the active stage's layout
            if stageHost.activeStageIndex < stageHost.stages.count {
                stageHost.stages[stageHost.activeStageIndex].layout = addTab(tab, to: stageHost.stages[stageHost.activeStageIndex].layout)
            }
            return .stageHost(stageHost)
        }
    }
}

// MARK: - DockStageContainerViewDelegate

extension DockStageHostView: DockStageContainerViewDelegate {
    public func stageContainer(_ container: DockStageContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightStage(at: index)
    }

    public func stageContainer(_ container: DockStageContainerView, didSwitchTo index: Int) {
        stageHostState.activeStageIndex = index
        headerView.clearSwipeHighlight()
        headerView.setActiveIndex(index)
        delegate?.stageHostView(self, didSwitchToStageAt: index)
    }

    public func stageContainer(_ container: DockStageContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        return panelProvider?(id)
    }

    public func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        guard stageHostState.activeStageIndex < stageHostState.stages.count else { return }

        var stage = stageHostState.stages[stageHostState.activeStageIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        let newLayout = stage.layout.movingTab(tabInfo.tabId, toGroupId: targetGroupId, at: index)
        stage.layout = newLayout
        stageHostState.stages[stageHostState.activeStageIndex] = stage

        containerView.updateStageLayout(newLayout, forStageAt: stageHostState.activeStageIndex)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        let allowTear = delegate?.stageHostView(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        panel.panelWillDetach()
        removeTabFromCurrentStage(tab.id)

        let childWindow = DockStageHostWindow(
            singlePanel: panel,
            at: screenPoint,
            panelProvider: panelProvider
        )

        childWindow.makeKeyAndOrderFront(nil)
        panel.panelDidDock(at: .floating)

        delegate?.stageHostView(self, didTearPanel: panel, to: childWindow)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        guard stageHostState.activeStageIndex < stageHostState.stages.count else { return }

        var stage = stageHostState.stages[stageHostState.activeStageIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        let tabState = TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )

        let newLayout = stage.layout.splitting(
            groupId: targetGroupId,
            direction: direction,
            withTab: tabState
        )
        stage.layout = newLayout
        stageHostState.stages[stageHostState.activeStageIndex] = stage

        containerView.updateStageLayout(newLayout, forStageAt: stageHostState.activeStageIndex)
    }
}
