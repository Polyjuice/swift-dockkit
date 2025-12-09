import AppKit

/// Reconciles layout changes with the actual view hierarchy
/// This is the core of the JSON-to-view synchronization system
///
/// Key principles:
/// 1. Panels are NEVER recreated - only moved between containers
/// 2. Split/TabGroup containers CAN be recreated when needed
/// 3. View controllers are reused when IDs match
/// 4. Changes are applied in safe order: detach first, then attach
public class DockLayoutReconciler {

    // MARK: - Dependencies

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Callback before a panel is detached from its container
    public var panelWillDetach: ((any DockablePanel) -> Void)?

    /// Callback after a panel is docked to a new location
    public var panelDidDock: ((any DockablePanel) -> Void)?

    /// Enable verbose logging of reconciliation phases
    public var verboseLogging: Bool = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Window Reconciliation

    /// Reconcile the windows collection with a target layout
    /// Returns the reconciled windows array
    public func reconcileWindows(
        currentWindows: [DockWindow],
        targetLayout: DockLayout,
        diff: DockLayoutDiff,
        windowFactory: (WindowState) -> DockWindow
    ) -> [DockWindow] {
        var windows = currentWindows

        // Suppress auto-close on ALL windows during reconciliation
        // This prevents windows from closing when tab groups temporarily become empty
        // during tab moves (Phase 5) or node tree reconciliation (Phase 4)
        for window in windows {
            window.suppressAutoClose = true
        }
        defer {
            for window in windows {
                window.suppressAutoClose = false
            }
        }

        // Phase 1: Pre-detach notifications for tabs that will move
        if verboseLogging { print("[RECONCILER] Phase 1: Pre-detach notifications for \(diff.movedTabs.count) tab(s)") }
        notifyPanelsWillDetach(for: diff, in: windows)

        // Phase 2: Close removed windows
        if verboseLogging { print("[RECONCILER] Phase 2: Close removed windows: \(diff.removedWindowIds.map { $0.uuidString.prefix(8) })") }
        for windowId in diff.removedWindowIds {
            if let index = windows.firstIndex(where: { $0.windowId == windowId }) {
                let window = windows[index]
                // Detach all panels first
                detachAllPanels(from: window.rootNode)
                window.close()
                windows.remove(at: index)
                if verboseLogging { print("[RECONCILER]   Closed window \(windowId.uuidString.prefix(8))") }
            }
        }

        // Phase 3: Create new windows
        if verboseLogging { print("[RECONCILER] Phase 3: Create new windows: \(diff.addedWindowIds.map { $0.uuidString.prefix(8) })") }
        for windowState in targetLayout.windows {
            if diff.addedWindowIds.contains(windowState.id) {
                let newWindow = windowFactory(windowState)
                windows.append(newWindow)
                if verboseLogging { print("[RECONCILER]   Created window \(windowState.id.uuidString.prefix(8))") }
            }
        }

        // Phase 4: Reconcile existing windows
        if verboseLogging { print("[RECONCILER] Phase 4: Reconcile \(diff.modifiedWindows.count) modified window(s)") }
        let targetWindowsById = Dictionary(uniqueKeysWithValues: targetLayout.windows.map { ($0.id, $0) })

        for window in windows {
            guard let targetState = targetWindowsById[window.windowId],
                  let modification = diff.modifiedWindows[window.windowId] else {
                continue
            }

            if verboseLogging { print("[RECONCILER]   Reconciling window \(window.windowId.uuidString.prefix(8)): frame=\(modification.frameChanged), fullscreen=\(modification.fullScreenChanged), nodes=\(modification.nodeChanges.hasChanges)") }
            reconcileWindow(window, with: targetState, modification: modification)
        }

        // Phase 5: Apply tab moves across windows
        if verboseLogging { print("[RECONCILER] Phase 5: Apply \(diff.movedTabs.count) tab move(s)") }
        applyTabMoves(diff.movedTabs, in: &windows, targetLayout: targetLayout)

        // Phase 6: Post-dock notifications
        if verboseLogging { print("[RECONCILER] Phase 6: Post-dock notifications") }
        notifyPanelsDidDock(for: diff, in: windows)

        if verboseLogging { print("[RECONCILER] Reconciliation complete. Window count: \(windows.count)") }
        return windows
    }

    /// Reconcile a single window with its target state
    private func reconcileWindow(
        _ window: DockWindow,
        with targetState: WindowState,
        modification: WindowModification
    ) {
        // Update frame if changed
        if modification.frameChanged {
            window.setFrame(targetState.frame, display: true, animate: false)
        }

        // Handle fullscreen change (macOS manages this specially)
        if modification.fullScreenChanged {
            if targetState.isFullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if !targetState.isFullScreen && window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }

        // Reconcile node tree if changed
        if modification.nodeChanges.hasChanges {
            reconcileNodeTree(
                in: window,
                targetNode: targetState.rootNode,
                nodeChanges: modification.nodeChanges
            )
        }
    }

    // MARK: - Node Tree Reconciliation

    /// Reconcile the node tree within a window
    private func reconcileNodeTree(
        in window: DockWindow,
        targetNode: DockLayoutNode,
        nodeChanges: NodeChanges
    ) {
        // Note: suppressAutoClose is already set at the top level in reconcileWindows()

        guard let rootVC = window.rootViewController else {
            // No existing root - update model and rebuild from scratch
            window.rootNode = convertLayoutNodeToDockNode(targetNode)
            window.rebuildLayout()
            return
        }

        // Try to reconcile in place
        let success = reconcileNode(
            currentVC: rootVC,
            targetNode: targetNode,
            parentSplit: nil,
            indexInParent: nil,
            window: window
        )

        if !success {
            // Fallback: update model to target and rebuild the entire layout
            if verboseLogging {
                print("[RECONCILER] In-place reconciliation failed, rebuilding layout")
            }
            window.rootNode = convertLayoutNodeToDockNode(targetNode)
            window.rebuildLayout()
        } else {
            // CRITICAL: Even on successful in-place reconciliation, we must update
            // window.rootNode to match the target layout. Otherwise getLayout() will
            // return stale IDs that don't match the view hierarchy, causing subsequent
            // tab moves to fail because the target group ID won't be found.
            window.rootNode = convertLayoutNodeToDockNode(targetNode)
            if verboseLogging {
                print("[RECONCILER] In-place reconciliation succeeded, updated rootNode model")
            }
        }
    }

    /// Reconcile a single node with its target state
    /// Returns true if successful, false if rebuild is needed
    @discardableResult
    private func reconcileNode(
        currentVC: NSViewController,
        targetNode: DockLayoutNode,
        parentSplit: DockSplitViewController?,
        indexInParent: Int?,
        window: DockWindow
    ) -> Bool {
        switch (currentVC, targetNode) {
        case (let splitVC as DockSplitViewController, .split(let targetSplit)):
            return reconcileSplit(splitVC, with: targetSplit, window: window)

        case (let tabGroupVC as DockTabGroupViewController, .tabGroup(let targetTabGroup)):
            return reconcileTabGroup(tabGroupVC, with: targetTabGroup)

        default:
            // Type mismatch - need to replace this node
            if let parent = parentSplit, let index = indexInParent {
                let newNode = convertLayoutNodeToDockNode(targetNode)
                parent.replaceChild(at: index, with: newNode)
                return true
            }
            // No parent means we need to rebuild root
            return false
        }
    }

    /// Reconcile a split view controller with its target state
    private func reconcileSplit(
        _ splitVC: DockSplitViewController,
        with targetSplit: SplitLayoutNode,
        window: DockWindow
    ) -> Bool {
        // Update axis if changed
        if splitVC.splitNode.axis != targetSplit.axis {
            splitVC.updateAxis(targetSplit.axis)
        }

        // Update proportions if changed
        if splitVC.splitNode.proportions != targetSplit.proportions {
            splitVC.setProportions(targetSplit.proportions)
        }

        // Reconcile children
        let currentChildIds = splitVC.splitNode.children.map { $0.nodeId }
        let targetChildIds = targetSplit.children.map { nodeIdFromLayoutNode($0) }

        // Check if we need structural changes
        if currentChildIds != targetChildIds {
            // Complex reconciliation - rebuild children
            return reconcileSplitChildren(splitVC, with: targetSplit.children, window: window)
        } else {
            // Same children, just recursively reconcile
            for (index, (childVC, targetChild)) in zip(splitVC.splitViewItems.map { $0.viewController }, targetSplit.children).enumerated() {
                if !reconcileNode(
                    currentVC: childVC,
                    targetNode: targetChild,
                    parentSplit: splitVC,
                    indexInParent: index,
                    window: window
                ) {
                    return false
                }
            }
            return true
        }
    }

    /// Reconcile split children when structure has changed
    private func reconcileSplitChildren(
        _ splitVC: DockSplitViewController,
        with targetChildren: [DockLayoutNode],
        window: DockWindow
    ) -> Bool {
        // Build maps for matching
        var currentChildMap: [UUID: (index: Int, vc: NSViewController)] = [:]
        for (index, item) in splitVC.splitViewItems.enumerated() {
            let nodeId = nodeIdFromViewController(item.viewController)
            currentChildMap[nodeId] = (index, item.viewController)
        }

        // Determine which children to keep, remove, or add
        let targetChildIds = Set(targetChildren.map { nodeIdFromLayoutNode($0) })
        let currentChildIds = Set(currentChildMap.keys)

        let toRemove = currentChildIds.subtracting(targetChildIds)
        let toAdd = targetChildIds.subtracting(currentChildIds)
        let toKeep = currentChildIds.intersection(targetChildIds)

        // Remove children (in reverse order to maintain indices)
        for (index, item) in splitVC.splitViewItems.enumerated().reversed() {
            let nodeId = nodeIdFromViewController(item.viewController)
            if toRemove.contains(nodeId) {
                // Detach panels before removing
                if let tabGroupVC = item.viewController as? DockTabGroupViewController {
                    for tab in tabGroupVC.tabGroupNode.tabs {
                        if let panel = tab.panel {
                            panelWillDetach?(panel)
                        }
                    }
                }
                splitVC.removeDockChild(at: index)
            }
        }

        // Reorder and add children to match target
        for (targetIndex, targetChild) in targetChildren.enumerated() {
            let targetId = nodeIdFromLayoutNode(targetChild)

            if toKeep.contains(targetId) {
                // This child exists - move to correct position if needed
                if let currentInfo = currentChildMap[targetId] {
                    // Recursively reconcile
                    if !reconcileNode(
                        currentVC: currentInfo.vc,
                        targetNode: targetChild,
                        parentSplit: splitVC,
                        indexInParent: targetIndex,
                        window: window
                    ) {
                        return false
                    }
                }
            } else if toAdd.contains(targetId) {
                // New child - create and insert
                let newNode = convertLayoutNodeToDockNode(targetChild)
                splitVC.insertChild(newNode, at: targetIndex)
            }
        }

        return true
    }

    /// Reconcile a tab group view controller with its target state
    private func reconcileTabGroup(
        _ tabGroupVC: DockTabGroupViewController,
        with targetTabGroup: TabGroupLayoutNode
    ) -> Bool {
        // Reconcile tabs
        tabGroupVC.reconcileTabs(with: targetTabGroup.tabs, panelProvider: panelProvider)

        // Update active tab index
        if tabGroupVC.tabGroupNode.activeTabIndex != targetTabGroup.activeTabIndex {
            tabGroupVC.activateTab(at: targetTabGroup.activeTabIndex)
        }

        return true
    }

    // MARK: - Tab Movement

    /// Apply tab moves across windows
    private func applyTabMoves(
        _ moves: [TabMove],
        in windows: inout [DockWindow],
        targetLayout: DockLayout
    ) {
        // Group moves by source window to batch removals
        let movesBySource = Dictionary(grouping: moves.filter { $0.fromWindowId != nil }) {
            $0.fromWindowId!
        }

        // Track tabs we need to insert
        var tabsToInsert: [(tab: DockTab, move: TabMove)] = []

        // Phase 1: Remove tabs from sources and collect for insertion
        for (sourceWindowId, windowMoves) in movesBySource {
            guard let sourceWindow = windows.first(where: { $0.windowId == sourceWindowId }) else {
                continue
            }

            for move in windowMoves {
                guard let sourceGroupId = move.fromGroupId else { continue }

                // Find and remove the tab
                if let (tab, _) = findAndRemoveTab(
                    withId: move.tabId,
                    fromGroupId: sourceGroupId,
                    in: sourceWindow
                ) {
                    tabsToInsert.append((tab, move))
                }
            }
        }

        // Phase 2: Insert tabs at destinations
        for (tab, move) in tabsToInsert {
            guard let targetWindow = windows.first(where: { $0.windowId == move.toWindowId }) else {
                continue
            }

            insertTab(tab, toGroupId: move.toGroupId, at: move.toIndex, in: targetWindow)
        }
    }

    /// Find and remove a tab from a window, returning the tab and its panel
    private func findAndRemoveTab(
        withId tabId: UUID,
        fromGroupId groupId: UUID,
        in window: DockWindow
    ) -> (tab: DockTab, panel: (any DockablePanel)?)? {
        guard let tabGroupVC = findTabGroupController(withId: groupId, in: window.rootViewController) else {
            return nil
        }

        guard let index = tabGroupVC.tabGroupNode.tabs.firstIndex(where: { $0.id == tabId }) else {
            return nil
        }

        let tab = tabGroupVC.tabGroupNode.tabs[index]

        // Notify panel will detach
        if let panel = tab.panel {
            panelWillDetach?(panel)
        }

        // Remove from view controller - use the existing public method
        _ = tabGroupVC.removeTab(at: index)

        return (tab, tab.panel)
    }

    /// Insert a tab into a target group
    private func insertTab(
        _ tab: DockTab,
        toGroupId groupId: UUID,
        at index: Int,
        in window: DockWindow
    ) {
        guard let tabGroupVC = findTabGroupController(withId: groupId, in: window.rootViewController) else {
            if verboseLogging {
                print("[RECONCILER] Warning: Target tab group \(groupId) not found")
            }
            return
        }

        // Check if tab already exists in target group (can happen when split mutation already added it)
        if tabGroupVC.tabGroupNode.tabs.contains(where: { $0.id == tab.id }) {
            if verboseLogging {
                print("[RECONCILER] Tab \(tab.id.uuidString.prefix(8)) already in target group, skipping insert")
            }
            return
        }

        tabGroupVC.insertDockTab(tab, at: index, activate: false)

        // Notify panel did dock
        if let panel = tab.panel {
            panelDidDock?(panel)
        }
    }

    // MARK: - Panel Notifications

    /// Notify panels that will be detached
    private func notifyPanelsWillDetach(for diff: DockLayoutDiff, in windows: [DockWindow]) {
        for move in diff.movedTabs {
            guard let sourceWindowId = move.fromWindowId,
                  let sourceWindow = windows.first(where: { $0.windowId == sourceWindowId }),
                  let groupId = move.fromGroupId,
                  let tabGroupVC = findTabGroupController(withId: groupId, in: sourceWindow.rootViewController),
                  let tab = tabGroupVC.tabGroupNode.tabs.first(where: { $0.id == move.tabId }),
                  let panel = tab.panel else {
                continue
            }

            panelWillDetach?(panel)
        }
    }

    /// Notify panels that were docked
    private func notifyPanelsDidDock(for diff: DockLayoutDiff, in windows: [DockWindow]) {
        for move in diff.movedTabs {
            guard let targetWindow = windows.first(where: { $0.windowId == move.toWindowId }),
                  let tabGroupVC = findTabGroupController(withId: move.toGroupId, in: targetWindow.rootViewController),
                  let tab = tabGroupVC.tabGroupNode.tabs.first(where: { $0.id == move.tabId }),
                  let panel = tab.panel else {
                continue
            }

            panelDidDock?(panel)
        }
    }

    /// Detach all panels from a node tree
    private func detachAllPanels(from node: DockNode) {
        switch node {
        case .tabGroup(let tabGroup):
            for tab in tabGroup.tabs {
                if let panel = tab.panel {
                    panelWillDetach?(panel)
                }
            }
        case .split(let split):
            for child in split.children {
                detachAllPanels(from: child)
            }
        }
    }

    // MARK: - Helpers

    /// Get node ID from a DockLayoutNode
    private func nodeIdFromLayoutNode(_ node: DockLayoutNode) -> UUID {
        switch node {
        case .split(let n): return n.id
        case .tabGroup(let n): return n.id
        }
    }

    /// Get node ID from a view controller
    private func nodeIdFromViewController(_ vc: NSViewController) -> UUID {
        if let splitVC = vc as? DockSplitViewController {
            return splitVC.nodeId
        } else if let tabGroupVC = vc as? DockTabGroupViewController {
            return tabGroupVC.tabGroupNode.id
        }
        return UUID() // Fallback - should not happen
    }

    /// Convert DockLayoutNode to DockNode
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
                // Try to get existing panel from provider
                if let panel = panelProvider?(tabState.id) {
                    if verboseLogging {
                        print("[RECONCILER] convertLayoutNodeToDockNode: FOUND panel '\(panel.panelTitle)' for tab \(tabState.id.uuidString.prefix(8))")
                    }
                    return DockTab(from: panel)
                }
                // Create placeholder tab
                if verboseLogging {
                    print("[RECONCILER] convertLayoutNodeToDockNode: panelProvider returned NIL for tab \(tabState.id.uuidString.prefix(8)) - creating placeholder")
                }
                return DockTab(
                    id: tabState.id,
                    title: tabState.title,
                    iconName: tabState.iconName,
                    panel: nil
                )
            }

            return .tabGroup(TabGroupNode(
                id: tabGroupLayout.id,
                tabs: tabs,
                activeTabIndex: tabGroupLayout.activeTabIndex
            ))
        }
    }

    /// Find a tab group controller by ID in the view hierarchy
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
}

