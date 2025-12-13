import AppKit

/// Recursive tree structure for dock layout
/// Each node is either a split (container with children) or a tab group (leaf with tabs)
public indirect enum DockNode {
    case split(SplitNode)
    case tabGroup(TabGroupNode)

    /// Generate a unique ID for this node
    public var nodeId: UUID {
        switch self {
        case .split(let node):
            return node.id
        case .tabGroup(let node):
            return node.id
        }
    }
}

/// A split node contains multiple children separated by dividers
public struct SplitNode: Identifiable {
    public let id: UUID
    public var axis: SplitAxis
    public var children: [DockNode]
    public var proportions: [CGFloat]  // Size ratios (must sum to 1.0)

    public init(id: UUID = UUID(), axis: SplitAxis, children: [DockNode], proportions: [CGFloat]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children

        // If proportions not provided, distribute equally
        if let proportions = proportions, proportions.count == children.count {
            self.proportions = proportions
        } else {
            let count = max(1, children.count)
            self.proportions = Array(repeating: 1.0 / CGFloat(count), count: count)
        }
    }

    /// Insert a new child at the given index
    public mutating func insertChild(_ node: DockNode, at index: Int) {
        children.insert(node, at: index)
        recalculateProportions()
    }

    /// Remove child at index
    public mutating func removeChild(at index: Int) {
        guard index >= 0 && index < children.count else { return }
        children.remove(at: index)
        recalculateProportions()
    }

    /// Recalculate proportions to distribute equally
    private mutating func recalculateProportions() {
        let count = max(1, children.count)
        proportions = Array(repeating: 1.0 / CGFloat(count), count: count)
    }
}

/// Axis for split orientation
public enum SplitAxis: String, Codable {
    case horizontal  // Children arranged left-to-right
    case vertical    // Children arranged top-to-bottom
}

/// A tab group node is a leaf that contains tabs
public struct TabGroupNode: Identifiable {
    public let id: UUID
    public var tabs: [DockTab]
    public var activeTabIndex: Int
    public var displayMode: TabGroupDisplayMode

    public init(id: UUID = UUID(), tabs: [DockTab] = [], activeTabIndex: Int = 0, displayMode: TabGroupDisplayMode = .tabs) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = min(activeTabIndex, max(0, tabs.count - 1))
        self.displayMode = displayMode
    }

    /// The currently active tab, if any
    public var activeTab: DockTab? {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    /// Add a tab at the end
    public mutating func addTab(_ tab: DockTab) {
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
    }

    /// Insert a tab at specific index
    public mutating func insertTab(_ tab: DockTab, at index: Int) {
        let insertIndex = max(0, min(index, tabs.count))
        tabs.insert(tab, at: insertIndex)
        if insertIndex <= activeTabIndex {
            activeTabIndex += 1
        }
    }

    /// Remove tab at index
    @discardableResult
    public mutating func removeTab(at index: Int) -> DockTab? {
        guard index >= 0 && index < tabs.count else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = max(0, tabs.count - 1)
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        return tab
    }

    /// Remove tab by ID
    @discardableResult
    public mutating func removeTab(withId id: UUID) -> DockTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        return removeTab(at: index)
    }
}

/// A single tab within a tab group
public class DockTab: Identifiable {
    public let id: UUID
    public var title: String
    public var iconName: String?

    /// Reference to the panel (ownership managed by DockContainerViewController.panelRegistry)
    /// NOTE: Using class instead of struct to safely hold reference to existential type
    public var panel: (any DockablePanel)?

    /// Cargo from the layout state - preserved for round-tripping
    /// The host app's panel factory uses this for panel configuration
    public var cargo: [String: AnyCodable]?

    public init(
        id: UUID = UUID(),
        title: String,
        iconName: String? = nil,
        panel: (any DockablePanel)? = nil,
        cargo: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.panel = panel
        self.cargo = cargo
    }

    /// Create a tab from a dockable panel
    public init(from panel: any DockablePanel, cargo: [String: AnyCodable]? = nil) {
        self.id = panel.panelId
        self.title = panel.panelTitle
        self.iconName = nil  // Will use panel.panelIcon directly
        self.panel = panel
        self.cargo = cargo
    }

    /// Get the icon (from panel if available, otherwise system symbol)
    public var icon: NSImage? {
        if let panel = panel {
            return panel.panelIcon
        }
        if let iconName = iconName {
            return NSImage(systemSymbolName: iconName, accessibilityDescription: title)
        }
        return nil
    }
}

// MARK: - Tree Traversal Helpers

public extension DockNode {
    /// Flatten the tree into a dictionary of [nodeId: DockNode]
    /// Useful for comparing trees and finding differences
    func flattenNodes() -> [UUID: DockNode] {
        var result: [UUID: DockNode] = [:]
        flattenNodes(into: &result)
        return result
    }

    private func flattenNodes(into result: inout [UUID: DockNode]) {
        result[self.nodeId] = self

        switch self {
        case .split(let splitNode):
            for child in splitNode.children {
                child.flattenNodes(into: &result)
            }
        case .tabGroup:
            break
        }
    }

    /// Find a node by its ID
    func findNode(byId id: UUID) -> DockNode? {
        if self.nodeId == id {
            return self
        }

        switch self {
        case .split(let splitNode):
            for child in splitNode.children {
                if let found = child.findNode(byId: id) {
                    return found
                }
            }
            return nil
        case .tabGroup:
            return nil
        }
    }

    /// Find the tab group containing a specific tab ID
    /// Returns the group ID and the index of the tab within that group
    func findTabGroup(containingTabId tabId: UUID) -> (groupId: UUID, index: Int)? {
        switch self {
        case .tabGroup(let tabGroupNode):
            if let index = tabGroupNode.tabs.firstIndex(where: { $0.id == tabId }) {
                return (groupId: tabGroupNode.id, index: index)
            }
            return nil

        case .split(let splitNode):
            for child in splitNode.children {
                if let found = child.findTabGroup(containingTabId: tabId) {
                    return found
                }
            }
            return nil
        }
    }

    /// Get all tab IDs in this tree
    func allTabIds() -> [UUID] {
        var result: [UUID] = []
        collectTabIds(into: &result)
        return result
    }

    private func collectTabIds(into result: inout [UUID]) {
        switch self {
        case .tabGroup(let tabGroupNode):
            result.append(contentsOf: tabGroupNode.tabs.map { $0.id })
        case .split(let splitNode):
            for child in splitNode.children {
                child.collectTabIds(into: &result)
            }
        }
    }

    /// Get all tab group nodes in this tree
    func allTabGroups() -> [TabGroupNode] {
        var result: [TabGroupNode] = []
        collectTabGroups(into: &result)
        return result
    }

    private func collectTabGroups(into result: inout [TabGroupNode]) {
        switch self {
        case .tabGroup(let tabGroupNode):
            result.append(tabGroupNode)
        case .split(let splitNode):
            for child in splitNode.children {
                child.collectTabGroups(into: &result)
            }
        }
    }

    /// Count total tabs in this tree
    var totalTabCount: Int {
        switch self {
        case .tabGroup(let tabGroupNode):
            return tabGroupNode.tabs.count
        case .split(let splitNode):
            return splitNode.children.reduce(0) { $0 + $1.totalTabCount }
        }
    }

    /// Check if tree is empty (no tabs)
    var isEmpty: Bool {
        return totalTabCount == 0
    }
}

// MARK: - DockLayoutNode Tree Traversal Helpers

public extension DockLayoutNode {
    /// Flatten the layout tree into a dictionary of [nodeId: DockLayoutNode]
    func flattenNodes() -> [UUID: DockLayoutNode] {
        var result: [UUID: DockLayoutNode] = [:]
        flattenNodes(into: &result)
        return result
    }

    private var layoutNodeId: UUID {
        switch self {
        case .split(let node): return node.id
        case .tabGroup(let node): return node.id
        }
    }

    private func flattenNodes(into result: inout [UUID: DockLayoutNode]) {
        result[self.layoutNodeId] = self

        switch self {
        case .split(let splitNode):
            for child in splitNode.children {
                child.flattenNodes(into: &result)
            }
        case .tabGroup:
            break
        }
    }

    /// Find a node by its ID
    func findNode(byId id: UUID) -> DockLayoutNode? {
        if self.layoutNodeId == id {
            return self
        }

        switch self {
        case .split(let splitNode):
            for child in splitNode.children {
                if let found = child.findNode(byId: id) {
                    return found
                }
            }
            return nil
        case .tabGroup:
            return nil
        }
    }

    /// Find the tab group containing a specific tab ID
    func findTabGroup(containingTabId tabId: UUID) -> (groupId: UUID, index: Int)? {
        switch self {
        case .tabGroup(let tabGroupNode):
            if let index = tabGroupNode.tabs.firstIndex(where: { $0.id == tabId }) {
                return (groupId: tabGroupNode.id, index: index)
            }
            return nil

        case .split(let splitNode):
            for child in splitNode.children {
                if let found = child.findTabGroup(containingTabId: tabId) {
                    return found
                }
            }
            return nil
        }
    }

    /// Get all tab IDs in this layout tree
    func allTabIds() -> [UUID] {
        var result: [UUID] = []
        collectTabIds(into: &result)
        return result
    }

    private func collectTabIds(into result: inout [UUID]) {
        switch self {
        case .tabGroup(let tabGroupNode):
            result.append(contentsOf: tabGroupNode.tabs.map { $0.id })
        case .split(let splitNode):
            for child in splitNode.children {
                child.collectTabIds(into: &result)
            }
        }
    }
}
