import AppKit

/// Central coordinator for all dock windows and panels
/// This is NOT a view controller - it manages windows but is not tied to any specific window
public class DockLayoutManager: DockWindowDelegate {

    // MARK: - Public Properties

    /// All managed windows (all windows are equal - no "main" window concept)
    public private(set) var windows: [DockWindow] = []

    /// Host app provides panel lookup by ID
    /// DockKit is panel-agnostic - it only knows panel IDs, not panel types
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Delegate for layout events
    public weak var delegate: DockLayoutManagerDelegate?

    /// Enable verbose JSON logging for debugging
    public var verboseLogging: Bool = false

    /// When true (default), empty splits are automatically collapsed when panels close.
    /// When false, empty space remains and the user must manually rearrange panels.
    public var reclaimEmptySpace: Bool = true

    /// True while `updateLayout` reconciles: window events and closes during
    /// that time are part of the update, which reports itself once.
    private var isApplyingLayout = false

    /// A change made in the windows is waiting for its coalesced
    /// `layoutManagerDidChangeLayout` (see `setNeedsLayoutNotification`).
    private var layoutChangePending = false

    /// The reconciler for applying layout changes
    private lazy var reconciler: DockLayoutReconciler = {
        let r = DockLayoutReconciler()
        r.panelProvider = { [weak self] id in self?.panelProvider?(id) }
        r.panelWillDetach = { panel in panel.panelWillDetach() }
        r.panelDidDock = { panel in panel.panelDidDock(at: .center) }
        return r
    }()

    // MARK: - Initialization

    public init() {}

    // MARK: - Core API (JSON Source of Truth)

    /// Get current layout as JSON-serializable struct
    /// Contains ALL windows and their layout trees, with each window's frame
    /// (its windowed frame while full screen), full-screen state and screen.
    /// Reflects every change the person makes in the windows as soon as it
    /// happens; `updateLayout(getLayout())` is a no-op.
    public func getLayout() -> DockLayout {
        let rootPanels = windows.map { window -> Panel in
            var panel = window.rootPanel
            panel.isTopLevelWindow = true
            panel.frame = window.layoutFrame
            panel.isFullScreen = window.isFullScreenForLayout
            panel.screenId = window.screenIdentifier
            return panel
        }
        return DockLayout(panels: rootPanels)
    }

    /// Compute reconciliation commands between current and target layout
    /// Use this to determine what panels need to be created/removed before calling updateLayout
    ///
    /// Typical usage:
    /// ```swift
    /// let commands = layoutManager.computeCommands(to: newLayout)
    ///
    /// // 1. Create new panels
    /// for cmd in commands.panelsToCreate {
    ///     let panel = factory.create(id: cmd.tabId, cargo: cmd.cargo)
    ///     panelRegistry[cmd.tabId] = panel
    /// }
    ///
    /// // 2. Remove old panels
    /// for tabId in commands.panelsToRemove {
    ///     panelRegistry[tabId]?.cleanup()
    ///     panelRegistry.removeValue(forKey: tabId)
    /// }
    ///
    /// // 3. Apply layout
    /// layoutManager.updateLayout(newLayout)
    /// ```
    public func computeCommands(to targetLayout: DockLayout) -> ReconciliationCommands {
        let currentLayout = getLayout()
        return DockLayoutDiff.extractCommands(from: currentLayout, to: targetLayout)
    }

    /// Apply layout changes (computes delta, reconciles view hierarchy)
    /// Host app must ensure all referenced panel IDs exist in its panelProvider
    public func updateLayout(_ layout: DockLayout) {
        let currentLayout = getLayout()
        let diff = DockLayoutDiff.compute(from: currentLayout, to: layout)

        // If no changes, nothing to do
        if diff.isEmpty {
            if verboseLogging {
                print("[LAYOUT_MANAGER] No changes detected, skipping update")
            }
            return
        }

        DockDiagnostics.counters.bump("diff")

        if verboseLogging {
            print("[LAYOUT_MANAGER] Applying layout update:")
            print(diff.debugDescription)
        }

        // Verbose: Log full JSON before/after
        if verboseLogging {
            print("[LAYOUT_MANAGER] === BEFORE (current layout) ===")
            printLayoutJSON(currentLayout)
            print("[LAYOUT_MANAGER] === AFTER (target layout) ===")
            printLayoutJSON(layout)
        }

        // Use reconciler for incremental updates
        reconciler.verboseLogging = verboseLogging
        let hadWindows = !windows.isEmpty
        // Restored, not cleared, at the end: an updateLayout nested in this
        // one (from a panel callback) must not end this one's quiet period
        let wasApplyingLayout = isApplyingLayout
        isApplyingLayout = true
        windows = reconciler.reconcileWindows(
            currentWindows: windows,
            targetLayout: layout,
            diff: diff,
            windowFactory: { [weak self] windowPanel in
                self?.createWindowFromPanel(windowPanel) ?? DockWindow(
                    id: windowPanel.id,
                    rootPanel: Panel(content: .group(PanelGroup(style: .tabs))),
                    frame: windowPanel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
                    layoutManager: nil
                )
            }
        )

        // NOTE: We do NOT sync from view controllers here!
        // The target layout we just applied IS correct.
        // Syncing would read proportions from NSSplitView before it has laid out,
        // getting garbage values like [0, 0] which corrupt the model.
        // User-initiated changes (divider drags, tab reorders) are captured via delegate callbacks.

        if verboseLogging {
            print("[LAYOUT_MANAGER] === RESULT (applied layout) ===")
            printLayoutJSON(layout)
        }

        // Notify delegate that layout changed (this covers any change the
        // windows reported meanwhile)
        isApplyingLayout = wasApplyingLayout
        layoutChangePending = false
        delegate?.layoutManagerDidChangeLayout(self)
        if hadWindows && windows.isEmpty {
            delegate?.layoutManagerDidCloseAllWindows(self)
        }
    }

    /// Report a change made in the windows (tab selection or order, a divider,
    /// a move, resize, full screen, close, tear-off) with one
    /// `layoutManagerDidChangeLayout` at the end of the current run-loop turn,
    /// however many changes the turn makes. `getLayout()` already reflects
    /// each change when it happens; only the call is coalesced.
    private func setNeedsLayoutNotification() {
        guard !isApplyingLayout, !layoutChangePending else { return }
        layoutChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.layoutChangePending else { return }
            self.layoutChangePending = false
            self.delegate?.layoutManagerDidChangeLayout(self)
        }
    }

    /// Print layout as pretty-printed JSON for debugging
    private func printLayoutJSON(_ layout: DockLayout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(layout),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("[LAYOUT_MANAGER] Failed to encode layout as JSON")
        }
    }

    /// Create a window from a Panel (used by reconciler)
    private func createWindowFromPanel(_ panel: Panel) -> DockWindow {
        let window = makeWindow(
            rootPanel: panel,
            frame: panel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        window.makeKeyAndOrderFront(nil)

        // Full screen after the window is on screen, from its windowed frame
        if panel.isFullScreen == true && !window.isFullScreenForLayout {
            enterFullScreenInTurn(window)
        }
        return window
    }

    // MARK: - Full Screen at Restore

    /// Restored windows waiting to enter full screen. One at a time: AppKit
    /// ignores a toggle while another window is mid-transition.
    private var fullScreenQueue: [DockWindow] = []

    /// The window entering full screen now, and the observer waiting for it.
    private var fullScreenInFlight: (window: DockWindow, observer: NSObjectProtocol)?

    /// How a window is sent to full screen (tests substitute a recorder).
    internal var toggleFullScreen: (DockWindow) -> Void = { $0.toggleFullScreen(nil) }

    /// How long to wait for a window's didEnterFullScreen before moving on:
    /// a toggle AppKit refused, or a failed transition, never reports one.
    internal var fullScreenTimeout: TimeInterval = 3

    private func enterFullScreenInTurn(_ window: DockWindow) {
        fullScreenQueue.append(window)
        startNextFullScreen()
    }

    private func startNextFullScreen() {
        guard fullScreenInFlight == nil else { return }
        while !fullScreenQueue.isEmpty {
            let window = fullScreenQueue.removeFirst()
            guard window.isVisible, !window.isFullScreenForLayout else { continue }

            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: nil
            ) { [weak self, weak window] _ in
                guard let self = self, let window = window else { return }
                self.finishFullScreen(window)
            }
            fullScreenInFlight = (window, observer)
            toggleFullScreen(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenTimeout) { [weak self, weak window] in
                guard let self = self, let window = window else { return }
                self.finishFullScreen(window)
            }
            return
        }
    }

    /// `window` arrived in full screen, closed, or ran out of time: next.
    private func finishFullScreen(_ window: DockWindow) {
        guard let inFlight = fullScreenInFlight, inFlight.window === window else { return }
        NotificationCenter.default.removeObserver(inFlight.observer)
        fullScreenInFlight = nil
        startNextFullScreen()
    }

    /// Every DockWindow the manager owns is made here: its id is its root
    /// panel's id (the reconciler, the diff and the move/split defaults all
    /// find windows by root panel id), and its controllers are built with the
    /// panel provider from the start.
    private func makeWindow(rootPanel: Panel, frame: NSRect) -> DockWindow {
        let window = DockWindow(
            id: rootPanel.id,
            rootPanel: rootPanel,
            frame: frame,
            layoutManager: self,
            panelProvider: { [weak self] id in self?.panelProvider?(id) }
        )
        window.dockDelegate = self
        return window
    }

    /// Verify layout matches actual macOS view state (for testing)
    public func verifyLayout(_ layout: DockLayout) -> [LayoutMismatch] {
        return DockLayoutVerifier.verify(layout: layout, against: windows)
    }

    /// Verify current layout matches actual macOS view state (for testing)
    public func verifyCurrentLayout() -> [LayoutMismatch] {
        return DockLayoutVerifier.verify(manager: self)
    }

    // MARK: - Window Management

    /// Create a new window with the given layout.
    /// The window's id is its root panel's id, and `frame` is the window's
    /// frame. A bare content root is put in a tab group of its own first (the
    /// window's root, and so its id), so tabs dropped into the window land in
    /// a group the layout knows.
    @discardableResult
    public func createWindow(
        rootPanel: Panel = Panel(content: .group(PanelGroup(style: .tabs))),
        frame: NSRect = NSRect(x: 100, y: 100, width: 800, height: 600)
    ) -> DockWindow {
        let root = rootPanel.isContent
            ? Panel(content: .group(PanelGroup(children: [rootPanel], activeIndex: 0, style: .tabs)))
            : rootPanel
        let window = makeWindow(rootPanel: root, frame: frame)
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        setNeedsLayoutNotification()
        return window
    }

    /// Close a window by ID
    public func closeWindow(_ windowId: UUID) {
        guard let window = windows.first(where: { $0.windowId == windowId }) else { return }
        // DockWindow.close() reports back through windowDidClose(_:)
        window.close()
        if windows.contains(where: { $0 === window }) {
            windowDidClose(window)
        }
    }

    /// Called by DockWindow when it closes (to remove itself from our array)
    /// This prevents dangling references to deallocated windows
    internal func windowDidClose(_ window: DockWindow) {
        finishFullScreen(window)
        if let index = windows.firstIndex(where: { $0.windowId == window.windowId }) {
            windows.remove(at: index)

            // During updateLayout the reconciler closes windows on its way to
            // the target layout; updateLayout reports the outcome itself.
            guard !isApplyingLayout else { return }
            delegate?.layoutManager(self, didCloseWindow: window.windowId,
                                    containing: window.rootPanel.allContentIds())
            setNeedsLayoutNotification()

            // Notify delegate if all windows are closed
            if windows.isEmpty {
                delegate?.layoutManagerDidCloseAllWindows(self)
            }
        }
    }

    /// Called by DockStageHostWindow when it closes
    /// This is a stub for stage host windows - they are managed separately
    internal func windowDidClose(_ window: DockStageHostWindow) {
        // Stage host windows are not tracked in the windows array
        // This method exists to satisfy the window's close callback
        // Full stage host support can be added later
    }

    /// Find window containing a specific panel
    public func findWindow(containingPanel panelId: UUID) -> DockWindow? {
        for window in windows {
            if window.containsPanel(panelId) {
                return window
            }
        }
        return nil
    }

    // MARK: - Panel Operations

    /// Add a panel to the first available tab group
    public func addPanel(_ panel: any DockablePanel, to windowId: UUID? = nil, groupId: UUID? = nil, activate: Bool = true) {
        // Find target window
        let targetWindow: DockWindow?
        if let windowId = windowId {
            targetWindow = windows.first { $0.windowId == windowId }
        } else {
            targetWindow = windows.first
        }

        guard let window = targetWindow else {
            // No windows exist - create one with this panel as content
            let contentPanel = Panel.contentPanel(
                id: panel.panelId,
                title: panel.panelTitle
            )
            let rootPanel = Panel(
                content: .group(PanelGroup(
                    children: [contentPanel],
                    activeIndex: 0,
                    style: .tabs
                ))
            )
            createWindow(rootPanel: rootPanel)
            return
        }

        window.addPanel(panel, to: groupId, activate: activate)
    }

    /// Rename a panel's tab in place, wherever it is (see DockWindow.setTitle).
    @discardableResult
    public func setTitle(_ title: String, forPanel panelId: UUID) -> Bool {
        findWindow(containingPanel: panelId)?.setTitle(title, forPanel: panelId) ?? false
    }

    /// Remove a panel from wherever it is
    public func removePanel(_ panelId: UUID) {
        for window in windows {
            if window.removePanel(panelId) {
                // Check if window is now empty
                if window.isEmpty {
                    closeWindow(window.windowId)
                }
                return
            }
        }
    }

    /// Detach a panel into a window of its own at `screenPoint` (the tear-off).
    ///
    /// The panel leaves wherever it is docked — keeping its title and cargo —
    /// and opens in a new window with a tab group, the source window's size,
    /// its tab strip under the pointer. A panel that is alone in its window
    /// moves that window there instead. A panel docked nowhere gets a new
    /// window too.
    @discardableResult
    public func detachPanel(_ panel: any DockablePanel, at screenPoint: NSPoint) -> DockWindow {
        panel.panelWillDetach()
        let window = detach(panelId: panel.panelId, title: panel.panelTitle, at: screenPoint)
        panel.panelDidDock(at: .floating)
        return window
    }

    /// The tear-off as a layout change (see `detachPanel(_:at:)`).
    @discardableResult
    private func detach(panelId: UUID, title: String?, at screenPoint: NSPoint) -> DockWindow {
        let layout = getLayout()
        let source = layout.findChild(panelId)
        let sourceWindow = source.flatMap { found in windows.first { $0.windowId == found.rootPanelId } }
        let size = sourceWindow?.layoutFrame.size ?? NSSize(width: 600, height: 400)
        let frame = NSRect(
            x: screenPoint.x - min(size.width / 2, 100),
            y: screenPoint.y - size.height + 20,
            width: size.width,
            height: size.height
        )

        // Alone in its window: the window is what was dragged out.
        if let window = sourceWindow, window.rootPanel.allContentIds() == [panelId],
           !window.isFullScreenForLayout {
            window.setFrame(frame, display: true)
            return window
        }

        let child = source?.panel ?? Panel.contentPanel(id: panelId, title: title ?? "Untitled")
        let newRoot = Panel(
            content: .group(PanelGroup(
                children: [child],
                activeIndex: 0,
                style: .tabs
            )),
            isTopLevelWindow: true,
            frame: frame,
            isFullScreen: false
        )
        updateLayout(layout.removingChild(panelId).addingPanel(newRoot))

        if let window = windows.first(where: { $0.windowId == newRoot.id }) {
            return window
        }
        // The reconciler always creates it; keep the old contract regardless
        let window = makeWindow(rootPanel: newRoot, frame: frame)
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        setNeedsLayoutNotification()
        return window
    }

    // MARK: - Private Methods

    /// Rebuild all windows from a layout (full rebuild, not incremental)
    private func rebuildFromLayout(_ layout: DockLayout) {
        // Close existing windows
        for window in windows {
            window.close()
        }
        windows.removeAll()

        // Create windows from layout
        for panel in layout.panels {
            let window = makeWindow(
                rootPanel: panel,
                frame: panel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            )
            windows.append(window)
            window.makeKeyAndOrderFront(nil)

            // Handle full-screen state
            if panel.isFullScreen == true && !window.isFullScreenForLayout {
                enterFullScreenInTurn(window)
            }
        }
    }

    // MARK: - Layout Persistence

    /// Save the current layout to UserDefaults
    public func saveLayout() {
        let layout = getLayout()
        layout.save()
    }

    /// Load and apply a saved layout
    public func loadSavedLayout() {
        if let layout = DockLayout.load() {
            updateLayout(layout)
        }
    }
}

// MARK: - DockLayoutManagerDelegate

/// Delegate for layout manager events.
///
/// All `didRequest*` methods are **proposals**: DockKit detects a user gesture and asks the
/// delegate what to do. The delegate is responsible for applying (or rejecting) the change
/// via the reactive layout model. Default implementations apply the change directly, which
/// is suitable for demos and simple apps. In production, the delegate typically routes
/// through an external controller (e.g. a governor) that decides and sends back a new layout.
public protocol DockLayoutManagerDelegate: AnyObject {
    /// Called when all windows have been closed. Default: nothing (a
    /// menu-bar app keeps running with no windows).
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager)

    /// The person asked to close a window (its close button, Cmd-W).
    /// `panelIds` are the content panels in it. Return false to keep it open
    /// (for instance to close some of its panels instead). Default: true.
    func layoutManager(_ manager: DockLayoutManager,
                       shouldCloseWindow window: DockWindow,
                       containing panelIds: [UUID]) -> Bool

    /// A window closed outside `updateLayout` — by the person (close button,
    /// Cmd-W), by `closeWindow`, or because its last tab closed — taking the
    /// content panels `panelIds` (none when its last tab closed) out of the
    /// layout. Followed by `layoutManagerDidChangeLayout`. Default: nothing.
    func layoutManager(_ manager: DockLayoutManager,
                       didCloseWindow windowId: UUID,
                       containing panelIds: [UUID])

    /// The person tore a tab off (dragged it out of every window). The panel
    /// is still docked: call `manager.detachPanel(panel, at:)` to give it a
    /// window of its own (the default), or return to leave it where it is.
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)

    /// Called when the layout changed, for auto-save. Covers `updateLayout`
    /// (called synchronously, once) and every change the person makes in the
    /// windows: tab selection and order, moves between windows, tear-offs,
    /// splits, dividers, window moves and resizes, full screen, closes. Those
    /// are coalesced into one call per run-loop turn. `getLayout()` holds the
    /// result, frames included.
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager)

    // MARK: - Proposals (UI-initiated actions)

    /// User clicked the close button on a tab. The delegate should remove the panel
    /// from the layout model if appropriate, or ignore to prevent closure.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestClosePanel panelId: UUID,
                       in groupId: UUID, windowId: UUID)

    /// User clicked a "+" button in a tab group. The delegate should create a panel
    /// and add it to the layout model, or ignore to do nothing.
    /// `actionId` identifies which `PanelAddAction` was tapped (for groups that
    /// declare `addActions`), or nil for the default single-button case.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestNewPanelIn groupId: UUID,
                       actionId: String?,
                       windowId: UUID)

    /// User dropped a tab into a group. The delegate should apply the move
    /// to the layout model, or ignore to cancel the move.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestMovePanel panelId: UUID,
                       toGroup targetGroupId: UUID,
                       at index: Int, windowId: UUID)

    /// User dropped a tab on a split zone. The delegate should apply the split
    /// to the layout model, or ignore to cancel.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestSplit direction: DockSplitDirection,
                       withPanel panelId: UUID,
                       in groupId: UUID, windowId: UUID)

    /// Called during drag to check if a panel can be dropped in a target group/zone.
    /// Must be fast (called on every mouse move). Return false to hide the drop zone.
    func layoutManager(_ manager: DockLayoutManager,
                       canMovePanel panelId: UUID,
                       toGroup targetGroupId: UUID,
                       at zone: DockDropZone) -> Bool
}

/// Default implementations for optional delegate methods.
/// Proposals apply the change directly — suitable for demos and simple apps.
public extension DockLayoutManagerDelegate {
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager) {}
    func layoutManager(_ manager: DockLayoutManager, shouldCloseWindow window: DockWindow, containing panelIds: [UUID]) -> Bool {
        true
    }
    func layoutManager(_ manager: DockLayoutManager, didCloseWindow windowId: UUID, containing panelIds: [UUID]) {}
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        manager.detachPanel(panel, at: screenPoint)
    }
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager) {}

    func layoutManager(_ manager: DockLayoutManager, didRequestClosePanel panelId: UUID, in groupId: UUID, windowId: UUID) {
        manager.removePanel(panelId)
    }

    func layoutManager(_ manager: DockLayoutManager, didRequestNewPanelIn groupId: UUID, actionId: String?, windowId: UUID) {
        // No-op — host app must implement to create panels
    }

    func layoutManager(_ manager: DockLayoutManager, didRequestMovePanel panelId: UUID, toGroup targetGroupId: UUID, at index: Int, windowId: UUID) {
        let layout = manager.getLayout()
        let newLayout = layout.movingChild(panelId, toGroupId: targetGroupId, at: index)
        manager.updateLayout(newLayout)
    }

    func layoutManager(_ manager: DockLayoutManager, didRequestSplit direction: DockSplitDirection, withPanel panelId: UUID, in groupId: UUID, windowId: UUID) {
        let layout = manager.getLayout()
        let child = layout.findChild(panelId)?.panel ?? Panel.contentPanel(id: panelId, title: "Untitled")
        let newLayout = layout.splitting(groupId: groupId, direction: direction, withChild: child)
        manager.updateLayout(newLayout)
    }

    func layoutManager(_ manager: DockLayoutManager, canMovePanel panelId: UUID, toGroup targetGroupId: UUID, at zone: DockDropZone) -> Bool {
        true
    }
}

// MARK: - DockWindowDelegate

extension DockLayoutManager {
    public func dockWindow(_ window: DockWindow, didClose: Void) {
        // Already handled by windowDidClose(_:)
    }

    public func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Propose the move — delegate decides, or apply default if no delegate
        if let delegate = delegate {
            delegate.layoutManager(self, didRequestMovePanel: tabInfo.tabId,
                                   toGroup: tabGroup.panel.id, at: index,
                                   windowId: window.windowId)
        } else {
            // Default: apply the move directly
            let layout = getLayout()
            let newLayout = layout.movingChild(tabInfo.tabId, toGroupId: tabGroup.panel.id, at: index)
            updateLayout(newLayout)
        }
    }

    public func dockWindow(_ window: DockWindow, wantsToDetachPanelId panelId: UUID, at screenPoint: NSPoint) {
        // Propose the tear-off — delegate decides (default: detachPanel), or
        // apply it directly if there is no delegate. The panel stays docked
        // until someone detaches it, so a refusal leaves the tab in place.
        if let panel = panelProvider?(panelId) {
            if let delegate = delegate {
                delegate.layoutManager(self, wantsToDetachPanel: panel, at: screenPoint)
            } else {
                detachPanel(panel, at: screenPoint)
            }
        } else {
            // No panel instance to propose: move its layout entry
            detach(panelId: panelId, title: nil, at: screenPoint)
        }
    }

    public func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {
        // Propose the split — delegate decides, or apply default if no delegate
        if let delegate = delegate {
            delegate.layoutManager(self, didRequestSplit: direction,
                                   withPanel: panelId, in: tabGroup.panel.id,
                                   windowId: window.windowId)
        } else {
            // Default: apply the split directly
            let layout = getLayout()
            let child = layout.findChild(panelId)?.panel ?? Panel.contentPanel(id: panelId, title: "Untitled")
            let newLayout = layout.splitting(groupId: tabGroup.panel.id, direction: direction, withChild: child)
            updateLayout(newLayout)
        }
    }

    public func dockWindow(_ window: DockWindow, didRequestClosePanel panelId: UUID, in tabGroup: DockTabGroupViewController) {
        // Propose close — delegate decides, or apply default if no delegate
        if let delegate = delegate {
            delegate.layoutManager(self, didRequestClosePanel: panelId,
                                   in: tabGroup.panel.id, windowId: window.windowId)
        } else {
            // Default: remove the panel
            removePanel(panelId)
        }
    }

    public func dockWindow(_ window: DockWindow, didRequestNewPanelIn tabGroup: DockTabGroupViewController, actionId: String?) {
        // Propose new panel — delegate decides (no default action without delegate)
        delegate?.layoutManager(self, didRequestNewPanelIn: tabGroup.panel.id,
                               actionId: actionId,
                               windowId: window.windowId)
    }

    public func dockWindow(_ window: DockWindow, canAcceptPanel panelId: UUID, in tabGroup: DockTabGroupViewController, at zone: DockDropZone) -> Bool {
        delegate?.layoutManager(self, canMovePanel: panelId, toGroup: tabGroup.panel.id, at: zone) ?? true
    }

    public func dockWindowDidChangeLayout(_ window: DockWindow) {
        setNeedsLayoutNotification()
    }

    public func dockWindowShouldClose(_ window: DockWindow) -> Bool {
        delegate?.layoutManager(self, shouldCloseWindow: window,
                                containing: window.rootPanel.allContentIds()) ?? true
    }
}

// MARK: - LayoutMismatch (for verifyLayout)

/// Represents a mismatch between expected layout and actual view state
public struct LayoutMismatch {
    /// Path to the mismatched element (e.g., "panels[0].group.children[1].children[0]")
    public let path: String

    /// What the layout JSON expected
    public let expected: String

    /// What the actual macOS view hierarchy shows
    public let actual: String

    /// Severity of the mismatch
    public let severity: Severity

    public enum Severity {
        case error    // Structure mismatch (wrong IDs, missing nodes)
        case warning  // Value mismatch within tolerance (proportions off by small amount)
    }

    public init(path: String, expected: String, actual: String, severity: Severity) {
        self.path = path
        self.expected = expected
        self.actual = actual
        self.severity = severity
    }
}
