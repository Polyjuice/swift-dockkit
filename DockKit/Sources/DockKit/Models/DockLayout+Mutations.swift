import Foundation
import CoreGraphics

// MARK: - Layout Mutation Helpers

/// Extension providing convenient mutation methods for DockLayout
/// These methods return new layout instances (immutable pattern) for use with updateLayout()
public extension DockLayout {

    // MARK: - Panel (Window) Operations

    /// Create a layout with a new root panel added
    func addingPanel(_ panel: Panel) -> DockLayout {
        var newLayout = self
        newLayout.panels.append(panel)
        return newLayout
    }

    /// Create a layout with a root panel removed
    func removingPanel(_ panelId: UUID) -> DockLayout {
        var newLayout = self
        newLayout.panels.removeAll { $0.id == panelId }
        return newLayout
    }

    /// Create a layout with a root panel's frame updated
    func updatingPanelFrame(_ panelId: UUID, frame: CGRect) -> DockLayout {
        var newLayout = self
        if let index = newLayout.panels.firstIndex(where: { $0.id == panelId }) {
            newLayout.panels[index].frame = frame
        }
        return newLayout
    }

    /// Create a layout with a root panel's fullscreen state updated
    func updatingPanelFullScreen(_ panelId: UUID, isFullScreen: Bool) -> DockLayout {
        var newLayout = self
        if let index = newLayout.panels.firstIndex(where: { $0.id == panelId }) {
            newLayout.panels[index].isFullScreen = isFullScreen
        }
        return newLayout
    }

    // MARK: - Child Panel Operations

    /// Create a layout with a content panel added to a specific group
    func addingChild(_ child: Panel, toGroupId groupId: UUID, at index: Int? = nil) -> DockLayout {
        var newLayout = self
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].addingChild(
                child,
                toGroupId: groupId,
                at: index,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    /// Create a layout with a panel removed (by ID, anywhere in the tree)
    /// Also removes any root panels that become empty as a result
    func removingChild(_ childId: UUID) -> DockLayout {
        var newLayout = self
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].removingChild(
                childId,
                modified: &modified
            )
            if modified { break }
        }
        // Clean up empty root panels
        newLayout.panels.removeAll { $0.isEmpty }
        return newLayout
    }

    /// Create a layout with a panel moved between groups
    func movingChild(_ childId: UUID, toGroupId: UUID, at index: Int) -> DockLayout {
        // First find and extract the panel
        guard let childInfo = findChild(childId) else {
            print("[LAYOUT] Warning: movingChild - panel \(childId.uuidString.prefix(8)) not found in layout")
            return self
        }

        // If the source and target group are the same, this is just a reorder
        if childInfo.groupId == toGroupId {
            // Check if this is a no-op
            if let groupInfo = findGroupPanel(toGroupId),
               let group = groupInfo.panel.group,
               let currentIndex = group.children.firstIndex(where: { $0.id == childId }) {
                if currentIndex == index || currentIndex == index - 1 {
                    return self
                }
            }

            // Reorder within the same group
            var newLayout = self
            for i in newLayout.panels.indices {
                var modified = false
                newLayout.panels[i] = newLayout.panels[i].reorderingChild(
                    childId,
                    inGroupId: toGroupId,
                    to: index,
                    modified: &modified
                )
                if modified { break }
            }
            return newLayout
        }

        // Cross-group move
        guard findGroupPanel(toGroupId) != nil else {
            print("[LAYOUT] Warning: movingChild - target group \(toGroupId.uuidString.prefix(8)) not found in layout")
            return self
        }

        // 1. Remove WITHOUT cleanup
        var newLayout = self
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].removingChildWithoutCleanup(
                childId,
                modified: &modified
            )
        }

        // 2. Add to target
        newLayout = newLayout.addingChild(childInfo.panel, toGroupId: toGroupId, at: index)

        // 3. Clean up empty nodes
        for i in newLayout.panels.indices {
            newLayout.panels[i] = newLayout.panels[i].cleanedUp()
        }

        // 4. Remove empty root panels
        newLayout.panels.removeAll { $0.isEmpty }

        return newLayout
    }

    /// Create a layout with the active child changed in a group
    func settingActiveChild(in groupId: UUID, to index: Int) -> DockLayout {
        var newLayout = self
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].settingActiveChild(
                inGroupId: groupId,
                to: index,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    // MARK: - Split Operations

    /// Create a layout with a group split into two
    /// The existing group becomes one child, and a new group with the given panel becomes the other
    func splitting(
        groupId: UUID,
        direction: DockSplitDirection,
        withChild child: Panel
    ) -> DockLayout {
        // GUARD: Check if this is a no-op
        if let groupInfo = findGroupPanel(groupId),
           let group = groupInfo.panel.group {
            if group.children.count == 1 && group.children.first?.id == child.id {
                print("[LAYOUT] No-op: Cannot split single-child group with its only child")
                return self
            }
        }

        var newLayout = self

        // Step 1: Remove the child from its current location
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].removingChildWithoutCleanup(
                child.id,
                modified: &modified
            )
        }

        // Step 2: Do the split operation
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].splittingGroup(
                groupId: groupId,
                direction: direction,
                withChild: child,
                modified: &modified
            )
            if modified { break }
        }

        // Step 3: Clean up
        for i in newLayout.panels.indices {
            newLayout.panels[i] = newLayout.panels[i].cleanedUp()
        }

        // Step 4: Remove empty root panels
        newLayout.panels.removeAll { $0.isEmpty }

        return newLayout
    }

    /// Create a layout with split proportions updated
    func updatingSplitProportions(_ groupId: UUID, proportions: [CGFloat]) -> DockLayout {
        var newLayout = self
        for i in newLayout.panels.indices {
            var modified = false
            newLayout.panels[i] = newLayout.panels[i].updatingSplitProportions(
                groupId,
                proportions: proportions,
                modified: &modified
            )
            if modified { break }
        }
        return newLayout
    }

    // MARK: - Query Helpers

    /// Find a content panel by ID and return its info
    func findChild(_ childId: UUID) -> (panel: Panel, groupId: UUID, rootPanelId: UUID)? {
        for rootPanel in panels {
            if let result = rootPanel.findChildInfo(childId) {
                return (panel: result.panel, groupId: result.groupId, rootPanelId: rootPanel.id)
            }
        }
        return nil
    }

    /// Find a group panel by its ID
    func findGroupPanel(_ groupId: UUID) -> (panel: Panel, rootPanelId: UUID)? {
        for rootPanel in panels {
            if let found = rootPanel.findPanel(byId: groupId), found.isGroup {
                return (panel: found, rootPanelId: rootPanel.id)
            }
        }
        return nil
    }

    /// Get all content panel IDs in the layout
    func getAllContentIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for panel in panels {
            ids.formUnion(panel.allContentIds())
        }
        return ids
    }

    /// Get all group panel IDs in the layout
    func getAllGroupIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for panel in panels {
            for group in panel.allGroups() {
                ids.insert(group.id)
            }
        }
        return ids
    }
}

// MARK: - Panel Mutation Helpers (recursive)

extension Panel {

    /// Add a child to a specific group
    func addingChild(_ child: Panel, toGroupId groupId: UUID, at index: Int?, modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        if id == groupId {
            let insertIndex = index ?? group.children.count
            group.children.insert(child, at: min(insertIndex, group.children.count))
            group.recalculateProportions()
            modified = true
            var newPanel = self
            newPanel.content = .group(group)
            return newPanel
        }

        // Recurse into children
        group.children = group.children.map { $0.addingChild(child, toGroupId: groupId, at: index, modified: &modified) }
        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Remove a child from the tree (with automatic cleanup)
    func removingChild(_ childId: UUID, modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        let originalCount = group.children.count
        group.children.removeAll { $0.id == childId }
        if group.children.count != originalCount {
            modified = true
            if group.activeIndex >= group.children.count {
                group.activeIndex = max(0, group.children.count - 1)
            }
            group.recalculateProportions()
        }

        // Recurse into remaining children
        group.children = group.children.map { $0.removingChild(childId, modified: &modified) }

        var newPanel = self
        newPanel.content = .group(group)
        return newPanel.cleanedUp()
    }

    /// Remove a child WITHOUT triggering cleanup
    func removingChildWithoutCleanup(_ childId: UUID, modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        let originalCount = group.children.count
        group.children.removeAll { $0.id == childId }
        if group.children.count != originalCount {
            modified = true
            if group.activeIndex >= group.children.count {
                group.activeIndex = max(0, group.children.count - 1)
            }
        }

        // Recurse into remaining children
        group.children = group.children.map { $0.removingChildWithoutCleanup(childId, modified: &modified) }

        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Clean up empty groups and collapse groups with single children
    func cleanedUp() -> Panel {
        guard case .group(var group) = content else { return self }

        // Recursively clean children first
        group.children = group.children.map { $0.cleanedUp() }

        // Remove empty children
        group.children.removeAll { $0.isEmpty }

        // For split-style groups: collapse if only one child remains
        if group.style == .split {
            if group.children.count == 1 {
                return group.children[0]
            }
            if group.children.isEmpty {
                var newPanel = self
                newPanel.content = .group(PanelGroup(style: .tabs))
                return newPanel
            }
        }

        // Adjust proportions if children were removed
        if group.proportions.count != group.children.count {
            group.recalculateProportions()
        }

        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Set active child in a group
    func settingActiveChild(inGroupId groupId: UUID, to index: Int, modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        if id == groupId {
            group.activeIndex = min(index, max(0, group.children.count - 1))
            modified = true
            var newPanel = self
            newPanel.content = .group(group)
            return newPanel
        }

        group.children = group.children.map { $0.settingActiveChild(inGroupId: groupId, to: index, modified: &modified) }
        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Reorder a child within the same group
    func reorderingChild(_ childId: UUID, inGroupId groupId: UUID, to index: Int, modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        if id == groupId,
           let currentIndex = group.children.firstIndex(where: { $0.id == childId }) {
            let child = group.children.remove(at: currentIndex)
            let safeIndex = min(max(0, index), group.children.count)
            group.children.insert(child, at: safeIndex)

            // Update active index if affected
            if group.activeIndex == currentIndex {
                group.activeIndex = safeIndex
            } else if currentIndex < group.activeIndex && safeIndex >= group.activeIndex {
                group.activeIndex -= 1
            } else if currentIndex > group.activeIndex && safeIndex <= group.activeIndex {
                group.activeIndex += 1
            }

            modified = true
            var newPanel = self
            newPanel.content = .group(group)
            return newPanel
        }

        group.children = group.children.map { $0.reorderingChild(childId, inGroupId: groupId, to: index, modified: &modified) }
        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Split a group into a split-style group
    func splittingGroup(
        groupId: UUID,
        direction: DockSplitDirection,
        withChild child: Panel,
        modified: inout Bool
    ) -> Panel {
        guard case .group(var group) = content else { return self }

        if id == groupId {
            // Remove the child from this group if it's already here
            group.children.removeAll { $0.id == child.id }
            if group.activeIndex >= group.children.count {
                group.activeIndex = max(0, group.children.count - 1)
            }

            // Create new group for the dropped panel
            let newGroup = Panel(
                content: .group(PanelGroup(
                    children: [child],
                    activeIndex: 0,
                    style: group.style == .split ? .tabs : group.style
                ))
            )

            // Wrap current group as a panel
            var sourcePanel = self
            sourcePanel.content = .group(group)

            // Determine axis and order
            let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .top)

            let children: [Panel] = insertFirst
                ? [newGroup, sourcePanel]
                : [sourcePanel, newGroup]

            modified = true
            // Return a new split-style panel wrapping both
            return Panel(
                id: UUID(),
                content: .group(PanelGroup(
                    children: children,
                    activeIndex: 0,
                    axis: axis,
                    proportions: [0.5, 0.5],
                    style: .split
                ))
            )
        }

        // Recurse into children
        group.children = group.children.map { $0.splittingGroup(groupId: groupId, direction: direction, withChild: child, modified: &modified) }
        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    /// Update split proportions
    func updatingSplitProportions(_ groupId: UUID, proportions: [CGFloat], modified: inout Bool) -> Panel {
        guard case .group(var group) = content else { return self }

        if id == groupId && group.style == .split && proportions.count == group.proportions.count {
            group.proportions = proportions
            modified = true
            var newPanel = self
            newPanel.content = .group(group)
            return newPanel
        }

        group.children = group.children.map { $0.updatingSplitProportions(groupId, proportions: proportions, modified: &modified) }
        var newPanel = self
        newPanel.content = .group(group)
        return newPanel
    }

    // MARK: - Query Helpers

    /// Find a child panel by ID (returns panel and its parent group ID)
    func findChildInfo(_ childId: UUID) -> (panel: Panel, groupId: UUID)? {
        guard case .group(let group) = content else { return nil }

        // Check direct children
        if let child = group.children.first(where: { $0.id == childId }) {
            return (panel: child, groupId: id)
        }

        // Recurse into children
        for child in group.children {
            if let result = child.findChildInfo(childId) {
                return result
            }
        }
        return nil
    }

    /// Find a group panel by ID within this tree
    func findGroupPanel(_ groupId: UUID) -> Panel? {
        if id == groupId && isGroup { return self }
        guard case .group(let group) = content else { return nil }
        for child in group.children {
            if let found = child.findGroupPanel(groupId) { return found }
        }
        return nil
    }
}

// MARK: - Factory Methods

public extension Panel {
    /// Create a simple window panel with a tab group
    static func simpleWindow(
        id: UUID = UUID(),
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        children: [Panel] = [],
        activeIndex: Int = 0
    ) -> Panel {
        Panel(
            id: id,
            content: .group(PanelGroup(
                children: children,
                activeIndex: activeIndex,
                style: .tabs
            )),
            isTopLevelWindow: true,
            frame: frame,
            isFullScreen: false
        )
    }

    /// Create a content panel (leaf)
    static func contentPanel(
        id: UUID = UUID(),
        title: String,
        iconName: String? = nil,
        cargo: [String: AnyCodable]? = nil
    ) -> Panel {
        Panel(
            id: id,
            title: title,
            iconName: iconName,
            cargo: cargo,
            content: .content
        )
    }
}
