import AppKit

/// Delegate for dock window events
public protocol DockWindowDelegate: AnyObject {
    func dockWindow(_ window: DockWindow, didClose: Void)
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)
    func dockWindow(_ window: DockWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockWindowDelegate {
    func dockWindow(_ window: DockWindow, didClose: Void) {}
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func dockWindow(_ window: DockWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {}
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {}
}

/// A dock window that can contain full layout trees (splits + tabs)
/// All windows are equal - there is no "main" window concept
public class DockWindow: NSWindow {

    // MARK: - Properties

    /// Window ID for tracking
    public let windowId: UUID

    /// The root dock node (can be split or tabGroup)
    /// Internal setter allows reconciler to update model before rebuilding
    public internal(set) var rootNode: DockNode

    /// Root view controller (either split or tab group)
    /// Note: Exposed as internal for backward compatibility with DockContainerViewController
    internal var rootViewController: NSViewController?

    /// Reference to the layout manager
    public weak var layoutManager: DockLayoutManager?

    /// Delegate for window events
    public weak var dockDelegate: DockWindowDelegate?

    /// Flag to suppress auto-close during reconciliation
    /// When true, the window won't auto-close when a tab group becomes empty
    /// This prevents premature closure during layout rebuilds
    internal var suppressAutoClose: Bool = false

    // MARK: - Initialization

    /// Create a window with a root node and frame
    public init(id: UUID = UUID(), rootNode: DockNode, frame: NSRect, layoutManager: DockLayoutManager? = nil) {
        self.windowId = id
        self.rootNode = rootNode
        self.layoutManager = layoutManager

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        rebuildLayout()
    }

    /// Convenience initializer for backward compatibility
    @available(*, deprecated, message: "Use init(id:rootNode:frame:layoutManager:) instead")
    public convenience init(id: UUID = UUID(), tabGroup: DockTabGroupViewController, frame: NSRect) {
        let rootNode = DockNode.tabGroup(tabGroup.tabGroupNode)
        self.init(id: id, rootNode: rootNode, frame: frame, layoutManager: nil)
    }

    /// Convenience initializer with a single panel
    public convenience init(with panel: any DockablePanel, at screenPoint: NSPoint, layoutManager: DockLayoutManager? = nil) {
        let tabGroup = TabGroupNode(tabs: [DockTab(from: panel)])
        let size = NSSize(width: 600, height: 400)
        let frame = NSRect(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        self.init(id: UUID(), rootNode: .tabGroup(tabGroup), frame: frame, layoutManager: layoutManager)
    }

    private func setupWindow() {
        // CRITICAL: Prevent window from being auto-released when closed
        // We manage window lifecycle ourselves via DockLayoutManager.windows array
        // Without this, the window can be deallocated during close() while
        // autoreleased references still exist, causing crashes in objc_release
        isReleasedWhenClosed = false

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbarStyle = .unifiedCompact
        animationBehavior = .none

        let toolbar = NSToolbar(identifier: "DockWindowToolbar-\(windowId.uuidString)")
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar

        minSize = NSSize(width: 300, height: 200)

        updateTitle()
    }

    // MARK: - Layout Building

    /// Rebuild the view hierarchy from rootNode
    public func rebuildLayout() {
        // Build new root view controller
        let newRootVC = createViewController(for: rootNode)

        // Let AppKit handle removing the old content view controller
        // DO NOT manually remove - that causes double-release crashes
        contentViewController = newRootVC
        rootViewController = newRootVC

        updateTitle()
    }

    /// Create view controller for a dock node
    private func createViewController(for node: DockNode) -> NSViewController {
        switch node {
        case .split(let splitNode):
            let splitVC = DockSplitViewController(splitNode: splitNode)
            splitVC.dockDelegate = self
            splitVC.tabGroupDelegate = self
            return splitVC

        case .tabGroup(let tabGroupNode):
            let tabGroupVC = DockTabGroupViewController(tabGroupNode: tabGroupNode)
            tabGroupVC.delegate = self
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
                panelProvider: nil
            )
            return hostVC
        }
    }

    // MARK: - Public API

    /// Check if window contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        return findPanel(panelId, in: rootNode) != nil
    }

    /// Check if window is empty (no panels)
    public var isEmpty: Bool {
        return !containsAnyPanel(in: rootNode)
    }

    /// Add a panel to a specific tab group (or first available)
    public func addPanel(_ panel: any DockablePanel, to groupId: UUID? = nil, activate: Bool = true) {
        if let groupId = groupId,
           let tabGroup = findTabGroupController(withId: groupId, in: rootViewController) {
            tabGroup.addTab(from: panel, activate: activate)
            updateRootNodeFromController()
        } else if let firstTabGroup = findFirstTabGroupController(in: rootViewController) {
            firstTabGroup.addTab(from: panel, activate: activate)
            updateRootNodeFromController()
        }
    }

    /// Remove a panel from this window
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        if removeTab(withId: panelId, from: &rootNode) {
            if layoutManager?.reclaimEmptySpace ?? true {
                cleanupEmptyNodes(&rootNode)
            }
            rebuildLayout()
            return true
        }
        return false
    }

    /// Update window title from active tab
    public func updateTitle() {
        if let activeTab = findFirstActiveTab(in: rootNode) {
            title = activeTab.title
        } else {
            title = "Panel"
        }
    }

    // MARK: - NSWindow Overrides

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func close() {
        // Debug: trace where close is being called from
        print("[WINDOW] close() called on window \(windowId.uuidString.prefix(8))")
        Thread.callStackSymbols.prefix(10).forEach { print("  \($0)") }

        dockDelegate?.dockWindow(self, didClose: ())
        // Notify layout manager to remove us from its windows array
        // This prevents dangling references after window is deallocated
        layoutManager?.windowDidClose(self)
        super.close()
    }

    // MARK: - Private Helpers

    private func findPanel(_ panelId: UUID, in node: DockNode) -> DockTab? {
        switch node {
        case .tabGroup(let tabGroupNode):
            return tabGroupNode.tabs.first { $0.id == panelId }
        case .split(let splitNode):
            for child in splitNode.children {
                if let found = findPanel(panelId, in: child) {
                    return found
                }
            }
            return nil
        case .stageHost(let stageHostNode):
            for stage in stageHostNode.stages {
                let node = DockNode.from(stage.layout)
                if let found = findPanel(panelId, in: node) {
                    return found
                }
            }
            return nil
        }
    }

    private func containsAnyPanel(in node: DockNode) -> Bool {
        switch node {
        case .tabGroup(let tabGroupNode):
            return !tabGroupNode.tabs.isEmpty
        case .split(let splitNode):
            return splitNode.children.contains { containsAnyPanel(in: $0) }
        case .stageHost(let stageHostNode):
            return stageHostNode.stages.contains { stage in
                let node = DockNode.from(stage.layout)
                return containsAnyPanel(in: node)
            }
        }
    }

    private func findFirstActiveTab(in node: DockNode) -> DockTab? {
        switch node {
        case .tabGroup(let tabGroupNode):
            return tabGroupNode.activeTab
        case .split(let splitNode):
            for child in splitNode.children {
                if let tab = findFirstActiveTab(in: child) {
                    return tab
                }
            }
            return nil
        case .stageHost(let stageHostNode):
            if stageHostNode.activeStageIndex < stageHostNode.stages.count {
                let activeStage = stageHostNode.stages[stageHostNode.activeStageIndex]
                let node = DockNode.from(activeStage.layout)
                return findFirstActiveTab(in: node)
            }
            return nil
        }
    }

    private func findTabGroupController(withId id: UUID, in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController,
           tabGroup.tabGroupNode.id == id {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findTabGroupController(withId: id, in: item.viewController) {
                    return found
                }
            }
        }

        return nil
    }

    private func findFirstTabGroupController(in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController {
            return tabGroup
        }

        if let splitVC = controller as? DockSplitViewController {
            for item in splitVC.splitViewItems {
                if let found = findFirstTabGroupController(in: item.viewController) {
                    return found
                }
            }
        }

        return nil
    }

    private func removeTab(withId tabId: UUID, from node: inout DockNode) -> Bool {
        switch node {
        case .tabGroup(var tabGroupNode):
            if let index = tabGroupNode.tabs.firstIndex(where: { $0.id == tabId }) {
                tabGroupNode.removeTab(at: index)
                node = .tabGroup(tabGroupNode)
                return true
            }
            return false

        case .split(var splitNode):
            for i in 0..<splitNode.children.count {
                if removeTab(withId: tabId, from: &splitNode.children[i]) {
                    node = .split(splitNode)
                    return true
                }
            }
            return false

        case .stageHost:
            // Stage hosts manage their own tabs internally
            return false
        }
    }

    private func cleanupEmptyNodes(_ node: inout DockNode) {
        switch node {
        case .tabGroup:
            break

        case .split(var splitNode):
            // Recursively clean children
            for i in 0..<splitNode.children.count {
                cleanupEmptyNodes(&splitNode.children[i])
            }

            // Remove empty nodes (empty tab groups OR empty splits)
            splitNode.children.removeAll { child in
                child.isEmpty
            }

            // Simplify if only one child remains
            if splitNode.children.count == 1 {
                node = splitNode.children[0]
            } else if splitNode.children.isEmpty {
                node = .tabGroup(TabGroupNode())
            } else {
                node = .split(splitNode)
            }

        case .stageHost:
            // Stage hosts manage their own cleanup internally
            break
        }
    }

    /// Sync rootNode model from the current view controller hierarchy
    /// Called after reconciliation to ensure getLayout() returns accurate state
    public func syncNodeFromViewController() {
        if let rootVC = rootViewController {
            rootNode = extractNode(from: rootVC)
        }
    }

    private func updateRootNodeFromController() {
        syncNodeFromViewController()
    }

    private func extractNode(from controller: NSViewController) -> DockNode {
        if let tabGroupVC = controller as? DockTabGroupViewController {
            return .tabGroup(tabGroupVC.tabGroupNode)
        } else if let splitVC = controller as? DockSplitViewController {
            let children = splitVC.splitViewItems.map { extractNode(from: $0.viewController) }
            return .split(SplitNode(
                id: splitVC.nodeId,
                axis: splitVC.isVertical ? .vertical : .horizontal,
                children: children,
                proportions: splitVC.getProportions()
            ))
        }
        return .tabGroup(TabGroupNode())
    }
}

// MARK: - DockTabGroupViewControllerDelegate

extension DockWindow: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachTab tab: DockTab, at screenPoint: NSPoint) {
        if let panel = tab.panel {
            dockDelegate?.dockWindow(self, wantsToDetachPanel: panel, at: screenPoint)
        } else {
            // Cannot proceed without panel reference
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        dockDelegate?.dockWindow(self, didReceiveTab: tabInfo, in: tabGroup, at: index)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastTab: Bool) {
        // During reconciliation, the reconciler manages window lifecycle
        // Don't auto-close based on stale model state
        if suppressAutoClose {
            return
        }

        updateRootNodeFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            cleanupEmptyNodes(&rootNode)
        }

        if isEmpty {
            close()
        } else {
            rebuildLayout()
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab) {
        dockDelegate?.dockWindow(self, wantsToSplit: direction, withTab: tab, in: tabGroup)
    }

    public func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {
        // Host app should handle this via delegate
    }
}

// MARK: - DockSplitViewControllerDelegate

extension DockWindow: DockSplitViewControllerDelegate {
    public func splitViewController(_ controller: DockSplitViewController, didUpdateProportions proportions: [CGFloat]) {
        // During reconciliation, the reconciler manages the model
        // Don't sync from view hierarchy - it may not match the target layout yet
        if suppressAutoClose {
            return
        }
        updateRootNodeFromController()
    }

    public func splitViewController(_ controller: DockSplitViewController, childDidBecomeEmpty index: Int) {
        // During reconciliation, the reconciler manages window lifecycle
        // Don't rebuild based on stale model state
        if suppressAutoClose {
            return
        }

        updateRootNodeFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            cleanupEmptyNodes(&rootNode)
        }
        rebuildLayout()
    }
}

// MARK: - Legacy Compatibility

/// Keep the old tabGroupController property for backward compatibility
public extension DockWindow {
    @available(*, deprecated, message: "Use rootNode instead - windows can now have splits")
    var tabGroupController: DockTabGroupViewController {
        if let tabGroupVC = rootViewController as? DockTabGroupViewController {
            return tabGroupVC
        }
        // Fallback: find first tab group
        if let firstTabGroup = findFirstTabGroupController(in: rootViewController) {
            return firstTabGroup
        }
        // Last resort: create empty tab group
        return DockTabGroupViewController(tabGroupNode: TabGroupNode())
    }
}

// MARK: - DockWindowController (unchanged)

public class DockWindowController: NSWindowController {
    public var dockWindow: DockWindow? {
        window as? DockWindow
    }

    public convenience init(dockWindow: DockWindow) {
        self.init(window: dockWindow)
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
    }
}
