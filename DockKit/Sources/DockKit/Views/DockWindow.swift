import AppKit

/// Delegate for dock window events
public protocol DockWindowDelegate: AnyObject {
    func dockWindow(_ window: DockWindow, didClose: Void)
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int)
    func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint)
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController)

    // MARK: - Proposals

    /// User clicked close on a tab. Route to layout manager for policy decision.
    func dockWindow(_ window: DockWindow, didRequestClosePanel panelId: UUID, in tabGroup: DockTabGroupViewController)

    /// User clicked a "+" button in a tab group. Route to layout manager for policy decision.
    /// `actionId` identifies which `PanelAddAction` was tapped, or nil for the
    /// default single-button case (no addActions configured on the group).
    func dockWindow(_ window: DockWindow, didRequestNewPanelIn tabGroup: DockTabGroupViewController, actionId: String?)

    /// During drag: can this panel be dropped in this group/zone?
    func dockWindow(_ window: DockWindow, canAcceptPanel panelId: UUID, in tabGroup: DockTabGroupViewController, at zone: DockDropZone) -> Bool

    /// The window's layout changed in place: tab selection or order, a divider,
    /// its frame, full screen or screen, or a local close/collapse.
    /// `window.rootPanel` and `window.layoutFrame` already reflect the change.
    /// Not called while the reconciler applies a layout.
    func dockWindowDidChangeLayout(_ window: DockWindow)

    /// The person asked to close the window (its close button, Cmd-W —
    /// `performClose`). Return false to keep it open.
    func dockWindowShouldClose(_ window: DockWindow) -> Bool
}

/// Default implementations
public extension DockWindowDelegate {
    func dockWindow(_ window: DockWindow, didClose: Void) {}
    func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {}
    func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint) {}
    func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {}
    func dockWindow(_ window: DockWindow, didRequestClosePanel panelId: UUID, in tabGroup: DockTabGroupViewController) {}
    func dockWindow(_ window: DockWindow, didRequestNewPanelIn tabGroup: DockTabGroupViewController, actionId: String?) {}
    func dockWindow(_ window: DockWindow, canAcceptPanel panelId: UUID, in tabGroup: DockTabGroupViewController, at zone: DockDropZone) -> Bool { true }
    func dockWindowDidChangeLayout(_ window: DockWindow) {}
    func dockWindowShouldClose(_ window: DockWindow) -> Bool { true }
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

    /// Panel provider for resolving content panel IDs to DockablePanel instances.
    /// Pass it to `init` so the first build resolves panels; setting it later
    /// rebuilds the view hierarchy with it.
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        didSet {
            if rootViewController != nil { rebuildLayout() }
        }
    }

    /// Flag to suppress auto-close during reconciliation
    /// When true, the window won't auto-close when a tab group becomes empty
    /// This prevents premature closure during layout rebuilds
    internal var suppressAutoClose: Bool = false

    /// The windowed frame to come back to while the window is full screen
    private var frameBeforeFullScreen: NSRect?

    /// Stands in for AppKit's full-screen state in tests: AppKit sets
    /// `.fullScreen` only during a real transition, which takes over a Space.
    internal var fullScreenStateForTesting: Bool?

    /// Whether the window is full screen, as the layout records it.
    public var isFullScreenForLayout: Bool {
        fullScreenStateForTesting ?? styleMask.contains(.fullScreen)
    }

    /// True while `rebuildLayout` swaps the controller tree: the outgoing
    /// controllers still report (a split's proportions as it is torn down),
    /// and syncing from them would put the old tree back into `rootPanel`.
    private var isRebuilding = false

    /// Controller and window events are the reconciler's or the rebuild's own
    /// doing, not the person's: don't sync the model from them or report them.
    private var ignoresViewEvents: Bool { suppressAutoClose || isRebuilding }

    // MARK: - Initialization

    /// Create a window with a root panel and frame.
    /// `frame` is the window's frame (not its content rect) — the same rect
    /// `layoutFrame` and `DockLayoutManager.getLayout()` report — and the
    /// window gets exactly that frame.
    public init(
        id: UUID = UUID(),
        rootPanel: Panel,
        frame: NSRect,
        layoutManager: DockLayoutManager? = nil,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.windowId = id
        self.rootPanel = rootPanel
        self.layoutManager = layoutManager
        self.panelProvider = panelProvider

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        // super.init took `frame` as the content rect; make it the frame
        // before building, so the tree first lays out at its real size.
        setFrame(frame, display: false)
        rebuildLayout()
        observeWindowChanges()
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
        self.init(id: tabGroup.id, rootPanel: tabGroup, frame: frame, layoutManager: layoutManager)
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

    /// Report moves, resizes, full screen and screen changes as layout changes.
    private func observeWindowChanges() {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(windowLayoutDidChange(_:)), name: name, object: self)
        }
        center.addObserver(self, selector: #selector(windowWillEnterFullScreen(_:)),
                           name: NSWindow.willEnterFullScreenNotification, object: self)
        center.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)),
                           name: NSWindow.didExitFullScreenNotification, object: self)
    }

    @objc private func windowLayoutDidChange(_ notification: Notification) {
        noteLayoutChange()
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = frame
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = nil
        noteLayoutChange()
    }

    /// Tell the delegate the layout changed in place. Skipped while the
    /// reconciler applies a layout (`updateLayout` reports that once) and
    /// while a rebuild swaps controllers (its caller reports).
    private func noteLayoutChange() {
        guard !ignoresViewEvents else { return }
        dockDelegate?.dockWindowDidChangeLayout(self)
    }

    // MARK: - Layout Building

    /// Rebuild the view hierarchy from rootPanel
    public func rebuildLayout() {
        // Build new root view controller
        let newRootVC = createViewController(for: rootPanel)

        // Installing a content view controller resizes the window to the
        // controller's view. A rebuild must not move or resize the window, so
        // give the view the content area's size first. That also lets the new
        // tree lay out at its real size: a split laid out in a shrunken window
        // would have its proportions distorted by the panes' minimum sizes.
        let keptFrame = frame

        isRebuilding = true
        defer { isRebuilding = false }

        if let contentSize = contentView?.bounds.size, contentSize.width > 0, contentSize.height > 0 {
            newRootVC.view.setFrameSize(contentSize)
        }

        // Let AppKit handle removing the old content view controller
        // DO NOT manually remove - that causes double-release crashes
        rootViewController = newRootVC
        contentViewController = newRootVC

        if frame != keptFrame && !isFullScreenForLayout {
            setFrame(keptFrame, display: true)
        }

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
            tabGroupVC.panelProvider = panelProvider
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

    /// The frame a layout records for this window: its frame, or while it is
    /// full screen, the windowed frame it returns to.
    public var layoutFrame: NSRect {
        if isFullScreenForLayout, let windowed = frameBeforeFullScreen {
            return windowed
        }
        return frame
    }

    /// A persistent identifier for the display the window is on: the
    /// display's UUID, which survives reboots and reconnects (unlike its
    /// `CGDirectDisplayID` alone). Nil when the window is on no screen.
    public var screenIdentifier: String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayId = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayId)?.takeRetainedValue() else {
            return String(displayId)
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Add a panel to a specific tab group (or first available)
    public func addPanel(_ panel: any DockablePanel, to groupId: UUID? = nil, activate: Bool = true) {
        if let groupId = groupId,
           let tabGroup = findTabGroupController(withId: groupId, in: rootViewController) {
            tabGroup.addTab(from: panel, activate: activate)
            updateRootPanelFromController()
            noteLayoutChange()
        } else if let firstTabGroup = findFirstTabGroupController(in: rootViewController) {
            firstTabGroup.addTab(from: panel, activate: activate)
            updateRootPanelFromController()
            noteLayoutChange()
        }
    }

    /// Remove a panel from this window
    @discardableResult
    public func removePanel(_ panelId: UUID) -> Bool {
        var modified = false
        var newRoot = rootPanel.removingChild(panelId, modified: &modified)
        if modified {
            if layoutManager?.reclaimEmptySpace ?? true {
                newRoot = newRoot.cleanedUp()
            }
            rootPanel = newRoot.keepingRootIdentity(of: rootPanel)
            rebuildLayout()
            noteLayoutChange()
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

    /// The close button and Cmd-W: the dock delegate decides first, then
    /// AppKit's usual `windowShouldClose` path (an app-set NSWindow delegate).
    public override func performClose(_ sender: Any?) {
        if let dockDelegate = dockDelegate, !dockDelegate.dockWindowShouldClose(self) {
            return
        }
        super.performClose(sender)
    }

    public override func close() {
        // Debug: trace where close is being called from
        if layoutManager?.verboseLogging == true {
            print("[WINDOW] close() called on window \(windowId.uuidString.prefix(8))")
            Thread.callStackSymbols.prefix(10).forEach { print("  \($0)") }
        }

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
        guard let rootVC = rootViewController else { return }
        var synced = extractPanel(from: rootVC)
        // A bare content root is shown in a wrapper tab group of its own;
        // while the wrapper holds just that panel, the root stays the panel.
        if rootPanel.isContent, let children = synced.group?.children,
           children.count == 1, children[0].id == rootPanel.id {
            synced = children[0]
        }
        rootPanel = synced.keepingRootIdentity(of: rootPanel)
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
        } else if let stageHostVC = controller as? DockStageHostViewController {
            return stageHostVC.hostView.stageHostPanel
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
        if ignoresViewEvents {
            return
        }

        updateRootPanelFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            rootPanel = rootPanel.cleanedUp().keepingRootIdentity(of: rootPanel)
        }

        if isEmpty {
            close()
        } else {
            rebuildLayout()
            noteLayoutChange()
        }
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID) {
        dockDelegate?.dockWindow(self, wantsToSplit: direction, withPanelId: panelId, in: tabGroup)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestClosePanel panelId: UUID, at index: Int) {
        dockDelegate?.dockWindow(self, didRequestClosePanel: panelId, in: tabGroup)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestNewPanelIn groupId: UUID, actionId: String?) {
        dockDelegate?.dockWindow(self, didRequestNewPanelIn: tabGroup, actionId: actionId)
    }

    public func tabGroup(_ tabGroup: DockTabGroupViewController, canAcceptPanel panelId: UUID, at zone: DockDropZone) -> Bool {
        dockDelegate?.dockWindow(self, canAcceptPanel: panelId, in: tabGroup, at: zone) ?? true
    }

    public func tabGroupDidReorderTab(_ tabGroup: DockTabGroupViewController) {
        // The tab group already reordered its own model; mirror it.
        if ignoresViewEvents { return }
        updateRootPanelFromController()
        noteLayoutChange()
    }

    public func tabGroupDidChangeActiveTab(_ tabGroup: DockTabGroupViewController) {
        // Click or swipe: the tab group already moved its activeIndex.
        if ignoresViewEvents { return }
        updateRootPanelFromController()
        updateTitle()
        noteLayoutChange()
    }
}

// MARK: - DockSplitViewControllerDelegate

extension DockWindow: DockSplitViewControllerDelegate {
    public func splitViewController(_ controller: DockSplitViewController, didUpdateProportions proportions: [CGFloat]) {
        // During reconciliation, the reconciler manages the model
        // Don't sync from view hierarchy - it may not match the target layout yet
        if ignoresViewEvents {
            return
        }
        updateRootPanelFromController()
        noteLayoutChange()
    }

    public func splitViewController(_ controller: DockSplitViewController, childDidBecomeEmpty index: Int) {
        // During reconciliation, the reconciler manages window lifecycle
        // Don't rebuild based on stale model state
        if ignoresViewEvents {
            return
        }

        updateRootPanelFromController()
        if layoutManager?.reclaimEmptySpace ?? true {
            rootPanel = rootPanel.cleanedUp().keepingRootIdentity(of: rootPanel)
        }
        rebuildLayout()
        noteLayoutChange()
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
