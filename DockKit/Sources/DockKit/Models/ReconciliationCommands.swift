import Foundation

// MARK: - Reconciliation Commands

/// High-level commands extracted from a layout diff
/// These are designed for easy consumption by the host app's panel factory
///
/// Usage:
/// ```swift
/// let commands = layoutManager.computeCommands(to: newLayout)
///
/// for cmd in commands.panelsToCreate {
///     let panel = factory.create(id: cmd.panelId, cargo: cmd.cargo)
///     panelRegistry[cmd.panelId] = panel
/// }
///
/// for panelId in commands.panelsToRemove {
///     panelRegistry[panelId]?.cleanup()
///     panelRegistry.removeValue(forKey: panelId)
/// }
///
/// layoutManager.updateLayout(newLayout)
/// ```
public struct ReconciliationCommands {
    /// Panels that need to be created (new content panels with cargo)
    public let panelsToCreate: [PanelCreationCommand]

    /// Panel IDs that should be removed/cleaned up
    public let panelsToRemove: [UUID]

    /// Panels whose cargo changed (for in-place updates, if supported)
    public let panelsToUpdate: [PanelUpdateCommand]

    /// Whether there are any panel-related commands
    public var isEmpty: Bool {
        panelsToCreate.isEmpty && panelsToRemove.isEmpty && panelsToUpdate.isEmpty
    }

    public init(
        panelsToCreate: [PanelCreationCommand] = [],
        panelsToRemove: [UUID] = [],
        panelsToUpdate: [PanelUpdateCommand] = []
    ) {
        self.panelsToCreate = panelsToCreate
        self.panelsToRemove = panelsToRemove
        self.panelsToUpdate = panelsToUpdate
    }
}

// MARK: - Panel Creation Command

/// Command to create a new panel
public struct PanelCreationCommand {
    /// The panel ID
    public let panelId: UUID

    /// The cargo containing type and configuration
    public let cargo: [String: AnyCodable]

    /// Target root panel
    public let rootPanelId: UUID

    /// Target group within the root panel
    public let groupId: UUID

    /// Suggested title from the layout
    public let title: String?

    /// Suggested icon name
    public let iconName: String?

    /// Convenience: Extract panel type from cargo
    public var panelType: String? {
        cargo["type"]?.stringValue
    }

    public init(
        panelId: UUID,
        cargo: [String: AnyCodable],
        rootPanelId: UUID,
        groupId: UUID,
        title: String?,
        iconName: String?
    ) {
        self.panelId = panelId
        self.cargo = cargo
        self.rootPanelId = rootPanelId
        self.groupId = groupId
        self.title = title
        self.iconName = iconName
    }
}

// MARK: - Panel Update Command

/// Command to update an existing panel's cargo
public struct PanelUpdateCommand {
    /// The panel ID
    public let panelId: UUID

    /// The old cargo (for comparison)
    public let oldCargo: [String: AnyCodable]?

    /// The new cargo
    public let newCargo: [String: AnyCodable]?

    /// Whether the panel type changed (requires recreation instead of update)
    public var typeChanged: Bool {
        oldCargo?["type"]?.stringValue != newCargo?["type"]?.stringValue
    }

    public init(
        panelId: UUID,
        oldCargo: [String: AnyCodable]?,
        newCargo: [String: AnyCodable]?
    ) {
        self.panelId = panelId
        self.oldCargo = oldCargo
        self.newCargo = newCargo
    }
}

// MARK: - Command Extraction

public extension DockLayoutDiff {
    /// Extract high-level reconciliation commands from this diff
    static func extractCommands(
        from currentLayout: DockLayout,
        to targetLayout: DockLayout
    ) -> ReconciliationCommands {
        let diff = Self.compute(from: currentLayout, to: targetLayout)
        return diff.toCommands(currentLayout: currentLayout, targetLayout: targetLayout)
    }

    /// Convert this diff to reconciliation commands
    func toCommands(
        currentLayout: DockLayout,
        targetLayout: DockLayout
    ) -> ReconciliationCommands {
        var toCreate: [PanelCreationCommand] = []
        var toRemove: [UUID] = []
        var toUpdate: [PanelUpdateCommand] = []

        // Build lookup maps
        let currentContentPanels = currentLayout.allContentPanelsWithLocation()
        let targetContentPanels = targetLayout.allContentPanelsWithLocation()

        let currentIds = Set(currentContentPanels.keys)
        let targetIds = Set(targetContentPanels.keys)

        // Panels to create (in target but not in current)
        let addedIds = targetIds.subtracting(currentIds)
        for panelId in addedIds {
            guard let (panel, rootPanelId, groupId) = targetContentPanels[panelId] else { continue }

            if let cargo = panel.cargo {
                toCreate.append(PanelCreationCommand(
                    panelId: panelId,
                    cargo: cargo,
                    rootPanelId: rootPanelId,
                    groupId: groupId,
                    title: panel.title,
                    iconName: panel.iconName
                ))
            }
        }

        // Panels to remove (in current but not in target)
        let removedIds = currentIds.subtracting(targetIds)
        toRemove = Array(removedIds)

        // Panels to potentially update (in both, check cargo changes)
        let commonIds = currentIds.intersection(targetIds)
        for panelId in commonIds {
            guard let (currentPanel, _, _) = currentContentPanels[panelId],
                  let (targetPanel, _, _) = targetContentPanels[panelId] else { continue }

            if !cargoEqual(currentPanel.cargo, targetPanel.cargo) {
                toUpdate.append(PanelUpdateCommand(
                    panelId: panelId,
                    oldCargo: currentPanel.cargo,
                    newCargo: targetPanel.cargo
                ))
            }
        }

        return ReconciliationCommands(
            panelsToCreate: toCreate,
            panelsToRemove: toRemove,
            panelsToUpdate: toUpdate
        )
    }

    /// Compare two cargo dictionaries for equality
    private func cargoEqual(
        _ a: [String: AnyCodable]?,
        _ b: [String: AnyCodable]?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case (let a?, let b?):
            return a == b
        }
    }
}

// MARK: - Layout Content Panel Extraction Helper

public extension DockLayout {
    /// Extract all content panels with their location info
    /// Returns: [panelId: (panel, rootPanelId, groupId)]
    func allContentPanelsWithLocation() -> [UUID: (panel: Panel, rootPanelId: UUID, groupId: UUID)] {
        var result: [UUID: (Panel, UUID, UUID)] = [:]

        for rootPanel in panels {
            collectContentPanels(from: rootPanel, rootPanelId: rootPanel.id, parentGroupId: rootPanel.id, into: &result)
        }

        return result
    }

    private func collectContentPanels(
        from panel: Panel,
        rootPanelId: UUID,
        parentGroupId: UUID,
        into result: inout [UUID: (Panel, UUID, UUID)]
    ) {
        switch panel.content {
        case .content:
            result[panel.id] = (panel, rootPanelId, parentGroupId)
        case .group(let group):
            for child in group.children {
                collectContentPanels(from: child, rootPanelId: rootPanelId, parentGroupId: panel.id, into: &result)
            }
        }
    }
}

// MARK: - Debug Description

extension ReconciliationCommands: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines: [String] = ["ReconciliationCommands:"]

        if !panelsToCreate.isEmpty {
            lines.append("  Panels to create: \(panelsToCreate.count)")
            for cmd in panelsToCreate {
                let type = cmd.panelType ?? "unknown"
                lines.append("    - \(cmd.panelId.uuidString.prefix(8)): \(type) '\(cmd.title ?? "")'")
            }
        }

        if !panelsToRemove.isEmpty {
            lines.append("  Panels to remove: \(panelsToRemove.count)")
            for id in panelsToRemove {
                lines.append("    - \(id.uuidString.prefix(8))")
            }
        }

        if !panelsToUpdate.isEmpty {
            lines.append("  Panels to update: \(panelsToUpdate.count)")
            for cmd in panelsToUpdate {
                let typeChange = cmd.typeChanged ? " (TYPE CHANGED)" : ""
                lines.append("    - \(cmd.panelId.uuidString.prefix(8))\(typeChange)")
            }
        }

        if isEmpty {
            lines.append("  (no panel commands)")
        }

        return lines.joined(separator: "\n")
    }
}
