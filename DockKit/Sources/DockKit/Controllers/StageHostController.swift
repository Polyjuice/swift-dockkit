import AppKit

// MARK: - StageHostControllerDelegate

/// Delegate for StageHostController events
public protocol StageHostControllerDelegate: AnyObject {
    /// Layout changed for a specific stage - rebuild that stage's view
    func controller(_ controller: StageHostController, didUpdateLayout layout: Panel, forStageAt index: Int)

    /// Stages list changed - rebuild header and possibly container
    func controller(_ controller: StageHostController, didUpdateStages stages: [Panel], activeIndex: Int)

    /// Active stage changed (swipe/click)
    func controller(_ controller: StageHostController, didSwitchToStage index: Int)

    /// Panel was detached - create new window
    func controller(_ controller: StageHostController, didDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)
}

// MARK: - StageHostController

/// Manages stage host state and operations
/// Used by both DockStageHostView and DockStageHostWindow to eliminate code duplication
///
/// The controller operates on a `Panel` whose content is `.group(PanelGroup)` with `style: .stages`.
/// Each child of that group is a "stage" — itself a Panel (typically with `.group` content representing
/// the stage's layout tree).
public class StageHostController {

    // MARK: - State

    /// The root panel (must have .group content with style .stages)
    public private(set) var panel: Panel
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?
    public weak var delegate: StageHostControllerDelegate?

    // MARK: - Computed Properties

    public var activeStageIndex: Int { panel.group?.activeIndex ?? 0 }

    /// The stage children of this stage host
    public var stages: [Panel] { panel.group?.children ?? [] }

    public var isEmpty: Bool {
        stages.allSatisfy { $0.isEmpty }
    }

    public var groupStyle: PanelGroupStyle {
        get { panel.group?.style ?? .stages }
        set {
            guard case .group(var g) = panel.content else { return }
            g.style = newValue
            panel.content = .group(g)
        }
    }

    // MARK: - Initialization

    public init(panel: Panel) {
        assert(panel.group?.style == .stages, "StageHostController requires a panel with stages group style")
        self.panel = panel
    }

    // MARK: - Child Close Operations

    /// Called when a content panel is closed via X button
    /// This removes the child from the active stage's layout tree using removingChild() which calls cleanedUp()
    public func handleChildClosed(_ childId: UUID) {
        guard var group = panel.group,
              group.activeIndex < group.children.count else { return }

        var stage = group.children[group.activeIndex]
        var modified = false
        stage = stage.removingChild(childId, modified: &modified)

        if modified {
            group.children[group.activeIndex] = stage
            panel.content = .group(group)
            delegate?.controller(self, didUpdateLayout: stage, forStageAt: group.activeIndex)
        }
    }

    /// Remove a panel from any stage
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        guard var group = panel.group else { return false }

        for i in 0..<group.children.count {
            var stage = group.children[i]
            var modified = false
            stage = stage.removingChild(panelId, modified: &modified)
            if modified {
                group.children[i] = stage
                panel.content = .group(group)
                if i == activeStageIndex {
                    delegate?.controller(self, didUpdateLayout: stage, forStageAt: i)
                }
                return true
            }
        }
        return false
    }

    // MARK: - Child Movement

    /// Handle a child panel being dropped in a group
    public func handleChildReceived(_ childId: UUID, title: String? = nil, iconName: String? = nil, in groupId: UUID, at index: Int) {
        guard var group = panel.group,
              group.activeIndex < group.children.count else { return }

        // Find existing panel anywhere in the tree to preserve title/icon
        let existingPanel = panel.findChildInfo(childId)?.panel

        var stage = group.children[group.activeIndex]

        // Remove from current location first (may be in any stage)
        var modified = false
        for i in group.children.indices {
            group.children[i] = group.children[i].removingChildWithoutCleanup(childId, modified: &modified)
        }
        stage = group.children[group.activeIndex]

        // Use existing panel data, fall back to drag info, fall back to placeholder
        let childPanel: Panel
        if let existing = existingPanel {
            childPanel = existing
        } else {
            childPanel = Panel.contentPanel(id: childId, title: title ?? "Untitled", iconName: iconName)
        }

        stage = stage.addingChild(childPanel, toGroupId: groupId, at: index, modified: &modified)
        stage = stage.cleanedUp()

        // Clean up all stages (source stage may have empty groups now)
        group.children[group.activeIndex] = stage
        for i in group.children.indices where i != group.activeIndex {
            group.children[i] = group.children[i].cleanedUp()
        }
        panel.content = .group(group)

        delegate?.controller(self, didUpdateLayout: stage, forStageAt: group.activeIndex)
    }

    /// Handle a child panel being dropped on a different stage header
    public func handleChildMovedToStage(_ childId: UUID, targetStageIndex: Int) {
        guard var group = panel.group else { return }
        guard let srcIndex = findStageContaining(childId),
              srcIndex != targetStageIndex else { return }

        guard let (childPanel, newSourceStage) = extractChild(childId, from: group.children[srcIndex]) else { return }

        group.children[srcIndex] = newSourceStage
        group.children[targetStageIndex] = insertChild(childPanel, into: group.children[targetStageIndex])
        group.activeIndex = targetStageIndex
        panel.content = .group(group)

        delegate?.controller(self, didUpdateStages: stages, activeIndex: targetStageIndex)
    }

    // MARK: - Split

    /// Handle a split request (panel dropped on edge of a group)
    public func handleSplit(groupId: UUID, direction: DockSplitDirection, withPanelId panelId: UUID) {
        guard var group = panel.group,
              group.activeIndex < group.children.count else { return }

        var stage = group.children[group.activeIndex]

        // Find the existing panel in the tree to preserve its title/iconName
        let existingPanel = stage.findChildInfo(panelId)?.panel
            ?? panel.findChildInfo(panelId)?.panel
        let childPanel = existingPanel ?? Panel.contentPanel(id: panelId, title: "Untitled")

        // Remove from source location first, then split
        var modified = false
        stage = stage.removingChildWithoutCleanup(panelId, modified: &modified)
        stage = stage.splittingGroup(groupId: groupId, direction: direction, withChild: childPanel, modified: &modified)
        stage = stage.cleanedUp()
        group.children[group.activeIndex] = stage
        panel.content = .group(group)

        delegate?.controller(self, didUpdateLayout: stage, forStageAt: group.activeIndex)
    }

    // MARK: - Detach

    /// Handle a panel being torn off to create a new window
    public func handleDetach(panelId: UUID, at screenPoint: NSPoint) {
        guard let dockablePanel = panelProvider?(panelId) else { return }

        dockablePanel.panelWillDetach()
        handleChildClosed(panelId)  // Remove from current stage

        delegate?.controller(self, didDetachPanel: dockablePanel, at: screenPoint)
    }

    // MARK: - Stage Operations

    /// Switch to a specific stage
    public func switchToStage(at index: Int) {
        guard var group = panel.group else { return }
        guard index >= 0 && index < group.children.count else { return }
        guard index != group.activeIndex else { return }

        group.activeIndex = index
        panel.content = .group(group)
        delegate?.controller(self, didSwitchToStage: index)
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Panel {
        guard var group = panel.group else {
            fatalError("StageHostController requires a panel with group content")
        }

        let stageNumber = group.children.count + 1
        let stage = Panel(
            title: title ?? "Stage \(stageNumber)",
            iconName: iconName,
            content: .group(PanelGroup(style: .tabs))
        )

        group.children.append(stage)
        group.activeIndex = group.children.count - 1
        panel.content = .group(group)

        delegate?.controller(self, didUpdateStages: stages, activeIndex: group.activeIndex)
        return stage
    }

    /// Remove a stage at the specified index
    public func removeStage(at index: Int) {
        guard var group = panel.group else { return }
        guard index >= 0 && index < group.children.count else { return }

        group.children.remove(at: index)

        // Adjust activeIndex
        if group.children.isEmpty {
            group.activeIndex = 0
        } else if group.activeIndex >= group.children.count {
            group.activeIndex = group.children.count - 1
        } else if group.activeIndex > index {
            group.activeIndex -= 1
        }

        panel.content = .group(group)
        delegate?.controller(self, didUpdateStages: stages, activeIndex: group.activeIndex)
    }

    /// Update the entire panel (for reconciliation or external updates)
    public func updatePanel(_ newPanel: Panel) {
        panel = newPanel
        delegate?.controller(self, didUpdateStages: stages, activeIndex: activeStageIndex)
    }

    /// Mark stage switch complete (called after animation finishes)
    public func completeStageSwitch(to index: Int) {
        guard var group = panel.group else { return }
        group.activeIndex = index
        panel.content = .group(group)
    }

    // MARK: - Queries

    /// Check if any stage contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        stages.contains { containsPanel(panelId, in: $0) }
    }

    // MARK: - Private Helpers

    private func findStageContaining(_ childId: UUID) -> Int? {
        for (index, stage) in stages.enumerated() {
            if containsPanel(childId, in: stage) {
                return index
            }
        }
        return nil
    }

    private func containsPanel(_ panelId: UUID, in node: Panel) -> Bool {
        if node.id == panelId && node.isContent { return true }
        guard let group = node.group else { return false }
        return group.children.contains { containsPanel(panelId, in: $0) }
    }

    private func extractChild(_ childId: UUID, from stagePanel: Panel) -> (Panel, Panel)? {
        guard case .group(var group) = stagePanel.content else { return nil }

        // Check direct children
        if let index = group.children.firstIndex(where: { $0.id == childId }) {
            let child = group.children.remove(at: index)
            if group.activeIndex >= group.children.count {
                group.activeIndex = max(0, group.children.count - 1)
            }
            var newStage = stagePanel
            newStage.content = .group(group)
            return (child, newStage.cleanedUp())
        }

        // Recurse into children
        for (i, childPanel) in group.children.enumerated() {
            if let (extracted, newChild) = extractChild(childId, from: childPanel) {
                group.children[i] = newChild
                var newStage = stagePanel
                newStage.content = .group(group)
                return (extracted, newStage.cleanedUp())
            }
        }
        return nil
    }

    private func insertChild(_ child: Panel, into stagePanel: Panel) -> Panel {
        guard case .group(var group) = stagePanel.content else { return stagePanel }

        switch group.style {
        case .tabs, .thumbnails:
            group.children.append(child)
            group.activeIndex = group.children.count - 1
            var newStage = stagePanel
            newStage.content = .group(group)
            return newStage

        case .split:
            if !group.children.isEmpty {
                group.children[0] = insertChild(child, into: group.children[0])
            }
            var newStage = stagePanel
            newStage.content = .group(group)
            return newStage

        case .stages:
            if group.activeIndex < group.children.count {
                group.children[group.activeIndex] = insertChild(child, into: group.children[group.activeIndex])
            }
            var newStage = stagePanel
            newStage.content = .group(group)
            return newStage
        }
    }
}
