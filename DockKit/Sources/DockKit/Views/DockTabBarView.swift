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
    func tabBarDidRequestNewTab(_ tabBar: DockTabBarView)
}

/// Optional delegate methods
public extension DockTabBarViewDelegate {
    func tabBarDidRequestNewTab(_ tabBar: DockTabBarView) {}
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

    /// Display mode - tabs or thumbnails
    public var displayMode: TabGroupDisplayMode = .tabs {
        didSet {
            if displayMode != oldValue {
                rebuildForDisplayMode()
            }
        }
    }

    private var tabs: [DockTab] = []
    private var selectedIndex: Int = 0
    private var tabButtons: [DockTabButton] = []
    private var thumbnailButtons: [DockThumbnailButton] = []
    private var stackView: NSStackView!
    private var addButton: NSButton!

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
        didSet { addButton?.isHidden = !showAddButton }
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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Stack view for tab buttons (no scroll view - simpler)
        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Add button
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!, target: self, action: #selector(addButtonClicked))
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            // Stack view takes left side
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -4),

            // Add button on right
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24)
        ])

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

    // MARK: - Public API

    public func setTabs(_ newTabs: [DockTab], selectedIndex: Int, displayMode: TabGroupDisplayMode = .tabs) {
        self.tabs = newTabs
        self.selectedIndex = max(0, min(selectedIndex, newTabs.count - 1))
        self.displayMode = displayMode
        rebuildForDisplayMode()
    }

    /// Rebuild the view based on current display mode
    private func rebuildForDisplayMode() {
        switch displayMode {
        case .tabs:
            rebuildTabButtons()
        case .thumbnails:
            rebuildThumbnailButtons()
        }
    }

    public func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedIndex = index
        updateSelectionState()
    }

    public func updateTab(at index: Int, title: String? = nil) {
        guard index >= 0 && index < tabs.count else { return }
        if let title = title {
            tabs[index].title = title
        }
        tabButtons[safe: index]?.update(with: tabs[index], isSelected: index == selectedIndex)
    }

    /// Update focus state - shows focus indicator on the selected tab
    public func setFocused(_ focused: Bool) {
        switch displayMode {
        case .tabs:
            for (index, button) in tabButtons.enumerated() {
                button.setFocused(focused && index == selectedIndex)
            }
        case .thumbnails:
            for (index, button) in thumbnailButtons.enumerated() {
                button.setFocused(focused && index == selectedIndex)
            }
        }
    }

    // MARK: - Private

    private func rebuildTabButtons() {
        // Remove old buttons (both types)
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        thumbnailButtons.forEach { $0.removeFromSuperview() }
        thumbnailButtons.removeAll()

        // Create new buttons
        for (index, tab) in tabs.enumerated() {
            let button = DockTabButton(tab: tab, isSelected: index == selectedIndex)
            button.onSelect = { [weak self] in
                self?.handleTabSelected(at: index)
            }
            button.onClose = { [weak self] in
                self?.handleTabClosed(at: index)
            }
            button.onDragBegan = { [weak self] event in
                self?.handleDragBegan(at: index, event: event)
            }

            tabButtons.append(button)
            stackView.addArrangedSubview(button)

            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        }
    }

    private func rebuildThumbnailButtons() {
        // Remove old buttons (both types)
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        thumbnailButtons.forEach { $0.removeFromSuperview() }
        thumbnailButtons.removeAll()

        // Create thumbnail buttons
        for (index, tab) in tabs.enumerated() {
            let button = DockThumbnailButton(tab: tab, isSelected: index == selectedIndex)
            button.onSelect = { [weak self] in
                self?.handleTabSelected(at: index)
            }
            button.onClose = { [weak self] in
                self?.handleTabClosed(at: index)
            }
            button.onDragBegan = { [weak self] event in
                self?.handleDragBegan(at: index, event: event)
            }

            thumbnailButtons.append(button)
            stackView.addArrangedSubview(button)

            // Thumbnails have fixed width
            button.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
    }

    private func updateSelectionState() {
        switch displayMode {
        case .tabs:
            for (index, button) in tabButtons.enumerated() {
                button.update(with: tabs[index], isSelected: index == selectedIndex)
            }
        case .thumbnails:
            for (index, button) in thumbnailButtons.enumerated() {
                button.update(with: tabs[index], isSelected: index == selectedIndex)
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

    @objc private func addButtonClicked() {
        delegate?.tabBarDidRequestNewTab(self)
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

        guard let tab = tabs[safe: index] else { return }

        // Create drag image
        let dragImage = createDragImage(for: tab)

        // Create pasteboard item
        let dragInfo = DockTabDragInfo(
            tabId: tab.id,
            sourceGroupId: groupId,
            title: tab.title,
            iconName: tab.iconName
        )

        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(dragInfo) {
            pasteboardItem.setData(data, forType: .dockTab)
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(tabButtons[index].frame, contents: dragImage)

        // Post notification that drag has begun so drop overlays can show
        // Include the drag info so overlays can decide whether to show
        NotificationCenter.default.post(name: .dockDragBegan, object: nil, userInfo: ["dragInfo": dragInfo])

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func createDragImage(for tab: DockTab) -> NSImage {
        // Get the actual tab button to use for drag image
        if let index = tabs.firstIndex(where: { $0.id == tab.id }),
           let button = tabButtons[safe: index] {
            // Create image from the actual view at screen resolution
            guard let bitmapRep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
                return createFallbackDragImage(for: tab)
            }
            button.cacheDisplay(in: button.bounds, to: bitmapRep)

            let image = NSImage(size: button.bounds.size)
            image.addRepresentation(bitmapRep)
            return image
        }
        return createFallbackDragImage(for: tab)
    }

    private func createFallbackDragImage(for tab: DockTab) -> NSImage {
        // Fallback if we can't capture the actual view
        let size = NSSize(width: 150, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw background
        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw icon
        if let icon = tab.icon {
            icon.draw(in: NSRect(x: 8, y: 7, width: 14, height: 14))
        }

        // Draw title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let titleRect = NSRect(x: 28, y: 7, width: 110, height: 14)
        (tab.title as NSString).draw(in: titleRect, withAttributes: attributes)

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
            if let fromIndex = tabs.firstIndex(where: { $0.id == dragInfo.tabId }) {
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

    private func calculateInsertionIndex(at point: NSPoint) -> Int {
        var accumulatedWidth: CGFloat = 0
        for (index, button) in tabButtons.enumerated() {
            let midPoint = accumulatedWidth + button.frame.width / 2
            if point.x < midPoint {
                return index
            }
            accumulatedWidth += button.frame.width + stackView.spacing
        }
        return tabButtons.count
    }

    private func showDropIndicator(at index: Int) {
        guard let indicator = dropIndicatorView else { return }

        var xPosition: CGFloat = 0
        if index < tabButtons.count {
            xPosition = tabButtons[index].frame.minX - 1
        } else if let lastButton = tabButtons.last {
            xPosition = lastButton.frame.maxX
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
public class DockTabButton: NSView {
    public var onSelect: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onDragBegan: ((NSEvent) -> Void)?

    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var focusIndicator: NSView!
    private var isSelected: Bool = false
    private var isFocused: Bool = false
    private var isHovering: Bool = false
    private var tab: DockTab

    public init(tab: DockTab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected
        super.init(frame: .zero)
        setupUI()
        update(with: tab, isSelected: isSelected)
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

    public func update(with tab: DockTab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected

        titleLabel.stringValue = tab.title
        iconView.image = tab.icon ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)

        updateAppearance()
    }

    public func setFocused(_ focused: Bool) {
        self.isFocused = focused
        updateAppearance()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            titleLabel.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
        }

        // Show focus indicator only when this tab is both selected AND the panel has focus
        focusIndicator.isHidden = !(isSelected && isFocused)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }
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
public class DockThumbnailButton: NSView {
    public var onSelect: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onDragBegan: ((NSEvent) -> Void)?

    private var thumbnailView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var selectionBorder: NSView!
    private var focusIndicator: NSView!
    private var isSelected: Bool = false
    private var isFocused: Bool = false
    private var isHovering: Bool = false
    private var tab: DockTab

    /// Height of thumbnail (width is fixed at 120pt in stack)
    private static let thumbnailHeight: CGFloat = 80

    public init(tab: DockTab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected
        super.init(frame: .zero)
        setupUI()
        update(with: tab, isSelected: isSelected)
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

    public func update(with tab: DockTab, isSelected: Bool) {
        self.tab = tab
        self.isSelected = isSelected

        titleLabel.stringValue = tab.title

        // Capture thumbnail from panel's view if available
        if let panel = tab.panel {
            captureThumbnail(from: panel.panelViewController.view)
        } else if let icon = tab.icon {
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

        // Background
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            titleLabel.textColor = .labelColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            titleLabel.textColor = .secondaryLabelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
        }

        // Focus indicator
        focusIndicator.isHidden = !(isSelected && isFocused)

        // Close button visibility
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }
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
        if let panel = tab.panel {
            captureThumbnail(from: panel.panelViewController.view)
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
