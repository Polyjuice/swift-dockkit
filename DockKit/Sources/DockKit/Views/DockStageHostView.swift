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

    /// Controller that manages state and operations
    public let controller: StageHostController

    /// Delegate for host view events
    public weak var delegate: DockStageHostViewDelegate?

    /// Delegate for bubbling swipe gestures to parent stage host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            containerView?.swipeGestureDelegate = swipeGestureDelegate
        }
    }

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

    /// Check if view is empty (all stages have no panels)
    public var isEmpty: Bool { controller.isEmpty }

    // MARK: - Views

    private var headerView: DockStageHeaderView!
    private var containerView: DockStageContainerView!
    private var headerHeightConstraint: NSLayoutConstraint!

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        stageHostState: StageHostWindowState,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.hostId = id
        self.controller = StageHostController(state: stageHostState)

        super.init(frame: .zero)

        controller.panelProvider = panelProvider
        controller.delegate = self

        setupViews()
        loadStages()
    }

    /// Initialize with a controller (for shared controller scenarios)
    public init(id: UUID = UUID(), controller: StageHostController) {
        self.hostId = id
        self.controller = controller

        super.init(frame: .zero)

        controller.delegate = self

        setupViews()
        loadStages()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        headerView = DockStageHeaderView()
        headerView.delegate = self
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        containerView = DockStageContainerView()
        containerView.delegate = self
        containerView.swipeGestureDelegate = swipeGestureDelegate
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

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
        headerView.setStages(controller.stages, activeIndex: controller.activeStageIndex)
        containerView.setStages(controller.stages, activeIndex: controller.activeStageIndex)

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
    }

    /// Update the stage state
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

    /// Check if view contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        controller.containsPanel(panelId)
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        controller.addNewStage(title: title, iconName: iconName)
    }

    /// Remove a panel from any stage
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        controller.removePanel(panelId)
    }

    /// Toggle slow motion for debugging
    public var slowMotionEnabled: Bool {
        get { containerView.slowMotionEnabled }
        set { containerView.slowMotionEnabled = newValue }
    }

    /// Toggle thumbnail mode
    public var thumbnailModeEnabled: Bool {
        get { containerView.displayMode == .thumbnails }
        set { containerView.displayMode = newValue ? .thumbnails : .tabs }
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

// MARK: - StageHostControllerDelegate

extension DockStageHostView: StageHostControllerDelegate {
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

        if controller.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureStageThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    public func controller(_ controller: StageHostController, didSwitchToStage index: Int) {
        delegate?.stageHostView(self, didSwitchToStageAt: index)
    }

    public func controller(_ controller: StageHostController, didDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        let childWindow = DockStageHostWindow(
            singlePanel: panel,
            at: screenPoint,
            panelProvider: panelProvider
        )
        childWindow.makeKeyAndOrderFront(nil)
        panel.panelDidDock(at: .floating)
        delegate?.stageHostView(self, didTearPanel: panel, to: childWindow)
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
        controller.handleTabMovedToStage(tabInfo.tabId, targetStageIndex: targetIndex)
    }

    public func stageHeader(_ header: DockStageHeaderView, didCloseStageAt index: Int) {
        controller.removeStage(at: index)
    }
}

// MARK: - DockStageContainerViewDelegate

extension DockStageHostView: DockStageContainerViewDelegate {
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
        delegate?.stageHostView(self, didSwitchToStageAt: index)
    }

    public func stageContainer(_ container: DockStageContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        panelProvider?(id)
    }

    public func stageContainer(_ container: DockStageContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        controller.handleTabReceived(tabInfo.tabId, in: tabGroup.tabGroupNode.id, at: index)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        let allowTear = delegate?.stageHostView(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        controller.handleDetach(tab: tab, at: screenPoint)
    }

    public func stageContainer(_ container: DockStageContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        controller.handleSplit(groupId: tabGroup.tabGroupNode.id, direction: direction, withTab: tab)
    }

    public func stageContainer(_ container: DockStageContainerView, didCloseTab tabId: UUID) {
        controller.handleTabClosed(tabId)
    }
}
