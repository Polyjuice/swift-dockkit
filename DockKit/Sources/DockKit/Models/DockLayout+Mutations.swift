import Foundation
import CoreGraphics

// MARK: - Layout Mutation Helpers

/// Extension providing convenient mutation methods for DockLayout
/// These methods return new layout instances (immutable pattern) for use with updateLayout()
public extension DockLayout {

    // MARK: - Window Operations

    /// Create a layout with a new window added
    func addingWindow(_ window: WindowState) -> DockLayout {
        var newLayout = self
        newLayout.windows.append(window)
        return newLayout
    }

    /// Create a layout with a window removed
    func removingWindow(_ windowId: UUID) -> DockLayout {
        var newLayout = self
        newLayout.windows.removeAll { $0.id == windowId }
        return newLayout
    }

    /// Create a layout with a window's frame updated
    func updatingWindowFrame(_ windowId: UUID, frame: CGRect) -> DockLayout {
        var newLayout = self
        if let index = newLayout.windows.firstIndex(where: { $0.id == windowId }) {
            newLayout.windows[index].frame = frame
        }
        return newLayout
    }

    /// Create a layout with a window's fullscreen state updated
    func updatingWindowFullScreen(_ windowId: UUID, isFullScreen: Bool) -> DockLayout {
        var newLayout = self
        if let index = newLayout.windows.firstIndex(where: { $0.id == windowId }) {
            newLayout.windows[index].isFullScreen = isFullScreen
        }
        return newLayout
    }

    // MARK: - Tab Operations

    /// Create a layout with a tab added to a specific group
    func addingTab(_ tab: TabLayoutState, toGroupId groupId: UUID, at index: Int? = nil) -> DockLayout {
        var newLayout = self
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.addingTab(
                tab,
                toGroupId: groupId,
                at: index,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    /// Create a layout with a tab removed
    /// Also removes any windows that become empty as a result
    func removingTab(_ tabId: UUID) -> DockLayout {
        var newLayout = self
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.removingTab(
                tabId,
                modified: &modified
            )
            if modified { break }
        }
        // Clean up empty windows
        newLayout.windows.removeAll { window in
            window.rootNode.isEmpty
        }
        return newLayout
    }

    /// Create a layout with a tab moved between groups
    func movingTab(_ tabId: UUID, toGroupId: UUID, at index: Int) -> DockLayout {
        // First find and extract the tab
        guard let tabInfo = findTab(tabId) else {
            // Tab not found in layout - this can happen if layout is stale
            // Return unchanged layout to prevent corruption
            print("[LAYOUT] Warning: movingTab - tab \(tabId.uuidString.prefix(8)) not found in layout")
            return self
        }

        // If the source and target group are the same, this is just a reorder
        // We still need to handle this case properly
        if tabInfo.groupId == toGroupId {
            // Check if this is a no-op (moving to same position or adjacent position)
            // Find current position of the tab
            if let groupInfo = findTabGroup(toGroupId),
               let currentIndex = groupInfo.group.tabs.firstIndex(where: { $0.id == tabId }) {
                // Check if move is effectively a no-op
                // Moving to same position OR moving to position right after current (which becomes same after remove)
                if currentIndex == index || currentIndex == index - 1 {
                    // No-op - tab is already at this position
                    return self
                }
            }

            // Just do a reorder within the same group
            var newLayout = self
            for windowIndex in newLayout.windows.indices {
                var modified = false
                newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.reorderingTab(
                    tabId,
                    inGroupId: toGroupId,
                    to: index,
                    modified: &modified
                )
                if modified { break }
            }
            return newLayout
        }

        // For cross-group moves:
        // First, verify the target group exists
        guard findTabGroup(toGroupId) != nil else {
            // Target group not found - this can happen if the layout is stale
            // (e.g., view has a group ID that doesn't match the JSON layout)
            print("[LAYOUT] Warning: movingTab - target group \(toGroupId.uuidString.prefix(8)) not found in layout")
            return self
        }

        // 1. Remove WITHOUT cleanup (preserve target group even if source becomes empty)
        // 2. Add to target
        // 3. Clean up empty nodes afterwards
        var newLayout = self
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.removingTabWithoutCleanup(
                tabId,
                modified: &modified
            )
        }

        // Add to target
        newLayout = newLayout.addingTab(tabInfo.tab, toGroupId: toGroupId, at: index)

        // Now clean up empty nodes
        for windowIndex in newLayout.windows.indices {
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.cleanedUp()
        }

        // Remove empty windows
        newLayout.windows.removeAll { $0.rootNode.isEmpty }

        return newLayout
    }

    /// Create a layout with the active tab changed in a group
    func settingActiveTab(in groupId: UUID, to index: Int) -> DockLayout {
        var newLayout = self
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.settingActiveTab(
                inGroupId: groupId,
                to: index,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    // MARK: - Split Operations

    /// Create a layout with a split created from a tab group
    /// The existing tab group becomes one child, and a new tab group with the given tab becomes the other
    /// This function handles:
    /// 1. Removing the tab from its source location (anywhere in the layout)
    /// 2. Creating the split with the tab in a new group
    /// 3. Cleaning up empty groups after the operation
    func splitting(
        groupId: UUID,
        direction: DockSplitDirection,
        withTab tab: TabLayoutState
    ) -> DockLayout {
        // GUARD: Check if this is a no-op (splitting a single-tab group with its only tab)
        // This happens when you drag a tab from a single-tab window onto the same window's split zone
        if let groupInfo = findTabGroup(groupId) {
            let group = groupInfo.group
            // If the group has exactly 1 tab AND that tab is the one we're splitting with,
            // this is a no-op - we'd end up with the same single-tab window
            if group.tabs.count == 1 && group.tabs.first?.id == tab.id {
                print("[LAYOUT] No-op: Cannot split single-tab group with its only tab")
                return self
            }
        }

        var newLayout = self

        // Step 1: First remove the tab from its current location (if it exists)
        // This handles the case where we're dragging from a different group
        for windowIndex in newLayout.windows.indices {
            var modified = false
            // Note: We use removingTabWithoutCleanup to avoid collapsing the tree prematurely
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.removingTabWithoutCleanup(
                tab.id,
                modified: &modified
            )
        }

        // Step 2: Do the split operation
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.splitting(
                groupId: groupId,
                direction: direction,
                withTab: tab,
                modified: &modified
            )
            if modified { break }
        }

        // Step 3: Clean up empty nodes AFTER the split
        for windowIndex in newLayout.windows.indices {
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.cleanedUp()
        }

        // Step 4: Remove completely empty windows
        newLayout.windows.removeAll { $0.rootNode.isEmpty }

        return newLayout
    }

    /// Create a layout with split proportions updated
    func updatingSplitProportions(_ splitId: UUID, proportions: [CGFloat]) -> DockLayout {
        var newLayout = self
        for windowIndex in newLayout.windows.indices {
            var modified = false
            newLayout.windows[windowIndex].rootNode = newLayout.windows[windowIndex].rootNode.updatingSplitProportions(
                splitId,
                proportions: proportions,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    // MARK: - Query Helpers

    /// Find a tab by ID and return its info
    func findTab(_ tabId: UUID) -> (tab: TabLayoutState, groupId: UUID, windowId: UUID)? {
        for window in windows {
            if let result = window.rootNode.findTabInfo(tabId) {
                return (tab: result.tab, groupId: result.groupId, windowId: window.id)
            }
        }
        return nil
    }

    /// Find a tab group by ID
    func findTabGroup(_ groupId: UUID) -> (group: TabGroupLayoutNode, windowId: UUID)? {
        for window in windows {
            if let group = window.rootNode.findTabGroupNode(groupId) {
                return (group: group, windowId: window.id)
            }
        }
        return nil
    }

    /// Get all tab IDs in the layout
    func getAllTabIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for window in windows {
            ids.formUnion(window.rootNode.allTabIds())
        }
        return ids
    }

    /// Get all tab group IDs in the layout
    func getAllTabGroupIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for window in windows {
            collectTabGroupIds(from: window.rootNode, into: &ids)
        }
        return ids
    }

    /// Helper to collect tab group IDs from a node tree
    private func collectTabGroupIds(from node: DockLayoutNode, into ids: inout Set<UUID>) {
        switch node {
        case .tabGroup(let tabGroup):
            ids.insert(tabGroup.id)
        case .split(let split):
            for child in split.children {
                collectTabGroupIds(from: child, into: &ids)
            }
        case .stageHost(let stageHost):
            // Collect from all stages in the nested host
            for stage in stageHost.stages {
                collectTabGroupIds(from: stage.layout, into: &ids)
            }
        }
    }
}

// MARK: - DockLayoutNode Mutation Helpers

extension DockLayoutNode {

    /// Add a tab to a specific group
    func addingTab(_ tab: TabLayoutState, toGroupId groupId: UUID, at index: Int?, modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            if tabGroup.id == groupId {
                let insertIndex = index ?? tabGroup.tabs.count
                tabGroup.tabs.insert(tab, at: min(insertIndex, tabGroup.tabs.count))
                modified = true
                return .tabGroup(tabGroup)
            }
            return self

        case .split(var split):
            split.children = split.children.map { child in
                child.addingTab(tab, toGroupId: groupId, at: index, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            // Recurse into all stages
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.addingTab(tab, toGroupId: groupId, at: index, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Remove a tab from the tree (with automatic cleanup)
    func removingTab(_ tabId: UUID, modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            let originalCount = tabGroup.tabs.count
            tabGroup.tabs.removeAll { $0.id == tabId }
            if tabGroup.tabs.count != originalCount {
                modified = true
                // Adjust active tab index if needed
                if tabGroup.activeTabIndex >= tabGroup.tabs.count {
                    tabGroup.activeTabIndex = max(0, tabGroup.tabs.count - 1)
                }
            }
            return .tabGroup(tabGroup)

        case .split(var split):
            split.children = split.children.map { child in
                child.removingTab(tabId, modified: &modified)
            }
            // Clean up empty children and collapse if needed
            return DockLayoutNode.split(split).cleanedUp()

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.removingTab(tabId, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Remove a tab from the tree WITHOUT triggering cleanup
    /// Used when we need to remove a tab but preserve the tree structure for subsequent operations
    func removingTabWithoutCleanup(_ tabId: UUID, modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            let originalCount = tabGroup.tabs.count
            tabGroup.tabs.removeAll { $0.id == tabId }
            if tabGroup.tabs.count != originalCount {
                modified = true
                // Adjust active tab index if needed
                if tabGroup.activeTabIndex >= tabGroup.tabs.count {
                    tabGroup.activeTabIndex = max(0, tabGroup.tabs.count - 1)
                }
            }
            return .tabGroup(tabGroup)

        case .split(var split):
            split.children = split.children.map { child in
                child.removingTabWithoutCleanup(tabId, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.removingTabWithoutCleanup(tabId, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Clean up empty tab groups/splits and collapse splits with single children
    public func cleanedUp() -> DockLayoutNode {
        switch self {
        case .tabGroup:
            return self

        case .split(var split):
            // Recursively clean children first
            split.children = split.children.map { $0.cleanedUp() }

            // Remove empty nodes (empty tab groups OR empty splits)
            // A split is empty if it has no children or all children are empty
            split.children.removeAll { child in
                child.isEmpty
            }

            // Collapse if only one child remains
            if split.children.count == 1 {
                return split.children[0]
            }

            // If no children remain, return empty tab group
            if split.children.isEmpty {
                return .tabGroup(TabGroupLayoutNode())
            }

            // Adjust proportions if children were removed
            if split.proportions.count != split.children.count {
                let equalProportion = 1.0 / CGFloat(split.children.count)
                split.proportions = Array(repeating: equalProportion, count: split.children.count)
            }

            return .split(split)

        case .stageHost(var stageHost):
            // Clean up all stages
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.cleanedUp()
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Set active tab in a group
    func settingActiveTab(inGroupId groupId: UUID, to index: Int, modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            if tabGroup.id == groupId {
                tabGroup.activeTabIndex = min(index, max(0, tabGroup.tabs.count - 1))
                modified = true
                return .tabGroup(tabGroup)
            }
            return self

        case .split(var split):
            split.children = split.children.map { child in
                child.settingActiveTab(inGroupId: groupId, to: index, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.settingActiveTab(inGroupId: groupId, to: index, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Reorder a tab within the same group
    /// The target index represents the FINAL desired position in the result array
    func reorderingTab(_ tabId: UUID, inGroupId groupId: UUID, to index: Int, modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            if tabGroup.id == groupId,
               let currentIndex = tabGroup.tabs.firstIndex(where: { $0.id == tabId }) {
                // Remove and reinsert at new position
                let tab = tabGroup.tabs.remove(at: currentIndex)
                // The target index represents the FINAL position we want the tab at
                // Since we removed the tab, the array is now one element shorter
                // - If moving backward (target < current): use target index as-is
                // - If moving forward (target > current): use target index as-is
                //   because target represents final position, not insertion point
                // Just clamp to valid range
                let safeIndex = min(max(0, index), tabGroup.tabs.count)
                tabGroup.tabs.insert(tab, at: safeIndex)

                // Update active tab index if it was affected
                if tabGroup.activeTabIndex == currentIndex {
                    tabGroup.activeTabIndex = safeIndex
                } else if currentIndex < tabGroup.activeTabIndex && safeIndex >= tabGroup.activeTabIndex {
                    tabGroup.activeTabIndex -= 1
                } else if currentIndex > tabGroup.activeTabIndex && safeIndex <= tabGroup.activeTabIndex {
                    tabGroup.activeTabIndex += 1
                }

                modified = true
                return .tabGroup(tabGroup)
            }
            return self

        case .split(var split):
            split.children = split.children.map { child in
                child.reorderingTab(tabId, inGroupId: groupId, to: index, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.reorderingTab(tabId, inGroupId: groupId, to: index, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Split a tab group into a split node
    func splitting(
        groupId: UUID,
        direction: DockSplitDirection,
        withTab tab: TabLayoutState,
        modified: inout Bool
    ) -> DockLayoutNode {
        switch self {
        case .tabGroup(var tabGroup):
            if tabGroup.id == groupId {
                // Remove the tab from the source group if it exists there
                // (this handles the case where we're splitting with an existing tab from this group)
                tabGroup.tabs.removeAll { $0.id == tab.id }

                // Adjust active tab index if needed
                if tabGroup.activeTabIndex >= tabGroup.tabs.count {
                    tabGroup.activeTabIndex = max(0, tabGroup.tabs.count - 1)
                }

                // Create new tab group for the dropped tab
                let newTabGroup = TabGroupLayoutNode(
                    id: UUID(),
                    tabs: [tab],
                    activeTabIndex: 0
                )

                // Determine axis and order
                let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
                let insertFirst = (direction == .left || direction == .top)

                // Use the modified tabGroup (with tab removed) as the source
                let sourceNode = DockLayoutNode.tabGroup(tabGroup)
                let children: [DockLayoutNode] = insertFirst
                    ? [.tabGroup(newTabGroup), sourceNode]
                    : [sourceNode, .tabGroup(newTabGroup)]

                modified = true
                return .split(SplitLayoutNode(
                    id: UUID(),
                    axis: axis,
                    children: children,
                    proportions: [0.5, 0.5]
                ))
            }
            return self

        case .split(var split):
            split.children = split.children.map { child in
                child.splitting(groupId: groupId, direction: direction, withTab: tab, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.splitting(groupId: groupId, direction: direction, withTab: tab, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    /// Update split proportions
    func updatingSplitProportions(_ splitId: UUID, proportions: [CGFloat], modified: inout Bool) -> DockLayoutNode {
        switch self {
        case .tabGroup:
            return self

        case .split(var split):
            if split.id == splitId && proportions.count == split.proportions.count {
                split.proportions = proportions
                modified = true
                return .split(split)
            }
            split.children = split.children.map { child in
                child.updatingSplitProportions(splitId, proportions: proportions, modified: &modified)
            }
            return .split(split)

        case .stageHost(var stageHost):
            stageHost.stages = stageHost.stages.map { stage in
                var d = stage
                d.layout = d.layout.updatingSplitProportions(splitId, proportions: proportions, modified: &modified)
                return d
            }
            return .stageHost(stageHost)
        }
    }

    // MARK: - Query Helpers

    /// Find a tab by ID (returns tab and its group ID)
    func findTabInfo(_ tabId: UUID) -> (tab: TabLayoutState, groupId: UUID)? {
        switch self {
        case .tabGroup(let tabGroup):
            if let tab = tabGroup.tabs.first(where: { $0.id == tabId }) {
                return (tab: tab, groupId: tabGroup.id)
            }
            return nil

        case .split(let split):
            for child in split.children {
                if let result = child.findTabInfo(tabId) {
                    return result
                }
            }
            return nil

        case .stageHost(let stageHost):
            for stage in stageHost.stages {
                if let result = stage.layout.findTabInfo(tabId) {
                    return result
                }
            }
            return nil
        }
    }

    /// Find a tab group by ID
    func findTabGroupNode(_ groupId: UUID) -> TabGroupLayoutNode? {
        switch self {
        case .tabGroup(let tabGroup):
            return tabGroup.id == groupId ? tabGroup : nil

        case .split(let split):
            for child in split.children {
                if let result = child.findTabGroupNode(groupId) {
                    return result
                }
            }
            return nil

        case .stageHost(let stageHost):
            for stage in stageHost.stages {
                if let result = stage.layout.findTabGroupNode(groupId) {
                    return result
                }
            }
            return nil
        }
    }

    // MARK: - Convenience Methods (without modified parameter)

    /// Move a tab to a different group (convenience method)
    public func movingTab(_ tabId: UUID, toGroupId: UUID, at index: Int) -> DockLayoutNode {
        // First find the tab info
        guard let tabInfo = findTabInfo(tabId) else { return self }

        // Remove from source, add to target
        var modified = false
        var result = removingTabWithoutCleanup(tabId, modified: &modified)
        result = result.addingTab(tabInfo.tab, toGroupId: toGroupId, at: index, modified: &modified)
        return result.cleanedUp()
    }

    /// Split a tab group (convenience method)
    public func splitting(groupId: UUID, direction: DockSplitDirection, withTab tab: TabLayoutState) -> DockLayoutNode {
        // GUARD: Check if this is a no-op (splitting a single-tab group with its only tab)
        if let group = findTabGroupNode(groupId) {
            if group.tabs.count == 1 && group.tabs.first?.id == tab.id {
                return self
            }
        }

        var modified = false
        var result = removingTabWithoutCleanup(tab.id, modified: &modified)
        result = result.splitting(groupId: groupId, direction: direction, withTab: tab, modified: &modified)
        return result.cleanedUp()
    }
}

// MARK: - Factory Methods

public extension WindowState {
    /// Create a simple window with a single tab group
    static func simple(
        id: UUID = UUID(),
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        tabs: [TabLayoutState] = [],
        activeTabIndex: Int = 0
    ) -> WindowState {
        WindowState(
            id: id,
            frame: frame,
            isFullScreen: false,
            rootNode: .tabGroup(TabGroupLayoutNode(
                id: UUID(),
                tabs: tabs,
                activeTabIndex: activeTabIndex
            ))
        )
    }
}

public extension TabLayoutState {
    /// Create a tab state from basic info
    static func create(
        id: UUID,
        title: String,
        iconName: String? = nil
    ) -> TabLayoutState {
        TabLayoutState(id: id, title: title, iconName: iconName)
    }
}
