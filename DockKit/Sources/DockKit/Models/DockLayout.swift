import Foundation

// MARK: - Panel Group Style

/// How a panel group presents its children
public enum PanelGroupStyle: String, Codable, CaseIterable {
    case tabs           // Standard tab bar, one child visible at a time
    case thumbnails     // Thumbnail previews, one child visible at a time
    case stages         // Stage-switching with animations, one child visible at a time
    case split          // All children visible, divided by axis
}

// MARK: - Split Axis

/// Axis for split orientation
public enum SplitAxis: String, Codable {
    case horizontal     // Children arranged left-to-right
    case vertical       // Children arranged top-to-bottom
}

// MARK: - Panel Content

/// What a panel contains — either leaf content or a group of sub-panels
public enum PanelContent: Codable {
    case content                    // Leaf — actual view (resolved via panelProvider at runtime)
    case group(PanelGroup)          // Container — N sub-panels with layout mode and style

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum ContentType: String, Codable {
        case content
        case group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)
        switch type {
        case .content:
            self = .content
        case .group:
            self = .group(try PanelGroup(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .content:
            try container.encode(ContentType.content, forKey: .type)
        case .group(let group):
            try container.encode(ContentType.group, forKey: .type)
            try group.encode(to: encoder)
        }
    }
}

// MARK: - Panel Group

/// A group of sub-panels with layout attributes
/// All attributes are preserved regardless of current style, enabling reversible style switches
public struct PanelGroup: Codable {
    public var children: [Panel]

    /// Which child is selected (used by tabs/thumbnails/stages styles)
    public var activeIndex: Int

    /// Split orientation (used by split style)
    public var axis: SplitAxis

    /// Split ratios for each child (used by split style, must sum to 1.0)
    public var proportions: [CGFloat]

    /// Determines which attributes are active for rendering
    public var style: PanelGroupStyle

    private enum CodingKeys: String, CodingKey {
        case children, activeIndex, axis, proportions, style
    }

    public init(
        children: [Panel] = [],
        activeIndex: Int = 0,
        axis: SplitAxis = .horizontal,
        proportions: [CGFloat]? = nil,
        style: PanelGroupStyle = .tabs
    ) {
        self.children = children
        self.activeIndex = activeIndex
        self.axis = axis
        self.style = style

        // If proportions not provided, distribute equally
        if let proportions = proportions, proportions.count == children.count {
            self.proportions = proportions
        } else {
            let count = max(1, children.count)
            self.proportions = Array(repeating: 1.0 / CGFloat(count), count: count)
        }
    }

    /// Recalculate proportions to distribute equally among current children
    public mutating func recalculateProportions() {
        let count = max(1, children.count)
        proportions = Array(repeating: 1.0 / CGFloat(count), count: count)
    }

    /// The currently active child, if any (meaningful for tabs/thumbnails/stages)
    public var activeChild: Panel? {
        guard activeIndex >= 0 && activeIndex < children.count else { return nil }
        return children[activeIndex]
    }
}

// MARK: - Panel

/// The universal layout unit in DockKit
/// Everything is a Panel — windows, tabs, stages, split panes, leaf content.
/// Behavioral differences are controlled by attributes, not types.
public struct Panel: Codable, Identifiable {
    public let id: UUID
    public var title: String?
    public var iconName: String?

    /// Arbitrary JSON cargo for panel-specific configuration
    /// The host app's panel factory interprets this (e.g., "type", "url", "cwd")
    /// DockKit stores and diffs cargo but doesn't interpret its contents
    public var cargo: [String: AnyCodable]?

    /// What this panel contains — leaf content or a group of sub-panels
    public var content: PanelContent

    // Window presentation attributes (preserved even when not a window)
    // Flipping isTopLevelWindow creates/destroys an OS window during reconciliation

    /// Whether this panel renders as a top-level OS window
    public var isTopLevelWindow: Bool

    /// Window frame (preserved across window/embedded transitions)
    public var frame: CGRect?

    /// Window fullscreen state (preserved across window/embedded transitions)
    public var isFullScreen: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, title, iconName, cargo, content
        case isTopLevelWindow, frame, isFullScreen
    }

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        iconName: String? = nil,
        cargo: [String: AnyCodable]? = nil,
        content: PanelContent = .content,
        isTopLevelWindow: Bool = false,
        frame: CGRect? = nil,
        isFullScreen: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.cargo = cargo
        self.content = content
        self.isTopLevelWindow = isTopLevelWindow
        self.frame = frame
        self.isFullScreen = isFullScreen
    }
}

// MARK: - DockLayout

/// The top-level layout state
/// Contains all root panels (typically those with isTopLevelWindow == true)
public struct DockLayout: Codable {
    public var version: Int = 2
    public var panels: [Panel]

    public init(panels: [Panel] = []) {
        self.panels = panels
    }

    /// Create an empty layout with a single window containing an empty tab group
    public static func empty() -> DockLayout {
        DockLayout(panels: [
            Panel(
                content: .group(PanelGroup(style: .tabs)),
                isTopLevelWindow: true,
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                isFullScreen: false
            )
        ])
    }
}

// MARK: - Panel Convenience Properties

public extension Panel {
    /// Whether this panel is a leaf content panel
    var isContent: Bool {
        if case .content = content { return true }
        return false
    }

    /// Whether this panel contains a group
    var isGroup: Bool {
        if case .group = content { return true }
        return false
    }

    /// The group, if this panel contains one
    var group: PanelGroup? {
        if case .group(let g) = content { return g }
        return nil
    }

    /// Whether this panel acts as a stage host (tabs-style group where children have groups)
    var isStageHost: Bool {
        guard let g = group else { return false }
        return g.style == .stages
    }
}

// MARK: - Tree Traversal

public extension Panel {
    /// Find a panel anywhere in this tree by ID
    func findPanel(byId targetId: UUID) -> Panel? {
        if id == targetId { return self }
        guard case .group(let group) = content else { return nil }
        for child in group.children {
            if let found = child.findPanel(byId: targetId) { return found }
        }
        return nil
    }

    /// Find the group containing a specific content panel ID
    /// Returns the group's panel ID and the index of the child within that group
    func findGroup(containingPanelId panelId: UUID) -> (groupId: UUID, index: Int)? {
        guard case .group(let group) = content else { return nil }

        // Check if any direct child matches
        if let index = group.children.firstIndex(where: { $0.id == panelId }) {
            return (groupId: id, index: index)
        }

        // Recurse into children that are groups
        for child in group.children {
            if let found = child.findGroup(containingPanelId: panelId) {
                return found
            }
        }
        return nil
    }

    /// Get all leaf content panels in this tree
    var allContentPanels: [Panel] {
        switch content {
        case .content:
            return [self]
        case .group(let group):
            return group.children.flatMap { $0.allContentPanels }
        }
    }

    /// Get all content panel IDs in this tree
    func allContentIds() -> [UUID] {
        var result: [UUID] = []
        collectContentIds(into: &result)
        return result
    }

    private func collectContentIds(into result: inout [UUID]) {
        switch content {
        case .content:
            result.append(id)
        case .group(let group):
            for child in group.children {
                child.collectContentIds(into: &result)
            }
        }
    }

    /// Get all group panels in this tree
    func allGroups() -> [Panel] {
        var result: [Panel] = []
        collectGroups(into: &result)
        return result
    }

    private func collectGroups(into result: inout [Panel]) {
        guard case .group(let group) = content else { return }
        result.append(self)
        for child in group.children {
            child.collectGroups(into: &result)
        }
    }

    /// Count total leaf content panels in this tree
    var totalContentCount: Int {
        switch content {
        case .content:
            return 1
        case .group(let group):
            return group.children.reduce(0) { $0 + $1.totalContentCount }
        }
    }

    /// Check if tree is empty (no content panels)
    var isEmpty: Bool {
        return totalContentCount == 0
    }

    /// Flatten the tree into a dictionary of [panelId: Panel]
    func flattenPanels() -> [UUID: Panel] {
        var result: [UUID: Panel] = [:]
        flattenPanels(into: &result)
        return result
    }

    private func flattenPanels(into result: inout [UUID: Panel]) {
        result[id] = self
        guard case .group(let group) = content else { return }
        for child in group.children {
            child.flattenPanels(into: &result)
        }
    }
}

// MARK: - Persistence

public extension DockLayout {
    private static let storageKey = "dockkit.panelLayout.v1"

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
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let layout = try? JSONDecoder().decode(DockLayout.self, from: data) {
            return layout
        }
        return nil
    }

    /// Clear the saved layout
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
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
