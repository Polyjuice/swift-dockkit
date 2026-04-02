import AppKit

/// Delegate for tab group events
public protocol DockTabGroupViewControllerDelegate: AnyObject {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachPanel panelId: UUID, at screenPoint: NSPoint)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didClosePanel panelId: UUID)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastPanel: Bool)
    func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID)
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController)
}

/// Optional delegate methods
public extension DockTabGroupViewControllerDelegate {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didClosePanel panelId: UUID) {}
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {}
}

/// A view controller that manages a tab bar and content area
/// This is the leaf node in the dock hierarchy.
///
/// Accepts a `Panel` with `.group(PanelGroup)` content where `style` is `.tabs` or `.thumbnails`.
/// Its children are `Panel` objects with `content: .content`.
///
/// Because `Panel` is a pure Codable struct with no DockablePanel reference,
/// this controller maintains its own mapping of panel ID → DockablePanel,
/// resolved via the `panelProvider` callback.
public class DockTabGroupViewController: NSViewController {
    public weak var delegate: DockTabGroupViewControllerDelegate?

    /// The panel group this controller represents (a Panel with .group content)
    public private(set) var panel: Panel

    /// Callback to resolve a panel ID to a DockablePanel instance
    /// The host app provides this to supply actual view controllers for content panels
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Local cache of resolved DockablePanel instances, keyed by panel ID
    private var resolvedPanels: [UUID: any DockablePanel] = [:]

    /// The tab bar
    private var tabBar: DockTabBarView!

    /// Tab bar height constraint (varies based on group style)
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

    public init(panel: Panel = Panel(content: .group(PanelGroup(style: .tabs)))) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.panel = Panel(content: .group(PanelGroup(style: .tabs)))
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
            let children = group?.children ?? []
            if dragInfo.sourceGroupId == panel.id && childPanels.count == 1 {
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

    // MARK: - Convenience Accessors

    /// The PanelGroup for this controller (the panel must have .group content)
    public var group: PanelGroup? {
        get { panel.group }
        set {
            if let newValue = newValue {
                panel.content = .group(newValue)
            }
        }
    }

    /// The child panels (tabs) in this group
    public var childPanels: [Panel] {
        get { group?.children ?? [] }
    }

    /// The active child index
    public var activeIndex: Int {
        get { group?.activeIndex ?? 0 }
        set {
            guard case .group(var g) = panel.content else { return }
            g.activeIndex = newValue
            panel.content = .group(g)
        }
    }

    /// The currently active child panel
    public var activeChild: Panel? {
        group?.activeChild
    }

    /// The group style (tabs or thumbnails)
    public var groupStyle: PanelGroupStyle {
        get { group?.style ?? .tabs }
        set {
            guard case .group(var g) = panel.content else { return }
            g.style = newValue
            panel.content = .group(g)
        }
    }

    // MARK: - Setup

    private func setupUI() {
        // Tab bar at top
        tabBar = DockTabBarView()
        tabBar.groupId = panel.id
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        // Content container below tab bar (clips content to prevent bleeding)
        contentContainer = NSView()
        contentContainer.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        contentContainer.layer?.masksToBounds = true

        // Height depends on group style (28 for tabs, 80 for thumbnails)
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: heightForGroupStyle(groupStyle))

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
              let activeChild = activeChild,
              let dockablePanel = resolvePanel(for: activeChild.id),
              let responder = dockablePanel.preferredFirstResponder else {
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

    // MARK: - Panel Resolution

    /// Resolve a DockablePanel for a given panel ID, using cache or panelProvider
    private func resolvePanel(for panelId: UUID) -> (any DockablePanel)? {
        if let cached = resolvedPanels[panelId] {
            return cached
        }
        if let resolved = panelProvider?(panelId) {
            resolvedPanels[panelId] = resolved
            return resolved
        }
        return nil
    }

    /// Remove a resolved panel from the cache
    private func evictPanel(for panelId: UUID) {
        resolvedPanels.removeValue(forKey: panelId)
    }

    // MARK: - Public API

    /// Add a panel as a new tab
    public func addTab(from dockablePanel: any DockablePanel, activate: Bool = true) {
        let childPanel = Panel(
            id: dockablePanel.panelId,
            title: dockablePanel.panelTitle,
            iconName: nil,
            content: .content
        )
        resolvedPanels[dockablePanel.panelId] = dockablePanel

        guard case .group(var g) = panel.content else { return }
        g.children.append(childPanel)
        panel.content = .group(g)

        updateTabBar()
        if activate {
            selectTab(at: childPanels.count - 1)
        }
    }

    /// Insert a panel at a specific index
    public func insertTab(from dockablePanel: any DockablePanel, at index: Int, activate: Bool = true) {
        let childPanel = Panel(
            id: dockablePanel.panelId,
            title: dockablePanel.panelTitle,
            iconName: nil,
            content: .content
        )
        resolvedPanels[dockablePanel.panelId] = dockablePanel

        guard case .group(var g) = panel.content else { return }
        let clampedIndex = max(0, min(index, g.children.count))
        g.children.insert(childPanel, at: clampedIndex)
        panel.content = .group(g)

        updateTabBar()
        if activate {
            selectTab(at: clampedIndex)
        }
    }

    /// Remove a tab by index
    @discardableResult
    public func removeTab(at index: Int) -> Panel? {
        guard case .group(var g) = panel.content,
              index >= 0 && index < g.children.count else { return nil }

        let removedChild = g.children.remove(at: index)

        // Adjust active index
        if g.activeIndex >= g.children.count {
            g.activeIndex = max(0, g.children.count - 1)
        }
        panel.content = .group(g)

        // Notify delegate about tab closure (for layout model updates)
        delegate?.tabGroup(self, didClosePanel: removedChild.id)

        // Notify the dockable panel
        resolvePanel(for: removedChild.id)?.panelDidResignActive()

        // Remove from cache
        evictPanel(for: removedChild.id)

        updateTabBar()
        updateContent()

        if childPanels.isEmpty {
            delegate?.tabGroup(self, didCloseLastPanel: true)
        }

        return removedChild
    }

    /// Remove a tab by ID
    @discardableResult
    public func removeTab(withId id: UUID) -> Panel? {
        guard let index = childPanels.firstIndex(where: { $0.id == id }) else { return nil }
        return removeTab(at: index)
    }

    /// Select a tab by index
    public func selectTab(at index: Int) {
        guard case .group(var g) = panel.content,
              index >= 0 && index < g.children.count else { return }

        // Notify old tab
        if let oldChild = g.activeChild {
            resolvePanel(for: oldChild.id)?.panelDidResignActive()
        }

        g.activeIndex = index
        panel.content = .group(g)

        tabBar.selectTab(at: index)
        updateContent()

        // Notify new tab
        if let newChild = group?.activeChild {
            resolvePanel(for: newChild.id)?.panelDidBecomeActive()
        }

        // Focus the new panel's content
        focusPanelContent()
    }

    /// Get the currently active child panel
    public var activeTab: Panel? {
        activeChild
    }

    /// Show/hide the drop overlay
    public func showDropOverlay(_ show: Bool) {
        isShowingDropOverlay = show
        dropOverlay?.isHidden = !show
    }

    // MARK: - Reconciliation Support

    /// Reconcile children with a target state (for layout reconciliation)
    public func reconcileTabs(with targetChildren: [Panel], panelProvider: ((UUID) -> (any DockablePanel)?)?) {
        guard case .group(var g) = panel.content else { return }

        let currentIds = Set(g.children.map { $0.id })
        let targetIds = Set(targetChildren.map { $0.id })

        // Remove children not in target
        let toRemove = currentIds.subtracting(targetIds)
        for panelId in toRemove {
            _ = removeTab(withId: panelId)
        }

        // Re-read group after removals
        guard case .group(var g2) = panel.content else { return }

        // Add or update children
        for (targetIndex, targetChild) in targetChildren.enumerated() {
            if let existingIndex = g2.children.firstIndex(where: { $0.id == targetChild.id }) {
                // Child exists - move to correct position if needed
                if existingIndex != targetIndex && targetIndex < g2.children.count {
                    let moved = g2.children.remove(at: existingIndex)
                    g2.children.insert(moved, at: targetIndex)
                }
                // Update title if changed
                let actualIndex = min(targetIndex, g2.children.count - 1)
                if actualIndex >= 0 && actualIndex < g2.children.count {
                    g2.children[actualIndex].title = targetChild.title
                    g2.children[actualIndex].iconName = targetChild.iconName
                    g2.children[actualIndex].cargo = targetChild.cargo
                }
            } else {
                // New child - insert and resolve its DockablePanel
                var newChild = targetChild
                // Ensure it's a content panel
                if case .content = newChild.content {} else {
                    newChild.content = .content
                }
                let clampedIndex = min(targetIndex, g2.children.count)
                g2.children.insert(newChild, at: clampedIndex)

                // Resolve and cache the DockablePanel
                if let resolved = panelProvider?(targetChild.id) {
                    resolvedPanels[targetChild.id] = resolved
                }
            }
        }

        panel.content = .group(g2)
        updateTabBar()
        updateContent()  // Also update content to show the panel
    }

    /// Insert a child Panel at a specific index (public for reconciliation)
    public func insertChildPanel(_ childPanel: Panel, at index: Int, dockablePanel: (any DockablePanel)? = nil, activate: Bool = true) {
        guard case .group(var g) = panel.content else { return }

        let clampedIndex = max(0, min(index, g.children.count))
        g.children.insert(childPanel, at: clampedIndex)
        panel.content = .group(g)

        if let dp = dockablePanel {
            resolvedPanels[childPanel.id] = dp
        }

        updateTabBar()
        if activate {
            selectTab(at: min(clampedIndex, childPanels.count - 1))
        }
    }

    /// Activate tab at index (for reconciliation)
    public func activateTab(at index: Int) {
        selectTab(at: index)
    }

    /// Update the group style (tabs vs thumbnails)
    public func setGroupStyle(_ style: PanelGroupStyle) {
        guard case .group(var g) = panel.content else { return }
        g.style = style
        panel.content = .group(g)
        updateTabBar()
    }

    // MARK: - Private

    private func updateTabBar() {
        let tabPanels = childPanels
        let currentActiveIndex = activeIndex
        let style = groupStyle
        tabBar.setTabs(tabPanels, selectedIndex: currentActiveIndex, groupStyle: style)

        // Update height for group style
        let newHeight = heightForGroupStyle(style)
        if tabBarHeightConstraint.constant != newHeight {
            tabBarHeightConstraint.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    private func heightForGroupStyle(_ style: PanelGroupStyle) -> CGFloat {
        switch style {
        case .tabs, .stages, .split:
            return 28
        case .thumbnails:
            return 80
        }
    }

    private func updateContent() {
        // Show new panel first (if any)
        let newPanelVC: NSViewController?
        if let activeChild = activeChild {
            if let dockablePanel = resolvePanel(for: activeChild.id) {
                newPanelVC = dockablePanel.panelViewController
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
        guard case .group(var g) = panel.content,
              fromIndex >= 0 && fromIndex < g.children.count,
              toIndex >= 0 && toIndex <= g.children.count else { return }

        let child = g.children.remove(at: fromIndex)
        let insertIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        g.children.insert(child, at: insertIndex)

        // Update active index if needed
        if g.activeIndex == fromIndex {
            g.activeIndex = insertIndex
        } else if fromIndex < g.activeIndex && toIndex > g.activeIndex {
            g.activeIndex -= 1
        } else if fromIndex > g.activeIndex && toIndex <= g.activeIndex {
            g.activeIndex += 1
        }

        panel.content = .group(g)
        updateTabBar()
    }

    public func tabBar(_ tabBar: DockTabBarView, didInitiateTearOff tabIndex: Int, at screenPoint: NSPoint) {
        guard let child = childPanels[safe: tabIndex] else { return }
        delegate?.tabGroup(self, didDetachPanel: child.id, at: screenPoint)
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
            delegate?.tabGroup(self, didReceiveTab: tabInfo, at: children.count)

        case .left:
            let panelId = findChildId(byId: tabInfo.tabId) ?? tabInfo.tabId
            delegate?.tabGroup(self, wantsToSplit: .left, withPanelId: panelId)

        case .right:
            let panelId = findChildId(byId: tabInfo.tabId) ?? tabInfo.tabId
            delegate?.tabGroup(self, wantsToSplit: .right, withPanelId: panelId)

        case .top:
            let panelId = findChildId(byId: tabInfo.tabId) ?? tabInfo.tabId
            delegate?.tabGroup(self, wantsToSplit: .top, withPanelId: panelId)

        case .bottom:
            let panelId = findChildId(byId: tabInfo.tabId) ?? tabInfo.tabId
            delegate?.tabGroup(self, wantsToSplit: .bottom, withPanelId: panelId)
        }
    }

    private func findChildId(byId id: UUID) -> UUID? {
        // Check if the ID matches one of our children
        if childPanels.contains(where: { $0.id == id }) {
            return id
        }
        // ID might be from another group - delegate will handle
        return nil
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
