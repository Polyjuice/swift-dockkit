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
        windowFactory: (Panel) -> DockWindow
    ) -> [DockWindow] {
        var windows = currentWindows

        // Suppress auto-close on ALL windows during reconciliation
        // This prevents windows from closing when tab groups temporarily become empty
        // during child moves (Phase 5) or panel tree reconciliation (Phase 4)
        for window in windows {
            window.suppressAutoClose = true
        }
        defer {
            for window in windows {
                window.suppressAutoClose = false
            }
        }

        // Phase 1: Pre-detach notifications for children that will move
        if verboseLogging { print("[RECONCILER] Phase 1: Pre-detach notifications for \(diff.movedChildren.count) child(ren)") }
        notifyPanelsWillDetach(for: diff, in: windows)

        // Phase 2: Close removed windows
        if verboseLogging { print("[RECONCILER] Phase 2: Close removed windows: \(diff.removedPanelIds.map { $0.uuidString.prefix(8) })") }
        for panelId in diff.removedPanelIds {
            if let index = windows.firstIndex(where: { $0.windowId == panelId }) {
                let window = windows[index]
                // Detach all panels first
                detachAllPanels(from: window.rootPanel)
                window.close()
                windows.remove(at: index)
                if verboseLogging { print("[RECONCILER]   Closed window \(panelId.uuidString.prefix(8))") }
            }
        }

        // Phase 3: Create new windows
        if verboseLogging { print("[RECONCILER] Phase 3: Create new windows: \(diff.addedPanelIds.map { $0.uuidString.prefix(8) })") }
        for rootPanel in targetLayout.panels {
            if diff.addedPanelIds.contains(rootPanel.id) {
                let newWindow = windowFactory(rootPanel)
                windows.append(newWindow)
                if verboseLogging { print("[RECONCILER]   Created window \(rootPanel.id.uuidString.prefix(8))") }
            }
        }

        // Phase 4: Reconcile existing windows
        if verboseLogging { print("[RECONCILER] Phase 4: Reconcile \(diff.modifiedPanels.count) modified window(s)") }
        let targetPanelsById = Dictionary(uniqueKeysWithValues: targetLayout.panels.map { ($0.id, $0) })

        for window in windows {
            guard let targetPanel = targetPanelsById[window.windowId],
                  let modification = diff.modifiedPanels[window.windowId] else {
                continue
            }

            if verboseLogging { print("[RECONCILER]   Reconciling window \(window.windowId.uuidString.prefix(8)): frame=\(modification.frameChanged), fullscreen=\(modification.fullScreenChanged), nodes=\(modification.nodeChanges.hasChanges)") }
            reconcileWindow(window, with: targetPanel, modification: modification)
        }

        // Phase 5: Apply child moves across windows
        if verboseLogging { print("[RECONCILER] Phase 5: Apply \(diff.movedChildren.count) child move(s)") }
        applyChildMoves(diff.movedChildren, in: &windows, targetLayout: targetLayout)

        // Phase 6: Post-dock notifications
        if verboseLogging { print("[RECONCILER] Phase 6: Post-dock notifications") }
        notifyPanelsDidDock(for: diff, in: windows)

        if verboseLogging { print("[RECONCILER] Reconciliation complete. Window count: \(windows.count)") }
        return windows
    }

    /// Reconcile a single window with its target state
    private func reconcileWindow(
        _ window: DockWindow,
        with targetPanel: Panel,
        modification: PanelModification
    ) {
        // Update frame if changed
        if modification.frameChanged, let frame = targetPanel.frame {
            window.setFrame(frame, display: true, animate: false)
        }

        // Handle fullscreen change (macOS manages this specially)
        if modification.fullScreenChanged {
            let targetFullScreen = targetPanel.isFullScreen ?? false
            if targetFullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if !targetFullScreen && window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }

        // Reconcile panel tree if changed
        if modification.nodeChanges.hasChanges {
            reconcilePanelTree(
                in: window,
                targetPanel: targetPanel,
                nodeChanges: modification.nodeChanges
            )
        }
    }

    // MARK: - Panel Tree Reconciliation

    /// Reconcile the panel tree within a window
    private func reconcilePanelTree(
        in window: DockWindow,
        targetPanel: Panel,
        nodeChanges: NodeChanges
    ) {
        // Note: suppressAutoClose is already set at the top level in reconcileWindows()

        guard let rootVC = window.rootViewController else {
            // No existing root - update model and rebuild from scratch
            window.rootPanel = resolvePanel(targetPanel)
            window.rebuildLayout()
            return
        }

        // Try to reconcile in place
        let success = reconcileNode(
            currentVC: rootVC,
            targetPanel: targetPanel,
            parentSplit: nil,
            indexInParent: nil,
            window: window
        )

        if !success {
            // Fallback: update model to target and rebuild the entire layout
            if verboseLogging {
                print("[RECONCILER] In-place reconciliation failed, rebuilding layout")
            }
            window.rootPanel = resolvePanel(targetPanel)
            window.rebuildLayout()
        } else {
            // CRITICAL: Even on successful in-place reconciliation, we must update
            // window.rootPanel to match the target layout. Otherwise getLayout() will
            // return stale IDs that don't match the view hierarchy, causing subsequent
            // child moves to fail because the target group ID won't be found.
            window.rootPanel = resolvePanel(targetPanel)
            if verboseLogging {
                print("[RECONCILER] In-place reconciliation succeeded, updated rootPanel model")
            }
        }
    }

    /// Reconcile a single node with its target state
    /// Returns true if successful, false if rebuild is needed
    @discardableResult
    private func reconcileNode(
        currentVC: NSViewController,
        targetPanel: Panel,
        parentSplit: DockSplitViewController?,
        indexInParent: Int?,
        window: DockWindow
    ) -> Bool {
        guard let targetGroup = targetPanel.group else {
            // Target is a content panel, not a group - need to replace
            if let parent = parentSplit, let index = indexInParent {
                parent.replaceChild(at: index, with: resolvePanel(targetPanel))
                return true
            }
            return false
        }

        switch (currentVC, targetGroup.style) {
        case (let splitVC as DockSplitViewController, .split):
            return reconcileSplit(splitVC, with: targetPanel, targetGroup: targetGroup, window: window)

        case (let tabGroupVC as DockTabGroupViewController, .tabs),
             (let tabGroupVC as DockTabGroupViewController, .thumbnails):
            return reconcileTabGroup(tabGroupVC, with: targetPanel, targetGroup: targetGroup)

        case (let stageHostVC as DockStageHostViewController, .stages):
            // Stage hosts: verify ID matches, rebuild if needed
            if stageHostVC.stagePanel.id != targetPanel.id {
                if let parent = parentSplit, let index = indexInParent {
                    parent.replaceChild(at: index, with: resolvePanel(targetPanel))
                    return true
                }
                return false
            }
            return true

        default:
            // Type mismatch - need to replace this node
            if let parent = parentSplit, let index = indexInParent {
                parent.replaceChild(at: index, with: resolvePanel(targetPanel))
                return true
            }
            // No parent means we need to rebuild root
            return false
        }
    }

    /// Reconcile a split view controller with its target state
    private func reconcileSplit(
        _ splitVC: DockSplitViewController,
        with targetPanel: Panel,
        targetGroup: PanelGroup,
        window: DockWindow
    ) -> Bool {
        let currentGroup = splitVC.panel.group!

        // Update axis if changed
        if currentGroup.axis != targetGroup.axis {
            splitVC.updateAxis(targetGroup.axis)
        }

        // Update proportions if changed
        if currentGroup.proportions != targetGroup.proportions {
            splitVC.setProportions(targetGroup.proportions)
        }

        // Reconcile children
        let currentChildIds = currentGroup.children.map { $0.id }
        let targetChildIds = targetGroup.children.map { $0.id }

        // Check if we need structural changes
        if currentChildIds != targetChildIds {
            // Complex reconciliation - rebuild children
            return reconcileSplitChildren(splitVC, with: targetGroup.children, window: window)
        } else {
            // Same children, just recursively reconcile
            for (index, (childVC, targetChild)) in zip(splitVC.splitViewItems.map { $0.viewController }, targetGroup.children).enumerated() {
                if !reconcileNode(
                    currentVC: childVC,
                    targetPanel: targetChild,
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
        with targetChildren: [Panel],
        window: DockWindow
    ) -> Bool {
        let currentGroup = splitVC.panel.group!

        // Build maps for matching
        var currentChildMap: [UUID: (index: Int, vc: NSViewController)] = [:]
        for (index, item) in splitVC.splitViewItems.enumerated() {
            let nodeId = nodeIdFromViewController(item.viewController)
            currentChildMap[nodeId] = (index, item.viewController)
        }

        // Determine which children to keep, remove, or add
        let targetChildIds = Set(targetChildren.map { $0.id })
        let currentChildIds = Set(currentGroup.children.map { $0.id })

        let toRemove = currentChildIds.subtracting(targetChildIds)
        let toAdd = targetChildIds.subtracting(currentChildIds)
        let toKeep = currentChildIds.intersection(targetChildIds)

        // Remove children (in reverse order to maintain indices)
        for (index, item) in splitVC.splitViewItems.enumerated().reversed() {
            let nodeId = nodeIdFromViewController(item.viewController)
            if toRemove.contains(nodeId) {
                // Detach panels before removing
                if let tabGroupVC = item.viewController as? DockTabGroupViewController {
                    let tabChildren = tabGroupVC.group?.children ?? []
                    for child in tabChildren {
                        if let dockablePanel = tabGroupVC.panelProvider?(child.id) {
                            panelWillDetach?(dockablePanel)
                        }
                    }
                }
                splitVC.removeDockChild(at: index)
            }
        }

        // Reorder and add children to match target
        for (targetIndex, targetChild) in targetChildren.enumerated() {
            let targetId = targetChild.id

            if toKeep.contains(targetId) {
                // This child exists - move to correct position if needed
                if let currentInfo = currentChildMap[targetId] {
                    // Recursively reconcile
                    if !reconcileNode(
                        currentVC: currentInfo.vc,
                        targetPanel: targetChild,
                        parentSplit: splitVC,
                        indexInParent: targetIndex,
                        window: window
                    ) {
                        return false
                    }
                }
            } else if toAdd.contains(targetId) {
                // New child - create and insert
                let resolvedChild = resolvePanel(targetChild)
                splitVC.insertChild(resolvedChild, at: targetIndex)
            }
        }

        return true
    }

    /// Reconcile a tab group view controller with its target state
    private func reconcileTabGroup(
        _ tabGroupVC: DockTabGroupViewController,
        with targetPanel: Panel,
        targetGroup: PanelGroup
    ) -> Bool {
        // Reconcile children
        tabGroupVC.reconcileTabs(with: targetGroup.children, panelProvider: panelProvider)

        // Update active child index
        if tabGroupVC.activeIndex != targetGroup.activeIndex {
            tabGroupVC.activateTab(at: targetGroup.activeIndex)
        }

        return true
    }

    // MARK: - Child Movement

    /// Apply child moves across windows
    private func applyChildMoves(
        _ moves: [ChildMove],
        in windows: inout [DockWindow],
        targetLayout: DockLayout
    ) {
        // Group moves by source window to batch removals
        let movesBySource = Dictionary(grouping: moves.filter { $0.fromRootPanelId != nil }) {
            $0.fromRootPanelId!
        }

        // Track children we need to insert
        var childrenToInsert: [(child: Panel, dockablePanel: (any DockablePanel)?, move: ChildMove)] = []

        // Phase 1: Remove children from sources and collect for insertion
        for (sourceRootPanelId, windowMoves) in movesBySource {
            guard let sourceWindow = windows.first(where: { $0.windowId == sourceRootPanelId }) else {
                continue
            }

            for move in windowMoves {
                guard let sourceGroupId = move.fromGroupId else { continue }

                // Find and remove the child
                if let result = findAndRemoveChild(
                    withId: move.childId,
                    fromGroupId: sourceGroupId,
                    in: sourceWindow
                ) {
                    childrenToInsert.append((result.child, result.dockablePanel, move))
                }
            }
        }

        // Phase 2: Insert children at destinations
        for (child, dockablePanel, move) in childrenToInsert {
            guard let targetWindow = windows.first(where: { $0.windowId == move.toRootPanelId }) else {
                continue
            }

            insertChild(child, dockablePanel: dockablePanel, toGroupId: move.toGroupId, at: move.toIndex, in: targetWindow)
        }
    }

    /// Find and remove a child from a window, returning the child panel and its DockablePanel
    private func findAndRemoveChild(
        withId childId: UUID,
        fromGroupId groupId: UUID,
        in window: DockWindow
    ) -> (child: Panel, dockablePanel: (any DockablePanel)?)? {
        guard let tabGroupVC = findTabGroupController(withId: groupId, in: window.rootViewController) else {
            return nil
        }

        let tabChildren = tabGroupVC.group?.children ?? []
        guard let index = tabChildren.firstIndex(where: { $0.id == childId }) else {
            return nil
        }

        let child = tabChildren[index]

        // Notify panel will detach
        if let dockablePanel = panelProvider?(childId) {
            panelWillDetach?(dockablePanel)
        }

        // Remove from view controller
        _ = tabGroupVC.removeTab(at: index)

        return (child, panelProvider?(childId))
    }

    /// Insert a child into a target group
    private func insertChild(
        _ child: Panel,
        dockablePanel: (any DockablePanel)?,
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

        // Check if child already exists in target group (can happen when split mutation already added it)
        let existingChildren = tabGroupVC.group?.children ?? []
        if existingChildren.contains(where: { $0.id == child.id }) {
            if verboseLogging {
                print("[RECONCILER] Child \(child.id.uuidString.prefix(8)) already in target group, skipping insert")
            }
            return
        }

        tabGroupVC.insertChildPanel(child, at: index, dockablePanel: dockablePanel, activate: false)

        // Notify panel did dock
        if let dockablePanel = dockablePanel ?? panelProvider?(child.id) {
            panelDidDock?(dockablePanel)
        }
    }

    // MARK: - Panel Notifications

    /// Notify panels that will be detached
    private func notifyPanelsWillDetach(for diff: DockLayoutDiff, in windows: [DockWindow]) {
        for move in diff.movedChildren {
            guard let sourceRootPanelId = move.fromRootPanelId,
                  let sourceWindow = windows.first(where: { $0.windowId == sourceRootPanelId }),
                  let groupId = move.fromGroupId,
                  let tabGroupVC = findTabGroupController(withId: groupId, in: sourceWindow.rootViewController),
                  (tabGroupVC.group?.children ?? []).contains(where: { $0.id == move.childId }),
                  let dockablePanel = panelProvider?(move.childId) else {
                continue
            }

            panelWillDetach?(dockablePanel)
        }
    }

    /// Notify panels that were docked
    private func notifyPanelsDidDock(for diff: DockLayoutDiff, in windows: [DockWindow]) {
        for move in diff.movedChildren {
            guard let targetWindow = windows.first(where: { $0.windowId == move.toRootPanelId }),
                  let tabGroupVC = findTabGroupController(withId: move.toGroupId, in: targetWindow.rootViewController),
                  (tabGroupVC.group?.children ?? []).contains(where: { $0.id == move.childId }),
                  let dockablePanel = panelProvider?(move.childId) else {
                continue
            }

            panelDidDock?(dockablePanel)
        }
    }

    /// Detach all panels from a panel tree
    private func detachAllPanels(from panel: Panel) {
        switch panel.content {
        case .content:
            if let dockablePanel = panelProvider?(panel.id) {
                panelWillDetach?(dockablePanel)
            }
        case .group(let group):
            for child in group.children {
                detachAllPanels(from: child)
            }
        }
    }

    // MARK: - Helpers

    /// Get node ID from a view controller
    private func nodeIdFromViewController(_ vc: NSViewController) -> UUID {
        if let splitVC = vc as? DockSplitViewController {
            return splitVC.nodeId
        } else if let tabGroupVC = vc as? DockTabGroupViewController {
            return tabGroupVC.panel.id
        } else if let stageHostVC = vc as? DockStageHostViewController {
            return stageHostVC.stagePanel.id
        }
        return UUID() // Fallback - should not happen
    }

    /// Resolve a target Panel by attaching DockablePanel instances via panelProvider
    /// This creates a Panel ready for the view hierarchy (with all children resolved)
    private func resolvePanel(_ targetPanel: Panel) -> Panel {
        switch targetPanel.content {
        case .content:
            // Leaf panel - try to resolve via panelProvider
            if let dockablePanel = panelProvider?(targetPanel.id) {
                if verboseLogging {
                    print("[RECONCILER] resolvePanel: FOUND panel '\(dockablePanel.panelTitle)' for \(targetPanel.id.uuidString.prefix(8))")
                }
            } else {
                if verboseLogging {
                    print("[RECONCILER] resolvePanel: panelProvider returned NIL for \(targetPanel.id.uuidString.prefix(8)) - creating placeholder")
                }
            }
            return targetPanel

        case .group(var group):
            // Recursively resolve children
            group.children = group.children.map { resolvePanel($0) }
            var resolved = targetPanel
            resolved.content = .group(group)
            return resolved
        }
    }

    /// Find a tab group controller by ID in the view hierarchy
    private func findTabGroupController(withId id: UUID, in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController,
           tabGroup.panel.id == id {
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
