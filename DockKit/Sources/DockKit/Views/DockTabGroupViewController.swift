import AppKit

/// Delegate for tab group events
public protocol DockTabGroupViewControllerDelegate: AnyObject {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachTab tab: DockTab, at screenPoint: NSPoint)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseTab tabId: UUID)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastTab: Bool)
    func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab)
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController)
}

/// Optional delegate methods
public extension DockTabGroupViewControllerDelegate {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseTab tabId: UUID) {}
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {}
}

/// A view controller that manages a tab bar and content area
/// This is the leaf node in the dock hierarchy
public class DockTabGroupViewController: NSViewController {
    public weak var delegate: DockTabGroupViewControllerDelegate?

    /// The tab group node this controller represents
    public private(set) var tabGroupNode: TabGroupNode

    /// The tab bar
    private var tabBar: DockTabBarView!

    /// Tab bar height constraint (varies based on displayMode)
    private var tabBarHeightConstraint: NSLayoutConstraint!

    /// Container for panel content
    private var contentContainer: NSView!

    /// Currently displayed panel view controller
    private var currentPanelVC: NSViewController?

    /// Drop overlay for split drop zones
    private var dropOverlay: DockDropOverlayView?

    /// Whether drop overlay is visible
    private var isShowingDropOverlay = false

    /// KVO observation for first responder changes
    private var firstResponderObservation: NSKeyValueObservation?

    public init(tabGroupNode: TabGroupNode = TabGroupNode()) {
        self.tabGroupNode = tabGroupNode
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.tabGroupNode = TabGroupNode()
        super.init(coder: coder)
    }

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupDragNotifications()
        updateTabBar()  // Populate tabs on initial load
        updateContent()
    }

    private func setupDragNotifications() {
        // Show/hide drop overlay when drags begin/end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDragBegan),
            name: .dockDragBegan,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDragEnded),
            name: .dockDragEnded,
            object: nil
        )
    }

    @objc private func handleDragBegan(_ notification: Notification) {
        // Check if we're the source of the drag and only have one tab
        // In that case, don't show the overlay since dropping on yourself is a no-op
        if let dragInfo = notification.userInfo?["dragInfo"] as? DockTabDragInfo {
            if dragInfo.sourceGroupId == tabGroupNode.id && tabGroupNode.tabs.count == 1 {
                // Don't show overlay - can't drop the only tab on itself
                return
            }
        }
        showDropOverlay(true)
    }

    @objc private func handleDragEnded() {
        showDropOverlay(false)
    }

    deinit {
        firstResponderObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        // Tab bar at top
        tabBar = DockTabBarView()
        tabBar.groupId = tabGroupNode.id
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        // Content container below tab bar
        contentContainer = NSView()
        contentContainer.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        // Height depends on display mode (28 for tabs, 80 for thumbnails)
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: heightForDisplayMode(tabGroupNode.displayMode))

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeightConstraint,

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Setup drop overlay
        dropOverlay = DockDropOverlayView()
        dropOverlay?.delegate = self
        dropOverlay?.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay?.isHidden = true
        if let overlay = dropOverlay {
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        setupFocusTracking()

        // Focus the panel content when this tab group becomes visible
        focusPanelContent()
    }

    // MARK: - Focus Management

    /// Focus the active panel's preferred first responder
    public func focusPanelContent() {
        guard let window = view.window,
              let panel = tabGroupNode.activeTab?.panel,
              let responder = panel.preferredFirstResponder else {
            return
        }

        // Make the panel's preferred view the first responder
        DispatchQueue.main.async {
            window.makeFirstResponder(responder)
        }
    }

    private func setupFocusTracking() {
        // Clean up previous observation
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil

        guard let window = view.window else {
            tabBar.setFocused(false)
            return
        }

        // Observe first responder changes
        firstResponderObservation = window.observe(\.firstResponder, options: [.new, .initial]) { [weak self] window, _ in
            DispatchQueue.main.async {
                self?.updateFocusIndicator()
            }
        }

        // Also observe window key status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStatusChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowKeyStatusChanged),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowKeyStatusChanged(_ notification: Notification) {
        updateFocusIndicator()
    }

    private func updateFocusIndicator() {
        guard let window = view.window else {
            tabBar.setFocused(false)
            return
        }

        // Check if window is key and if any view in our content container is first responder
        let isWindowKey = window.isKeyWindow
        let hasFocus = isWindowKey && isFirstResponderInContent(window.firstResponder)

        tabBar.setFocused(hasFocus)
    }

    /// Check if the given responder is within our content container
    private func isFirstResponderInContent(_ responder: NSResponder?) -> Bool {
        guard let responderView = responder as? NSView else { return false }

        // Check if the responder is our content container or a descendant of it
        var current: NSView? = responderView
        while let view = current {
            if view === contentContainer {
                return true
            }
            current = view.superview
        }
        return false
    }

    // MARK: - Public API

    /// Add a panel as a new tab
    public func addTab(from panel: any DockablePanel, activate: Bool = true) {
        let tab = DockTab(from: panel)
        tabGroupNode.addTab(tab)
        updateTabBar()
        if activate {
            selectTab(at: tabGroupNode.tabs.count - 1)
        }
    }

    /// Insert a panel at a specific index
    public func insertTab(from panel: any DockablePanel, at index: Int, activate: Bool = true) {
        let tab = DockTab(from: panel)
        tabGroupNode.insertTab(tab, at: index)
        updateTabBar()
        if activate {
            selectTab(at: index)
        }
    }

    /// Remove a tab by index
    @discardableResult
    public func removeTab(at index: Int) -> DockTab? {
        guard let tab = tabGroupNode.removeTab(at: index) else { return nil }

        // Notify delegate about tab closure (for layout model updates)
        delegate?.tabGroup(self, didCloseTab: tab.id)

        // Notify panel
        tab.panel?.panelDidResignActive()

        updateTabBar()
        updateContent()

        if tabGroupNode.tabs.isEmpty {
            delegate?.tabGroup(self, didCloseLastTab: true)
        }

        return tab
    }

    /// Remove a tab by ID
    @discardableResult
    public func removeTab(withId id: UUID) -> DockTab? {
        guard let index = tabGroupNode.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        return removeTab(at: index)
    }

    /// Select a tab by index
    public func selectTab(at index: Int) {
        guard index >= 0 && index < tabGroupNode.tabs.count else { return }

        // Notify old tab
        tabGroupNode.activeTab?.panel?.panelDidResignActive()

        tabGroupNode.activeTabIndex = index
        tabBar.selectTab(at: index)
        updateContent()

        // Notify new tab
        tabGroupNode.activeTab?.panel?.panelDidBecomeActive()

        // Focus the new panel's content
        focusPanelContent()
    }

    /// Get the currently active tab
    public var activeTab: DockTab? {
        tabGroupNode.activeTab
    }

    /// Show/hide the drop overlay
    public func showDropOverlay(_ show: Bool) {
        isShowingDropOverlay = show
        dropOverlay?.isHidden = !show
    }

    // MARK: - Reconciliation Support

    /// Reconcile tabs with a target state (for layout reconciliation)
    public func reconcileTabs(with targetTabs: [TabLayoutState], panelProvider: ((UUID) -> (any DockablePanel)?)?) {
        let currentTabIds = Set(tabGroupNode.tabs.map { $0.id })
        let targetTabIds = Set(targetTabs.map { $0.id })

        // Remove tabs not in target
        let toRemove = currentTabIds.subtracting(targetTabIds)
        for tabId in toRemove {
            _ = removeTab(withId: tabId)
        }

        // Add or update tabs
        for (targetIndex, targetTab) in targetTabs.enumerated() {
            if let existingIndex = tabGroupNode.tabs.firstIndex(where: { $0.id == targetTab.id }) {
                // Tab exists - move to correct position if needed
                if existingIndex != targetIndex && targetIndex < tabGroupNode.tabs.count {
                    moveTabInternal(from: existingIndex, to: targetIndex)
                }
                // Update title if changed
                let actualIndex = min(targetIndex, tabGroupNode.tabs.count - 1)
                if actualIndex >= 0 && actualIndex < tabGroupNode.tabs.count {
                    tabGroupNode.tabs[actualIndex].title = targetTab.title
                }
            } else {
                // New tab - create and insert
                let panel = panelProvider?(targetTab.id)
                let tab = DockTab(
                    id: targetTab.id,
                    title: targetTab.title,
                    iconName: targetTab.iconName,
                    panel: panel
                )
                insertTabInternal(tab, at: targetIndex)
            }
        }

        updateTabBar()
        updateContent()  // Also update content to show the panel
    }

    /// Move a tab from one index to another (for reconciliation)
    private func moveTabInternal(from sourceIndex: Int, to targetIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabGroupNode.tabs.count,
              targetIndex >= 0, targetIndex < tabGroupNode.tabs.count,
              sourceIndex != targetIndex else { return }

        let tab = tabGroupNode.tabs.remove(at: sourceIndex)
        tabGroupNode.tabs.insert(tab, at: targetIndex)
    }

    /// Insert a DockTab at a specific index (for reconciliation)
    private func insertTabInternal(_ tab: DockTab, at index: Int) {
        tabGroupNode.insertTab(tab, at: index)
    }

    /// Insert a DockTab at a specific index (public for reconciliation)
    public func insertDockTab(_ tab: DockTab, at index: Int, activate: Bool = true) {
        tabGroupNode.insertTab(tab, at: index)
        updateTabBar()
        if activate {
            selectTab(at: min(index, tabGroupNode.tabs.count - 1))
        }
    }

    /// Activate tab at index (for reconciliation)
    public func activateTab(at index: Int) {
        selectTab(at: index)
    }

    /// Update the display mode (tabs vs thumbnails)
    public func setDisplayMode(_ mode: TabGroupDisplayMode) {
        tabGroupNode.displayMode = mode
        updateTabBar()
    }

    /// Update the display mode using StageDisplayMode
    public func setDisplayMode(_ mode: StageDisplayMode) {
        // Convert to tab bar display mode
        tabBar.displayMode = mode
        updateTabBarForStageMode(mode)
    }

    // MARK: - Private

    private func updateTabBar() {
        tabBar.setTabs(tabGroupNode.tabs, selectedIndex: tabGroupNode.activeTabIndex, displayMode: tabGroupNode.displayMode)

        // Update height for display mode
        let newHeight = heightForDisplayMode(tabGroupNode.displayMode)
        if tabBarHeightConstraint.constant != newHeight {
            tabBarHeightConstraint.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    private func updateTabBarForStageMode(_ mode: StageDisplayMode) {
        tabBar.setTabs(tabGroupNode.tabs, selectedIndex: tabGroupNode.activeTabIndex, displayMode: mode)

        // Update height for display mode
        let newHeight = heightForStageDisplayMode(mode)
        if tabBarHeightConstraint.constant != newHeight {
            tabBarHeightConstraint.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    private func heightForDisplayMode(_ mode: TabGroupDisplayMode) -> CGFloat {
        switch mode {
        case .tabs:
            return 28
        case .thumbnails:
            return 80
        }
    }

    private func heightForStageDisplayMode(_ mode: StageDisplayMode) -> CGFloat {
        switch mode {
        case .tabs:
            return 28
        case .thumbnails:
            return 80
        case .custom:
            return DockKit.customTabRenderer?.tabBarHeight ?? 28
        }
    }

    private func updateContent() {
        // Show new panel first (if any)
        let newPanelVC: NSViewController?
        if let activeTab = tabGroupNode.activeTab {
            if let panel = activeTab.panel {
                newPanelVC = panel.panelViewController
            } else {
                newPanelVC = nil
            }
        } else {
            newPanelVC = nil
        }

        // Only update if panel actually changed
        guard newPanelVC !== currentPanelVC else { return }

        // Add new panel before removing old one to avoid empty state
        if let panelVC = newPanelVC {
            // IMPORTANT: Remove from any existing parent first
            // This can happen when stages are rebuilt - the panel's view controller
            // might still have a parent reference to a deallocated tab group controller
            if panelVC.parent != nil {
                panelVC.view.removeFromSuperview()
                panelVC.removeFromParent()
            }

            addChild(panelVC)
            panelVC.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(panelVC.view)

            NSLayoutConstraint.activate([
                panelVC.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                panelVC.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                panelVC.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                panelVC.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }

        // Now remove old panel - use proper child VC lifecycle
        // IMPORTANT: Only remove the view if it's actually in OUR contentContainer
        // The view may have already been moved to a different container (different window)
        if let oldVC = currentPanelVC {
            // Only remove from superview if it's in our container
            if oldVC.view.superview === contentContainer {
                oldVC.view.removeFromSuperview()
            }
            // Only remove from parent if we are the parent
            if oldVC.parent === self {
                oldVC.removeFromParent()
            }
        }

        currentPanelVC = newPanelVC
    }
}

// MARK: - DockTabBarViewDelegate

extension DockTabGroupViewController: DockTabBarViewDelegate {
    public func tabBar(_ tabBar: DockTabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    public func tabBar(_ tabBar: DockTabBarView, didCloseTabAt index: Int) {
        removeTab(at: index)
    }

    public func tabBar(_ tabBar: DockTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int) {
        guard fromIndex >= 0 && fromIndex < tabGroupNode.tabs.count,
              toIndex >= 0 && toIndex <= tabGroupNode.tabs.count else { return }

        let tab = tabGroupNode.tabs.remove(at: fromIndex)
        let insertIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        tabGroupNode.tabs.insert(tab, at: insertIndex)

        // Update active index if needed
        if tabGroupNode.activeTabIndex == fromIndex {
            tabGroupNode.activeTabIndex = insertIndex
        } else if fromIndex < tabGroupNode.activeTabIndex && toIndex > tabGroupNode.activeTabIndex {
            tabGroupNode.activeTabIndex -= 1
        } else if fromIndex > tabGroupNode.activeTabIndex && toIndex <= tabGroupNode.activeTabIndex {
            tabGroupNode.activeTabIndex += 1
        }

        updateTabBar()
    }

    public func tabBar(_ tabBar: DockTabBarView, didInitiateTearOff tabIndex: Int, at screenPoint: NSPoint) {
        guard let tab = tabGroupNode.tabs[safe: tabIndex] else { return }
        delegate?.tabGroup(self, didDetachTab: tab, at: screenPoint)
    }

    public func tabBar(_ tabBar: DockTabBarView, didReceiveDroppedTab tabInfo: DockTabDragInfo, at index: Int) {
        delegate?.tabGroup(self, didReceiveTab: tabInfo, at: index)
    }

    public func tabBarDidRequestNewTab(_ tabBar: DockTabBarView) {
        delegate?.tabGroupDidRequestNewTab(self)
    }
}

// MARK: - DockDropOverlayViewDelegate

extension DockTabGroupViewController: DockDropOverlayViewDelegate {
    public func dropOverlay(_ overlay: DockDropOverlayView, didSelectZone zone: DockDropZone, withTab tabInfo: DockTabDragInfo) {
        // Convert zone to split direction and notify delegate
        switch zone {
        case .center:
            // Add as tab to this group
            delegate?.tabGroup(self, didReceiveTab: tabInfo, at: tabGroupNode.tabs.count)

        case .left:
            if let tab = findTab(byId: tabInfo.tabId) {
                delegate?.tabGroup(self, wantsToSplit: .left, withTab: tab)
            } else {
                // Tab from external source - create placeholder and split
                let placeholderTab = DockTab(id: tabInfo.tabId, title: tabInfo.title, iconName: tabInfo.iconName)
                delegate?.tabGroup(self, wantsToSplit: .left, withTab: placeholderTab)
            }

        case .right:
            if let tab = findTab(byId: tabInfo.tabId) {
                delegate?.tabGroup(self, wantsToSplit: .right, withTab: tab)
            } else {
                let placeholderTab = DockTab(id: tabInfo.tabId, title: tabInfo.title, iconName: tabInfo.iconName)
                delegate?.tabGroup(self, wantsToSplit: .right, withTab: placeholderTab)
            }

        case .top:
            if let tab = findTab(byId: tabInfo.tabId) {
                delegate?.tabGroup(self, wantsToSplit: .top, withTab: tab)
            } else {
                let placeholderTab = DockTab(id: tabInfo.tabId, title: tabInfo.title, iconName: tabInfo.iconName)
                delegate?.tabGroup(self, wantsToSplit: .top, withTab: placeholderTab)
            }

        case .bottom:
            if let tab = findTab(byId: tabInfo.tabId) {
                delegate?.tabGroup(self, wantsToSplit: .bottom, withTab: tab)
            } else {
                let placeholderTab = DockTab(id: tabInfo.tabId, title: tabInfo.title, iconName: tabInfo.iconName)
                delegate?.tabGroup(self, wantsToSplit: .bottom, withTab: placeholderTab)
            }
        }
    }

    private func findTab(byId id: UUID) -> DockTab? {
        // First check our own tabs
        if let tab = tabGroupNode.tabs.first(where: { $0.id == id }) {
            return tab
        }
        // Tab might be from another group - delegate will handle
        return nil
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
