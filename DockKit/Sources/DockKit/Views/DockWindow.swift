import AppKit

/// Delegate for dock window events
public protocol DockWindowDelegate: AnyObject {
    func dockWindow(_ window: DockWindow, didClose: Void)
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)
    func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint)
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController)
}

/// Default implementations
public extension DockWindowDelegate {
    func dockWindow(_ window: DockWindow, didClose: Void) {}
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint) {}
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {}
}

/// A dock window that can contain full layout trees (splits + tabs)
/// All windows are equal - there is no "main" window concept
public class DockWindow: NSWindow {

    // MARK: - Properties

    /// Window ID for tracking
    public let windowId: UUID

    /// The root panel (can be a split group, tab group, stage host, or leaf content)
    /// Internal setter allows reconciler to update model before rebuilding
    public internal(set) var rootPanel: Panel

    /// Root view controller (either split or tab group)
    /// Note: Exposed as internal for backward compatibility with DockContainerViewController
    internal var rootViewController: NSViewController?

    /// Reference to the layout manager
    public weak var layoutManager: DockLayoutManager?

    /// Delegate for window events
    public weak var dockDelegate: DockWindowDelegate?

    /// Panel provider for resolving content panel IDs to DockablePanel instances
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Flag to suppress auto-close during reconciliation
    /// When true, the window won't auto-close when a tab group becomes empty
    /// This prevents premature closure during layout rebuilds
    internal var suppressAutoClose: Bool = false

    // MARK: - Initialization

    /// Create a window with a root panel and frame
    public init(id: UUID = UUID(), rootPanel: Panel, frame: NSRect, layoutManager: DockLayoutManager? = nil) {
        self.windowId = id
        self.rootPanel = rootPanel
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

    /// Convenience initializer with a single panel
    public convenience init(with panel: any DockablePanel, at screenPoint: NSPoint, layoutManager: DockLayoutManager? = nil) {
        let contentPanel = Panel(
            id: panel.panelId,
            title: panel.panelTitle,
            content: .content
        )
        let tabGroup = Panel(
            content: .group(PanelGroup(
                children: [contentPanel],
                activeIndex: 0,
                style: .tabs
            ))
        )
        let size = NSSize(width: 600, height: 400)
        let frame = NSRect(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        self.init(id: UUID(), rootPanel: tabGroup, frame: frame, layoutManager: layoutManager)
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

    /// Rebuild the view hierarchy from rootPanel
    public func rebuildLayout() {
        // Build new root view controller
        let newRootVC = createViewController(for: rootPanel)

        // Let AppKit handle removing the old content view controller
        // DO NOT manually remove - that causes double-release crashes
        contentViewController = newRootVC
        rootViewController = newRootVC

        updateTitle()
    }

    /// Create view controller for a panel
    private func createViewController(for panel: Panel) -> NSViewController {
        switch panel.content {
        case .group(let group):
            switch group.style {
            case .split:
                let splitVC = DockSplitViewController(panel: panel)
                splitVC.dockDelegate = self
                splitVC.tabGroupDelegate = self
                splitVC.panelProvider = panelProvider
                return splitVC

            case .tabs, .thumbnails:
                let tabGroupVC = DockTabGroupViewController(panel: panel)
                tabGroupVC.delegate = self
                tabGroupVC.panelProvider = panelProvider
                return tabGroupVC

            case .stages:
                let hostVC = DockStageHostViewController(
                    panel: panel,
                    panelProvider: panelProvider
                )
                return hostVC
            }

        case .content:
            // Leaf content panel — wrap in a tab group with a single child
            let wrapper = Panel(
                content: .group(PanelGroup(
                    children: [panel],
                    activeIndex: 0,
                    style: .tabs
                ))
            )
            let tabGroupVC = DockTabGroupViewController(panel: wrapper)
            tabGroupVC.delegate = self
            return tabGroupVC
        }
    }

    // MARK: - Public API

    /// Check if window contains a specific panel
    public func containsPanel(_ panelId: UUID) -> Bool {
        return rootPanel.findPanel(byId: panelId) != nil
    }

    /// Check if window is empty (no panels)
    public var isEmpty: Bool {
        return rootPanel.isEmpty
    }

    /// Add a panel to a specific tab group (or first available)
    public func addPanel(_ panel: any DockablePanel, to groupId: UUID? = nil, activate: Bool = true) {
        if let groupId = groupId,
           let tabGroup = findTabGroupController(withId: groupId, in: rootViewController) {
            tabGroup.addTab(from: panel, activate: activate)
            updateRootPanelFromController()
        } else if let firstTabGroup = findFirstTabGroupController(in: rootViewController) {
            firstTabGroup.addTab(from: panel, activate: activate)
            updateRootPanelFromController()
        }
    }

    /// Remove a panel from this window
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        var modified = false
        rootPanel = rootPanel.removingChild(panelId, modified: &modified)
        if modified {
            if layoutManager?.reclaimEmptySpace ?? true {
                rootPanel = rootPanel.cleanedUp()
            }
            rebuildLayout()
            return true
        }
        return false
    }

    /// Update window title from active tab
    public func updateTitle() {
        if let activeTitle = findFirstActiveTitle(in: rootPanel) {
            title = activeTitle
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

    /// Find the title of the first active content panel
    private func findFirstActiveTitle(in panel: Panel) -> String? {
        switch panel.content {
        case .content:
            return panel.title
        case .group(let group):
            switch group.style {
            case .tabs, .thumbnails, .stages:
                // Use the active child
                if let activeChild = group.activeChild {
                    return findFirstActiveTitle(in: activeChild)
                }
                return nil
            case .split:
                // Return the first active title from any child
                for child in group.children {
                    if let title = findFirstActiveTitle(in: child) {
                        return title
                    }
                }
                return nil
            }
        }
    }

    private func findTabGroupController(withId id: UUID, in controller: NSViewController?) -> DockTabGroupViewController? {
        if let tabGroup = controller as? DockTabGroupViewController,
           tabGroup.panel.id == id {
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

    /// Sync rootPanel model from the current view controller hierarchy
    /// Called after reconciliation to ensure getLayout() returns accurate state
    public func syncPanelFromViewController() {
        if let rootVC = rootViewController {
            rootPanel = extractPanel(from: rootVC)
        }
    }

    private func updateRootPanelFromController() {
        syncPanelFromViewController()
    }

    private func extractPanel(from controller: NSViewController) -> Panel {
        if let tabGroupVC = controller as? DockTabGroupViewController {
            return tabGroupVC.panel
        } else if let splitVC = controller as? DockSplitViewController {
            let children = splitVC.splitViewItems.map { extractPanel(from: $0.viewController) }
            var panel = splitVC.panel
            if case .group(var group) = panel.content {
                group.children = children
                group.proportions = splitVC.getProportions()
                panel.content = .group(group)
            }
            return panel
        }
        // Fallback: empty tab group
        return Panel(content: .group(PanelGroup(style: .tabs)))
    }
}

// MARK: - DockTabGroupViewControllerDelegate

extension DockWindow: DockTabGroupViewControllerDelegate {
    public func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachPanel panelId: UUID, at screenPoint: NSPoint) {
        dockDelegate?.dockWindow(self, wantsToDetachPanelId: panelId, at: screenPoint)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int) {
        dockDelegate?.dockWindow(self, didReceiveTab: tabInfo, in: tabGroup, at: index)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastPanel: Bool) {
        // During reconciliation, the reconciler manages window lifecycle
        // Don't auto-close based on stale model state
        if suppressAutoClose {
            return
        }

        updateRootPanelFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            rootPanel = rootPanel.cleanedUp()
        }

        if isEmpty {
            close()
        } else {
            rebuildLayout()
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID) {
        dockDelegate?.dockWindow(self, wantsToSplit: direction, withPanelId: panelId, in: tabGroup)
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
        updateRootPanelFromController()
    }

    public func splitViewController(_ controller: DockSplitViewController, childDidBecomeEmpty index: Int) {
        // During reconciliation, the reconciler manages window lifecycle
        // Don't rebuild based on stale model state
        if suppressAutoClose {
            return
        }

        updateRootPanelFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            rootPanel = rootPanel.cleanedUp()
        }
        rebuildLayout()
    }
}

// MARK: - Legacy Compatibility

/// Keep the old tabGroupController property for backward compatibility
public extension DockWindow {
    @available(*, deprecated, message: "Use rootPanel instead - windows can now have splits")
    var tabGroupController: DockTabGroupViewController {
        if let tabGroupVC = rootViewController as? DockTabGroupViewController {
            return tabGroupVC
        }
        // Fallback: find first tab group
        if let firstTabGroup = findFirstTabGroupController(in: rootViewController) {
            return firstTabGroup
        }
        // Last resort: create empty tab group
        return DockTabGroupViewController(panel: Panel(content: .group(PanelGroup(style: .tabs))))
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
