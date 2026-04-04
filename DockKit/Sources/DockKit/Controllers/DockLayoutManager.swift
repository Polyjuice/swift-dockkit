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
    /// Contains ALL windows and their layout trees
    public func getLayout() -> DockLayout {
        let rootPanels = windows.map { window -> Panel in
            var panel = window.rootPanel
            panel.isTopLevelWindow = true
            panel.frame = window.frame
            panel.isFullScreen = window.styleMask.contains(.fullScreen)
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

        // Notify delegate that layout changed
        delegate?.layoutManagerDidChangeLayout(self)
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
        let window = DockWindow(
            id: panel.id,
            rootPanel: panel,
            frame: panel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
            layoutManager: self
        )
        window.dockDelegate = self
        window.panelProvider = { [weak self] id in self?.panelProvider?(id) }

        if panel.isFullScreen == true && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        window.makeKeyAndOrderFront(nil)
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

    /// Create a new window with the given layout
    @discardableResult
    public func createWindow(
        rootPanel: Panel = Panel(content: .group(PanelGroup(style: .tabs))),
        frame: NSRect = NSRect(x: 100, y: 100, width: 800, height: 600)
    ) -> DockWindow {
        let window = DockWindow(
            id: UUID(),
            rootPanel: rootPanel,
            frame: frame,
            layoutManager: self
        )
        window.dockDelegate = self
        window.panelProvider = { [weak self] id in self?.panelProvider?(id) }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Close a window by ID
    public func closeWindow(_ windowId: UUID) {
        guard let index = windows.firstIndex(where: { $0.windowId == windowId }) else { return }
        let window = windows.remove(at: index)
        window.close()

        // Notify delegate if all windows are closed
        if windows.isEmpty {
            delegate?.layoutManagerDidCloseAllWindows(self)
        }
    }

    /// Called by DockWindow when it closes (to remove itself from our array)
    /// This prevents dangling references to deallocated windows
    internal func windowDidClose(_ window: DockWindow) {
        if let index = windows.firstIndex(where: { $0.windowId == window.windowId }) {
            windows.remove(at: index)

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

    /// Detach a panel into a new floating window
    @discardableResult
    public func detachPanel(_ panel: any DockablePanel, at screenPoint: NSPoint) -> DockWindow {
        panel.panelWillDetach()

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
        let frame = NSRect(
            x: screenPoint.x - 300,
            y: screenPoint.y - 200,
            width: 600,
            height: 400
        )

        let window = DockWindow(
            id: UUID(),
            rootPanel: rootPanel,
            frame: frame,
            layoutManager: self
        )
        window.dockDelegate = self
        window.panelProvider = { [weak self] id in self?.panelProvider?(id) }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)

        panel.panelDidDock(at: .floating)

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
            let window = DockWindow(
                id: panel.id,
                rootPanel: panel,
                frame: panel.frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
                layoutManager: self
            )
            window.dockDelegate = self
            window.panelProvider = { [weak self] id in self?.panelProvider?(id) }
            windows.append(window)

            // Handle full-screen state
            if panel.isFullScreen == true && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }

            window.makeKeyAndOrderFront(nil)
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
    /// Called when all windows have been closed
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager)

    /// Called when a panel requests to be detached
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)

    /// Called when layout changes (for auto-save, etc.)
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager)

    // MARK: - Proposals (UI-initiated actions)

    /// User clicked the close button on a tab. The delegate should remove the panel
    /// from the layout model if appropriate, or ignore to prevent closure.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestClosePanel panelId: UUID,
                       in groupId: UUID, windowId: UUID)

    /// User clicked the "+" button in a tab group. The delegate should create a panel
    /// and add it to the layout model, or ignore to do nothing.
    func layoutManager(_ manager: DockLayoutManager,
                       didRequestNewPanelIn groupId: UUID,
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
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {}
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager) {}

    func layoutManager(_ manager: DockLayoutManager, didRequestClosePanel panelId: UUID, in groupId: UUID, windowId: UUID) {
        manager.removePanel(panelId)
    }

    func layoutManager(_ manager: DockLayoutManager, didRequestNewPanelIn groupId: UUID, windowId: UUID) {
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
        // Remove from current location
        removePanel(panelId)

        // Look up the dockable panel and notify delegate (host app creates new window)
        if let panel = panelProvider?(panelId) {
            delegate?.layoutManager(self, wantsToDetachPanel: panel, at: screenPoint)
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

    public func dockWindow(_ window: DockWindow, didRequestNewPanelIn tabGroup: DockTabGroupViewController) {
        // Propose new panel — delegate decides (no default action without delegate)
        delegate?.layoutManager(self, didRequestNewPanelIn: tabGroup.panel.id,
                               windowId: window.windowId)
    }

    public func dockWindow(_ window: DockWindow, canAcceptPanel panelId: UUID, in tabGroup: DockTabGroupViewController, at zone: DockDropZone) -> Bool {
        delegate?.layoutManager(self, canMovePanel: panelId, toGroup: tabGroup.panel.id, at: zone) ?? true
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
