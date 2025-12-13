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
///     let panel = factory.create(id: cmd.tabId, cargo: cmd.cargo)
///     panelRegistry[cmd.tabId] = panel
/// }
///
/// for tabId in commands.panelsToRemove {
///     panelRegistry[tabId]?.cleanup()
///     panelRegistry.removeValue(forKey: tabId)
/// }
///
/// layoutManager.updateLayout(newLayout)
/// ```
public struct ReconciliationCommands {
    /// Panels that need to be created (new tabs with cargo)
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
/// The tab ID should be used as the panel ID for registration
public struct PanelCreationCommand {
    /// The tab ID - use this as the panel ID for registration
    public let tabId: UUID

    /// The cargo containing type and configuration
    public let cargo: [String: AnyCodable]

    /// Target window for this panel
    public let windowId: UUID

    /// Target tab group within the window
    public let groupId: UUID

    /// Suggested title from the layout
    public let title: String

    /// Suggested icon name
    public let iconName: String?

    /// Convenience: Extract panel type from cargo
    public var panelType: String? {
        cargo["type"]?.stringValue
    }

    public init(
        tabId: UUID,
        cargo: [String: AnyCodable],
        windowId: UUID,
        groupId: UUID,
        title: String,
        iconName: String?
    ) {
        self.tabId = tabId
        self.cargo = cargo
        self.windowId = windowId
        self.groupId = groupId
        self.title = title
        self.iconName = iconName
    }
}

// MARK: - Panel Update Command

/// Command to update an existing panel's cargo
public struct PanelUpdateCommand {
    /// The tab/panel ID
    public let tabId: UUID

    /// The old cargo (for comparison)
    public let oldCargo: [String: AnyCodable]?

    /// The new cargo
    public let newCargo: [String: AnyCodable]?

    /// Whether the panel type changed (requires recreation instead of update)
    public var typeChanged: Bool {
        oldCargo?["type"]?.stringValue != newCargo?["type"]?.stringValue
    }

    public init(
        tabId: UUID,
        oldCargo: [String: AnyCodable]?,
        newCargo: [String: AnyCodable]?
    ) {
        self.tabId = tabId
        self.oldCargo = oldCargo
        self.newCargo = newCargo
    }
}

// MARK: - Command Extraction

public extension DockLayoutDiff {
    /// Extract high-level reconciliation commands from this diff
    ///
    /// - Parameters:
    ///   - currentLayout: The layout before changes
    ///   - targetLayout: The layout after changes
    /// - Returns: Commands for the host app to process
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
        let currentTabs = currentLayout.allTabs()
        let targetTabs = targetLayout.allTabs()

        let currentTabIds = Set(currentTabs.keys)
        let targetTabIds = Set(targetTabs.keys)

        // Tabs to create (in target but not in current)
        let addedTabIds = targetTabIds.subtracting(currentTabIds)
        for tabId in addedTabIds {
            guard let (tab, windowId, groupId) = targetTabs[tabId] else { continue }

            // Only include tabs that have cargo (type information)
            if let cargo = tab.cargo {
                toCreate.append(PanelCreationCommand(
                    tabId: tabId,
                    cargo: cargo,
                    windowId: windowId,
                    groupId: groupId,
                    title: tab.title,
                    iconName: tab.iconName
                ))
            }
        }

        // Tabs to remove (in current but not in target)
        let removedTabIds = currentTabIds.subtracting(targetTabIds)
        toRemove = Array(removedTabIds)

        // Tabs to potentially update (in both, check cargo changes)
        let commonTabIds = currentTabIds.intersection(targetTabIds)
        for tabId in commonTabIds {
            guard let (currentTab, _, _) = currentTabs[tabId],
                  let (targetTab, _, _) = targetTabs[tabId] else { continue }

            // Check if cargo changed
            if !cargoEqual(currentTab.cargo, targetTab.cargo) {
                toUpdate.append(PanelUpdateCommand(
                    tabId: tabId,
                    oldCargo: currentTab.cargo,
                    newCargo: targetTab.cargo
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
            // Use Equatable conformance of AnyCodable
            return a == b
        }
    }
}

// MARK: - Layout Tab Extraction Helper

public extension DockLayout {
    /// Extract all tabs with their location info
    /// Returns: [tabId: (tab, windowId, groupId)]
    func allTabs() -> [UUID: (tab: TabLayoutState, windowId: UUID, groupId: UUID)] {
        var result: [UUID: (TabLayoutState, UUID, UUID)] = [:]

        for window in windows {
            collectTabs(from: window.rootNode, windowId: window.id, into: &result)
        }

        return result
    }

    private func collectTabs(
        from node: DockLayoutNode,
        windowId: UUID,
        into result: inout [UUID: (TabLayoutState, UUID, UUID)]
    ) {
        switch node {
        case .tabGroup(let group):
            for tab in group.tabs {
                result[tab.id] = (tab, windowId, group.id)
            }
        case .split(let split):
            for child in split.children {
                collectTabs(from: child, windowId: windowId, into: &result)
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
                lines.append("    - \(cmd.tabId.uuidString.prefix(8)): \(type) '\(cmd.title)'")
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
                lines.append("    - \(cmd.tabId.uuidString.prefix(8))\(typeChange)")
            }
        }

        if isEmpty {
            lines.append("  (no panel commands)")
        }

        return lines.joined(separator: "\n")
    }
}
