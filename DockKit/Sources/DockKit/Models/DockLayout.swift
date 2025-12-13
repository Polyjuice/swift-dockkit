import Foundation

// MARK: - Display Mode

/// How a tab group displays its tabs
public enum TabGroupDisplayMode: String, Codable {
    case tabs        // Traditional tab bar with icon and title
    case thumbnails  // Visual preview thumbnails of panel content
}

// MARK: - New Architecture (Equal Windows)

/// Serializable representation of a dock layout
/// Contains ALL windows - there is no "main" window, all windows are equal
public struct DockLayout: Codable {
    public var version: Int = 1
    public var windows: [WindowState]

    public init(windows: [WindowState] = []) {
        self.windows = windows
    }

    /// Create an empty layout with a single window containing an empty tab group
    public static func empty() -> DockLayout {
        DockLayout(windows: [
            WindowState(
                id: UUID(),
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                isFullScreen: false,
                rootNode: .tabGroup(TabGroupLayoutNode())
            )
        ])
    }
}

/// State of a single window
/// All windows have identical capabilities (splits, tabs, etc.)
public struct WindowState: Codable, Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var rootNode: DockLayoutNode

    public init(id: UUID = UUID(), frame: CGRect, isFullScreen: Bool = false, rootNode: DockLayoutNode) {
        self.id = id
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.rootNode = rootNode
    }
}

/// Codable version of DockNode - uses explicit type discriminator for cleaner JSON
public indirect enum DockLayoutNode: Codable {
    case split(SplitLayoutNode)
    case tabGroup(TabGroupLayoutNode)

    // Custom coding to add "type" discriminator
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum NodeType: String, Codable {
        case split
        case tabGroup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .split:
            self = .split(try SplitLayoutNode(from: decoder))
        case .tabGroup:
            self = .tabGroup(try TabGroupLayoutNode(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .split(let node):
            try container.encode(NodeType.split, forKey: .type)
            try node.encode(to: encoder)
        case .tabGroup(let node):
            try container.encode(NodeType.tabGroup, forKey: .type)
            try node.encode(to: encoder)
        }
    }
}

/// Codable version of SplitNode
public struct SplitLayoutNode: Codable {
    public let id: UUID
    public var axis: SplitAxis
    public var children: [DockLayoutNode]
    public var proportions: [CGFloat]

    private enum CodingKeys: String, CodingKey {
        case id, axis, children, proportions
    }

    public init(id: UUID = UUID(), axis: SplitAxis = .horizontal, children: [DockLayoutNode] = [], proportions: [CGFloat] = []) {
        self.id = id
        self.axis = axis
        self.children = children
        self.proportions = proportions.isEmpty ?
            Array(repeating: 1.0 / max(1, CGFloat(children.count)), count: children.count) :
            proportions
    }
}

/// Codable version of TabGroupNode
public struct TabGroupLayoutNode: Codable {
    public let id: UUID
    public var tabs: [TabLayoutState]
    public var activeTabIndex: Int
    public var displayMode: TabGroupDisplayMode

    private enum CodingKeys: String, CodingKey {
        case id, tabs, activeTabIndex, displayMode
    }

    public init(id: UUID = UUID(), tabs: [TabLayoutState] = [], activeTabIndex: Int = 0, displayMode: TabGroupDisplayMode = .tabs) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.displayMode = displayMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabs = try container.decode([TabLayoutState].self, forKey: .tabs)
        activeTabIndex = try container.decode(Int.self, forKey: .activeTabIndex)
        // Default to .tabs for backward compatibility with existing JSON
        displayMode = try container.decodeIfPresent(TabGroupDisplayMode.self, forKey: .displayMode) ?? .tabs
    }
}

/// Codable state for a single tab
/// NOTE: DockKit is panel-agnostic - the host app interprets the cargo field
public struct TabLayoutState: Codable {
    public let id: UUID
    public var title: String
    public var iconName: String?

    /// Arbitrary JSON cargo for panel-specific configuration
    /// The host app's panel factory interprets this (e.g., "type", "url", "cwd")
    /// DockKit stores and diffs cargo but doesn't interpret its contents
    public var cargo: [String: AnyCodable]?

    public init(
        id: UUID = UUID(),
        title: String,
        iconName: String? = nil,
        cargo: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.cargo = cargo
    }
}

// MARK: - DockLayoutNode Helpers

public extension DockLayoutNode {
    /// Check if this node contains no tabs (empty tree)
    var isEmpty: Bool {
        switch self {
        case .tabGroup(let tabGroup):
            return tabGroup.tabs.isEmpty
        case .split(let split):
            return split.children.allSatisfy { $0.isEmpty }
        }
    }
}

// MARK: - Conversion from Runtime Models

public extension DockLayoutNode {
    /// Create a layout node from a runtime DockNode
    static func from(_ node: DockNode) -> DockLayoutNode {
        switch node {
        case .split(let splitNode):
            return .split(SplitLayoutNode(
                id: splitNode.id,
                axis: splitNode.axis,
                children: splitNode.children.map { DockLayoutNode.from($0) },
                proportions: splitNode.proportions
            ))
        case .tabGroup(let tabGroupNode):
            return .tabGroup(TabGroupLayoutNode(
                id: tabGroupNode.id,
                tabs: tabGroupNode.tabs.map { TabLayoutState.from($0) },
                activeTabIndex: tabGroupNode.activeTabIndex,
                displayMode: tabGroupNode.displayMode
            ))
        }
    }
}

public extension TabLayoutState {
    /// Create a tab state from a runtime DockTab
    static func from(_ tab: DockTab) -> TabLayoutState {
        TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )
    }
}

// MARK: - Persistence

public extension DockLayout {
    private static let storageKey = "dockkit.dockLayout.v2"
    private static let legacyStorageKey = "dockkit.dockLayout"

    /// Save the layout to UserDefaults
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Load the layout from UserDefaults
    static func load() -> DockLayout? {
        // Try new format first
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let layout = try? JSONDecoder().decode(DockLayout.self, from: data) {
            return layout
        }

        // TODO: Migration from legacy format could be added here

        return nil
    }

    /// Clear the saved layout
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }
}

// MARK: - JSON Export/Import

public extension DockLayout {
    /// Export layout as JSON string
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Import layout from JSON string
    static func fromJSON(_ json: String) -> DockLayout? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DockLayout.self, from: data)
    }
}

// MARK: - Legacy Support (Deprecated)
// These types are kept for backward compatibility during migration

@available(*, deprecated, message: "Use WindowState instead")
public struct FloatingWindowState: Codable {
    public let id: UUID
    public var frame: CGRect
    public var tabGroup: TabGroupLayoutNode

    public init(id: UUID = UUID(), frame: CGRect, tabGroup: TabGroupLayoutNode) {
        self.id = id
        self.frame = frame
        self.tabGroup = tabGroup
    }
}

/// Info about a floating window (runtime, not codable) - DEPRECATED
@available(*, deprecated, message: "Use WindowState for all windows")
public struct FloatingWindowInfo {
    public let id: UUID
    public let frame: CGRect
    public let tabGroup: TabGroupNode

    public init(id: UUID, frame: CGRect, tabGroup: TabGroupNode) {
        self.id = id
        self.frame = frame
        self.tabGroup = tabGroup
    }
}
