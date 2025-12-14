import AppKit

/// Delegate for desktop host window events
public protocol DockDesktopHostWindowDelegate: AnyObject {
    /// Called when the window is closed
    func desktopHostWindow(_ window: DockDesktopHostWindow, didClose: Void)

    /// Called when the active desktop changes
    func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int)

    /// Called when a tab is received via drag
    func desktopHostWindow(_ window: DockDesktopHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)

    /// Called before a panel is torn off. Return false to prevent tearing.
    func desktopHostWindow(_ window: DockDesktopHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool

    /// Called after a panel was torn off into a new window
    func desktopHostWindow(_ window: DockDesktopHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockDesktopHostWindow)

    /// Called when a split is requested
    func desktopHostWindow(_ window: DockDesktopHostWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockDesktopHostWindowDelegate {
    func desktopHostWindow(_ window: DockDesktopHostWindow, didClose: Void) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func desktopHostWindow(_ window: DockDesktopHostWindow, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool { true }
    func desktopHostWindow(_ window: DockDesktopHostWindow, didTearPanel panel: any DockablePanel, to newWindow: DockDesktopHostWindow) {}
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

    /// Display mode for tabs and desktop indicators
    public var displayMode: DesktopDisplayMode {
        get { desktopHostState.displayMode }
        set {
            desktopHostState.displayMode = newValue
            headerView?.displayMode = newValue
            // Update tab bars in container if needed
            containerView?.displayMode = newValue
        }
    }

    // MARK: - Child Window Tracking

    /// Child windows spawned from panel tearing
    public private(set) var spawnedWindows: [DockDesktopHostWindow] = []

    /// Parent window (if this window was spawned from tearing)
    public private(set) weak var spawnerWindow: DockDesktopHostWindow?

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

    /// Convenience initializer for creating a window with a single panel
    /// Used when tearing a panel off to create a new desktop host
    public convenience init(
        singlePanel panel: any DockablePanel,
        at screenPoint: NSPoint,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        // Create a single desktop with the panel
        let tabState = TabLayoutState(
            id: panel.panelId,
            title: panel.panelTitle,
            iconName: panel.panelIcon != nil ? "doc" : nil
        )
        let tabGroup = TabGroupLayoutNode(
            tabs: [tabState],
            activeTabIndex: 0
        )
        let desktop = Desktop(
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

        let state = DesktopHostWindowState(
            frame: frame,
            activeDesktopIndex: 0,
            desktops: [desktop]
        )

        self.init(
            desktopHostState: state,
            frame: frame,
            panelProvider: panelProvider
        )
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

        // Default to thumbnail mode height
        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: DockDesktopHeaderView.thumbnailHeaderHeight)

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
    /// Note: This is a local view state change, not a layout mutation.
    /// We update the state directly since switching doesn't add/remove panels.
    public func switchToDesktop(at index: Int, animated: Bool = true) {
        guard index >= 0 && index < desktopHostState.desktops.count else { return }
        guard index != desktopHostState.activeDesktopIndex else { return }

        desktopHostState.activeDesktopIndex = index
        containerView.switchToDesktop(at: index, animated: animated)
        headerView.setActiveIndex(index)
        updateTitle()
    }

    /// Update the desktop state (for reconciliation)
    public func updateDesktopHostState(_ state: DesktopHostWindowState) {
        let activeIndexChanged = desktopHostState.activeDesktopIndex != state.activeDesktopIndex
        let desktopCountChanged = desktopHostState.desktops.count != state.desktops.count

        desktopHostState = state
        headerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)
        containerView.setDesktops(state.desktops, activeIndex: state.activeDesktopIndex)

        if activeIndexChanged || desktopCountChanged {
            updateTitle()
        }

        // Recapture thumbnails after views are rebuilt (if in thumbnail mode)
        if desktopCountChanged && state.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let thumbnails = self.containerView.captureDesktopThumbnails()
                self.headerView.setThumbnails(thumbnails)
            }
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

    /// Add a new empty desktop
    /// This creates a new state and sends it through the reconciler
    @discardableResult
    public func addNewDesktop(title: String? = nil, iconName: String? = nil) -> Desktop {
        let desktopNumber = desktopHostState.desktops.count + 1
        let desktop = Desktop(
            title: title ?? "Desktop \(desktopNumber)",
            iconName: iconName,
            layout: .tabGroup(TabGroupLayoutNode())  // Empty tab group
        )

        // Create new state (immutable update pattern)
        var newState = desktopHostState
        newState.desktops.append(desktop)
        newState.activeDesktopIndex = newState.desktops.count - 1

        // Send through reconciler
        updateDesktopHostState(newState)

        return desktop
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

    // MARK: - Panel Removal

    /// Remove a panel from any desktop in this window
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

    // MARK: - Child Window Management

    /// Add a spawned child window (called internally during tearing)
    private func addSpawnedWindow(_ child: DockDesktopHostWindow) {
        spawnedWindows.append(child)
        child.spawnerWindow = self
    }

    /// Remove a spawned child window (called when child closes)
    internal func removeSpawnedWindow(_ child: DockDesktopHostWindow) {
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

        guard let srcIndex = sourceDesktopIndex else {
            return
        }

        // Don't drop on the same desktop
        guard srcIndex != targetIndex else {
            return
        }

        // Create new state with tab moved
        var newState = desktopHostState

        // Remove tab from source desktop
        guard let (tabState, newSourceLayout) = removeTab(tabInfo.tabId, from: newState.desktops[srcIndex].layout) else {
            return
        }
        newState.desktops[srcIndex].layout = newSourceLayout

        // Add tab to target desktop
        newState.desktops[targetIndex].layout = addTab(tabState, to: newState.desktops[targetIndex].layout)

        // Switch to target desktop
        newState.activeDesktopIndex = targetIndex

        // Update through reconciler
        updateDesktopHostState(newState)
    }

    // MARK: - Layout Helpers

    private func containsTab(_ tabId: UUID, in layout: DockLayoutNode) -> Bool {
        switch layout {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.contains { $0.id == tabId }
        case .split(let split):
            return split.children.contains { containsTab(tabId, in: $0) }
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
        }
    }
}

// MARK: - DockDesktopContainerViewDelegate

extension DockDesktopHostWindow: DockDesktopContainerViewDelegate {
    public func desktopContainer(_ container: DockDesktopContainerView, didBeginSwipingTo index: Int) {
        headerView.highlightDesktop(at: index)
    }

    public func desktopContainer(_ container: DockDesktopContainerView, didSwitchTo index: Int) {
        // This is a user gesture completing - update state to reflect the new active desktop.
        // This is a view state sync, not a layout mutation requiring reconciliation.
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
        // Get the panel
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        // Check if delegate allows tearing (default: yes)
        let allowTear = desktopDelegate?.desktopHostWindow(self, willTearPanel: panel, at: screenPoint) ?? true
        guard allowTear else { return }

        // Notify panel it's about to detach
        panel.panelWillDetach()

        // Remove from current desktop
        removeTabFromCurrentDesktop(tab.id)

        // Create new desktop host window with the panel
        let childWindow = DockDesktopHostWindow(
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
        desktopDelegate?.desktopHostWindow(self, didTearPanel: panel, to: childWindow)
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
