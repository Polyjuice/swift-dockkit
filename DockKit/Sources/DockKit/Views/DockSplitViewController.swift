import AppKit

// MARK: - Custom Split View with Visible Dividers

/// Custom NSSplitView that draws visible dividers with a gap and handle
public class DockSplitView: NSSplitView {
    /// The thickness of the divider gap
    public static let dividerGap: CGFloat = 6

    public override var dividerThickness: CGFloat {
        return Self.dividerGap
    }

    public override func drawDivider(in rect: NSRect) {
        // Fill divider background with dark/black color
        NSColor.black.setFill()
        rect.fill()

        // Draw a centered white line/handle
        NSColor.white.withAlphaComponent(0.6).setFill()

        if isVertical {
            // Vertical divider (horizontal split) - draw vertical line
            let handleWidth: CGFloat = 1
            let handleHeight: CGFloat = min(40, rect.height * 0.4)
            let handleRect = NSRect(
                x: rect.midX - handleWidth / 2,
                y: rect.midY - handleHeight / 2,
                width: handleWidth,
                height: handleHeight
            )
            let path = NSBezierPath(roundedRect: handleRect, xRadius: handleWidth / 2, yRadius: handleWidth / 2)
            path.fill()
        } else {
            // Horizontal divider (vertical split) - draw horizontal line
            let handleWidth: CGFloat = min(40, rect.width * 0.4)
            let handleHeight: CGFloat = 1
            let handleRect = NSRect(
                x: rect.midX - handleWidth / 2,
                y: rect.midY - handleHeight / 2,
                width: handleWidth,
                height: handleHeight
            )
            let path = NSBezierPath(roundedRect: handleRect, xRadius: handleHeight / 2, yRadius: handleHeight / 2)
            path.fill()
        }
    }

}

/// Delegate for split view events
public protocol DockSplitViewControllerDelegate: AnyObject {
    func splitViewController(_ controller: DockSplitViewController, didUpdateProportions proportions: [CGFloat])
    func splitViewController(_ controller: DockSplitViewController, childDidBecomeEmpty index: Int)
}

/// A split view controller that manages dock node children
/// Handles the recursive structure of splits within splits
public class DockSplitViewController: NSSplitViewController {
    public weak var dockDelegate: DockSplitViewControllerDelegate?

    /// Delegate for child tab groups - passed down from container
    public weak var tabGroupDelegate: DockTabGroupViewControllerDelegate?

    /// Delegate for swipe gesture bubbling - passed down to nested stage hosts (Version 3)
    public weak var swipeGestureDelegate: SwipeGestureDelegate?

    /// The split node this controller represents
    public private(set) var splitNode: SplitNode

    /// Map of child view controllers to their node IDs
    private var childNodeMap: [UUID: NSViewController] = [:]

    // MARK: - Computed Properties for Layout Extraction

    /// The ID of the split node
    public var nodeId: UUID {
        return splitNode.id
    }

    /// Whether this split is vertical (i.e., children arranged horizontally)
    /// Note: NSSplitView.isVertical means dividers are vertical (children are horizontal)
    public var isVertical: Bool {
        return splitNode.axis == .vertical
    }

    /// Get the current proportions from the split view
    public func getProportions() -> [CGFloat] {
        return splitNode.proportions
    }

    public init(splitNode: SplitNode) {
        self.splitNode = splitNode
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.splitNode = SplitNode(axis: .horizontal, children: [])
        super.init(coder: coder)
    }

    public override func loadView() {
        // Use custom DockSplitView instead of default NSSplitView
        let customSplitView = DockSplitView()
        customSplitView.isVertical = splitNode.axis == .horizontal
        self.splitView = customSplitView
        self.view = customSplitView
    }

    public override func viewDidLoad() {
        // IMPORTANT: NSSplitViewController requires splitViewItems to be configured
        // BEFORE super.viewDidLoad() is called, otherwise it crashes trying to set up
        // constraints on an empty split view.
        buildChildren()
        super.viewDidLoad()
        setupSplitView()
    }

    // MARK: - Setup

    private func setupSplitView() {
        splitView.isVertical = splitNode.axis == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = self
    }

    /// Build child view controllers from the split node
    public func buildChildren() {
        // Remove existing children
        for item in splitViewItems.reversed() {
            removeSplitViewItem(item)
        }
        childNodeMap.removeAll()

        // Create new children
        for (index, childNode) in splitNode.children.enumerated() {
            let childVC = createViewController(for: childNode)
            let item = NSSplitViewItem(viewController: childVC)

            // Configure item
            item.canCollapse = false
            item.holdingPriority = .defaultLow
            item.minimumThickness = 100  // Minimum 100pt per pane

            addSplitViewItem(item)
            childNodeMap[childNode.nodeId] = childVC

            // Set initial proportion (will be applied in viewDidAppear)
            if index < splitNode.proportions.count {
                // Store proportion for later
            }
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        applyProportions()
    }

    /// Apply stored proportions to split view
    private func applyProportions() {
        guard splitViewItems.count == splitNode.proportions.count,
              splitViewItems.count > 1 else { return }

        let totalSize = splitNode.axis == .horizontal ?
            splitView.bounds.width : splitView.bounds.height

        var position: CGFloat = 0
        for (index, proportion) in splitNode.proportions.dropLast().enumerated() {
            position += totalSize * proportion
            splitView.setPosition(position, ofDividerAt: index)
        }
    }

    // MARK: - Child Management

    /// Create appropriate view controller for a dock node
    private func createViewController(for node: DockNode) -> NSViewController {
        switch node {
        case .split(let splitNode):
            let splitVC = DockSplitViewController(splitNode: splitNode)
            splitVC.dockDelegate = dockDelegate
            splitVC.tabGroupDelegate = tabGroupDelegate
            // Pass swipe gesture delegate down for nested stage hosts (Version 3)
            splitVC.swipeGestureDelegate = swipeGestureDelegate
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: tabGroupNode)
            tabGroupVC.delegate = tabGroupDelegate
            return tabGroupVC

        case .stageHost(let stageHostNode):
            // Create a nested stage host view controller (Version 3 feature)
            let layoutNode = StageHostLayoutNode(
                id: stageHostNode.id,
                title: stageHostNode.title,
                iconName: stageHostNode.iconName,
                activeStageIndex: stageHostNode.activeStageIndex,
                stages: stageHostNode.stages,
                displayMode: stageHostNode.displayMode
            )
            let hostVC = DockStageHostViewController(
                layoutNode: layoutNode,
                panelProvider: nil // Will be set by parent if needed
            )
            // Connect swipe gesture delegate for bubbling (Version 3)
            hostVC.swipeGestureDelegate = swipeGestureDelegate
            return hostVC
        }
    }

    /// Get the view controller for a specific node ID
    public func childViewController(for nodeId: UUID) -> NSViewController? {
        return childNodeMap[nodeId]
    }

    /// Insert a new child at the specified index
    public func insertChild(_ node: DockNode, at index: Int) {
        let insertIndex = max(0, min(index, splitNode.children.count))

        // Update model
        splitNode.insertChild(node, at: insertIndex)

        // Create and insert view controller
        let childVC = createViewController(for: node)
        let item = NSSplitViewItem(viewController: childVC)
        item.canCollapse = false
        item.minimumThickness = 100

        insertSplitViewItem(item, at: insertIndex)
        childNodeMap[node.nodeId] = childVC
    }

    /// Remove a child at the specified index (dock-specific, different from NSViewController)
    public func removeDockChild(at index: Int) {
        guard index >= 0 && index < splitNode.children.count else { return }

        let nodeId = splitNode.children[index].nodeId

        // Update model
        splitNode.removeChild(at: index)

        // Remove view controller
        if index < splitViewItems.count {
            removeSplitViewItem(splitViewItems[index])
        }
        childNodeMap.removeValue(forKey: nodeId)

        // Notify delegate if we're now empty
        if splitNode.children.isEmpty {
            dockDelegate?.splitViewController(self, childDidBecomeEmpty: 0)
        }
    }

    /// Replace a child node with a new node
    public func replaceChild(at index: Int, with newNode: DockNode) {
        guard index >= 0 && index < splitNode.children.count else { return }

        // Remove old
        let oldNodeId = splitNode.children[index].nodeId
        childNodeMap.removeValue(forKey: oldNodeId)

        // Update model
        splitNode.children[index] = newNode

        // Create new view controller
        let newVC = createViewController(for: newNode)

        // Replace in split view
        if index < splitViewItems.count {
            removeSplitViewItem(splitViewItems[index])
        }

        let item = NSSplitViewItem(viewController: newVC)
        item.canCollapse = false
        item.minimumThickness = 100
        insertSplitViewItem(item, at: index)

        childNodeMap[newNode.nodeId] = newVC
    }

    /// Split a child in a direction
    public func splitChild(at index: Int, direction: DockSplitDirection, withNewNode newNode: DockNode) {
        guard index >= 0 && index < splitNode.children.count else { return }

        let existingNode = splitNode.children[index]

        // Determine new split axis
        let newAxis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical

        // Create new split node containing existing and new
        let insertFirst = (direction == .left || direction == .top)
        let children = insertFirst ? [newNode, existingNode] : [existingNode, newNode]

        let newSplitNode = SplitNode(axis: newAxis, children: children)

        // Replace the child with the new split
        replaceChild(at: index, with: .split(newSplitNode))
    }

    // MARK: - Reconciliation Support

    /// Update the split axis (for reconciliation)
    public func updateAxis(_ axis: SplitAxis) {
        splitNode.axis = axis
        splitView.isVertical = axis == .horizontal
    }

    /// Set the proportions for children (for reconciliation)
    public func setProportions(_ proportions: [CGFloat]) {
        guard proportions.count == splitNode.proportions.count else { return }
        splitNode.proportions = proportions

        // Apply to split view
        let totalSize = splitNode.axis == .horizontal ?
            splitView.bounds.width : splitView.bounds.height

        guard totalSize > 0, proportions.count > 1 else { return }

        var position: CGFloat = 0
        for (index, proportion) in proportions.dropLast().enumerated() {
            position += totalSize * proportion
            splitView.setPosition(position, ofDividerAt: index)
        }
    }
}

// MARK: - NSSplitViewDelegate

extension DockSplitViewController {
    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        updateProportionsFromSplitView()
    }

    private func updateProportionsFromSplitView() {
        guard splitViewItems.count > 1 else { return }

        let totalSize = splitNode.axis == .horizontal ?
            splitView.bounds.width : splitView.bounds.height

        guard totalSize > 0 else { return }

        var proportions: [CGFloat] = []
        for item in splitViewItems {
            let itemSize = splitNode.axis == .horizontal ?
                item.viewController.view.bounds.width :
                item.viewController.view.bounds.height
            proportions.append(itemSize / totalSize)
        }

        // Normalize to ensure they sum to 1.0
        let sum = proportions.reduce(0, +)
        if sum > 0 {
            proportions = proportions.map { $0 / sum }
        }

        // GUARD: Don't update if any proportion is 0 or very small - this indicates
        // the split view hasn't fully laid out yet and we'd be storing garbage values
        // that cause invisible panes
        let minProportion: CGFloat = 0.01  // 1% minimum
        if proportions.contains(where: { $0 < minProportion }) {
            return
        }

        splitNode.proportions = proportions
        dockDelegate?.splitViewController(self, didUpdateProportions: proportions)
    }

    // NOTE: Do NOT implement splitView(_:constrainMinCoordinate:ofSubviewAt:) or
    // splitView(_:constrainMaxCoordinate:ofSubviewAt:) - they are incompatible with
    // NSSplitViewController's autolayout. Use NSSplitViewItem.minimumThickness instead.
}
