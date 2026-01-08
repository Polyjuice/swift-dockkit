import Foundation

// MARK: - Stage Types for StageHostWindow

/// A virtual workspace within a StageHostWindow
/// Each stage has its own independent layout tree
public struct Stage: Codable, Identifiable {
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

/// State for a stage host window containing multiple stages
public struct StageHostWindowState: Codable, Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var activeStageIndex: Int
    public var stages: [Stage]

    /// Display mode for tabs and stage indicators
    /// Controls whether to use tabs, thumbnails, or custom renderer
    public var displayMode: StageDisplayMode

    private enum CodingKeys: String, CodingKey {
        case id, frame, isFullScreen, activeStageIndex, stages, displayMode
    }

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        isFullScreen: Bool = false,
        activeStageIndex: Int = 0,
        stages: [Stage],
        displayMode: StageDisplayMode = .thumbnails
    ) {
        self.id = id
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.activeStageIndex = activeStageIndex
        self.stages = stages
        self.displayMode = displayMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decode(CGRect.self, forKey: .frame)
        isFullScreen = try container.decode(Bool.self, forKey: .isFullScreen)
        activeStageIndex = try container.decode(Int.self, forKey: .activeStageIndex)
        stages = try container.decode([Stage].self, forKey: .stages)
        // Default to .tabs for backward compatibility
        displayMode = try container.decodeIfPresent(StageDisplayMode.self, forKey: .displayMode) ?? .tabs
    }

    /// Get the active stage's layout
    public var activeLayout: DockLayoutNode {
        guard activeStageIndex >= 0 && activeStageIndex < stages.count else {
            return .tabGroup(TabGroupLayoutNode())
        }
        return stages[activeStageIndex].layout
    }
}

// MARK: - DockLayoutNode Helpers for Stages

public extension DockLayoutNode {
    /// Get the node ID
    var nodeId: UUID {
        switch self {
        case .split(let node): return node.id
        case .tabGroup(let node): return node.id
        case .stageHost(let node): return node.id
        }
    }
}
