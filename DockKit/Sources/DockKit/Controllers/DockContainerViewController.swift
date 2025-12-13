import AppKit

/// The main dock container that manages the entire docking layout
/// This is the root view controller for the docking system
open class DockContainerViewController: NSViewController {

    /// The root dock node
    public private(set) var rootNode: DockNode

    /// Floating windows
    private var floatingWindows: [UUID: DockWindow] = [:]

    /// Panel registry (maps panel IDs to panels)
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    /// Root view controller (either split or tab group)
    private var rootViewController: NSViewController?

    /// Global drop overlay for docking
    private var globalDropOverlay: DockDropOverlayView?

    /// Whether drag is currently in progress
    private var isDragging = false

    // MARK: - Initialization

    public init(rootNode: DockNode? = nil) {
        // Default to an empty tab group
        self.rootNode = rootNode ?? .tabGroup(TabGroupNode())
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.rootNode = .tabGroup(TabGroupNode())
        super.init(coder: coder)
    }

    // MARK: - View Lifecycle

    open override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        rebuildLayout()
        setupDragObservers()
    }

    // MARK: - Layout Building

    /// Rebuild the entire layout from the root node
    public func rebuildLayout() {
        // Remove existing root
        rootViewController?.view.removeFromSuperview()
        rootViewController?.removeFromParent()
        rootViewController = nil

        // Build new root
        rootViewController = createViewController(for: rootNode)

        if let rootVC = rootViewController {
            addChild(rootVC)
            rootVC.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(rootVC.view)

            NSLayoutConstraint.activate([
                rootVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                rootVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                rootVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                rootVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }

    /// Create view controller for a dock node
    private func createViewController(for node: DockNode) -> NSViewController {
        switch node {
        case .split(let splitNode):
            let splitVC = DockSplitViewController(splitNode: splitNode)
            splitVC.dockDelegate = self
            splitVC.tabGroupDelegate = self  // Set tab group delegate for children
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: tabGroupNode)
            tabGroupVC.delegate = self
            return tabGroupVC
        }
    }

    // Note: Delegates are now set in createViewController methods, not here.
    // Split view children get their delegates set when created by DockSplitViewController.

    // MARK: - Panel Management

    /// Add a panel to the dock
    public func addPanel(_ panel: any DockablePanel, to groupId: UUID? = nil, activate: Bool = true) {
        // Register the panel
        panelRegistry[panel.panelId] = panel

        // Find target tab group
        if let targetGroupId = groupId,
           let tabGroup = findTabGroup(withId: targetGroupId) {
            tabGroup.addTab(from: panel, activate: activate)
        } else if let firstTabGroup = findFirstTabGroup() {
            // Add to first available tab group
            firstTabGroup.addTab(from: panel, activate: activate)
        } else {
            // Create a new tab group for this panel
            let tabGroupNode = TabGroupNode(tabs: [DockTab(from: panel)])
            rootNode = .tabGroup(tabGroupNode)
            rebuildLayout()
        }
    }

    /// Remove a panel from the dock
    public func removePanel(_ panelId: UUID) {
        panelRegistry.removeValue(forKey: panelId)

        // Find and remove from tab groups
        removeTab(withId: panelId, from: &rootNode)
        rebuildLayout()
    }

    /// Find a tab group by ID
    public func findTabGroup(withId id: UUID) -> DockTabGroupViewController? {
        return findTabGroupController(withId: id, in: rootViewController)
    }

    private func findTabGroupController(withId id: UUID, in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController,
           tabGroup.tabGroupNode.id == id {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findTabGroupController(withId: id, in: item.viewController) {
                    return found
                }
            }
        }

        return nil
    }

    /// Find the first tab group in the hierarchy
    private func findFirstTabGroup() -> DockTabGroupViewController? {
        return findFirstTabGroupController(in: rootViewController)
    }

    private func findFirstTabGroupController(in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findFirstTabGroupController(in: item.viewController) {
                    return found
                }
            }
        }

        return nil
    }

    // MARK: - Floating Windows

    /// Detach a panel into a floating window
    @discardableResult
    public func detachPanel(_ panel: any DockablePanel, at screenPoint: NSPoint) -> DockWindow {
        panel.panelWillDetach()

        let window = DockWindow(with: panel, at: screenPoint)
        window.dockDelegate = self
        floatingWindows[window.windowId] = window
        window.makeKeyAndOrderFront(nil)

        return window
    }

    /// Close a floating window
    public func closeFloatingWindow(_ windowId: UUID) {
        if let window = floatingWindows.removeValue(forKey: windowId) {
            window.close()
        }
    }

    // MARK: - Node Manipulation

    /// Remove a tab from the node tree
    private func removeTab(withId tabId: UUID, from node: inout DockNode) {
        switch node {
        case .tabGroup(var tabGroupNode):
            tabGroupNode.removeTab(withId: tabId)
            node = .tabGroup(tabGroupNode)

        case .split(var splitNode):
            for i in 0..<splitNode.children.count {
                removeTab(withId: tabId, from: &splitNode.children[i])
            }
            // Clean up empty children
            splitNode.children.removeAll { child in
                if case .tabGroup(let tg) = child, tg.tabs.isEmpty {
                    return true
                }
                return false
            }
            // If only one child remains, promote it
            if splitNode.children.count == 1 {
                node = splitNode.children[0]
            } else {
                node = .split(splitNode)
            }
        }
    }

    // MARK: - Drag Observers

    private func setupDragObservers() {
        // Register for drag notifications to show/hide global drop overlay
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDragBegan(_:)),
            name: .dockDragBegan,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDragEnded(_:)),
            name: .dockDragEnded,
            object: nil
        )
    }

    @objc private func handleDragBegan(_ notification: Notification) {
        isDragging = true
        showDropOverlays(true)
    }

    @objc private func handleDragEnded(_ notification: Notification) {
        isDragging = false
        showDropOverlays(false)
    }

    private func showDropOverlays(_ show: Bool) {
        // Show drop overlays on all tab groups
        showDropOverlaysRecursively(in: rootViewController, show: show)
    }

    private func showDropOverlaysRecursively(in controller: NSViewController?, show: Bool) {
        if let tabGroup = controller as? DockTabGroupViewController {
            tabGroup.showDropOverlay(show)
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                showDropOverlaysRecursively(in: item.viewController, show: show)
            }
        }
    }

    // MARK: - Layout Persistence

    /// Save the current layout
    public func saveLayout() {
        // Build windows array: main window content + floating windows
        var windowStates: [WindowState] = []

        // Main window content (index 0 is treated as main for backward compatibility)
        let mainWindowState = WindowState(
            id: UUID(),
            frame: view.window?.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
            isFullScreen: view.window?.styleMask.contains(.fullScreen) ?? false,
            rootNode: DockLayoutNode.from(rootNode)
        )
        windowStates.append(mainWindowState)

        // Floating windows
        for window in floatingWindows.values {
            let windowState = WindowState(
                id: window.windowId,
                frame: window.frame,
                isFullScreen: window.styleMask.contains(.fullScreen),
                rootNode: DockLayoutNode.from(window.rootNode)
            )
            windowStates.append(windowState)
        }

        let layout = DockLayout(windows: windowStates)
        layout.save()
    }

    /// Restore a saved layout
    public func restoreLayout(_ layout: DockLayout) {
        // Close existing floating windows
        for window in floatingWindows.values {
            window.close()
        }
        floatingWindows.removeAll()

        guard !layout.windows.isEmpty else { return }

        // First window is treated as main content
        let mainWindowState = layout.windows[0]
        rootNode = restoreNode(from: mainWindowState.rootNode)
        rebuildLayout()

        // Remaining windows become floating windows
        for windowState in layout.windows.dropFirst() {
            let restoredNode = restoreNode(from: windowState.rootNode)
            let window = DockWindow(
                id: windowState.id,
                rootNode: restoredNode,
                frame: windowState.frame,
                layoutManager: nil
            )
            window.dockDelegate = self
            floatingWindows[window.windowId] = window

            // Handle full-screen state
            if windowState.isFullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }

            window.makeKeyAndOrderFront(nil)
        }
    }

    private func restoreNode(from layoutNode: DockLayoutNode) -> DockNode {
        switch layoutNode {
        case .split(let splitLayout):
            let children = splitLayout.children.map { restoreNode(from: $0) }
            let splitNode = SplitNode(
                id: splitLayout.id,
                axis: splitLayout.axis,
                children: children,
                proportions: splitLayout.proportions
            )
            return .split(splitNode)

        case .tabGroup(let tabGroupLayout):
            return .tabGroup(restoreTabGroupNode(from: tabGroupLayout))
        }
    }

    private func restoreTabGroupNode(from layout: TabGroupLayoutNode) -> TabGroupNode {
        var tabs: [DockTab] = []
        for tabState in layout.tabs {
            // Try to find existing panel
            if let panel = panelRegistry[tabState.id] {
                tabs.append(DockTab(from: panel))
            } else {
                // Create placeholder tab
                tabs.append(DockTab(
                    id: tabState.id,
                    title: tabState.title,
                    iconName: tabState.iconName
                ))
            }
        }
        return TabGroupNode(id: layout.id, tabs: tabs, activeTabIndex: layout.activeTabIndex, displayMode: layout.displayMode)
    }
}

// MARK: - DockTabGroupViewControllerDelegate

extension DockContainerViewController: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachTab tab: DockTab, at screenPoint: NSPoint) {
        guard let panel = tab.panel else { return }

        // Remove from current location
        tabGroup.removeTab(withId: tab.id)

        // Create floating window
        detachPanel(panel, at: screenPoint)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        // Find the panel from another location
        guard let panel = panelRegistry[tabInfo.tabId] else { return }

        // Remove from source (model only - view will be handled by insertTab)
        removeTab(withId: tabInfo.tabId, from: &rootNode)

        // Also close any floating window that might contain this tab
        closeFloatingWindowContaining(tabId: tabInfo.tabId)

        // Add to target - this updates both model and view
        tabGroup.insertTab(from: panel, at: index, activate: true)

        // Update the model to reflect the new tab in this group
        updateTabGroupNodeForController(tabGroup)

        // Don't call rebuildLayout() here - the view is already updated
        // Just clean up any empty groups
        cleanupEmptyGroups()
    }

    /// Update the model to match the controller's tab group
    private func updateTabGroupNodeForController(_ tabGroup: DockTabGroupViewController) {
        updateTabGroupNodeInTree(tabGroup.tabGroupNode, in: &rootNode)
    }

    private func updateTabGroupNodeInTree(_ updatedNode: TabGroupNode, in node: inout DockNode) {
        switch node {
        case .tabGroup(var tg):
            if tg.id == updatedNode.id {
                node = .tabGroup(updatedNode)
            }
        case .split(var splitNode):
            for i in 0..<splitNode.children.count {
                updateTabGroupNodeInTree(updatedNode, in: &splitNode.children[i])
            }
            node = .split(splitNode)
        }
    }

    /// Close floating window containing a specific tab
    private func closeFloatingWindowContaining(tabId: UUID) {
        for (windowId, window) in floatingWindows {
            if window.tabGroupController.tabGroupNode.tabs.contains(where: { $0.id == tabId }) {
                window.tabGroupController.removeTab(withId: tabId)
                if window.tabGroupController.tabGroupNode.tabs.isEmpty {
                    floatingWindows.removeValue(forKey: windowId)
                    window.close()
                }
                break
            }
        }
    }

    /// Remove a tab from the view controller hierarchy (not just the model)
    private func removeTabFromAllControllers(_ tabId: UUID) {
        removeTabFromController(tabId, in: rootViewController)
    }

    private func removeTabFromController(_ tabId: UUID, in controller: NSViewController?) {
        if let tabGroup = controller as? DockTabGroupViewController {
            if tabGroup.tabGroupNode.tabs.contains(where: { $0.id == tabId }) {
                tabGroup.removeTab(withId: tabId)
            }
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                removeTabFromController(tabId, in: item.viewController)
            }
        }
    }

    /// Clean up empty tab groups without full rebuild
    private func cleanupEmptyGroups() {
        var needsRebuild = false
        cleanupEmptyGroupsInNode(&rootNode, needsRebuild: &needsRebuild)
        if needsRebuild {
            rebuildLayout()
        }
    }

    private func cleanupEmptyGroupsInNode(_ node: inout DockNode, needsRebuild: inout Bool) {
        switch node {
        case .tabGroup(let tg):
            if tg.tabs.isEmpty {
                needsRebuild = true
            }
        case .split(var splitNode):
            for i in 0..<splitNode.children.count {
                cleanupEmptyGroupsInNode(&splitNode.children[i], needsRebuild: &needsRebuild)
            }
            // Remove empty children
            let beforeCount = splitNode.children.count
            splitNode.children.removeAll { child in
                if case .tabGroup(let tg) = child, tg.tabs.isEmpty {
                    return true
                }
                return false
            }
            if splitNode.children.count != beforeCount {
                needsRebuild = true
            }
            // Simplify if only one child
            if splitNode.children.count == 1 {
                node = splitNode.children[0]
                needsRebuild = true
            } else {
                node = .split(splitNode)
            }
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastTab: Bool) {
        // Tab group is now empty - rebuild layout to remove it
        removeEmptyTabGroup(tabGroup.tabGroupNode.id, from: &rootNode)
        rebuildLayout()
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab) {
        // Try to get panel from tab directly, or look up from registry
        guard let panel = tab.panel ?? panelRegistry[tab.id] else {
            print("Warning: Could not find panel for tab \(tab.id)")
            return
        }

        // Find the tab group in our hierarchy and split it
        splitTabGroup(tabGroup.tabGroupNode.id, direction: direction, withPanel: panel)
    }

    public func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {
        // Subclass or delegate can override to provide default panel creation
    }

    private func removeEmptyTabGroup(_ groupId: UUID, from node: inout DockNode) {
        switch node {
        case .tabGroup(let tg):
            if tg.id == groupId && tg.tabs.isEmpty {
                // This will be removed by parent
            }

        case .split(var splitNode):
            // Recursively check children
            for i in 0..<splitNode.children.count {
                removeEmptyTabGroup(groupId, from: &splitNode.children[i])
            }

            // Remove empty tab groups
            splitNode.children.removeAll { child in
                if case .tabGroup(let tg) = child, tg.tabs.isEmpty {
                    return true
                }
                return false
            }

            // Simplify if only one child remains
            if splitNode.children.count == 1 {
                node = splitNode.children[0]
            } else if splitNode.children.isEmpty {
                node = .tabGroup(TabGroupNode())
            } else {
                node = .split(splitNode)
            }
        }
    }

    private func splitTabGroup(_ groupId: UUID, direction: DockSplitDirection, withPanel panel: any DockablePanel) {
        // Remove panel from its current location
        removeTab(withId: panel.panelId, from: &rootNode)

        // Create new tab for the panel
        let newTab = DockTab(from: panel)
        let newTabGroup = TabGroupNode(tabs: [newTab])
        let newNode = DockNode.tabGroup(newTabGroup)

        // Find and split the target group
        splitNodeContainingGroup(groupId, direction: direction, withNewNode: newNode, in: &rootNode)

        rebuildLayout()
    }

    /// Debug helper to describe a node
    private func describeNode(_ node: DockNode, indent: String = "") -> String {
        switch node {
        case .tabGroup(let tg):
            let tabNames = tg.tabs.map { "\($0.title)(panel:\($0.panel != nil))" }.joined(separator: ", ")
            return "\(indent)TabGroup(id:\(tg.id.uuidString.prefix(8)), tabs:[\(tabNames)], activeIdx:\(tg.activeTabIndex))"
        case .split(let split):
            var result = "\(indent)Split(id:\(split.id.uuidString.prefix(8)), axis:\(split.axis), proportions:\(split.proportions))\n"
            for (i, child) in split.children.enumerated() {
                result += "\(indent)  child[\(i)]: \(describeNode(child, indent: indent + "    "))\n"
            }
            return result
        }
    }

    private func splitNodeContainingGroup(_ groupId: UUID, direction: DockSplitDirection, withNewNode newNode: DockNode, in node: inout DockNode) {
        switch node {
        case .tabGroup(let tg):
            if tg.id == groupId {
                // Replace this node with a split containing both
                let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
                let insertFirst = (direction == .left || direction == .top)
                let children = insertFirst ? [newNode, node] : [node, newNode]
                node = .split(SplitNode(axis: axis, children: children))
            }

        case .split(var splitNode):
            for i in 0..<splitNode.children.count {
                splitNodeContainingGroup(groupId, direction: direction, withNewNode: newNode, in: &splitNode.children[i])
            }
            node = .split(splitNode)
        }
    }
}

// MARK: - DockSplitViewControllerDelegate

extension DockContainerViewController: DockSplitViewControllerDelegate {
    public func splitViewController(_ controller: DockSplitViewController, didUpdateProportions proportions: [CGFloat]) {
        // Proportions updated - could auto-save here
    }

    public func splitViewController(_ controller: DockSplitViewController, childDidBecomeEmpty index: Int) {
        // A child became empty - rebuild to clean up
        rebuildLayout()
    }
}

// MARK: - DockWindowDelegate

extension DockContainerViewController: DockWindowDelegate {
    public func dockWindow(_ window: DockWindow, didClose: Void) {
        floatingWindows.removeValue(forKey: window.windowId)
    }

    public func dockWindow(_ window: DockWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        // Detach into a new floating window
        detachPanel(panel, at: screenPoint)
    }

    public func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Handle split request from floating window - for now just log
        print("[DockContainerVC] Floating window requested split - not implemented")
    }

    public func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Find the panel from the registry
        guard let panel = panelRegistry[tabInfo.tabId] else { return }

        // Remove from source - BOTH model AND view controller in main window
        removeTab(withId: tabInfo.tabId, from: &rootNode)
        removeTabFromAllControllers(tabInfo.tabId)

        // Also close any floating window that might contain this tab (except this one)
        for (windowId, otherWindow) in floatingWindows where windowId != window.windowId {
            // Find first tab group in the floating window
            if let floatingTabGroup = findFirstTabGroupController(in: otherWindow.rootViewController),
               floatingTabGroup.tabGroupNode.tabs.contains(where: { $0.id == tabInfo.tabId }) {
                floatingTabGroup.removeTab(withId: tabInfo.tabId)
                if floatingTabGroup.tabGroupNode.tabs.isEmpty && otherWindow.isEmpty {
                    floatingWindows.removeValue(forKey: windowId)
                    otherWindow.close()
                }
                break
            }
        }

        // Add to target floating window's tab group
        tabGroup.insertTab(from: panel, at: index, activate: true)

        // Clean up empty groups in main window
        cleanupEmptyGroups()
    }
}
