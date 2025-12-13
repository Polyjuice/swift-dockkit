import AppKit

/// Delegate for desktop host window events
public protocol DockDesktopHostWindowDelegate: AnyObject {
    /// Called when the window is closed
    func desktopHostWindow(_ window: DockDesktopHostWindow, didClose: Void)

    /// Called when the active desktop changes
    func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int)

    /// Called when a tab is received via drag
    func desktopHostWindow(_ window: DockDesktopHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called when a panel wants to detach
    func desktopHostWindow(_ window: DockDesktopHostWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)

    /// Called when a split is requested
    func desktopHostWindow(_ window: DockDesktopHostWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockDesktopHostWindowDelegate {
    func desktopHostWindow(_ window: DockDesktopHostWindow, didClose: Void) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A window that hosts multiple desktops with swipe gesture navigation
/// Structure:
/// ┌─────────────────────────────────────────┐
/// │  Desktop Header (selection UI)          │  ← Fixed height, shows desktop icons/titles
/// ├─────────────────────────────────────────┤
/// │                                         │
/// │       Desktop Container                 │  ← Shows active desktop's layout
/// │       (animated transitions)            │
/// │                                         │
/// └─────────────────────────────────────────┘
public class DockDesktopHostWindow: NSWindow {

    // MARK: - Properties

    /// Window ID for tracking
    public let windowId: UUID

    /// The desktop host state
    public private(set) var desktopHostState: DesktopHostWindowState

    /// Reference to the layout manager
    public weak var layoutManager: DockLayoutManager?

    /// Delegate for window events
    public weak var desktopDelegate: DockDesktopHostWindowDelegate?

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Flag to suppress auto-close during reconciliation
    internal var suppressAutoClose: Bool = false

    // MARK: - Views

    /// The header view showing desktop tabs
    private var headerView: DockDesktopHeaderView!

    /// The container view holding desktop content
    private var containerView: DockDesktopContainerView!

    /// Content view that holds header + container
    private var rootView: NSView!

    /// Header height constraint (changes in thumbnail mode)
    private var headerHeightConstraint: NSLayoutConstraint!

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        desktopHostState: DesktopHostWindowState,
        frame: NSRect,
        layoutManager: DockLayoutManager? = nil,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.windowId = id
        self.desktopHostState = desktopHostState
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
        loadDesktops()
    }

    // MARK: - Setup

    private func setupWindow() {
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbarStyle = .unifiedCompact
        animationBehavior = .none

        let toolbar = NSToolbar(identifier: "DockDesktopHostWindowToolbar-\(windowId.uuidString)")
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar

        minSize = NSSize(width: 400, height: 300)

        updateTitle()
    }

    private func setupViews() {
        // Root view
        rootView = NSView()
        rootView.wantsLayer = true
        contentView = rootView

        // Header view
        headerView = DockDesktopHeaderView()
        headerView.delegate = self
        headerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(headerView)

        // Container view
        containerView = DockDesktopContainerView()
        containerView.delegate = self
        containerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(containerView)

        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockDesktopHeaderView.headerHeight)

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

    private func loadDesktops() {
        headerView.setDesktops(desktopHostState.desktops, activeIndex: desktopHostState.activeDesktopIndex)
        containerView.setDesktops(desktopHostState.desktops, activeIndex: desktopHostState.activeDesktopIndex)
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

        desktopHostState.activeDesktopIndex = index
        containerView.switchToDesktop(at: index, animated: animated)
        headerView.setActiveIndex(index)
        updateTitle()
    }

    /// Update the desktop state (for reconciliation)
    public func updateDesktopHostState(_ state: DesktopHostWindowState) {
        let activeIndexChanged = desktopHostState.activeDesktopIndex != state.activeDesktopIndex

        desktopHostState = state
        headerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)
        containerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)

        if activeIndexChanged {
            updateTitle()
        }
    }

    /// Check if window contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        for desktop in desktopHostState.desktops {
            if containsPanel(panelId, in: desktop.layout) {
                return true
            }
        }
        return false
    }

    /// Check if window is empty (all desktops have no panels)
    public var isEmpty: Bool {
        return desktopHostState.desktops.allSatisfy { $0.layout.isEmpty }
    }

    // MARK: - Title

    public func updateTitle() {
        guard desktopHostState.activeDesktopIndex >= 0 &&
              desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else {
            title = "Desktop"
            return
        }

        let desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        if let desktopTitle = desktop.title {
            title = desktopTitle
        } else {
            title = "Desktop \(desktopHostState.activeDesktopIndex + 1)"
        }
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
        desktopDelegate?.desktopHostWindow(self, didClose: ())
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
        }
    }
}

// MARK: - DockDesktopHeaderViewDelegate

extension DockDesktopHostWindow: DockDesktopHeaderViewDelegate {
    public func desktopHeader(_ header: DockDesktopHeaderView, didSelectDesktopAt index: Int) {
        switchToDesktop(at: index, animated: true)
        desktopDelegate?.desktopHostWindow(self, didSwitchToDesktopAt: index)
    }

    public func desktopHeader(_ header: DockDesktopHeaderView, didToggleSlowMotion enabled: Bool) {
        containerView.slowMotionEnabled = enabled
    }

    public func desktopHeader(_ header: DockDesktopHeaderView, didToggleThumbnailMode enabled: Bool) {
        // Set thumbnail mode on header and get new height
        let newHeight = headerView.setThumbnailMode(enabled)

        // Capture and set thumbnails if enabling
        if enabled {
            let thumbnails = containerView.captureDesktopThumbnails()
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
}

// MARK: - DockDesktopContainerViewDelegate

extension DockDesktopHostWindow: DockDesktopContainerViewDelegate {
    public func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightDesktop(at: index)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, didSwitchTo index: Int) {
        desktopHostState.activeDesktopIndex = index
        headerView.clearSwipeHighlight()
        headerView.setActiveIndex(index)
        updateTitle()
        desktopDelegate?.desktopHostWindow(self, didSwitchToDesktopAt: index)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, panelForId id: UUID) -> (any DockablePanel)? {
        return panelProvider?(id)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Get the current desktop's layout
        guard desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else { return }

        var desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        // Use layout mutation to move the tab
        let newLayout = desktop.layout.movingTab(tabInfo.tabId, toGroupId: targetGroupId, at: index)
        desktop.layout = newLayout
        desktopHostState.desktops[desktopHostState.activeDesktopIndex] = desktop

        // Rebuild the desktop view
        containerView.updateDesktopLayout(newLayout, forDesktopAt: desktopHostState.activeDesktopIndex)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, wantsToDetachTab tab: DockTab, from tabGroup: DockTabGroupViewController, at screenPoint: NSPoint) {
        // Forward to delegate - host app handles creating new windows
        if let panel = tab.panel ?? panelProvider?(tab.id) {
            desktopDelegate?.desktopHostWindow(self, wantsToDetachPanel: panel, at: screenPoint)
        }
    }

    public func desktopContainer(_ container: DockDesktopContainerView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Get the current desktop's layout
        guard desktopHostState.activeDesktopIndex < desktopHostState.desktops.count else { return }

        var desktop = desktopHostState.desktops[desktopHostState.activeDesktopIndex]
        let targetGroupId = tabGroup.tabGroupNode.id

        // Create tab state from DockTab
        let tabState = TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )

        // Use layout mutation to perform the split
        let newLayout = desktop.layout.splitting(
            groupId: targetGroupId,
            direction: direction,
            withTab: tabState
        )
        desktop.layout = newLayout
        desktopHostState.desktops[desktopHostState.activeDesktopIndex] = desktop

        // Rebuild the desktop view
        containerView.updateDesktopLayout(newLayout, forDesktopAt: desktopHostState.activeDesktopIndex)
    }
}
