import AppKit

/// Root NSView for DockTabGroupViewController. Installs a local scroll-event
/// monitor so plain two-finger horizontal swipes are intercepted before they
/// can be consumed by content subviews (webviews, terminals, scroll views),
/// mirroring the approach `DockStageContainerView` uses for Shift-swipes.
///
/// Shift-held swipes are always passed through so the enclosing stage
/// container can handle them. Events are also passed through when a nested
/// swipeable carousel (another tab group or stage container) sits under the
/// mouse, so the innermost carousel handles the gesture first and bubbles
/// up when it reaches its edge.
final class DockTabGroupRootView: NSView {
    weak var controller: DockTabGroupViewController?

    private var scrollEventMonitor: Any?
    private var isInterceptingHorizontalGesture = false

    deinit {
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupScrollEventMonitor()
        } else if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
            isInterceptingHorizontalGesture = false
        }
    }

    private func setupScrollEventMonitor() {
        guard scrollEventMonitor == nil else { return }

        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }

            // Window-scope guard — never react to events targeted at other windows.
            guard let eventWindow = event.window, eventWindow == self.window else { return event }

            // If we already own an in-progress gesture, route every subsequent event
            // to our controller regardless of where the cursor has moved, what
            // modifiers are held, or whether a nested swipeable now sits under the
            // cursor. The pin releases on .ended / .cancelled / momentum-end below.
            if self.isInterceptingHorizontalGesture {
                if let controller = self.controller {
                    _ = controller.handleCarouselScroll(event)
                }
                if event.phase == .ended || event.phase == .cancelled ||
                   event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    self.isInterceptingHorizontalGesture = false
                }
                return nil
            }

            // Capture-decision gates: only used to decide whether a *new* gesture
            // should be owned by this monitor. Once owned (above), they no longer apply.
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInSelf) else { return event }

            // Shift belongs to stage navigation — let it pass so the stage container's
            // monitor can handle it.
            if event.modifierFlags.contains(.shift) {
                return event
            }

            // If there's a nested swipeable carousel under the mouse, let it handle
            // first. The innermost carousel will bubble back up to us when at its edge.
            if self.hasNestedSwipeableAt(point: locationInSelf) {
                return event
            }

            // Only trackpad gesture events (ignore legacy mouse wheel ticks)
            let isGestureEvent = event.phase != [] || event.momentumPhase != []
            guard isGestureEvent else { return event }

            // Decide horizontal-dominance once per gesture at .began. Once set, the
            // short-circuit at the top of the closure takes over for the rest of
            // the gesture.
            if event.phase == .began {
                let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.5
                if isHorizontalDominant {
                    self.isInterceptingHorizontalGesture = true
                    if let controller = self.controller {
                        _ = controller.handleCarouselScroll(event)
                    }
                    return nil
                }
            }

            return event
        }
    }

    /// Returns true if there is a nested swipeable carousel (another tab group
    /// or a stage container) at the given point in our coordinates.
    private func hasNestedSwipeableAt(point: NSPoint) -> Bool {
        return findNestedSwipeableAt(point: point, in: self) != nil
    }

    private func findNestedSwipeableAt(point: NSPoint, in view: NSView) -> NSView? {
        for subview in view.subviews {
            let pointInSubview = subview.convert(point, from: self)
            guard subview.bounds.contains(pointInSubview) else { continue }

            if let nested = subview as? DockTabGroupRootView, nested !== self {
                return nested
            }
            if subview is DockStageContainerView {
                return subview
            }

            if let found = findNestedSwipeableAt(point: point, in: subview) {
                return found
            }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Fallback path — most plain swipes are caught by the monitor above.
        // This only fires for events that bypass the monitor (e.g., synthesized
        // events) or land here via responder chain propagation.
        if event.modifierFlags.contains(.shift) {
            super.scrollWheel(with: event)
            return
        }
        if let controller = controller, controller.handleCarouselScroll(event) {
            return
        }
        super.scrollWheel(with: event)
    }
}

/// Delegate for tab group events
public protocol DockTabGroupViewControllerDelegate: AnyObject {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didDetachPanel panelId: UUID, at screenPoint: NSPoint)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didReceiveTab tabInfo: DockTabDragInfo, at index: Int)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didClosePanel panelId: UUID)
    func tabGroup(_ tabGroup: DockTabGroupViewController, didCloseLastPanel: Bool)
    func tabGroup(_ tabGroup: DockTabGroupViewController, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID)
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController)

    /// User clicked the close button on a tab. This is a **proposal** — the delegate
    /// decides whether to actually close. Default: calls removeTab on the tab group.
    func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestClosePanel panelId: UUID, at index: Int)

    /// User clicked the "+" button. This is a **proposal** — the delegate decides
    /// whether to create a new panel. Default: no-op.
    func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestNewPanelIn groupId: UUID)

    /// During drag: can this panel be dropped in this group/zone?
    /// Must be fast (called on every mouse move). Return false to hide the drop zone.
    func tabGroup(_ tabGroup: DockTabGroupViewController, canAcceptPanel panelId: UUID, at zone: DockDropZone) -> Bool

    /// Tab was reordered within this group (drag within the same tab bar).
    func tabGroupDidReorderTab(_ tabGroup: DockTabGroupViewController)
}

/// Optional delegate methods
public extension DockTabGroupViewControllerDelegate {
    func tabGroup(_ tabGroup: DockTabGroupViewController, didClosePanel panelId: UUID) {}
    func tabGroupDidRequestNewTab(_ tabGroup: DockTabGroupViewController) {}
    func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestClosePanel panelId: UUID, at index: Int) {
        tabGroup.removeTab(at: index)
    }
    func tabGroup(_ tabGroup: DockTabGroupViewController, didRequestNewPanelIn groupId: UUID) {}
    func tabGroup(_ tabGroup: DockTabGroupViewController, canAcceptPanel panelId: UUID, at zone: DockDropZone) -> Bool { true }
    func tabGroupDidReorderTab(_ tabGroup: DockTabGroupViewController) {}
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
///
/// Tab contents are laid out side-by-side inside a clip view so that
/// two-finger horizontal swipes produce the same interactive carousel animation
/// as the stage container. At the edge, the swipe bubbles up to
/// `swipeGestureDelegate` (typically a parent stage container).
public class DockTabGroupViewController: NSViewController, DockStageReconcilable {
    public weak var delegate: DockTabGroupViewControllerDelegate?

    /// The panel group this controller represents (a Panel with .group content)
    public private(set) var panel: Panel

    /// Callback to resolve a panel ID to a DockablePanel instance
    /// The host app provides this to supply actual view controllers for content panels
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        didSet { tabBar?.panelProvider = panelProvider }
    }

    /// Parent swipeable carousel — receives bubbled events when this tab group
    /// reaches its edge. Typically set by the enclosing `DockStageContainerView`
    /// or `DockSplitViewController`.
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet { carousel.swipeGestureDelegate = swipeGestureDelegate }
    }

    /// Local cache of resolved DockablePanel instances, keyed by panel ID
    private var resolvedPanels: [UUID: any DockablePanel] = [:]

    /// The tab bar
    private var tabBar: DockTabBarView!

    /// Tab bar height constraint (varies based on group style)
    private var tabBarHeightConstraint: NSLayoutConstraint!

    /// Clip view that masks the sliding content.
    private var clipView: NSView!

    /// Sliding content view, width = clipView.width * tabCount.
    private var contentView: NSView!

    /// Leading constraint on contentView (animated by the swipe engine).
    private var contentLeadingConstraint: NSLayoutConstraint!

    /// Width constraint on contentView (multiplied by tab count).
    private var contentWidthConstraint: NSLayoutConstraint?

    /// Per-tab wrapper views laid out side-by-side inside `contentView`.
    private var tabContentViews: [UUID: NSView] = [:]

    /// Cached view controllers per tab panel ID.
    private var tabViewControllers: [UUID: NSViewController] = [:]

    /// Drop overlay for split drop zones
    private var dropOverlay: DockDropOverlayView?

    /// Whether drop overlay is visible
    private var isShowingDropOverlay = false

    /// KVO observation for first responder changes
    private var firstResponderObservation: NSKeyValueObservation?

    /// The swipe carousel gesture engine.
    private let carousel = SwipeCarouselGesture()

    public init(panel: Panel = Panel(content: .group(PanelGroup(style: .tabs)))) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.panel = Panel(content: .group(PanelGroup(style: .tabs)))
        super.init(coder: coder)
    }

    public override func loadView() {
        let root = DockTabGroupRootView()
        root.controller = self
        root.wantsLayer = true
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupCarousel()
        setupDragNotifications()
        rebuildTabContent()
        updateTabBar()
    }

    private func setupDragNotifications() {
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
        if let dragInfo = notification.userInfo?["dragInfo"] as? DockTabDragInfo {
            if dragInfo.sourceGroupId == panel.id && childPanels.count == 1 {
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

    public var group: PanelGroup? {
        get { panel.group }
        set {
            if let newValue = newValue {
                panel.content = .group(newValue)
            }
        }
    }

    public var childPanels: [Panel] {
        get { group?.children ?? [] }
    }

    public var activeIndex: Int {
        get { group?.activeIndex ?? 0 }
        set {
            guard case .group(var g) = panel.content else { return }
            g.activeIndex = newValue
            panel.content = .group(g)
        }
    }

    public var activeChild: Panel? {
        group?.activeChild
    }

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
        tabBar.panelProvider = panelProvider
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        // Clip view below tab bar masks the sliding content
        clipView = NSView()
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        clipView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clipView)

        // Sliding content view inside the clip view
        contentView = NSView()
        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(contentView)

        contentLeadingConstraint = contentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: heightForGroupStyle(groupStyle))

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeightConstraint,

            clipView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            clipView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
            contentLeadingConstraint
        ])

        // Setup drop overlay
        dropOverlay = DockDropOverlayView()
        dropOverlay?.delegate = self
        dropOverlay?.canAcceptPanel = { [weak self] panelId, zone in
            guard let self = self else { return true }
            return self.delegate?.tabGroup(self, canAcceptPanel: panelId, at: zone) ?? true
        }
        dropOverlay?.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay?.isHidden = true
        if let overlay = dropOverlay {
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: clipView.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: clipView.bottomAnchor)
            ])
        }
    }

    private func setupCarousel() {
        carousel.clipView = clipView
        carousel.contentView = contentView
        carousel.leadingConstraint = contentLeadingConstraint
        carousel.source = view
        carousel.positionCount = { [weak self] in self?.childPanels.count ?? 0 }
        carousel.activePosition = { [weak self] in self?.activeIndex ?? 0 }
        carousel.didCommitPosition = { [weak self] newIndex in
            self?.commitActiveIndex(newIndex)
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        setupFocusTracking()
        focusPanelContent()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutTabContentViews()
    }

    // MARK: - Focus Management

    public func focusPanelContent() {
        guard let window = view.window,
              let activeChild = activeChild,
              let dockablePanel = resolvePanel(for: activeChild.id),
              let responder = dockablePanel.preferredFirstResponder else {
            return
        }
        DispatchQueue.main.async {
            window.makeFirstResponder(responder)
        }
    }

    private func setupFocusTracking() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil

        guard let window = view.window else {
            tabBar.setFocused(false)
            return
        }

        firstResponderObservation = window.observe(\.firstResponder, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateFocusIndicator()
            }
        }

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
        let isWindowKey = window.isKeyWindow
        let hasFocus = isWindowKey && isFirstResponderInContent(window.firstResponder)
        tabBar.setFocused(hasFocus)
    }

    private func isFirstResponderInContent(_ responder: NSResponder?) -> Bool {
        guard let responderView = responder as? NSView else { return false }
        var current: NSView? = responderView
        while let v = current {
            if v === clipView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Panel Resolution

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

    private func evictPanel(for panelId: UUID) {
        resolvedPanels.removeValue(forKey: panelId)
    }

    // MARK: - Public API

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

        rebuildTabContent()
        updateTabBar()
        if activate {
            selectTab(at: childPanels.count - 1)
        }
    }

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

        rebuildTabContent()
        updateTabBar()
        if activate {
            selectTab(at: clampedIndex)
        }
    }

    @discardableResult
    public func removeTab(at index: Int) -> Panel? {
        guard case .group(var g) = panel.content,
              index >= 0 && index < g.children.count else { return nil }

        let removedChild = g.children.remove(at: index)

        if g.activeIndex >= g.children.count {
            g.activeIndex = max(0, g.children.count - 1)
        }
        panel.content = .group(g)

        delegate?.tabGroup(self, didClosePanel: removedChild.id)
        resolvePanel(for: removedChild.id)?.panelDidResignActive()
        evictPanel(for: removedChild.id)

        rebuildTabContent()
        updateTabBar()

        if childPanels.isEmpty {
            delegate?.tabGroup(self, didCloseLastPanel: true)
        }

        return removedChild
    }

    @discardableResult
    public func removeTab(withId id: UUID) -> Panel? {
        guard let index = childPanels.firstIndex(where: { $0.id == id }) else { return nil }
        return removeTab(at: index)
    }

    /// Select a tab by index. Animates the carousel to the new position; model
    /// and tab-bar state are updated by `commitActiveIndex` via the engine callback.
    public func selectTab(at index: Int) {
        guard index >= 0, index < childPanels.count else { return }
        guard index != activeIndex else { return }
        carousel.animateToPosition(index)
    }

    public var activeTab: Panel? {
        activeChild
    }

    public func showDropOverlay(_ show: Bool) {
        isShowingDropOverlay = show
        dropOverlay?.isHidden = !show
    }

    // MARK: - Scroll Routing

    /// Called by the root view's scrollWheel override.
    ///
    /// Always forwarded to the carousel engine — even for a single-tab group.
    /// With only one position the engine treats any swipe as "past the edge"
    /// and bubbles to `swipeGestureDelegate` (typically the enclosing stage
    /// container), so a lone tab still rolls directly into a stage swipe.
    @discardableResult
    func handleCarouselScroll(_ event: NSEvent) -> Bool {
        return carousel.handleScrollWheel(event)
    }

    // MARK: - Carousel callbacks

    private func commitActiveIndex(_ newIndex: Int) {
        guard case .group(var g) = panel.content,
              newIndex >= 0 && newIndex < g.children.count else { return }

        // If called from a swipe (not explicit selectTab), notify old tab
        let oldIndex = g.activeIndex
        if oldIndex != newIndex, let oldChild = g.activeChild {
            resolvePanel(for: oldChild.id)?.panelDidResignActive()
        }

        g.activeIndex = newIndex
        panel.content = .group(g)
        tabBar.selectTab(at: newIndex)

        if let newChild = group?.activeChild {
            resolvePanel(for: newChild.id)?.panelDidBecomeActive()
        }
        focusPanelContent()
    }

    // MARK: - Reconciliation Support

    /// Apply a new Panel in place. Keeps wrapper views + content VCs; only
    /// diffs the tab children, style, and active index. No-op for identical
    /// panels. See `DockStageReconcilable`.
    public func reconcile(newPanel: Panel) {
        guard case .group(let newGroup) = newPanel.content else { return }

        reconcileTabs(with: newGroup.children, panelProvider: { [weak self] id in
            self?.panelProvider?(id)
        })

        if newGroup.style != self.groupStyle {
            setGroupStyle(newGroup.style)
        }

        let targetIndex = newGroup.activeIndex
        if targetIndex >= 0, targetIndex < childPanels.count, targetIndex != activeIndex {
            selectTab(at: targetIndex)
        }
    }

    public func reconcileTabs(with targetChildren: [Panel], panelProvider: ((UUID) -> (any DockablePanel)?)?) {
        guard case .group(var g) = panel.content else { return }

        let currentIds = Set(g.children.map { $0.id })
        let targetIds = Set(targetChildren.map { $0.id })

        let toRemove = currentIds.subtracting(targetIds)
        for panelId in toRemove {
            _ = removeTab(withId: panelId)
        }

        guard case .group(var g2) = panel.content else { return }

        for (targetIndex, targetChild) in targetChildren.enumerated() {
            if let existingIndex = g2.children.firstIndex(where: { $0.id == targetChild.id }) {
                if existingIndex != targetIndex && targetIndex < g2.children.count {
                    let moved = g2.children.remove(at: existingIndex)
                    g2.children.insert(moved, at: targetIndex)
                }
                let actualIndex = min(targetIndex, g2.children.count - 1)
                if actualIndex >= 0 && actualIndex < g2.children.count {
                    g2.children[actualIndex].title = targetChild.title
                    g2.children[actualIndex].iconName = targetChild.iconName
                    g2.children[actualIndex].cargo = targetChild.cargo
                }
            } else {
                var newChild = targetChild
                if case .content = newChild.content {} else {
                    newChild.content = .content
                }
                let clampedIndex = min(targetIndex, g2.children.count)
                g2.children.insert(newChild, at: clampedIndex)

                if let resolved = panelProvider?(targetChild.id) {
                    resolvedPanels[targetChild.id] = resolved
                }
            }
        }

        panel.content = .group(g2)
        rebuildTabContent()
        updateTabBar()
    }

    public func insertChildPanel(_ childPanel: Panel, at index: Int, dockablePanel: (any DockablePanel)? = nil, activate: Bool = true) {
        guard case .group(var g) = panel.content else { return }

        let clampedIndex = max(0, min(index, g.children.count))
        g.children.insert(childPanel, at: clampedIndex)
        panel.content = .group(g)

        if let dp = dockablePanel {
            resolvedPanels[childPanel.id] = dp
        }

        rebuildTabContent()
        updateTabBar()
        if activate {
            selectTab(at: min(clampedIndex, childPanels.count - 1))
        }
    }

    public func activateTab(at index: Int) {
        selectTab(at: index)
    }

    public func setGroupStyle(_ style: PanelGroupStyle) {
        guard case .group(var g) = panel.content else { return }
        g.style = style
        panel.content = .group(g)
        updateTabBar()
    }

    // MARK: - Tab Content Layout

    /// Rebuild the side-by-side layout of per-tab content views and VCs.
    /// Called on initial load and whenever the tab set changes.
    private func rebuildTabContent() {
        let children = childPanels
        let presentIds = Set(children.map { $0.id })

        // Remove views/VCs for panels no longer present
        for (id, wrapper) in tabContentViews where !presentIds.contains(id) {
            wrapper.removeFromSuperview()
            tabContentViews.removeValue(forKey: id)
        }
        for (id, vc) in tabViewControllers where !presentIds.contains(id) {
            if vc.parent === self { vc.removeFromParent() }
            if vc.view.superview != nil { vc.view.removeFromSuperview() }
            tabViewControllers.removeValue(forKey: id)
        }

        // Ensure a wrapper + VC exists for each current panel
        for childPanel in children {
            if tabContentViews[childPanel.id] == nil {
                let wrapper = NSView()
                wrapper.wantsLayer = true
                wrapper.translatesAutoresizingMaskIntoConstraints = true
                contentView.addSubview(wrapper)
                tabContentViews[childPanel.id] = wrapper
            }
            if tabViewControllers[childPanel.id] == nil,
               let wrapper = tabContentViews[childPanel.id],
               let dockablePanel = resolvePanel(for: childPanel.id) {
                let vc = dockablePanel.panelViewController

                // Detach from any previous parent
                if vc.parent != nil {
                    vc.view.removeFromSuperview()
                    vc.removeFromParent()
                }
                addChild(vc)
                vc.view.translatesAutoresizingMaskIntoConstraints = false
                wrapper.addSubview(vc.view)
                NSLayoutConstraint.activate([
                    vc.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
                    vc.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                    vc.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                    vc.view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
                ])
                tabViewControllers[childPanel.id] = vc
            }
        }

        // Content view width = N * clip width
        contentWidthConstraint?.isActive = false
        contentWidthConstraint = nil
        if !children.isEmpty {
            contentWidthConstraint = contentView.widthAnchor.constraint(
                equalTo: clipView.widthAnchor,
                multiplier: CGFloat(max(1, children.count))
            )
            contentWidthConstraint?.isActive = true
        }

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        layoutTabContentViews()
    }

    /// Position tab wrapper views inside contentView (frame-based horizontal stack).
    private func layoutTabContentViews() {
        let children = childPanels
        let width = clipView.bounds.width
        let height = clipView.bounds.height
        guard width > 0, height > 0 else { return }

        for (index, child) in children.enumerated() {
            guard let wrapper = tabContentViews[child.id] else { continue }
            wrapper.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }

        // Re-anchor leading constraint if not actively animating
        carousel.updateContentPositionIfNeeded()
    }

    // MARK: - Private

    private func updateTabBar() {
        let tabPanels = childPanels
        let currentActiveIndex = activeIndex
        let style = groupStyle
        tabBar.setTabs(tabPanels, selectedIndex: currentActiveIndex, groupStyle: style)

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
}

// MARK: - SwipeGestureDelegate (to forward bubbled events from nested carousels)

extension DockTabGroupViewController: SwipeGestureDelegate {
    public func handleBubbledScrollEvent(_ event: NSEvent, from source: NSView) -> Bool {
        return carousel.handleBubbledScrollEvent(event)
    }

    public func nestedContainerDidEndGesture(_ source: NSView) {
        carousel.nestedDidEnd()
    }
}

// MARK: - DockTabBarViewDelegate

extension DockTabGroupViewController: DockTabBarViewDelegate {
    public func tabBar(_ tabBar: DockTabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    public func tabBar(_ tabBar: DockTabBarView, didCloseTabAt index: Int) {
        guard case .group(let g) = panel.content,
              index >= 0 && index < g.children.count else { return }
        let panelId = g.children[index].id
        delegate?.tabGroup(self, didRequestClosePanel: panelId, at: index)
    }

    public func tabBar(_ tabBar: DockTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int) {
        guard case .group(var g) = panel.content,
              fromIndex >= 0 && fromIndex < g.children.count,
              toIndex >= 0 && toIndex <= g.children.count else { return }

        let child = g.children.remove(at: fromIndex)
        let insertIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        g.children.insert(child, at: insertIndex)

        if g.activeIndex == fromIndex {
            g.activeIndex = insertIndex
        } else if fromIndex < g.activeIndex && toIndex > g.activeIndex {
            g.activeIndex -= 1
        } else if fromIndex > g.activeIndex && toIndex <= g.activeIndex {
            g.activeIndex += 1
        }

        panel.content = .group(g)
        rebuildTabContent()
        updateTabBar()
        delegate?.tabGroupDidReorderTab(self)
    }

    public func tabBar(_ tabBar: DockTabBarView, didInitiateTearOff tabIndex: Int, at screenPoint: NSPoint) {
        guard let child = childPanels[safe: tabIndex] else { return }
        delegate?.tabGroup(self, didDetachPanel: child.id, at: screenPoint)
    }

    public func tabBar(_ tabBar: DockTabBarView, didReceiveDroppedTab tabInfo: DockTabDragInfo, at index: Int) {
        delegate?.tabGroup(self, didReceiveTab: tabInfo, at: index)
    }

    public func tabBarDidRequestNewTab(_ tabBar: DockTabBarView) {
        delegate?.tabGroup(self, didRequestNewPanelIn: panel.id)
    }
}

// MARK: - DockDropOverlayViewDelegate

extension DockTabGroupViewController: DockDropOverlayViewDelegate {
    public func dropOverlay(_ overlay: DockDropOverlayView, didSelectZone zone: DockDropZone, withTab tabInfo: DockTabDragInfo) {
        switch zone {
        case .center:
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
        if childPanels.contains(where: { $0.id == id }) {
            return id
        }
        return nil
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
