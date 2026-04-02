import AppKit

/// The main dock container that manages the entire docking layout
/// This is the root view controller for the docking system
open class DockContainerViewController: NSViewController {

    /// The root panel (a group panel containing the layout tree)
    public private(set) var rootPanel: Panel

    /// Floating windows
    private var floatingWindows: [UUID: DockWindow] = [:]

    /// Panel registry (maps panel IDs to dockable panels)
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    /// Root view controller (either split or tab group)
    private var rootViewController: NSViewController?

    /// Global drop overlay for docking
    private var globalDropOverlay: DockDropOverlayView?

    /// Whether drag is currently in progress
    private var isDragging = false

    // MARK: - Initialization

    public init(rootPanel: Panel? = nil) {
        // Default to an empty tab-style group
        self.rootPanel = rootPanel ?? Panel(
            content: .group(PanelGroup(style: .tabs))
        )
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.rootPanel = Panel(
            content: .group(PanelGroup(style: .tabs))
        )
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

    /// Rebuild the entire layout from the root panel
    public func rebuildLayout() {
        // Remove existing root
        rootViewController?.view.removeFromSuperview()
        rootViewController?.removeFromParent()
        rootViewController = nil

        // Build new root
        rootViewController = createViewController(for: rootPanel)

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

    /// Create view controller for a panel
    private func createViewController(for panel: Panel) -> NSViewController {
        switch panel.content {
        case .content:
            // Leaf content panel — wrap in a single-child tab group for display
            let wrapperPanel = Panel(
                content: .group(PanelGroup(
                    children: [panel],
                    activeIndex: 0,
                    style: .tabs
                ))
            )
            let tabGroupVC = DockTabGroupViewController(panel: wrapperPanel)
            tabGroupVC.panelProvider = { [weak self] id in self?.panelRegistry[id] }
            tabGroupVC.delegate = self
            return tabGroupVC

        case .group(let group):
            switch group.style {
            case .split:
                let splitVC = DockSplitViewController(panel: panel)
                splitVC.dockDelegate = self
                splitVC.tabGroupDelegate = self
                splitVC.panelProvider = { [weak self] id in
                    self?.panelRegistry[id]
                }
                return splitVC

            case .tabs, .thumbnails:
                let tabGroupVC = DockTabGroupViewController(panel: panel)
                tabGroupVC.panelProvider = { [weak self] id in self?.panelRegistry[id] }
                tabGroupVC.delegate = self
                return tabGroupVC

            case .stages:
                let hostVC = DockStageHostViewController(
                    panel: panel,
                    panelProvider: { [weak self] id in
                        self?.panelRegistry[id]
                    }
                )
                return hostVC
            }
        }
    }

    // MARK: - Panel Management

    /// Add a panel to the dock
    public func addPanel(_ panel: any DockablePanel, to groupId: UUID? = nil, activate: Bool = true) {
        // Register the panel
        panelRegistry[panel.panelId] = panel

        // Find target group
        if let targetGroupId = groupId,
           let tabGroup = findTabGroupController(withId: targetGroupId) {
            tabGroup.addTab(from: panel, activate: activate)
        } else if let firstTabGroup = findFirstTabGroupController() {
            // Add to first available tab group
            firstTabGroup.addTab(from: panel, activate: activate)
        } else {
            // Create a new tab group for this panel
            let contentPanel = Panel.contentPanel(
                id: panel.panelId,
                title: panel.panelTitle
            )
            rootPanel = Panel(
                content: .group(PanelGroup(
                    children: [contentPanel],
                    activeIndex: 0,
                    style: .tabs
                ))
            )
            rebuildLayout()
        }
    }

    /// Remove a panel from the dock
    public func removePanel(_ panelId: UUID) {
        panelRegistry.removeValue(forKey: panelId)

        // Find and remove from tree
        removeChild(withId: panelId, from: &rootPanel)
        rebuildLayout()
    }

    /// Find a tab group controller by ID
    public func findTabGroupController(withId id: UUID) -> DockTabGroupViewController? {
        return findTabGroupControllerImpl(withId: id, in: rootViewController)
    }

    private func findTabGroupControllerImpl(withId id: UUID, in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController,
           tabGroup.panel.id == id {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findTabGroupControllerImpl(withId: id, in: item.viewController) {
                    return found
                }
            }
        }

        return nil
    }

    /// Find the first tab group controller in the hierarchy
    private func findFirstTabGroupController() -> DockTabGroupViewController? {
        return findFirstTabGroupControllerImpl(in: rootViewController)
    }

    private func findFirstTabGroupControllerImpl(in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findFirstTabGroupControllerImpl(in: item.viewController) {
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

    // MARK: - Panel Tree Manipulation

    /// Remove a child panel from the panel tree
    private func removeChild(withId childId: UUID, from panel: inout Panel) {
        switch panel.content {
        case .content:
            // Leaf — nothing to remove from
            break

        case .group(var group):
            switch group.style {
            case .tabs, .thumbnails:
                group.children.removeAll { $0.id == childId }
                if group.activeIndex >= group.children.count {
                    group.activeIndex = max(0, group.children.count - 1)
                }
                group.recalculateProportions()
                panel.content = .group(group)

            case .split:
                for i in 0..<group.children.count {
                    removeChild(withId: childId, from: &group.children[i])
                }
                // Clean up empty children
                group.children.removeAll { child in
                    if case .group(let g) = child.content, g.children.isEmpty {
                        return true
                    }
                    return child.isContent == false && child.isEmpty
                }
                // If only one child remains, promote it
                if group.children.count == 1 {
                    panel = group.children[0]
                } else {
                    group.recalculateProportions()
                    panel.content = .group(group)
                }

            case .stages:
                // Stage hosts manage their own children internally
                break
            }
        }
    }

    // MARK: - Drag Observers

    private func setupDragObservers() {
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
        var rootPanels: [Panel] = []

        // Main window content
        var mainPanel = rootPanel
        mainPanel.isTopLevelWindow = true
        mainPanel.frame = view.window?.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        mainPanel.isFullScreen = view.window?.styleMask.contains(.fullScreen) ?? false
        rootPanels.append(mainPanel)

        // Floating windows
        for window in floatingWindows.values {
            var windowPanel = window.rootPanel
            windowPanel.isTopLevelWindow = true
            windowPanel.frame = window.frame
            windowPanel.isFullScreen = window.styleMask.contains(.fullScreen)
            rootPanels.append(windowPanel)
        }

        let layout = DockLayout(panels: rootPanels)
        layout.save()
    }

    /// Restore a saved layout
    public func restoreLayout(_ layout: DockLayout) {
        // Close existing floating windows
        for window in floatingWindows.values {
            window.close()
        }
        floatingWindows.removeAll()

        guard !layout.panels.isEmpty else { return }

        // First panel is treated as main content
        let mainPanel = layout.panels[0]
        rootPanel = restorePanel(mainPanel)
        rebuildLayout()

        // Remaining panels become floating windows
        for windowPanel in layout.panels.dropFirst() {
            let restoredPanel = restorePanel(windowPanel)
            let window = DockWindow(
                id: windowPanel.id,
                rootPanel: restoredPanel,
                frame: windowPanel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
                layoutManager: nil
            )
            window.dockDelegate = self
            floatingWindows[window.windowId] = window

            // Handle full-screen state
            if windowPanel.isFullScreen == true && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }

            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Restore a panel, resolving any content panels to registered dockable panels
    private func restorePanel(_ panel: Panel) -> Panel {
        switch panel.content {
        case .content:
            // Leaf content — just return as-is (panelProvider resolves at render time)
            return panel

        case .group(var group):
            group.children = group.children.map { restorePanel($0) }
            var restored = panel
            restored.content = .group(group)
            return restored
        }
    }
}

// MARK: - DockTabGroupViewControllerDelegate

extension DockContainerViewController: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachPanel panelId: UUID, at screenPoint: NSPoint) {
        guard let panel = panelRegistry[panelId] else { return }

        // Remove from current location
        _ = tabGroup.removeTab(withId: panelId)

        // Create floating window
        detachPanel(panel, at: screenPoint)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        // Find the panel from registry
        guard let panel = panelRegistry[tabInfo.tabId] else { return }

        // Remove from source (model only - view will be handled by insertTab)
        removeChild(withId: tabInfo.tabId, from: &rootPanel)

        // Also close any floating window that might contain this tab
        closeFloatingWindowContaining(childId: tabInfo.tabId)

        // Add to target - this updates both model and view
        tabGroup.insertTab(from: panel, at: index, activate: true)

        // Update the model to reflect the new child in this group
        updateGroupPanelForController(tabGroup)

        // Don't call rebuildLayout() here - the view is already updated
        // Just clean up any empty groups
        cleanupEmptyGroups()
    }

    /// Update the model to match the controller's group panel
    private func updateGroupPanelForController(_ tabGroup: DockTabGroupViewController) {
        updateGroupPanelInTree(tabGroup.panel, in: &rootPanel)
    }

    private func updateGroupPanelInTree(_ updatedPanel: Panel, in panel: inout Panel) {
        switch panel.content {
        case .content:
            break
        case .group(var group):
            if panel.id == updatedPanel.id {
                panel = updatedPanel
            } else {
                for i in 0..<group.children.count {
                    updateGroupPanelInTree(updatedPanel, in: &group.children[i])
                }
                panel.content = .group(group)
            }
        }
    }

    /// Close floating window containing a specific child panel
    private func closeFloatingWindowContaining(childId: UUID) {
        for (windowId, window) in floatingWindows {
            if window.containsPanel(childId) {
                _ = window.removePanel(childId)
                if window.isEmpty {
                    floatingWindows.removeValue(forKey: windowId)
                    window.close()
                }
                break
            }
        }
    }

    /// Remove a child panel from all controllers in the view hierarchy
    private func removeChildFromAllControllers(_ childId: UUID) {
        removeChildFromController(childId, in: rootViewController)
    }

    private func removeChildFromController(_ childId: UUID, in controller: NSViewController?) {
        if let tabGroup = controller as? DockTabGroupViewController {
            if tabGroup.panel.group?.children.contains(where: { $0.id == childId }) == true {
                _ = tabGroup.removeTab(withId: childId)
            }
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                removeChildFromController(childId, in: item.viewController)
            }
        }
    }

    /// Clean up empty groups without full rebuild
    private func cleanupEmptyGroups() {
        var needsRebuild = false
        cleanupEmptyGroupsInPanel(&rootPanel, needsRebuild: &needsRebuild)
        if needsRebuild {
            rebuildLayout()
        }
    }

    private func cleanupEmptyGroupsInPanel(_ panel: inout Panel, needsRebuild: inout Bool) {
        switch panel.content {
        case .content:
            break

        case .group(var group):
            switch group.style {
            case .tabs, .thumbnails:
                if group.children.isEmpty {
                    needsRebuild = true
                }

            case .split:
                for i in 0..<group.children.count {
                    cleanupEmptyGroupsInPanel(&group.children[i], needsRebuild: &needsRebuild)
                }
                // Remove empty children
                let beforeCount = group.children.count
                group.children.removeAll { child in
                    if case .group(let g) = child.content, g.children.isEmpty,
                       g.style == .tabs || g.style == .thumbnails {
                        return true
                    }
                    return false
                }
                if group.children.count != beforeCount {
                    needsRebuild = true
                }
                // Simplify if only one child
                if group.children.count == 1 {
                    panel = group.children[0]
                    needsRebuild = true
                } else {
                    group.recalculateProportions()
                    panel.content = .group(group)
                }

            case .stages:
                // Stage hosts manage their own cleanup
                break
            }
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastPanel: Bool) {
        // Tab group is now empty - rebuild layout to remove it
        removeEmptyGroup(tabGroup.panel.id, from: &rootPanel)
        rebuildLayout()
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID) {
        // Look up the dockable panel from registry
        guard let panel = panelRegistry[panelId] else {
            print("Warning: Could not find panel for child \(panelId)")
            return
        }

        // Find the tab group in our hierarchy and split it
        splitGroup(tabGroup.panel.id, direction: direction, withPanel: panel)
    }

    public func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {
        // Subclass or delegate can override to provide default panel creation
    }

    private func removeEmptyGroup(_ groupId: UUID, from panel: inout Panel) {
        switch panel.content {
        case .content:
            break

        case .group(var group):
            switch group.style {
            case .tabs, .thumbnails:
                if panel.id == groupId && group.children.isEmpty {
                    // This will be removed by parent
                }

            case .split:
                // Recursively check children
                for i in 0..<group.children.count {
                    removeEmptyGroup(groupId, from: &group.children[i])
                }

                // Remove empty tab/thumbnail groups
                group.children.removeAll { child in
                    if case .group(let g) = child.content, g.children.isEmpty,
                       (g.style == .tabs || g.style == .thumbnails) {
                        return true
                    }
                    return false
                }

                // Simplify if only one child remains
                if group.children.count == 1 {
                    panel = group.children[0]
                } else if group.children.isEmpty {
                    panel = Panel(content: .group(PanelGroup(style: .tabs)))
                } else {
                    group.recalculateProportions()
                    panel.content = .group(group)
                }

            case .stages:
                // Stage hosts manage their own groups
                break
            }
        }
    }

    private func splitGroup(_ groupId: UUID, direction: DockSplitDirection, withPanel panel: any DockablePanel) {
        // Remove panel from its current location
        removeChild(withId: panel.panelId, from: &rootPanel)

        // Create new content panel
        let newContentPanel = Panel.contentPanel(
            id: panel.panelId,
            title: panel.panelTitle
        )
        let newGroupPanel = Panel(
            content: .group(PanelGroup(
                children: [newContentPanel],
                activeIndex: 0,
                style: .tabs
            ))
        )

        // Find and split the target group
        splitPanelContainingGroup(groupId, direction: direction, withNewPanel: newGroupPanel, in: &rootPanel)

        rebuildLayout()
    }

    /// Debug helper to describe a panel tree
    private func describePanel(_ panel: Panel, indent: String = "") -> String {
        switch panel.content {
        case .content:
            return "\(indent)Content(id:\(panel.id.uuidString.prefix(8)), title:\(panel.title ?? "nil"))"
        case .group(let group):
            switch group.style {
            case .tabs, .thumbnails:
                let childNames = group.children.map { "\($0.title ?? "?")" }.joined(separator: ", ")
                return "\(indent)\(group.style)(id:\(panel.id.uuidString.prefix(8)), children:[\(childNames)], activeIdx:\(group.activeIndex))"
            case .split:
                var result = "\(indent)Split(id:\(panel.id.uuidString.prefix(8)), axis:\(group.axis), proportions:\(group.proportions))\n"
                for (i, child) in group.children.enumerated() {
                    result += "\(indent)  child[\(i)]: \(describePanel(child, indent: indent + "    "))\n"
                }
                return result
            case .stages:
                return "\(indent)StageHost(id:\(panel.id.uuidString.prefix(8)), stages:\(group.children.count))"
            }
        }
    }

    private func splitPanelContainingGroup(_ groupId: UUID, direction: DockSplitDirection, withNewPanel newPanel: Panel, in panel: inout Panel) {
        switch panel.content {
        case .content:
            break

        case .group(var group):
            if panel.id == groupId && (group.style == .tabs || group.style == .thumbnails) {
                // Replace this panel with a split containing both
                let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
                let insertFirst = (direction == .left || direction == .top)
                let children = insertFirst ? [newPanel, panel] : [panel, newPanel]
                panel = Panel(
                    content: .group(PanelGroup(
                        children: children,
                        activeIndex: 0,
                        axis: axis,
                        proportions: [0.5, 0.5],
                        style: .split
                    ))
                )
            } else if group.style == .split {
                for i in 0..<group.children.count {
                    splitPanelContainingGroup(groupId, direction: direction, withNewPanel: newPanel, in: &group.children[i])
                }
                panel.content = .group(group)
            }
            // .stages — cannot split inside a stage host from outside
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

    public func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint) {
        // Detach into a new floating window
        guard let panel = panelRegistry[panelId] else { return }
        detachPanel(panel, at: screenPoint)
    }

    public func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {
        // Handle split request from floating window - for now just log
        print("[DockContainerVC] Floating window requested split - not implemented")
    }

    public func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Find the panel from the registry
        guard let panel = panelRegistry[tabInfo.tabId] else { return }

        // Remove from source - BOTH model AND view controller in main window
        removeChild(withId: tabInfo.tabId, from: &rootPanel)
        removeChildFromAllControllers(tabInfo.tabId)

        // Also close any floating window that might contain this tab (except this one)
        for (windowId, otherWindow) in floatingWindows where windowId != window.windowId {
            if let floatingTabGroup = findFirstTabGroupControllerImpl(in: otherWindow.rootViewController),
               floatingTabGroup.panel.group?.children.contains(where: { $0.id == tabInfo.tabId }) == true {
                _ = floatingTabGroup.removeTab(withId: tabInfo.tabId)
                if floatingTabGroup.panel.group?.children.isEmpty == true && otherWindow.isEmpty {
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
