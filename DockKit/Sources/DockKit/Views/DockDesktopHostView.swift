import AppKit

/// Delegate for desktop host view events
public protocol DockDesktopHostViewDelegate: AnyObject {
    /// Called when the active desktop changes
    func desktopHostView(_ view: DockDesktopHostView, didSwitchToDesktopAt index: Int)

    /// Called when a tab is received via drag
    func desktopHostView(_ view: DockDesktopHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called before a panel is torn off. Return false to prevent tearing.
    func desktopHostView(_ view: DockDesktopHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool

    /// Called after a panel was torn off into a new window
    func desktopHostView(_ view: DockDesktopHostView, didTearPanel panel: any DockablePanel, to newWindow: DockDesktopHostWindow)

    /// Called when a split is requested
    func desktopHostView(_ view: DockDesktopHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockDesktopHostViewDelegate {
    func desktopHostView(_ view: DockDesktopHostView, didSwitchToDesktopAt index: Int) {}
    func desktopHostView(_ view: DockDesktopHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func desktopHostView(_ view: DockDesktopHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool { true }
    func desktopHostView(_ view: DockDesktopHostView, didTearPanel panel: any DockablePanel, to newWindow: DockDesktopHostWindow) {}
    func desktopHostView(_ view: DockDesktopHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A view that hosts multiple desktops with swipe gesture navigation.
/// This is the view-based equivalent of DockDesktopHostWindow, allowing desktop hosts
/// to be nested inside other layouts (Version 3 feature).
///
/// Structure:
/// ┌─────────────────────────────────────────┐
/// │  Desktop Header (selection UI)          │  ← Fixed height, shows desktop icons/titles
/// ├─────────────────────────────────────────┤
/// │                                         │
/// │       Desktop Container                 │  ← Shows active desktop's layout
/// │       (animated transitions)            │
/// │                                         │
/// └─────────────────────────────────────────┘
public class DockDesktopHostView: NSView {

    // MARK: - Properties

    /// Unique identifier for this host
    public let hostId: UUID

    /// The desktop host state
    public private(set) var desktopHostState: DesktopHostWindowState

    /// Delegate for host view events
    public weak var delegate: DockDesktopHostViewDelegate?

    /// Delegate for bubbling swipe gestures to parent desktop host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            containerView?.swipeGestureDelegate = swipeGestureDelegate
        }
    }

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Display mode for tabs and desktop indicators
    public var displayMode: DesktopDisplayMode {
        get { desktopHostState.displayMode }
        set {
            desktopHostState.displayMode = newValue
            headerView?.displayMode = newValue
            containerView?.displayMode = newValue
        }
    }

    // MARK: - Views

    /// The header view showing desktop tabs
    private var headerView: DockDesktopHeaderView!

    /// The container view holding desktop content
    private var containerView: DockDesktopContainerView!

    /// Header height constraint (changes in thumbnail mode)
    private var headerHeightConstraint: NSLayoutConstraint!

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        desktopHostState: DesktopHostWindowState,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.hostId = id
        self.desktopHostState = desktopHostState
        self.panelProvider = panelProvider

        super.init(frame: .zero)

        setupViews()
        loadDesktops()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        // Header view
        headerView = DockDesktopHeaderView()
        headerView.delegate = self
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Container view
        containerView = DockDesktopContainerView()
        containerView.delegate = self
        containerView.swipeGestureDelegate = swipeGestureDelegate
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        // Default to thumbnail mode height
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockDesktopHeaderView.thumbnailHeaderHeight)

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

    private func loadDesktops() {
        headerView.setDesktops(desktopHostState.desktops, activeIndex: desktopHostState.activeDesktopIndex)
        containerView.setDesktops(desktopHostState.desktops, activeIndex: desktopHostState.activeDesktopIndex)

        // Capture thumbnails after a brief delay (for initial thumbnail mode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let thumbnails = self.containerView.captureDesktopThumbnails()
            self.headerView.setThumbnails(thumbnails)
        }
    }

    // MARK: - Public API

    /// Get the active desktop's root node
    public var activeDesktopRootNode: DockNode? {
        guard desktopHostState.activeDesktopIndex >= 0 &&
              desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else {
            return nil
        }

        let layout = desktopHostState.desktops[desktopHostState.activeDesktopIndex].layout
        return convertLayoutNodeToDockNode(layout)
    }

    /// Switch to a specific desktop
    public func switchToDesktop(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < desktopHostState.desktops.count else { return }
        guard index != desktopHostState.activeDesktopIndex else { return }

        desktopHostState.activeDesktopIndex = index
        containerView.switchToDesktop(at: index, animated: animated)
        headerView.setActiveIndex(index)
    }

    /// Update the desktop state
    public func updateDesktopHostState(_ state: DesktopHostWindowState) {
        let activeIndexChanged = desktopHostState.activeDesktopIndex != state.activeDesktopIndex
        let desktopCountChanged = desktopHostState.desktops.count != state.desktops.count

        desktopHostState = state
        headerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)
        containerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)

        // Recapture thumbnails after views are rebuilt (if in thumbnail mode)
        if desktopCountChanged && state.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureDesktopThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
        }
    }

    /// Check if view contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        for desktop in desktopHostState.desktops {
            if containsPanel(panelId, in: desktop.layout) {
                return true
            }
        }
        return false
    }

    /// Check if view is empty (all desktops have no panels)
    public var isEmpty: Bool {
        return desktopHostState.desktops.allSatisfy { $0.layout.isEmpty }
    }

    /// Add a new empty desktop
    @discardableResult
    public func addNewDesktop(title: String? = nil, iconName: String? = nil) -> Desktop {
        let desktopNumber = desktopHostState.desktops.count + 1
        let desktop = Desktop(
            title: title ?? "Desktop \(desktopNumber)",
            iconName: iconName,
            layout: .tabGroup(TabGroupLayoutNode())
        )

        var newState = desktopHostState
        newState.desktops.append(desktop)
        newState.activeDesktopIndex = newState.desktops.count - 1

        updateDesktopHostState(newState)

        return desktop
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

    /// Remove a panel from any desktop in this view
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        for i in 0..<desktopHostState.desktops.count {
            var desktop = desktopHostState.desktops[i]
            var modified = false
            desktop.layout = desktop.layout.removingTab(panelId, modified: &modified)
            if modified {
                desktopHostState.desktops[i] = desktop
                if i == desktopHostState.activeDesktopIndex {
                    containerView.updateDesktopLayout(desktop.layout, forDesktopAt: i)
                }
                return true
            }
        }
        return false
    }

    /// Remove a tab from the currently active desktop
    private func removeTabFromCurrentDesktop(_ tabId: UUID) {
        guard desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else { return }

        var desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        var modified = false
        desktop.layout = desktop.layout.removingTab(tabId, modified: &modified)

        if modified {
            desktopHostState.desktops[desktopHostState.activeDesktopIndex] = desktop
            containerView.updateDesktopLayout(desktop.layout, forDesktopAt: desktopHostState.activeDesktopIndex)
        }
    }

    // MARK: - Private Helpers

    private func containsPanel(_ panelId: UUID, in node: DockLayoutNode) -> Bool {
        switch node {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.contains { $0.id == panelId }
        case .split(let split):
            return split.children.contains { containsPanel(panelId, in: $0) }
        case .desktopHost(let desktopHost):
            return desktopHost.desktops.contains { containsPanel(panelId, in: $0.layout) }
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

        case .desktopHost(let desktopHostLayout):
            return .desktopHost(DesktopHostNode(from: desktopHostLayout))
        }
    }
}

// MARK: - DockDesktopHeaderViewDelegate

extension DockDesktopHostView: DockDesktopHeaderViewDelegate {
    public func desktopHeader(_ header: DockDesktopHeaderView, didSelectDesktopAt index: Int) {
        switchToDesktop(at: index, animated: true)
        delegate?.desktopHostView(self, didSwitchToDesktopAt: index)
    }

    public func desktopHeader(_ header: DockDesktopHeaderView, didToggleSlowMotion enabled: Bool) {
        containerView.slowMotionEnabled = enabled
    }

    public func desktopHeader(_ header: DockDesktopHeaderView, didToggleThumbnailMode enabled: Bool) {
        let newHeight = headerView.setThumbnailMode(enabled)

        if enabled {
            let thumbnails = containerView.captureDesktopThumbnails()
            headerView.setThumbnails(thumbnails)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            headerHeightConstraint.constant = newHeight
            self.layoutSubtreeIfNeeded()
        }
    }

    public func desktopHeaderDidRequestNewDesktop(_ header: DockDesktopHeaderView) {
        addNewDesktop()
    }

    public func desktopHeader(_ header: DockDesktopHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onDesktopAt targetIndex: Int) {
        // Find which desktop contains the source tab
        var sourceDesktopIndex: Int? = nil
        for (index, desktop) in desktopHostState.desktops.enumerated() {
            if containsTab(tabInfo.tabId, in: desktop.layout) {
                sourceDesktopIndex = index
                break
            }
        }

        guard let srcIndex = sourceDesktopIndex else { return }
        guard srcIndex != targetIndex else { return }

        var newState = desktopHostState

        guard let (tabState, newSourceLayout) = removeTab(tabInfo.tabId, from: newState.desktops[srcIndex].layout) else {
            return
        }
        newState.desktops[srcIndex].layout = newSourceLayout
        newState.desktops[targetIndex].layout = addTab(tabState, to: newState.desktops[targetIndex].layout)
        newState.activeDesktopIndex = targetIndex

        updateDesktopHostState(newState)
    }

    // MARK: - Layout Helpers

    private func containsTab(_ tabId: UUID, in layout: DockLayoutNode) -> Bool {
        switch layout {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.contains { $0.id == tabId }
        case .split(let split):
            return split.children.contains { containsTab(tabId, in: $0) }
        case .desktopHost(let desktopHost):
            return desktopHost.desktops.contains { containsTab(tabId, in: $0.layout) }
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
        case .desktopHost(var desktopHost):
            for (i, desktop) in desktopHost.desktops.enumerated() {
                if let (tab, newLayout) = removeTab(tabId, from: desktop.layout) {
                    desktopHost.desktops[i].layout = newLayout
                    return (tab, .desktopHost(desktopHost))
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
        case .desktopHost(var desktopHost):
            // Add to the active desktop's layout
            if desktopHost.activeDesktopIndex < desktopHost.desktops.count {
                desktopHost.desktops[desktopHost.activeDesktopIndex].layout = addTab(tab, to: desktopHost.desktops[desktopHost.activeDesktopIndex].layout)
            }
            return .desktopHost(desktopHost)
        }
    }
}

// MARK: - DockDesktopContainerViewDelegate

extension DockDesktopHostView: DockDesktopContainerViewDelegate {
    public func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightDesktop(at: index)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, didSwitchTo index: Int) {
        desktopHostState.activeDesktopIndex = index
        headerView.clearSwipeHighlight()
        headerView.setActiveIndex(index)
        delegate?.desktopHostView(self, didSwitchToDesktopAt: index)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        return panelProvider?(id)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        guard desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else { return }

        var desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        let newLayout = desktop.layout.movingTab(tabInfo.tabId, toGroupId: targetGroupId, at: index)
        desktop.layout = newLayout
        desktopHostState.desktops[desktopHostState.activeDesktopIndex] = desktop

        containerView.updateDesktopLayout(newLayout, forDesktopAt: desktopHostState.activeDesktopIndex)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        let allowTear = delegate?.desktopHostView(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        panel.panelWillDetach()
        removeTabFromCurrentDesktop(tab.id)

        let childWindow = DockDesktopHostWindow(
            singlePanel: panel,
            at: screenPoint,
            panelProvider: panelProvider
        )

        childWindow.makeKeyAndOrderFront(nil)
        panel.panelDidDock(at: .floating)

        delegate?.desktopHostView(self, didTearPanel: panel, to: childWindow)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        guard desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else { return }

        var desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        let tabState = TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )

        let newLayout = desktop.layout.splitting(
            groupId: targetGroupId,
            direction: direction,
            withTab: tabState
        )
        desktop.layout = newLayout
        desktopHostState.desktops[desktopHostState.activeDesktopIndex] = desktop

        containerView.updateDesktopLayout(newLayout, forDesktopAt: desktopHostState.activeDesktopIndex)
    }
}
