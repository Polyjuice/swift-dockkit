import AppKit

/// Custom pasteboard type for tab dragging
public extension NSPasteboard.PasteboardType {
    static let dockTab = NSPasteboard.PasteboardType("com.dockkit.dock.tab")
}

/// Delegate for DockTabBarView events
public protocol DockTabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: DockTabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: DockTabBarView, didCloseTabAt index: Int)
    func tabBar(_ tabBar: DockTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int)
    func tabBar(_ tabBar: DockTabBarView, didInitiateTearOff tabIndex: Int, at screenPoint: NSPoint)
    func tabBar(_ tabBar: DockTabBarView, didReceiveDroppedTab tabInfo: DockTabDragInfo, at index: Int)
    /// User clicked a "+" button. `actionId` is the id of the tapped `PanelAddAction`,
    /// or nil for the default single-button case (no addActions configured).
    func tabBar(_ tabBar: DockTabBarView, didRequestNewTabWith actionId: String?)
}

/// Optional delegate methods
public extension DockTabBarViewDelegate {
    func tabBar(_ tabBar: DockTabBarView, didRequestNewTabWith actionId: String?) {}
}

/// NSButton that carries a `PanelAddAction.id` so the click handler can
/// identify which "+" button the user pressed. `actionId == nil` means the
/// default/legacy single-button case.
public final class AddActionButton: NSButton {
    public var actionId: String?
}

/// Information about a tab being dragged
public struct DockTabDragInfo: Codable {
    public let tabId: UUID
    public let sourceGroupId: UUID
    public let title: String
    public let iconName: String?

    public init(tabId: UUID, sourceGroupId: UUID, title: String, iconName: String?) {
        self.tabId = tabId
        self.sourceGroupId = sourceGroupId
        self.title = title
        self.iconName = iconName
    }
}

/// A draggable, closable tab bar with tear-off support
public class DockTabBarView: NSView, NSDraggingSource {
    public weak var delegate: DockTabBarViewDelegate?

    /// Identifier of the tab group this bar belongs to
    public var groupId: UUID = UUID()

    /// Group style - tabs, thumbnails, or custom
    public var groupStyle: PanelGroupStyle = .tabs {
        didSet {
            if groupStyle != oldValue {
                rebuildForGroupStyle()
            }
        }
    }

    /// Panel provider for resolving DockablePanel instances (used by thumbnail buttons)
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    private var panels: [Panel] = []
    private var selectedIndex: Int = 0
    private var tabButtons: [DockTabButton] = []
    private var thumbnailButtons: [DockThumbnailButton] = []
    private var customTabViews: [DockTabView] = []
    /// Panel IDs in the same order as `customTabViews`. The DockTabView protocol
    /// doesn't expose the panel, so we track identity ourselves to enable reuse.
    private var customTabPanelIds: [UUID] = []
    private var stackView: NSStackView!
    /// Container for one or more "+" buttons pinned to the trailing edge.
    private var addButtonStack: NSStackView!
    /// Current "+" button views (in order). Subviews of `addButtonStack`.
    private var addButtonViews: [NSView] = []
    /// Last-seen add actions, used to diff in `setTabs` so we only rebuild
    /// the stack when the configuration actually changes.
    private var addActions: [PanelAddAction] = []

    // Drag state
    private var draggedTabIndex: Int?
    private var dragStartPoint: NSPoint?
    private var dragStartScreenY: CGFloat?  // Screen Y when drag started
    private var isDraggingOut: Bool = false
    private var dropIndicatorView: NSView?
    private var dropInsertionIndex: Int?

    // Tear-off threshold in pixels - must drag this far vertically to tear off
    private let tearOffThreshold: CGFloat = 40

    // Configuration
    public var showAddButton: Bool = true {
        didSet { addButtonStack?.isHidden = !showAddButton }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupDragAndDrop()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupDragAndDrop()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        applyBarBackground()

        // Stack view for tab buttons (no scroll view - simpler)
        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Container for one or more "+" buttons
        addButtonStack = NSStackView()
        addButtonStack.orientation = .horizontal
        addButtonStack.spacing = 2
        addButtonStack.distribution = .fill
        addButtonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButtonStack)

        NSLayoutConstraint.activate([
            // Stack view takes left side
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: addButtonStack.leadingAnchor, constant: -4),

            // Add button stack pinned to trailing edge
            addButtonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButtonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButtonStack.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Start with the default single "+" button (legacy behavior).
        rebuildAddButtons(actions: [], renderer: nil)

        // Setup drop indicator
        dropIndicatorView = NSView()
        dropIndicatorView?.wantsLayer = true
        dropIndicatorView?.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView?.isHidden = true
        addSubview(dropIndicatorView!)
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([.dockTab])
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBarBackground()
    }

    /// CGColor freezes the dynamic windowBackgroundColor at the moment of
    /// assignment, so we re-resolve whenever the host's appearance changes.
    private func applyBarBackground() {
        var cg: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = NSColor.windowBackgroundColor.cgColor
        }
        layer?.backgroundColor = cg
    }

    // MARK: - Public API

    public func setTabs(_ newPanels: [Panel], selectedIndex: Int, groupStyle newStyle: PanelGroupStyle = .tabs, addActions newAddActions: [PanelAddAction] = []) {
        let previousPanels = self.panels
        self.panels = newPanels
        self.selectedIndex = max(0, min(selectedIndex, newPanels.count - 1))

        let actionsChanged = newAddActions != self.addActions
        self.addActions = newAddActions

        // Style change crosses view-collection families (tab buttons / thumbnails / custom),
        // which can't reuse each other. Fall through to full rebuild via groupStyle's didSet.
        if newStyle != self.groupStyle {
            self.groupStyle = newStyle
            // groupStyle's didSet rebuilt everything (including add buttons).
            return
        }

        // Same style — reconcile so existing views survive structural changes
        // (close one tab → only that view goes; siblings stay put, no flicker).
        reconcileForGroupStyle(previousPanels: previousPanels)

        if actionsChanged {
            rebuildAddButtons(actions: addActions, renderer: DockKit.customTabRenderer)
        }
    }

    /// Incremental update path: reuse existing views by panel ID, only add/remove
    /// what actually changed, then reorder the stack arrangement to match.
    private func reconcileForGroupStyle(previousPanels: [Panel]) {
        DockDiagnostics.counters.bump("tabReconcile")

        switch groupStyle {
        case .tabs, .split, .stages:
            if DockKit.customTabRenderer != nil {
                reconcileCustomTabViews(previousPanels: previousPanels)
            } else {
                reconcileStandardTabButtons(previousPanels: previousPanels)
            }
        case .thumbnails:
            reconcileThumbnailButtons(previousPanels: previousPanels)
        }
    }

    /// Rebuild the view based on current group style
    private func rebuildForGroupStyle() {
        DockDiagnostics.counters.bump("tabRebuild")

        // Determine effective style - fall back to tabs if custom renderer not registered
        let effectiveStyle: PanelGroupStyle
        if DockKit.customTabRenderer != nil {
            effectiveStyle = groupStyle
        } else {
            effectiveStyle = groupStyle
        }

        switch effectiveStyle {
        case .tabs, .split, .stages:
            if DockKit.customTabRenderer != nil {
                rebuildCustomTabViews()
            } else {
                rebuildTabButtons()
            }
        case .thumbnails:
            rebuildThumbnailButtons()
        }
    }

    public func selectTab(at index: Int) {
        guard index >= 0 && index < panels.count else { return }
        selectedIndex = index
        updateSelectionState()
    }

    public func updateTab(at index: Int, title: String? = nil) {
        guard index >= 0 && index < panels.count else { return }
        if let title = title {
            panels[index].title = title
        }
        tabButtons[safe: index]?.update(with: panels[index], isSelected: index == selectedIndex)
    }

    /// Update focus state - shows focus indicator on the selected tab
    public func setFocused(_ focused: Bool) {
        let effectiveStyle = groupStyle
        switch effectiveStyle {
        case .tabs, .split, .stages:
            if DockKit.customTabRenderer != nil {
                let renderer = DockKit.customTabRenderer!
                for (index, view) in customTabViews.enumerated() {
                    renderer.setFocused(focused && index == selectedIndex, on: view)
                }
            } else {
                for (index, button) in tabButtons.enumerated() {
                    button.setFocused(focused && index == selectedIndex)
                }
            }
        case .thumbnails:
            for (index, button) in thumbnailButtons.enumerated() {
                button.setFocused(focused && index == selectedIndex)
            }
        }
    }

    // MARK: - Private

    private func clearAllTabViews() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        thumbnailButtons.forEach { $0.removeFromSuperview() }
        thumbnailButtons.removeAll()
        customTabViews.forEach { $0.removeFromSuperview() }
        customTabViews.removeAll()
        customTabPanelIds.removeAll()
    }

    // MARK: - Incremental reconciliation

    private func reconcileStandardTabButtons(previousPanels: [Panel]) {
        // If the other style families have leftover views, drop them.
        thumbnailButtons.forEach { $0.removeFromSuperview() }
        thumbnailButtons.removeAll()
        customTabViews.forEach { $0.removeFromSuperview() }
        customTabViews.removeAll()
        customTabPanelIds.removeAll()

        let newIds = panels.map { $0.id }
        let newIdSet = Set(newIds)

        // Index existing buttons by panel ID
        var byId: [UUID: DockTabButton] = [:]
        for btn in tabButtons { byId[btn.panelId] = btn }

        // Drop buttons whose IDs are gone
        for btn in tabButtons where !newIdSet.contains(btn.panelId) {
            btn.removeFromSuperview()
        }

        // Build the new ordered list, reusing where possible
        var nextButtons: [DockTabButton] = []
        nextButtons.reserveCapacity(panels.count)
        for (index, panel) in panels.enumerated() {
            if let reused = byId[panel.id] {
                reused.update(with: panel, isSelected: index == selectedIndex)
                nextButtons.append(reused)
            } else {
                let button = DockTabButton(panel: panel, isSelected: index == selectedIndex)
                bindClosures(for: button, panelId: panel.id)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
                button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
                nextButtons.append(button)
            }
        }

        // Reorder stack arrangement without destroying reused views
        for btn in nextButtons where btn.superview === stackView {
            stackView.removeArrangedSubview(btn)
        }
        for btn in nextButtons {
            stackView.addArrangedSubview(btn)
        }

        tabButtons = nextButtons
        // Standard path: ensure built-in "+" buttons are visible (custom-renderer
        // remnants, if any, are cleared by `rebuildAddButtons`).
        rebuildAddButtons(actions: addActions, renderer: nil)
    }

    private func reconcileThumbnailButtons(previousPanels: [Panel]) {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        customTabViews.forEach { $0.removeFromSuperview() }
        customTabViews.removeAll()
        customTabPanelIds.removeAll()

        let newIds = panels.map { $0.id }
        let newIdSet = Set(newIds)

        var byId: [UUID: DockThumbnailButton] = [:]
        for btn in thumbnailButtons { byId[btn.panelId] = btn }

        for btn in thumbnailButtons where !newIdSet.contains(btn.panelId) {
            btn.removeFromSuperview()
        }

        var nextButtons: [DockThumbnailButton] = []
        nextButtons.reserveCapacity(panels.count)
        for (index, panel) in panels.enumerated() {
            if let reused = byId[panel.id] {
                reused.update(with: panel, isSelected: index == selectedIndex)
                nextButtons.append(reused)
            } else {
                let button = DockThumbnailButton(panel: panel, isSelected: index == selectedIndex, panelProvider: panelProvider)
                bindClosures(for: button, panelId: panel.id)
                button.widthAnchor.constraint(equalToConstant: 120).isActive = true
                nextButtons.append(button)
            }
        }

        for btn in nextButtons where btn.superview === stackView {
            stackView.removeArrangedSubview(btn)
        }
        for btn in nextButtons {
            stackView.addArrangedSubview(btn)
        }

        thumbnailButtons = nextButtons
        rebuildAddButtons(actions: addActions, renderer: nil)
    }

    private func reconcileCustomTabViews(previousPanels: [Panel]) {
        guard let renderer = DockKit.customTabRenderer else {
            // Renderer cleared between calls; fall back to standard path.
            reconcileStandardTabButtons(previousPanels: previousPanels)
            return
        }

        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        thumbnailButtons.forEach { $0.removeFromSuperview() }
        thumbnailButtons.removeAll()

        let newIds = panels.map { $0.id }
        let newIdSet = Set(newIds)

        var byId: [UUID: DockTabView] = [:]
        for (i, id) in customTabPanelIds.enumerated() where i < customTabViews.count {
            byId[id] = customTabViews[i]
        }

        for (i, id) in customTabPanelIds.enumerated() where !newIdSet.contains(id) && i < customTabViews.count {
            customTabViews[i].removeFromSuperview()
        }

        var nextViews: [DockTabView] = []
        var nextIds: [UUID] = []
        nextViews.reserveCapacity(panels.count)
        nextIds.reserveCapacity(panels.count)
        for (index, panel) in panels.enumerated() {
            if let reused = byId[panel.id] {
                renderer.updateTabView(reused, for: panel, isSelected: index == selectedIndex)
                nextViews.append(reused)
                nextIds.append(panel.id)
            } else {
                let view = renderer.createTabView(for: panel, isSelected: index == selectedIndex)
                bindClosures(for: view, panelId: panel.id)
                nextViews.append(view)
                nextIds.append(panel.id)
            }
        }

        for view in nextViews where view.superview === stackView {
            stackView.removeArrangedSubview(view)
        }
        for view in nextViews {
            stackView.addArrangedSubview(view)
        }

        customTabViews = nextViews
        customTabPanelIds = nextIds

        rebuildAddButtons(actions: addActions, renderer: renderer)
    }

    /// Bind tab event closures by panel ID, not index. A button stays bound to
    /// its panel even when siblings are inserted/removed/reordered around it.
    private func bindClosures(for view: DockTabView, panelId: UUID) {
        view.onSelect = { [weak self] in
            guard let self, let idx = self.indexOfPanel(panelId) else { return }
            self.handleTabSelected(at: idx)
        }
        view.onClose = { [weak self] in
            guard let self, let idx = self.indexOfPanel(panelId) else { return }
            self.handleTabClosed(at: idx)
        }
        view.onDragBegan = { [weak self] event in
            guard let self, let idx = self.indexOfPanel(panelId) else { return }
            self.handleDragBegan(at: idx, event: event)
        }
    }

    private func indexOfPanel(_ id: UUID) -> Int? {
        return panels.firstIndex(where: { $0.id == id })
    }

    private func rebuildTabButtons() {
        clearAllTabViews()

        // Create new buttons
        for (index, panel) in panels.enumerated() {
            let button = DockTabButton(panel: panel, isSelected: index == selectedIndex)
            bindClosures(for: button, panelId: panel.id)

            tabButtons.append(button)
            stackView.addArrangedSubview(button)

            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        }

        rebuildAddButtons(actions: addActions, renderer: nil)
    }

    private func rebuildThumbnailButtons() {
        clearAllTabViews()

        // Create thumbnail buttons
        for (index, panel) in panels.enumerated() {
            let button = DockThumbnailButton(panel: panel, isSelected: index == selectedIndex, panelProvider: panelProvider)
            bindClosures(for: button, panelId: panel.id)

            thumbnailButtons.append(button)
            stackView.addArrangedSubview(button)

            // Thumbnails have fixed width
            button.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }

        rebuildAddButtons(actions: addActions, renderer: nil)
    }

    private func rebuildCustomTabViews() {
        guard let renderer = DockKit.customTabRenderer else {
            // Should not happen - rebuildForGroupStyle checks this
            rebuildTabButtons()
            return
        }

        clearAllTabViews()

        // Create custom tab views
        for (index, panel) in panels.enumerated() {
            let view = renderer.createTabView(for: panel, isSelected: index == selectedIndex)
            bindClosures(for: view, panelId: panel.id)

            customTabViews.append(view)
            customTabPanelIds.append(panel.id)
            stackView.addArrangedSubview(view)
        }

        rebuildAddButtons(actions: addActions, renderer: renderer)
    }

    private func updateSelectionState() {
        let useCustom = DockKit.customTabRenderer != nil && (groupStyle == .tabs || groupStyle == .split || groupStyle == .stages)

        if useCustom {
            guard let renderer = DockKit.customTabRenderer else { return }
            for (index, view) in customTabViews.enumerated() {
                guard index < panels.count else { continue }
                renderer.updateTabView(view, for: panels[index], isSelected: index == selectedIndex)
            }
        } else if groupStyle == .thumbnails {
            for (index, button) in thumbnailButtons.enumerated() {
                guard index < panels.count else { continue }
                button.update(with: panels[index], isSelected: index == selectedIndex)
            }
        } else {
            for (index, button) in tabButtons.enumerated() {
                guard index < panels.count else { continue }
                button.update(with: panels[index], isSelected: index == selectedIndex)
            }
        }
    }

    private func handleTabSelected(at index: Int) {
        selectedIndex = index
        updateSelectionState()
        delegate?.tabBar(self, didSelectTabAt: index)
    }

    private func handleTabClosed(at index: Int) {
        delegate?.tabBar(self, didCloseTabAt: index)
    }

    @objc private func addButtonClicked(_ sender: NSButton) {
        let actionId = (sender as? AddActionButton)?.actionId
        delegate?.tabBar(self, didRequestNewTabWith: actionId)
    }

    /// Rebuild the trailing-edge "+" buttons. Empty `actions` renders the
    /// default single "+" button (legacy behavior). When a custom renderer is
    /// supplied, each button is created via `renderer.createAddButton(for:)`;
    /// otherwise built-in `AddActionButton` instances are used.
    private func rebuildAddButtons(actions: [PanelAddAction], renderer: DockTabRenderer?) {
        for view in addButtonViews {
            (addButtonStack?.arrangedSubviews.contains(view) ?? false ? addButtonStack : nil)?
                .removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        addButtonViews.removeAll()

        let effectiveActions: [PanelAddAction?] = actions.isEmpty ? [nil] : actions.map { Optional($0) }

        for action in effectiveActions {
            let view: NSView
            if let renderer = renderer {
                view = renderer.createAddButton(for: action) ?? makeBuiltInAddButton(for: action)
            } else {
                view = makeBuiltInAddButton(for: action)
            }
            addButtonStack.addArrangedSubview(view)
            addButtonViews.append(view)
        }

        addButtonStack.isHidden = !showAddButton
    }

    private func makeBuiltInAddButton(for action: PanelAddAction?) -> NSView {
        let symbol = action?.iconName ?? "plus"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: action?.tooltip ?? "New Tab")
            ?? NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!
        let button = AddActionButton(image: image, target: self, action: #selector(addButtonClicked(_:)))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.actionId = action?.id
        if let tooltip = action?.tooltip { button.toolTip = tooltip }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: - Drag Initiation

    private func handleDragBegan(at index: Int, event: NSEvent) {
        draggedTabIndex = index
        dragStartPoint = event.locationInWindow
        isDraggingOut = false

        // Record screen Y for tear-off detection
        if let window = self.window {
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            dragStartScreenY = screenPoint.y
        }

        guard let panel = panels[safe: index] else { return }

        // Create drag image
        let dragImage = createDragImage(for: panel)

        // Create pasteboard item
        let dragInfo = DockTabDragInfo(
            tabId: panel.id,
            sourceGroupId: groupId,
            title: panel.title ?? "Untitled",
            iconName: panel.iconName
        )

        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(dragInfo) {
            pasteboardItem.setData(data, forType: .dockTab)
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let views = activeTabViews
        let frame = index < views.count ? views[index].frame : CGRect(x: 0, y: 0, width: 100, height: 28)
        draggingItem.setDraggingFrame(frame, contents: dragImage)

        // Post notification that drag has begun so drop overlays can show
        // Include the drag info so overlays can decide whether to show
        NotificationCenter.default.post(name: .dockDragBegan, object: nil, userInfo: ["dragInfo": dragInfo])

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func createDragImage(for panel: Panel) -> NSImage {
        // Get the actual tab view to use for drag image
        let views = activeTabViews
        if let index = panels.firstIndex(where: { $0.id == panel.id }),
           index < views.count {
            let view = views[index]
            // Create image from the actual view at screen resolution
            guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return createFallbackDragImage(for: panel)
            }
            view.cacheDisplay(in: view.bounds, to: bitmapRep)

            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmapRep)
            return image
        }
        return createFallbackDragImage(for: panel)
    }

    private func createFallbackDragImage(for panel: Panel) -> NSImage {
        // Fallback if we can't capture the actual view
        let size = NSSize(width: 150, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw background
        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw icon
        if let iconName = panel.iconName,
           let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: 8, y: 7, width: 14, height: 14))
        }

        // Draw title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let titleRect = NSRect(x: 28, y: 7, width: 110, height: 14)
        let title = panel.title ?? "Untitled"
        (title as NSString).draw(in: titleRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }

    // MARK: - NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? [.move, .copy] : []
    }

    public func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let startY = dragStartScreenY else { return }

        // Track if we've moved far enough to potentially tear off
        // We don't create a window here - just track the state for endDrag
        let verticalDistance = abs(screenPoint.y - startY)
        if verticalDistance > tearOffThreshold && !isDraggingOut {
            isDraggingOut = true
            // Disable snap-back animation once we're outside the threshold
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Post notification that drag has ended so drop overlays can hide
        NotificationCenter.default.post(name: .dockDragEnded, object: nil)

        // Capture values before cleanup
        let wasDraggingOut = isDraggingOut
        let tearOffIndex = draggedTabIndex

        // Cleanup
        draggedTabIndex = nil
        dragStartPoint = nil
        dragStartScreenY = nil
        isDraggingOut = false
        hideDropIndicator()

        // If operation is none (drag wasn't accepted) and we dragged outside tab bar, create floating window
        if operation == [] && wasDraggingOut {
            if let index = tearOffIndex {
                delegate?.tabBar(self, didInitiateTearOff: index, at: screenPoint)
            }
        }
    }

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            return []
        }
        return .move
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            hideDropIndicator()
            return []
        }

        let location = convert(sender.draggingLocation, from: nil)
        let insertionIndex = calculateInsertionIndex(at: location)
        showDropIndicator(at: insertionIndex)
        dropInsertionIndex = insertionIndex

        return .move
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
        dropInsertionIndex = nil
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()

        guard let data = sender.draggingPasteboard.data(forType: .dockTab),
              let dragInfo = try? JSONDecoder().decode(DockTabDragInfo.self, from: data),
              let insertionIndex = dropInsertionIndex else {
            return false
        }

        // Check if it's a reorder within the same tab bar
        if dragInfo.sourceGroupId == groupId {
            if let fromIndex = panels.firstIndex(where: { $0.id == dragInfo.tabId }) {
                let toIndex = insertionIndex > fromIndex ? insertionIndex - 1 : insertionIndex
                if fromIndex != toIndex {
                    delegate?.tabBar(self, didReorderTabFrom: fromIndex, to: toIndex)
                }
            }
        } else {
            // Tab from different group
            delegate?.tabBar(self, didReceiveDroppedTab: dragInfo, at: insertionIndex)
        }

        dropInsertionIndex = nil
        return true
    }

    // MARK: - Drop Indicator

    /// Get the currently active tab views based on group style
    private var activeTabViews: [NSView] {
        if DockKit.customTabRenderer != nil && (groupStyle == .tabs || groupStyle == .split || groupStyle == .stages) {
            return customTabViews
        }
        switch groupStyle {
        case .tabs, .split, .stages:
            return tabButtons
        case .thumbnails:
            return thumbnailButtons
        }
    }

    private func calculateInsertionIndex(at point: NSPoint) -> Int {
        let views = activeTabViews
        var accumulatedWidth: CGFloat = 0
        for (index, view) in views.enumerated() {
            let midPoint = accumulatedWidth + view.frame.width / 2
            if point.x < midPoint {
                return index
            }
            accumulatedWidth += view.frame.width + stackView.spacing
        }
        return views.count
    }

    private func showDropIndicator(at index: Int) {
        guard let indicator = dropIndicatorView else { return }

        let views = activeTabViews
        var xPosition: CGFloat = 0
        if index < views.count {
            xPosition = views[index].frame.minX - 1
        } else if let lastView = views.last {
            xPosition = lastView.frame.maxX
        }

        indicator.frame = NSRect(x: xPosition, y: 4, width: 2, height: bounds.height - 8)
        indicator.isHidden = false
    }

    private func hideDropIndicator() {
        dropIndicatorView?.isHidden = true
    }
}

// MARK: - DockTabButton

/// Individual tab button with drag support
public class DockTabButton: NSView, DockTabView {
    public var onSelect: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onDragBegan: ((NSEvent) -> Void)?

    /// Identity of the panel this button represents. Used by DockTabBarView's
    /// incremental reconciliation to match existing views to new panel data.
    public var panelId: UUID { panel.id }

    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var focusIndicator: NSView!
    private var isSelected: Bool = false
    private var isFocused: Bool = false
    private var isHovering: Bool = false
    private var panel: Panel

    public init(panel: Panel, isSelected: Bool) {
        self.panel = panel
        self.isSelected = isSelected
        super.init(frame: .zero)
        setupUI()
        update(with: panel, isSelected: isSelected)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true

        // Focus indicator (small dot before icon)
        focusIndicator = NSView()
        focusIndicator.wantsLayer = true
        focusIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        focusIndicator.layer?.cornerRadius = 3
        focusIndicator.translatesAutoresizingMaskIntoConstraints = false
        focusIndicator.isHidden = true
        addSubview(focusIndicator)

        // Icon
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Close button
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            focusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            focusIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusIndicator.widthAnchor.constraint(equalToConstant: 6),
            focusIndicator.heightAnchor.constraint(equalToConstant: 6),

            iconView.leadingAnchor.constraint(equalTo: focusIndicator.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            heightAnchor.constraint(equalToConstant: 28)
        ])

        // Tracking area for hover
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    public func update(with panel: Panel, isSelected: Bool) {
        self.panel = panel
        self.isSelected = isSelected

        titleLabel.stringValue = panel.title ?? "Untitled"

        if let iconName = panel.iconName {
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }

        updateAppearance()
    }

    public func setFocused(_ focused: Bool) {
        self.isFocused = focused
        updateAppearance()
    }

    private func updateAppearance() {
        var cg: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = (isSelected ? NSColor.controlBackgroundColor : .clear).cgColor
        }
        layer?.backgroundColor = cg
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor

        // Show focus indicator only when this tab is both selected AND the panel has focus
        focusIndicator.isHidden = !(isSelected && isFocused)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    public override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    public override func mouseDragged(with event: NSEvent) {
        // Initiate drag
        onDragBegan?(event)
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

// MARK: - DockThumbnailButton

/// Thumbnail button showing a visual preview of the panel content
public class DockThumbnailButton: NSView, DockTabView {
    public var onSelect: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onDragBegan: ((NSEvent) -> Void)?

    /// Identity of the panel this thumbnail represents. Used by DockTabBarView's
    /// incremental reconciliation to match existing views to new panel data.
    public var panelId: UUID { panel.id }

    private var thumbnailView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var selectionBorder: NSView!
    private var focusIndicator: NSView!
    private var isSelected: Bool = false
    private var isFocused: Bool = false
    private var isHovering: Bool = false
    private var panel: Panel

    /// Panel provider for resolving DockablePanel instances (for thumbnail capture)
    private var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Height of thumbnail (width is fixed at 120pt in stack)
    private static let thumbnailHeight: CGFloat = 80

    public init(panel: Panel, isSelected: Bool, panelProvider: ((UUID) -> (any DockablePanel)?)?) {
        self.panel = panel
        self.isSelected = isSelected
        self.panelProvider = panelProvider
        super.init(frame: .zero)
        setupUI()
        update(with: panel, isSelected: isSelected)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6

        translatesAutoresizingMaskIntoConstraints = false

        // Selection border (behind thumbnail)
        selectionBorder = NSView()
        selectionBorder.wantsLayer = true
        selectionBorder.layer?.cornerRadius = 8
        selectionBorder.layer?.borderWidth = 2
        selectionBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorder.isHidden = true
        selectionBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionBorder)

        // Thumbnail image view
        thumbnailView = NSImageView()
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)

        // Focus indicator (small dot at top-left)
        focusIndicator = NSView()
        focusIndicator.wantsLayer = true
        focusIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        focusIndicator.layer?.cornerRadius = 3
        focusIndicator.translatesAutoresizingMaskIntoConstraints = false
        focusIndicator.isHidden = true
        addSubview(focusIndicator)

        // Title label at bottom
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Close button (top-right corner)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Selection border surrounds thumbnail
            selectionBorder.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectionBorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            selectionBorder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            selectionBorder.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2),

            // Thumbnail fills most of the space
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            thumbnailView.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight - 24),

            // Focus indicator at top-left
            focusIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            focusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            focusIndicator.widthAnchor.constraint(equalToConstant: 6),
            focusIndicator.heightAnchor.constraint(equalToConstant: 6),

            // Title at bottom
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            // Close button at top-right
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            // Fixed height
            heightAnchor.constraint(equalToConstant: Self.thumbnailHeight)
        ])

        // Tracking area for hover
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    public func update(with panel: Panel, isSelected: Bool) {
        self.panel = panel
        self.isSelected = isSelected

        titleLabel.stringValue = panel.title ?? "Untitled"

        // Capture thumbnail from DockablePanel's view if available
        if let dockablePanel = panelProvider?(panel.id) {
            captureThumbnail(from: dockablePanel.panelViewController.view)
        } else if let iconName = panel.iconName,
                  let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            // Fall back to icon if no panel view
            thumbnailView.image = icon
        } else {
            thumbnailView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }

        updateAppearance()
    }

    public func setFocused(_ focused: Bool) {
        self.isFocused = focused
        updateAppearance()
    }

    /// Capture a thumbnail image from the panel's view
    private func captureThumbnail(from view: NSView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            thumbnailView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            return
        }

        // Calculate aspect ratio to fit in thumbnail
        let targetSize = NSSize(width: 108, height: Self.thumbnailHeight - 24)

        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            thumbnailView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)

        let image = NSImage(size: targetSize)
        image.lockFocus()

        // Draw scaled
        let sourceSize = view.bounds.size
        let scaleFactor = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scaleFactor
        let scaledHeight = sourceSize.height * scaleFactor
        let x = (targetSize.width - scaledWidth) / 2
        let y = (targetSize.height - scaledHeight) / 2

        bitmapRep.draw(in: NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight))

        image.unlockFocus()
        thumbnailView.image = image
    }

    private func updateAppearance() {
        // Selection border
        selectionBorder.isHidden = !isSelected

        var bg: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                bg = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            } else if isHovering {
                bg = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            } else {
                bg = NSColor.clear.cgColor
            }
        }
        layer?.backgroundColor = bg
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor

        // Focus indicator
        focusIndicator.isHidden = !(isSelected && isFocused)

        // Close button visibility
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    public override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    public override func mouseDragged(with event: NSEvent) {
        onDragBegan?(event)
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// Refresh the thumbnail capture
    public func refreshThumbnail() {
        if let dockablePanel = panelProvider?(panel.id) {
            captureThumbnail(from: dockablePanel.panelViewController.view)
        }
    }
}

// MARK: - Notification Names

public extension NSNotification.Name {
    static let dockDragBegan = NSNotification.Name("DockDragBegan")
    static let dockDragEnded = NSNotification.Name("DockDragEnded")
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
