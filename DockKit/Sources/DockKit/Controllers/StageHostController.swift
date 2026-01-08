import AppKit

// MARK: - StageHostControllerDelegate

/// Delegate for StageHostController events
public protocol StageHostControllerDelegate: AnyObject {
    /// Layout changed for a specific stage - rebuild that stage's view
    func controller(_ controller: StageHostController, didUpdateLayout layout: DockLayoutNode, forStageAt index: Int)

    /// Stages list changed - rebuild header and possibly container
    func controller(_ controller: StageHostController, didUpdateStages stages: [Stage], activeIndex: Int)

    /// Active stage changed (swipe/click)
    func controller(_ controller: StageHostController, didSwitchToStage index: Int)

    /// Panel was detached - create new window
    func controller(_ controller: StageHostController, didDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)
}

// MARK: - StageHostController

/// Manages stage host state and operations
/// Used by both DockStageHostView and DockStageHostWindow to eliminate code duplication
public class StageHostController {

    // MARK: - State

    public private(set) var state: StageHostWindowState
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?
    public weak var delegate: StageHostControllerDelegate?

    // MARK: - Computed Properties

    public var activeStageIndex: Int { state.activeStageIndex }
    public var stages: [Stage] { state.stages }

    public var isEmpty: Bool {
        state.stages.allSatisfy { $0.layout.isEmpty }
    }

    public var displayMode: StageDisplayMode {
        get { state.displayMode }
        set { state.displayMode = newValue }
    }

    // MARK: - Initialization

    public init(state: StageHostWindowState) {
        self.state = state
    }

    // MARK: - Tab Operations

    /// Called when a tab is closed via X button
    /// This is the key method that fixes the empty space bug - it uses removingTab() which calls cleanedUp()
    public func handleTabClosed(_ tabId: UUID) {
        guard state.activeStageIndex < state.stages.count else { return }

        var stage = state.stages[state.activeStageIndex]
        var modified = false
        stage.layout = stage.layout.removingTab(tabId, modified: &modified)
        // ↑ removingTab() calls cleanedUp() which removes empty nodes!

        if modified {
            state.stages[state.activeStageIndex] = stage
            delegate?.controller(self, didUpdateLayout: stage.layout, forStageAt: state.activeStageIndex)
        }
    }

    /// Remove a panel from any stage
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        for i in 0..<state.stages.count {
            var stage = state.stages[i]
            var modified = false
            stage.layout = stage.layout.removingTab(panelId, modified: &modified)
            if modified {
                state.stages[i] = stage
                if i == state.activeStageIndex {
                    delegate?.controller(self, didUpdateLayout: stage.layout, forStageAt: i)
                }
                return true
            }
        }
        return false
    }

    // MARK: - Tab Movement

    /// Handle a tab being dropped in a tab group
    public func handleTabReceived(_ tabId: UUID, in groupId: UUID, at index: Int) {
        guard state.activeStageIndex < state.stages.count else { return }

        var stage = state.stages[state.activeStageIndex]
        stage.layout = stage.layout.movingTab(tabId, toGroupId: groupId, at: index)
        state.stages[state.activeStageIndex] = stage

        delegate?.controller(self, didUpdateLayout: stage.layout, forStageAt: state.activeStageIndex)
    }

    /// Handle a tab being dropped on a different stage header
    public func handleTabMovedToStage(_ tabId: UUID, targetStageIndex: Int) {
        guard let srcIndex = findStageContaining(tabId),
              srcIndex != targetStageIndex else { return }

        guard let (tabState, newSourceLayout) = extractTab(tabId, from: state.stages[srcIndex].layout) else { return }

        state.stages[srcIndex].layout = newSourceLayout
        state.stages[targetStageIndex].layout = insertTab(tabState, into: state.stages[targetStageIndex].layout)
        state.activeStageIndex = targetStageIndex

        delegate?.controller(self, didUpdateStages: state.stages, activeIndex: targetStageIndex)
    }

    // MARK: - Split

    /// Handle a split request (tab dropped on edge of a tab group)
    public func handleSplit(groupId: UUID, direction: DockSplitDirection, withTab tab: DockTab) {
        guard state.activeStageIndex < state.stages.count else { return }

        var stage = state.stages[state.activeStageIndex]
        let tabState = TabLayoutState(id: tab.id, title: tab.title, iconName: tab.iconName, cargo: tab.cargo)
        stage.layout = stage.layout.splitting(groupId: groupId, direction: direction, withTab: tabState)
        state.stages[state.activeStageIndex] = stage

        delegate?.controller(self, didUpdateLayout: stage.layout, forStageAt: state.activeStageIndex)
    }

    // MARK: - Detach

    /// Handle a tab being torn off to create a new window
    public func handleDetach(tab: DockTab, at screenPoint: NSPoint) {
        guard let panel = tab.panel ?? panelProvider?(tab.id) else { return }

        panel.panelWillDetach()
        handleTabClosed(tab.id)  // Remove from current stage

        delegate?.controller(self, didDetachPanel: panel, at: screenPoint)
    }

    // MARK: - Stage Operations

    /// Switch to a specific stage
    public func switchToStage(at index: Int) {
        guard index >= 0 && index < state.stages.count else { return }
        guard index != state.activeStageIndex else { return }

        state.activeStageIndex = index
        delegate?.controller(self, didSwitchToStage: index)
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        let stageNumber = state.stages.count + 1
        let stage = Stage(
            title: title ?? "Stage \(stageNumber)",
            iconName: iconName,
            layout: .tabGroup(TabGroupLayoutNode())
        )

        state.stages.append(stage)
        state.activeStageIndex = state.stages.count - 1

        delegate?.controller(self, didUpdateStages: state.stages, activeIndex: state.activeStageIndex)
        return stage
    }

    /// Update the entire state (for reconciliation or external updates)
    public func updateState(_ newState: StageHostWindowState) {
        state = newState
        delegate?.controller(self, didUpdateStages: state.stages, activeIndex: state.activeStageIndex)
    }

    /// Mark stage switch complete (called after animation finishes)
    public func completeStageSwitch(to index: Int) {
        state.activeStageIndex = index
    }

    // MARK: - Queries

    /// Check if any stage contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        state.stages.contains { containsPanel(panelId, in: $0.layout) }
    }

    // MARK: - Private Helpers

    private func findStageContaining(_ tabId: UUID) -> Int? {
        for (index, stage) in state.stages.enumerated() {
            if containsTab(tabId, in: stage.layout) {
                return index
            }
        }
        return nil
    }

    private func containsPanel(_ panelId: UUID, in node: DockLayoutNode) -> Bool {
        switch node {
        case .tabGroup(let group):
            return group.tabs.contains { $0.id == panelId }
        case .split(let split):
            return split.children.contains { containsPanel(panelId, in: $0) }
        case .stageHost(let host):
            return host.stages.contains { containsPanel(panelId, in: $0.layout) }
        }
    }

    private func containsTab(_ tabId: UUID, in node: DockLayoutNode) -> Bool {
        containsPanel(tabId, in: node)
    }

    private func extractTab(_ tabId: UUID, from layout: DockLayoutNode) -> (TabLayoutState, DockLayoutNode)? {
        switch layout {
        case .tabGroup(var group):
            guard let index = group.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
            let tab = group.tabs.remove(at: index)
            if group.activeTabIndex >= group.tabs.count {
                group.activeTabIndex = max(0, group.tabs.count - 1)
            }
            return (tab, .tabGroup(group).cleanedUp())

        case .split(var split):
            for (i, child) in split.children.enumerated() {
                if let (tab, newChild) = extractTab(tabId, from: child) {
                    split.children[i] = newChild
                    return (tab, .split(split).cleanedUp())
                }
            }
            return nil

        case .stageHost(var host):
            for (i, stage) in host.stages.enumerated() {
                if let (tab, newLayout) = extractTab(tabId, from: stage.layout) {
                    host.stages[i].layout = newLayout
                    return (tab, .stageHost(host))
                }
            }
            return nil
        }
    }

    private func insertTab(_ tab: TabLayoutState, into layout: DockLayoutNode) -> DockLayoutNode {
        switch layout {
        case .tabGroup(var group):
            group.tabs.append(tab)
            group.activeTabIndex = group.tabs.count - 1
            return .tabGroup(group)
        case .split(var split):
            if !split.children.isEmpty {
                split.children[0] = insertTab(tab, into: split.children[0])
            }
            return .split(split)
        case .stageHost(var host):
            if host.activeStageIndex < host.stages.count {
                host.stages[host.activeStageIndex].layout = insertTab(tab, into: host.stages[host.activeStageIndex].layout)
            }
            return .stageHost(host)
        }
    }
}
