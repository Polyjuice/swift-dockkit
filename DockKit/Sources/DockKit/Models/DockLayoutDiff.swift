import Foundation

// MARK: - Layout Diff

/// Represents the difference between two DockLayout states
/// Used to determine minimal view hierarchy changes needed
public struct DockLayoutDiff {
    /// Root panels that were added
    public var addedPanelIds: Set<UUID>

    /// Root panels that were removed
    public var removedPanelIds: Set<UUID>

    /// Root panels that were modified (frame, fullscreen, or content changes)
    public var modifiedPanels: [UUID: PanelModification]

    /// Content panels that moved between groups (within or across root panels)
    public var movedChildren: [ChildMove]

    /// Whether there are any changes
    public var isEmpty: Bool {
        return addedPanelIds.isEmpty &&
               removedPanelIds.isEmpty &&
               modifiedPanels.isEmpty &&
               movedChildren.isEmpty
    }

    public init(
        addedPanelIds: Set<UUID> = [],
        removedPanelIds: Set<UUID> = [],
        modifiedPanels: [UUID: PanelModification] = [:],
        movedChildren: [ChildMove] = []
    ) {
        self.addedPanelIds = addedPanelIds
        self.removedPanelIds = removedPanelIds
        self.modifiedPanels = modifiedPanels
        self.movedChildren = movedChildren
    }
}

// MARK: - Panel Modification

/// Describes changes to a specific root panel
public struct PanelModification {
    public let panelId: UUID

    /// Frame change details (if changed)
    public var frameChanged: Bool

    /// Full-screen state changed
    public var fullScreenChanged: Bool

    /// Changes to the panel tree inside this root panel
    public var nodeChanges: NodeChanges

    public init(
        panelId: UUID,
        frameChanged: Bool = false,
        fullScreenChanged: Bool = false,
        nodeChanges: NodeChanges = NodeChanges()
    ) {
        self.panelId = panelId
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

/// Changes to the panel tree within a root panel
public struct NodeChanges {
    /// Panel IDs that were removed from the tree
    public var removedPanelIds: Set<UUID>

    /// New panels that were added (keyed by ID)
    public var addedPanels: [UUID: Panel]

    /// Panels that were modified in place
    public var modifiedNodes: [UUID: NodeModification]

    public init(
        removedPanelIds: Set<UUID> = [],
        addedPanels: [UUID: Panel] = [:],
        modifiedNodes: [UUID: NodeModification] = [:]
    ) {
        self.removedPanelIds = removedPanelIds
        self.addedPanels = addedPanels
        self.modifiedNodes = modifiedNodes
    }

    /// Whether there are any node changes
    public var hasChanges: Bool {
        return !removedPanelIds.isEmpty ||
               !addedPanels.isEmpty ||
               !modifiedNodes.isEmpty
    }
}

// MARK: - Node Modification

/// Describes changes to a specific panel node
public struct NodeModification {
    public let panelId: UUID

    /// For split groups: proportions changed
    public var proportionsChanged: Bool

    /// For split groups: axis changed
    public var axisChanged: Bool

    /// Children were reordered
    public var childrenReordered: Bool

    /// For tabs/stages groups: active index changed
    public var activeChildChanged: Bool

    /// Children were added, removed, or reordered
    public var childrenChanged: Bool

    /// Style changed (e.g., tabs -> split)
    public var styleChanged: Bool

    /// Specific child changes
    public var childChanges: ChildChanges?

    public init(
        panelId: UUID,
        proportionsChanged: Bool = false,
        axisChanged: Bool = false,
        childrenReordered: Bool = false,
        activeChildChanged: Bool = false,
        childrenChanged: Bool = false,
        styleChanged: Bool = false,
        childChanges: ChildChanges? = nil
    ) {
        self.panelId = panelId
        self.proportionsChanged = proportionsChanged
        self.axisChanged = axisChanged
        self.childrenReordered = childrenReordered
        self.activeChildChanged = activeChildChanged
        self.childrenChanged = childrenChanged
        self.styleChanged = styleChanged
        self.childChanges = childChanges
    }

    /// Whether there are any changes
    public var hasChanges: Bool {
        return proportionsChanged ||
               axisChanged ||
               childrenReordered ||
               activeChildChanged ||
               childrenChanged ||
               styleChanged
    }
}

// MARK: - Child Changes

/// Detailed changes to children within a group
public struct ChildChanges {
    /// Child IDs that were added to this group
    public var addedChildIds: [UUID]

    /// Child IDs that were removed from this group
    public var removedChildIds: [UUID]

    /// Children that were reordered
    public var reorderedChildren: [(childId: UUID, fromIndex: Int, toIndex: Int)]

    public init(
        addedChildIds: [UUID] = [],
        removedChildIds: [UUID] = [],
        reorderedChildren: [(childId: UUID, fromIndex: Int, toIndex: Int)] = []
    ) {
        self.addedChildIds = addedChildIds
        self.removedChildIds = removedChildIds
        self.reorderedChildren = reorderedChildren
    }

    public var hasChanges: Bool {
        return !addedChildIds.isEmpty ||
               !removedChildIds.isEmpty ||
               !reorderedChildren.isEmpty
    }
}

// MARK: - Child Move

/// Describes a panel moving between groups
public struct ChildMove {
    public let childId: UUID

    /// Source root panel (nil if from external source)
    public let fromRootPanelId: UUID?

    /// Source group
    public let fromGroupId: UUID?

    /// Source index in the group
    public let fromIndex: Int?

    /// Target root panel
    public let toRootPanelId: UUID

    /// Target group
    public let toGroupId: UUID

    /// Target index in the group
    public let toIndex: Int

    public init(
        childId: UUID,
        fromRootPanelId: UUID?,
        fromGroupId: UUID?,
        fromIndex: Int?,
        toRootPanelId: UUID,
        toGroupId: UUID,
        toIndex: Int
    ) {
        self.childId = childId
        self.fromRootPanelId = fromRootPanelId
        self.fromGroupId = fromGroupId
        self.fromIndex = fromIndex
        self.toRootPanelId = toRootPanelId
        self.toGroupId = toGroupId
        self.toIndex = toIndex
    }

    /// Whether this is a move within the same root panel
    public var isWithinSameRootPanel: Bool {
        return fromRootPanelId == toRootPanelId
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

        let currentIds = Set(currentLayout.panels.map { $0.id })
        let targetIds = Set(targetLayout.panels.map { $0.id })

        // Find added and removed root panels
        diff.addedPanelIds = targetIds.subtracting(currentIds)
        diff.removedPanelIds = currentIds.subtracting(targetIds)

        // Build lookup maps
        let currentById = Dictionary(uniqueKeysWithValues: currentLayout.panels.map { ($0.id, $0) })
        let targetById = Dictionary(uniqueKeysWithValues: targetLayout.panels.map { ($0.id, $0) })

        // Compare panels that exist in both
        let commonIds = currentIds.intersection(targetIds)
        for panelId in commonIds {
            guard let currentPanel = currentById[panelId],
                  let targetPanel = targetById[panelId] else { continue }

            let modification = computePanelModification(
                current: currentPanel,
                target: targetPanel
            )

            if modification.hasChanges {
                diff.modifiedPanels[panelId] = modification
            }
        }

        // Detect child moves across groups
        diff.movedChildren = detectChildMoves(
            currentLayout: currentLayout,
            targetLayout: targetLayout
        )

        return diff
    }

    /// Compute modification for a single root panel
    private static func computePanelModification(
        current: Panel,
        target: Panel
    ) -> PanelModification {
        var modification = PanelModification(panelId: current.id)

        // Check frame change
        modification.frameChanged = current.frame != target.frame

        // Check fullscreen change
        modification.fullScreenChanged = current.isFullScreen != target.isFullScreen

        // Compute tree changes
        modification.nodeChanges = computeNodeChanges(
            current: current,
            target: target
        )

        return modification
    }

    /// Compute changes between two panel trees
    private static func computeNodeChanges(
        current: Panel,
        target: Panel
    ) -> NodeChanges {
        var changes = NodeChanges()

        // Flatten both trees
        let currentPanels = current.flattenPanels()
        let targetPanels = target.flattenPanels()

        let currentIds = Set(currentPanels.keys)
        let targetIds = Set(targetPanels.keys)

        // Removed panels
        changes.removedPanelIds = currentIds.subtracting(targetIds)

        // Added panels
        for id in targetIds.subtracting(currentIds) {
            if let panel = targetPanels[id] {
                changes.addedPanels[id] = panel
            }
        }

        // Modified panels (exist in both)
        for id in currentIds.intersection(targetIds) {
            guard let currentPanel = currentPanels[id],
                  let targetPanel = targetPanels[id] else { continue }

            if let modification = computeNodeModification(current: currentPanel, target: targetPanel) {
                changes.modifiedNodes[id] = modification
            }
        }

        return changes
    }

    /// Compute modification for a single panel node
    private static func computeNodeModification(
        current: Panel,
        target: Panel
    ) -> NodeModification? {
        // Both must be groups to compare structurally
        guard case .group(let currentGroup) = current.content,
              case .group(let targetGroup) = target.content else {
            // If content type changed, handled as remove + add
            return nil
        }

        var mod = NodeModification(panelId: current.id)

        mod.styleChanged = currentGroup.style != targetGroup.style
        mod.axisChanged = currentGroup.axis != targetGroup.axis
        mod.proportionsChanged = currentGroup.proportions != targetGroup.proportions
        mod.activeChildChanged = currentGroup.activeIndex != targetGroup.activeIndex

        // Check child changes
        let currentChildIds = currentGroup.children.map { $0.id }
        let targetChildIds = targetGroup.children.map { $0.id }

        if currentChildIds != targetChildIds {
            mod.childrenChanged = true
            mod.childrenReordered = Set(currentChildIds) == Set(targetChildIds) && currentChildIds != targetChildIds
            mod.childChanges = computeChildChanges(
                currentChildren: currentGroup.children,
                targetChildren: targetGroup.children
            )
        }

        return mod.hasChanges ? mod : nil
    }

    /// Compute detailed child changes
    private static func computeChildChanges(
        currentChildren: [Panel],
        targetChildren: [Panel]
    ) -> ChildChanges {
        var changes = ChildChanges()

        let currentIds = Set(currentChildren.map { $0.id })
        let targetIds = Set(targetChildren.map { $0.id })

        changes.addedChildIds = Array(targetIds.subtracting(currentIds))
        changes.removedChildIds = Array(currentIds.subtracting(targetIds))

        let commonIds = currentIds.intersection(targetIds)
        for childId in commonIds {
            if let currentIndex = currentChildren.firstIndex(where: { $0.id == childId }),
               let targetIndex = targetChildren.firstIndex(where: { $0.id == childId }),
               currentIndex != targetIndex {
                changes.reorderedChildren.append((childId: childId, fromIndex: currentIndex, toIndex: targetIndex))
            }
        }

        return changes
    }

    /// Detect children that moved between different groups
    private static func detectChildMoves(
        currentLayout: DockLayout,
        targetLayout: DockLayout
    ) -> [ChildMove] {
        var moves: [ChildMove] = []

        var currentLocations: [UUID: (rootPanelId: UUID, groupId: UUID, index: Int)] = [:]
        var targetLocations: [UUID: (rootPanelId: UUID, groupId: UUID, index: Int)] = [:]

        for rootPanel in currentLayout.panels {
            collectChildLocations(panel: rootPanel, rootPanelId: rootPanel.id, into: &currentLocations)
        }

        for rootPanel in targetLayout.panels {
            collectChildLocations(panel: rootPanel, rootPanelId: rootPanel.id, into: &targetLocations)
        }

        for (childId, targetLocation) in targetLocations {
            if let currentLocation = currentLocations[childId] {
                if currentLocation.groupId != targetLocation.groupId {
                    moves.append(ChildMove(
                        childId: childId,
                        fromRootPanelId: currentLocation.rootPanelId,
                        fromGroupId: currentLocation.groupId,
                        fromIndex: currentLocation.index,
                        toRootPanelId: targetLocation.rootPanelId,
                        toGroupId: targetLocation.groupId,
                        toIndex: targetLocation.index
                    ))
                }
            } else {
                moves.append(ChildMove(
                    childId: childId,
                    fromRootPanelId: nil,
                    fromGroupId: nil,
                    fromIndex: nil,
                    toRootPanelId: targetLocation.rootPanelId,
                    toGroupId: targetLocation.groupId,
                    toIndex: targetLocation.index
                ))
            }
        }

        return moves
    }

    /// Collect content panel locations from a panel tree
    private static func collectChildLocations(
        panel: Panel,
        rootPanelId: UUID,
        into locations: inout [UUID: (rootPanelId: UUID, groupId: UUID, index: Int)]
    ) {
        guard case .group(let group) = panel.content else { return }

        for (index, child) in group.children.enumerated() {
            if child.isContent {
                locations[child.id] = (rootPanelId: rootPanelId, groupId: panel.id, index: index)
            } else {
                // Recurse into child groups
                collectChildLocations(panel: child, rootPanelId: rootPanelId, into: &locations)
            }
        }
    }
}

// MARK: - Debug Description

extension DockLayoutDiff: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines: [String] = ["DockLayoutDiff:"]

        if !addedPanelIds.isEmpty {
            lines.append("  Added panels: \(addedPanelIds.map { $0.uuidString.prefix(8) })")
        }

        if !removedPanelIds.isEmpty {
            lines.append("  Removed panels: \(removedPanelIds.map { $0.uuidString.prefix(8) })")
        }

        if !modifiedPanels.isEmpty {
            lines.append("  Modified panels:")
            for (id, mod) in modifiedPanels {
                lines.append("    \(id.uuidString.prefix(8)): frame=\(mod.frameChanged), fullscreen=\(mod.fullScreenChanged), nodes=\(mod.nodeChanges.hasChanges)")
            }
        }

        if !movedChildren.isEmpty {
            lines.append("  Moved children:")
            for move in movedChildren {
                let from = move.fromGroupId.map { String($0.uuidString.prefix(8)) } ?? "external"
                let to = String(move.toGroupId.uuidString.prefix(8))
                lines.append("    \(move.childId.uuidString.prefix(8)): \(from) -> \(to)[\(move.toIndex)]")
            }
        }

        if isEmpty {
            lines.append("  (no changes)")
        }

        return lines.joined(separator: "\n")
    }
}
