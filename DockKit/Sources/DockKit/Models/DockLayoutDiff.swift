import Foundation

// MARK: - Layout Diff

/// Represents the difference between two DockLayout states
/// Used to determine minimal view hierarchy changes needed
public struct DockLayoutDiff {
    /// Windows that were added
    public var addedWindowIds: Set<UUID>

    /// Windows that were removed
    public var removedWindowIds: Set<UUID>

    /// Windows that were modified (frame, fullscreen, or content changes)
    public var modifiedWindows: [UUID: WindowModification]

    /// Tabs that moved between groups (within or across windows)
    public var movedTabs: [TabMove]

    /// Whether there are any changes
    public var isEmpty: Bool {
        return addedWindowIds.isEmpty &&
               removedWindowIds.isEmpty &&
               modifiedWindows.isEmpty &&
               movedTabs.isEmpty
    }

    public init(
        addedWindowIds: Set<UUID> = [],
        removedWindowIds: Set<UUID> = [],
        modifiedWindows: [UUID: WindowModification] = [:],
        movedTabs: [TabMove] = []
    ) {
        self.addedWindowIds = addedWindowIds
        self.removedWindowIds = removedWindowIds
        self.modifiedWindows = modifiedWindows
        self.movedTabs = movedTabs
    }
}

// MARK: - Window Modification

/// Describes changes to a specific window
public struct WindowModification {
    public let windowId: UUID

    /// Frame change details (if changed)
    public var frameChanged: Bool

    /// Full-screen state changed
    public var fullScreenChanged: Bool

    /// Changes to the node tree inside this window
    public var nodeChanges: NodeChanges

    public init(
        windowId: UUID,
        frameChanged: Bool = false,
        fullScreenChanged: Bool = false,
        nodeChanges: NodeChanges = NodeChanges()
    ) {
        self.windowId = windowId
        self.frameChanged = frameChanged
        self.fullScreenChanged = fullScreenChanged
        self.nodeChanges = nodeChanges
    }

    /// Whether this modification has any actual changes
    public var hasChanges: Bool {
        return frameChanged || fullScreenChanged || nodeChanges.hasChanges
    }
}

// MARK: - Node Changes

/// Changes to the node tree within a window
public struct NodeChanges {
    /// Node IDs that were removed from the tree
    public var removedNodeIds: Set<UUID>

    /// New nodes that were added (keyed by ID)
    public var addedNodes: [UUID: DockLayoutNode]

    /// Nodes that were modified in place
    public var modifiedNodes: [UUID: NodeModification]

    public init(
        removedNodeIds: Set<UUID> = [],
        addedNodes: [UUID: DockLayoutNode] = [:],
        modifiedNodes: [UUID: NodeModification] = [:]
    ) {
        self.removedNodeIds = removedNodeIds
        self.addedNodes = addedNodes
        self.modifiedNodes = modifiedNodes
    }

    /// Whether there are any node changes
    public var hasChanges: Bool {
        return !removedNodeIds.isEmpty ||
               !addedNodes.isEmpty ||
               !modifiedNodes.isEmpty
    }
}

// MARK: - Node Modification

/// Describes changes to a specific node
public struct NodeModification {
    public let nodeId: UUID

    /// For split nodes: proportions changed
    public var proportionsChanged: Bool

    /// For split nodes: axis changed (horizontal <-> vertical)
    public var axisChanged: Bool

    /// For split nodes: children were reordered
    public var childrenReordered: Bool

    /// For tab groups: active tab index changed
    public var activeTabChanged: Bool

    /// For tab groups: tabs were added, removed, or reordered
    public var tabsChanged: Bool

    /// Specific tab changes for tab groups
    public var tabChanges: TabChanges?

    public init(
        nodeId: UUID,
        proportionsChanged: Bool = false,
        axisChanged: Bool = false,
        childrenReordered: Bool = false,
        activeTabChanged: Bool = false,
        tabsChanged: Bool = false,
        tabChanges: TabChanges? = nil
    ) {
        self.nodeId = nodeId
        self.proportionsChanged = proportionsChanged
        self.axisChanged = axisChanged
        self.childrenReordered = childrenReordered
        self.activeTabChanged = activeTabChanged
        self.tabsChanged = tabsChanged
        self.tabChanges = tabChanges
    }

    /// Whether there are any changes
    public var hasChanges: Bool {
        return proportionsChanged ||
               axisChanged ||
               childrenReordered ||
               activeTabChanged ||
               tabsChanged
    }
}

// MARK: - Tab Changes

/// Detailed changes to tabs within a tab group
public struct TabChanges {
    /// Tab IDs that were added to this group
    public var addedTabIds: [UUID]

    /// Tab IDs that were removed from this group
    public var removedTabIds: [UUID]

    /// Tabs that were reordered (mapping from old index to new index)
    public var reorderedTabs: [(tabId: UUID, fromIndex: Int, toIndex: Int)]

    public init(
        addedTabIds: [UUID] = [],
        removedTabIds: [UUID] = [],
        reorderedTabs: [(tabId: UUID, fromIndex: Int, toIndex: Int)] = []
    ) {
        self.addedTabIds = addedTabIds
        self.removedTabIds = removedTabIds
        self.reorderedTabs = reorderedTabs
    }

    public var hasChanges: Bool {
        return !addedTabIds.isEmpty ||
               !removedTabIds.isEmpty ||
               !reorderedTabs.isEmpty
    }
}

// MARK: - Tab Move

/// Describes a tab moving between groups (possibly across windows)
public struct TabMove {
    public let tabId: UUID

    /// Source window (nil if from external source)
    public let fromWindowId: UUID?

    /// Source tab group
    public let fromGroupId: UUID?

    /// Source index in the group
    public let fromIndex: Int?

    /// Target window
    public let toWindowId: UUID

    /// Target tab group
    public let toGroupId: UUID

    /// Target index in the group
    public let toIndex: Int

    public init(
        tabId: UUID,
        fromWindowId: UUID?,
        fromGroupId: UUID?,
        fromIndex: Int?,
        toWindowId: UUID,
        toGroupId: UUID,
        toIndex: Int
    ) {
        self.tabId = tabId
        self.fromWindowId = fromWindowId
        self.fromGroupId = fromGroupId
        self.fromIndex = fromIndex
        self.toWindowId = toWindowId
        self.toGroupId = toGroupId
        self.toIndex = toIndex
    }

    /// Whether this is a move within the same window
    public var isWithinSameWindow: Bool {
        return fromWindowId == toWindowId
    }

    /// Whether this is a move within the same group (just reordering)
    public var isWithinSameGroup: Bool {
        return fromGroupId == toGroupId
    }
}

// MARK: - Diff Computation

public extension DockLayoutDiff {
    /// Compute the difference between two layouts
    static func compute(from currentLayout: DockLayout, to targetLayout: DockLayout) -> DockLayoutDiff {
        var diff = DockLayoutDiff()

        let currentWindowIds = Set(currentLayout.windows.map { $0.id })
        let targetWindowIds = Set(targetLayout.windows.map { $0.id })

        // Find added and removed windows
        diff.addedWindowIds = targetWindowIds.subtracting(currentWindowIds)
        diff.removedWindowIds = currentWindowIds.subtracting(targetWindowIds)

        // Build lookup maps for existing windows
        let currentWindowsById = Dictionary(uniqueKeysWithValues: currentLayout.windows.map { ($0.id, $0) })
        let targetWindowsById = Dictionary(uniqueKeysWithValues: targetLayout.windows.map { ($0.id, $0) })

        // Compare windows that exist in both
        let commonWindowIds = currentWindowIds.intersection(targetWindowIds)
        for windowId in commonWindowIds {
            guard let currentWindow = currentWindowsById[windowId],
                  let targetWindow = targetWindowsById[windowId] else { continue }

            let modification = computeWindowModification(
                current: currentWindow,
                target: targetWindow
            )

            if modification.hasChanges {
                diff.modifiedWindows[windowId] = modification
            }
        }

        // Detect tab moves across windows
        diff.movedTabs = detectTabMoves(
            currentLayout: currentLayout,
            targetLayout: targetLayout
        )

        return diff
    }

    /// Compute modification for a single window
    private static func computeWindowModification(
        current: WindowState,
        target: WindowState
    ) -> WindowModification {
        var modification = WindowModification(windowId: current.id)

        // Check frame change
        modification.frameChanged = current.frame != target.frame

        // Check fullscreen change
        modification.fullScreenChanged = current.isFullScreen != target.isFullScreen

        // Compute node tree changes
        modification.nodeChanges = computeNodeChanges(
            current: current.rootNode,
            target: target.rootNode
        )

        return modification
    }

    /// Compute changes between two node trees
    private static func computeNodeChanges(
        current: DockLayoutNode,
        target: DockLayoutNode
    ) -> NodeChanges {
        var changes = NodeChanges()

        // Flatten both trees
        let currentNodes = current.flattenNodes()
        let targetNodes = target.flattenNodes()

        let currentIds = Set(currentNodes.keys)
        let targetIds = Set(targetNodes.keys)

        // Removed nodes
        changes.removedNodeIds = currentIds.subtracting(targetIds)

        // Added nodes
        for id in targetIds.subtracting(currentIds) {
            if let node = targetNodes[id] {
                changes.addedNodes[id] = node
            }
        }

        // Modified nodes (exist in both)
        for id in currentIds.intersection(targetIds) {
            guard let currentNode = currentNodes[id],
                  let targetNode = targetNodes[id] else { continue }

            if let modification = computeNodeModification(current: currentNode, target: targetNode) {
                changes.modifiedNodes[id] = modification
            }
        }

        return changes
    }

    /// Compute modification for a single node
    private static func computeNodeModification(
        current: DockLayoutNode,
        target: DockLayoutNode
    ) -> NodeModification? {
        switch (current, target) {
        case (.split(let currentSplit), .split(let targetSplit)):
            var mod = NodeModification(nodeId: currentSplit.id)

            mod.axisChanged = currentSplit.axis != targetSplit.axis
            mod.proportionsChanged = currentSplit.proportions != targetSplit.proportions

            // Check if children order changed
            let currentChildIds = currentSplit.children.map { nodeId(for: $0) }
            let targetChildIds = targetSplit.children.map { nodeId(for: $0) }
            mod.childrenReordered = currentChildIds != targetChildIds

            return mod.hasChanges ? mod : nil

        case (.tabGroup(let currentGroup), .tabGroup(let targetGroup)):
            var mod = NodeModification(nodeId: currentGroup.id)

            mod.activeTabChanged = currentGroup.activeTabIndex != targetGroup.activeTabIndex

            // Check tab changes
            let currentTabIds = currentGroup.tabs.map { $0.id }
            let targetTabIds = targetGroup.tabs.map { $0.id }

            if currentTabIds != targetTabIds {
                mod.tabsChanged = true
                mod.tabChanges = computeTabChanges(
                    currentTabs: currentGroup.tabs,
                    targetTabs: targetGroup.tabs
                )
            }

            return mod.hasChanges ? mod : nil

        default:
            // Type changed - this will be handled as remove + add
            return nil
        }
    }

    /// Compute detailed tab changes
    private static func computeTabChanges(
        currentTabs: [TabLayoutState],
        targetTabs: [TabLayoutState]
    ) -> TabChanges {
        var changes = TabChanges()

        let currentTabIds = Set(currentTabs.map { $0.id })
        let targetTabIds = Set(targetTabs.map { $0.id })

        // Added tabs
        changes.addedTabIds = Array(targetTabIds.subtracting(currentTabIds))

        // Removed tabs
        changes.removedTabIds = Array(currentTabIds.subtracting(targetTabIds))

        // Reordered tabs (tabs that exist in both but at different indices)
        let commonTabIds = currentTabIds.intersection(targetTabIds)
        for tabId in commonTabIds {
            if let currentIndex = currentTabs.firstIndex(where: { $0.id == tabId }),
               let targetIndex = targetTabs.firstIndex(where: { $0.id == tabId }),
               currentIndex != targetIndex {
                changes.reorderedTabs.append((tabId: tabId, fromIndex: currentIndex, toIndex: targetIndex))
            }
        }

        return changes
    }

    /// Get node ID from a DockLayoutNode
    private static func nodeId(for node: DockLayoutNode) -> UUID {
        switch node {
        case .split(let n): return n.id
        case .tabGroup(let n): return n.id
        case .desktopHost(let n): return n.id
        }
    }

    /// Detect tabs that moved between different tab groups
    private static func detectTabMoves(
        currentLayout: DockLayout,
        targetLayout: DockLayout
    ) -> [TabMove] {
        var moves: [TabMove] = []

        // Build maps of tab locations
        var currentTabLocations: [UUID: (windowId: UUID, groupId: UUID, index: Int)] = [:]
        var targetTabLocations: [UUID: (windowId: UUID, groupId: UUID, index: Int)] = [:]

        for window in currentLayout.windows {
            collectTabLocations(node: window.rootNode, windowId: window.id, into: &currentTabLocations)
        }

        for window in targetLayout.windows {
            collectTabLocations(node: window.rootNode, windowId: window.id, into: &targetTabLocations)
        }

        // Find tabs that moved to different groups
        for (tabId, targetLocation) in targetTabLocations {
            if let currentLocation = currentTabLocations[tabId] {
                // Tab exists in both - check if it moved to a different group
                if currentLocation.groupId != targetLocation.groupId {
                    moves.append(TabMove(
                        tabId: tabId,
                        fromWindowId: currentLocation.windowId,
                        fromGroupId: currentLocation.groupId,
                        fromIndex: currentLocation.index,
                        toWindowId: targetLocation.windowId,
                        toGroupId: targetLocation.groupId,
                        toIndex: targetLocation.index
                    ))
                }
            } else {
                // Tab is new (appeared from nowhere) - could be from external source
                moves.append(TabMove(
                    tabId: tabId,
                    fromWindowId: nil,
                    fromGroupId: nil,
                    fromIndex: nil,
                    toWindowId: targetLocation.windowId,
                    toGroupId: targetLocation.groupId,
                    toIndex: targetLocation.index
                ))
            }
        }

        return moves
    }

    /// Collect tab locations from a node tree
    private static func collectTabLocations(
        node: DockLayoutNode,
        windowId: UUID,
        into locations: inout [UUID: (windowId: UUID, groupId: UUID, index: Int)]
    ) {
        switch node {
        case .tabGroup(let tabGroup):
            for (index, tab) in tabGroup.tabs.enumerated() {
                locations[tab.id] = (windowId: windowId, groupId: tabGroup.id, index: index)
            }

        case .split(let split):
            for child in split.children {
                collectTabLocations(node: child, windowId: windowId, into: &locations)
            }

        case .desktopHost(let desktopHost):
            for desktop in desktopHost.desktops {
                collectTabLocations(node: desktop.layout, windowId: windowId, into: &locations)
            }
        }
    }
}

// MARK: - Debug Description

extension DockLayoutDiff: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines: [String] = ["DockLayoutDiff:"]

        if !addedWindowIds.isEmpty {
            lines.append("  Added windows: \(addedWindowIds.map { $0.uuidString.prefix(8) })")
        }

        if !removedWindowIds.isEmpty {
            lines.append("  Removed windows: \(removedWindowIds.map { $0.uuidString.prefix(8) })")
        }

        if !modifiedWindows.isEmpty {
            lines.append("  Modified windows:")
            for (id, mod) in modifiedWindows {
                lines.append("    \(id.uuidString.prefix(8)): frame=\(mod.frameChanged), fullscreen=\(mod.fullScreenChanged), nodes=\(mod.nodeChanges.hasChanges)")
            }
        }

        if !movedTabs.isEmpty {
            lines.append("  Moved tabs:")
            for move in movedTabs {
                let from = move.fromGroupId.map { String($0.uuidString.prefix(8)) } ?? "external"
                let to = String(move.toGroupId.uuidString.prefix(8))
                lines.append("    \(move.tabId.uuidString.prefix(8)): \(from) -> \(to)[\(move.toIndex)]")
            }
        }

        if isEmpty {
            lines.append("  (no changes)")
        }

        return lines.joined(separator: "\n")
    }
}
