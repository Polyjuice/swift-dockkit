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

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        isFullScreen: Bool = false,
        activeDesktopIndex: Int = 0,
        desktops: [Desktop]
    ) {
        self.id = id
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.activeDesktopIndex = activeDesktopIndex
        self.desktops = desktops
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
        }
    }
}
