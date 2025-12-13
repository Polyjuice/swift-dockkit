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
        let windowStates = windows.map { window -> WindowState in
            WindowState(
                id: window.windowId,
                frame: window.frame,
                isFullScreen: window.styleMask.contains(.fullScreen),
                rootNode: DockLayoutNode.from(window.rootNode)
            )
        }
        return DockLayout(windows: windowStates)
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
            windowFactory: { [weak self] windowState in
                self?.createWindowFromState(windowState) ?? DockWindow(
                    id: windowState.id,
                    rootNode: .tabGroup(TabGroupNode()),
                    frame: windowState.frame,
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

    /// Create a window from a WindowState (used by reconciler)
    private func createWindowFromState(_ state: WindowState) -> DockWindow {
        let rootNode = restoreNode(from: state.rootNode)
        let window = DockWindow(
            id: state.id,
            rootNode: rootNode,
            frame: state.frame,
            layoutManager: self
        )
        window.dockDelegate = self

        if state.isFullScreen && !window.styleMask.contains(.fullScreen) {
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
        rootNode: DockNode = .tabGroup(TabGroupNode()),
        frame: NSRect = NSRect(x: 100, y: 100, width: 800, height: 600)
    ) -> DockWindow {
        let window = DockWindow(
            id: UUID(),
            rootNode: rootNode,
            frame: frame,
            layoutManager: self
        )
        window.dockDelegate = self
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

    /// Called by DockDesktopHostWindow when it closes
    /// This is a stub for desktop host windows - they are managed separately
    internal func windowDidClose(_ window: DockDesktopHostWindow) {
        // Desktop host windows are not tracked in the windows array
        // This method exists to satisfy the window's close callback
        // Full desktop host support can be added later
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
            // No windows exist - create one
            let tabGroup = TabGroupNode(tabs: [DockTab(from: panel)])
            createWindow(rootNode: .tabGroup(tabGroup))
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

        let tabGroup = TabGroupNode(tabs: [DockTab(from: panel)])
        let frame = NSRect(
            x: screenPoint.x - 300,
            y: screenPoint.y - 200,
            width: 600,
            height: 400
        )

        let window = DockWindow(
            id: UUID(),
            rootNode: .tabGroup(tabGroup),
            frame: frame,
            layoutManager: self
        )
        window.dockDelegate = self
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
        for windowState in layout.windows {
            let rootNode = restoreNode(from: windowState.rootNode)
            let window = DockWindow(
                id: windowState.id,
                rootNode: rootNode,
                frame: windowState.frame,
                layoutManager: self
            )
            window.dockDelegate = self
            windows.append(window)

            // Handle full-screen state
            if windowState.isFullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }

            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Restore a DockNode from a layout node
    private func restoreNode(from layoutNode: DockLayoutNode) -> DockNode {
        switch layoutNode {
        case .split(let splitLayout):
            let children = splitLayout.children.map { restoreNode(from: $0) }
            let splitNode = SplitNode(
                id: splitLayout.id,
                axis: splitLayout.axis,
                children: children,
                proportions: splitLayout.proportions
            )
            return .split(splitNode)

        case .tabGroup(let tabGroupLayout):
            var tabs: [DockTab] = []
            for tabState in tabGroupLayout.tabs {
                // Try to get panel from provider
                if let panel = panelProvider?(tabState.id) {
                    tabs.append(DockTab(from: panel, cargo: tabState.cargo))
                } else {
                    // Create placeholder tab (panel not yet registered)
                    tabs.append(DockTab(
                        id: tabState.id,
                        title: tabState.title,
                        iconName: tabState.iconName,
                        cargo: tabState.cargo
                    ))
                }
            }
            return .tabGroup(TabGroupNode(
                id: tabGroupLayout.id,
                tabs: tabs,
                activeTabIndex: tabGroupLayout.activeTabIndex,
                displayMode: tabGroupLayout.displayMode
            ))
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

/// Delegate for layout manager events
public protocol DockLayoutManagerDelegate: AnyObject {
    /// Called when all windows have been closed
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager)

    /// Called when a panel requests to be detached
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint)

    /// Called when layout changes (for auto-save, etc.)
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager)
}

/// Default implementations for optional delegate methods
public extension DockLayoutManagerDelegate {
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager) {}
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {}
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager) {}
}

// MARK: - DockWindowDelegate

extension DockLayoutManager {
    public func dockWindow(_ window: DockWindow, didClose: Void) {
        // Already handled by windowDidClose(_:)
    }

    public func dockWindow(_ window: DockWindow, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Get current layout and compute new layout with tab moved
        let currentLayout = getLayout()
        let targetGroupId = tabGroup.tabGroupNode.id

        // Use layout mutation API to move the tab
        let newLayout = currentLayout.movingTab(tabInfo.tabId, toGroupId: targetGroupId, at: index)

        // Apply the new layout
        updateLayout(newLayout)
    }

    public func dockWindow(_ window: DockWindow, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        // Remove from current location
        removePanel(panel.panelId)

        // Create new floating window via delegate (host app creates new window)
        delegate?.layoutManager(self, wantsToDetachPanel: panel, at: screenPoint)
    }

    public func dockWindow(_ window: DockWindow, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Get current layout
        let currentLayout = getLayout()
        let targetGroupId = tabGroup.tabGroupNode.id

        // Create TabLayoutState from DockTab
        let tabState = TabLayoutState(
            id: tab.id,
            title: tab.title,
            iconName: tab.iconName,
            cargo: tab.cargo
        )

        // Use layout mutation API to perform the split
        let newLayout = currentLayout.splitting(
            groupId: targetGroupId,
            direction: direction,
            withTab: tabState
        )

        // Apply the new layout
        updateLayout(newLayout)
    }
}

// MARK: - LayoutMismatch (for verifyLayout)

/// Represents a mismatch between expected layout and actual view state
public struct LayoutMismatch {
    /// Path to the mismatched element (e.g., "windows[0].rootNode.children[1].tabs[0]")
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
