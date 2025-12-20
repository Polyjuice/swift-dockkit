import Foundation

// MARK: - Desktop Types for DesktopHostWindow

/// A virtual workspace within a DesktopHostWindow
/// Each desktop has its own independent layout tree
public struct Desktop: Codable, Identifiable {
    public let id: UUID
    public var title: String?
    public var iconName: String?
    public var layout: DockLayoutNode

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        iconName: String? = nil,
        layout: DockLayoutNode
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.layout = layout
    }
}

/// State for a desktop host window containing multiple desktops
public struct DesktopHostWindowState: Codable, Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var activeDesktopIndex: Int
    public var desktops: [Desktop]

    /// Display mode for tabs and desktop indicators
    /// Controls whether to use tabs, thumbnails, or custom renderer
    public var displayMode: DesktopDisplayMode

    private enum CodingKeys: String, CodingKey {
        case id, frame, isFullScreen, activeDesktopIndex, desktops, displayMode
    }

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        isFullScreen: Bool = false,
        activeDesktopIndex: Int = 0,
        desktops: [Desktop],
        displayMode: DesktopDisplayMode = .thumbnails
    ) {
        self.id = id
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.activeDesktopIndex = activeDesktopIndex
        self.desktops = desktops
        self.displayMode = displayMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decode(CGRect.self, forKey: .frame)
        isFullScreen = try container.decode(Bool.self, forKey: .isFullScreen)
        activeDesktopIndex = try container.decode(Int.self, forKey: .activeDesktopIndex)
        desktops = try container.decode([Desktop].self, forKey: .desktops)
        // Default to .tabs for backward compatibility
        displayMode = try container.decodeIfPresent(DesktopDisplayMode.self, forKey: .displayMode) ?? .tabs
    }

    /// Get the active desktop's layout
    public var activeLayout: DockLayoutNode {
        guard activeDesktopIndex >= 0 && activeDesktopIndex < desktops.count else {
            return .tabGroup(TabGroupLayoutNode())
        }
        return desktops[activeDesktopIndex].layout
    }
}

// MARK: - DockLayoutNode Helpers for Desktops

public extension DockLayoutNode {
    /// Get the node ID
    var nodeId: UUID {
        switch self {
        case .split(let node): return node.id
        case .tabGroup(let node): return node.id
        case .desktopHost(let node): return node.id
        }
    }
}
