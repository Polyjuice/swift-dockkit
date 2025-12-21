import AppKit

/// Delegate for desktop header events
public protocol DockDesktopHeaderViewDelegate: AnyObject {
    /// Called when user clicks a desktop to switch to it
    func desktopHeader(_ header: DockDesktopHeaderView, didSelectDesktopAt index: Int)

    /// Called when user reorders desktops (optional)
    func desktopHeader(_ header: DockDesktopHeaderView, didMoveDesktopFrom fromIndex: Int, to toIndex: Int)

    /// Called when slow motion toggle changes
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleSlowMotion enabled: Bool)

    /// Called when thumbnail mode toggle changes
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleThumbnailMode enabled: Bool)

    /// Called when user clicks the (+) button to create a new desktop
    func desktopHeaderDidRequestNewDesktop(_ header: DockDesktopHeaderView)

    /// Called when a tab is dropped on a desktop thumbnail
    func desktopHeader(_ header: DockDesktopHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onDesktopAt index: Int)
}

/// Default implementations
public extension DockDesktopHeaderViewDelegate {
    func desktopHeader(_ header: DockDesktopHeaderView, didMoveDesktopFrom fromIndex: Int, to toIndex: Int) {}
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleSlowMotion enabled: Bool) {}
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleThumbnailMode enabled: Bool) {}
    func desktopHeaderDidRequestNewDesktop(_ header: DockDesktopHeaderView) {}
    func desktopHeader(_ header: DockDesktopHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onDesktopAt index: Int) {}
}

/// A header view showing desktop icons/titles for selection
public class DockDesktopHeaderView: NSView {

    // MARK: - Properties

    public weak var delegate: DockDesktopHeaderViewDelegate?

    /// The desktops being displayed
    private var desktops: [Desktop] = []

    /// Currently active desktop index
    private var activeIndex: Int = 0

    /// Stack view containing desktop buttons
    private var stackView: NSStackView!

    /// Desktop indicator buttons (built-in)
    private var desktopButtons: [DockDesktopButton] = []

    /// Custom desktop views (when using custom renderer)
    private var customDesktopViews: [DockDesktopView] = []

    /// Stack view height constraint (changes in thumbnail mode)
    private var stackHeightConstraint: NSLayoutConstraint!

    /// Current display mode
    public var displayMode: DesktopDisplayMode = .tabs {
        didSet {
            if displayMode != oldValue {
                rebuildButtons()
            }
        }
    }

    /// Slow motion toggle switch
    private var slowMotionSwitch: NSSwitch!
    private var slowMotionLabel: NSTextField!

    /// Thumbnail mode toggle switch
    private var thumbnailSwitch: NSSwitch!
    private var thumbnailLabel: NSTextField!

    /// Height of the header (normal mode)
    public static let headerHeight: CGFloat = 36

    /// Height of the header in thumbnail mode
    public static let thumbnailHeaderHeight: CGFloat = 96

    /// Current thumbnail mode state (default: true for thumbnail mode)
    private var isThumbnailMode: Bool = true

    /// Add desktop button (+)
    private var addDesktopButton: NSButton!

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        // Add subtle bottom border
        let borderLayer = CALayer()
        borderLayer.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(borderLayer)
        borderLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        borderLayer.autoresizingMask = [.layerWidthSizable]

        // Create centered stack view for desktop indicators
        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 8
        stackView.distribution = .fillEqually
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Default to thumbnail mode height
        stackHeightConstraint = stackView.heightAnchor.constraint(equalToConstant: DockDesktopButton.thumbnailHeight)

        // Add desktop button (+) - styled like Mission Control
        addDesktopButton = NSButton(frame: .zero)
        addDesktopButton.bezelStyle = .regularSquare
        addDesktopButton.isBordered = false
        addDesktopButton.title = ""
        addDesktopButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Desktop")
        addDesktopButton.imagePosition = .imageOnly
        addDesktopButton.imageScaling = .scaleProportionallyDown
        addDesktopButton.contentTintColor = .secondaryLabelColor
        addDesktopButton.target = self
        addDesktopButton.action = #selector(addDesktopClicked(_:))
        addDesktopButton.translatesAutoresizingMaskIntoConstraints = false
        addDesktopButton.wantsLayer = true
        addDesktopButton.layer?.cornerRadius = 6
        stackView.addArrangedSubview(addDesktopButton)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Ensure stack doesn't overlap traffic light buttons (close/minimize/zoom)
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 78),
            stackHeightConstraint,
            addDesktopButton.widthAnchor.constraint(equalToConstant: 44),
            addDesktopButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Slow motion toggle on the right
        slowMotionLabel = NSTextField(labelWithString: "Slow")
        slowMotionLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        slowMotionLabel.textColor = .tertiaryLabelColor
        slowMotionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slowMotionLabel)

        slowMotionSwitch = NSSwitch()
        slowMotionSwitch.controlSize = .mini
        slowMotionSwitch.target = self
        slowMotionSwitch.action = #selector(slowMotionToggled(_:))
        slowMotionSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slowMotionSwitch)

        // Thumbnail mode toggle (left of slow motion)
        thumbnailLabel = NSTextField(labelWithString: "Thumbs")
        thumbnailLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        thumbnailLabel.textColor = .tertiaryLabelColor
        thumbnailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailLabel)

        thumbnailSwitch = NSSwitch()
        thumbnailSwitch.controlSize = .mini
        thumbnailSwitch.state = .on  // Default to thumbnail mode
        thumbnailSwitch.target = self
        thumbnailSwitch.action = #selector(thumbnailToggled(_:))
        thumbnailSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailSwitch)

        NSLayoutConstraint.activate([
            // Slow motion on far right
            slowMotionSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slowMotionSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            slowMotionLabel.trailingAnchor.constraint(equalTo: slowMotionSwitch.leadingAnchor, constant: -4),
            slowMotionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Thumbnail toggle to the left of slow motion
            thumbnailSwitch.trailingAnchor.constraint(equalTo: slowMotionLabel.leadingAnchor, constant: -16),
            thumbnailSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailLabel.trailingAnchor.constraint(equalTo: thumbnailSwitch.leadingAnchor, constant: -4),
            thumbnailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func slowMotionToggled(_ sender: NSSwitch) {
        delegate?.desktopHeader(self, didToggleSlowMotion: sender.state == .on)
    }

    @objc private func thumbnailToggled(_ sender: NSSwitch) {
        delegate?.desktopHeader(self, didToggleThumbnailMode: sender.state == .on)
    }

    @objc private func addDesktopClicked(_ sender: NSButton) {
        delegate?.desktopHeaderDidRequestNewDesktop(self)
    }

    // MARK: - Window Dragging

    private var eventMonitor: Any?
    private var dragStartLocation: NSPoint?

    /// Title bar height to exclude from drag area
    private let titleBarHeight: CGFloat = 28

    private func setupDragMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self, let window = self.window else { return event }

            // Convert to header view coordinates
            let locationInWindow = event.locationInWindow
            let locationInHeader = self.convert(locationInWindow, from: nil)

            // Check if event is in our bounds
            guard self.bounds.contains(locationInHeader) else {
                return event
            }

            // Exclude the title bar area at the top (where close/minimize/zoom buttons are)
            // In flipped coordinates, 0 is top. In non-flipped, 0 is bottom.
            let windowHeight = window.frame.height
            let yFromTop = windowHeight - locationInWindow.y
            if yFromTop < self.titleBarHeight {
                // In title bar area - let system handle it
                return event
            }

            // Check if click is on an interactive control
            if event.type == .leftMouseDown {
                // Use hitTest from the window's content view to find what's under the click
                if let contentView = window.contentView {
                    let locationInContent = contentView.convert(locationInWindow, from: nil)
                    if let hit = contentView.hitTest(locationInContent) {
                        if self.isInteractiveControl(hit) {
                            // Let the control handle it
                            return event
                        }
                    }
                }
                // Start drag
                self.dragStartLocation = locationInWindow
                return nil  // Consume the event
            } else if event.type == .leftMouseDragged {
                if let startLocation = self.dragStartLocation {
                    let delta = NSPoint(
                        x: locationInWindow.x - startLocation.x,
                        y: locationInWindow.y - startLocation.y
                    )
                    var newOrigin = window.frame.origin
                    newOrigin.x += delta.x
                    newOrigin.y += delta.y
                    window.setFrameOrigin(newOrigin)
                    return nil  // Consume the event
                }
            } else if event.type == .leftMouseUp {
                if self.dragStartLocation != nil {
                    self.dragStartLocation = nil
                    return nil  // Consume the event
                }
            }

            return event
        }
    }

    private func isInteractiveControl(_ view: NSView?) -> Bool {
        guard let view = view else { return false }
        // Only the header view itself and the stack view background are non-interactive
        // Everything else (buttons, switches, desktop buttons, their subviews) is interactive
        if view === self || view === stackView {
            return false
        }
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && eventMonitor == nil {
            setupDragMonitor()
        } else if window == nil, let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Public API

    /// Set the desktops to display
    public func setDesktops(_ newDesktops: [Desktop], activeIndex: Int) {
        desktops = newDesktops
        self.activeIndex = max(0, min(activeIndex, desktops.count - 1))
        rebuildButtons()
    }

    /// Update the active desktop (visual highlight only)
    public func setActiveIndex(_ index: Int) {
        guard index >= 0 && index < desktops.count else { return }
        activeIndex = index
        updateButtonStates()
    }

    /// Highlight a desktop during swipe (preview state)
    /// This moves the indicator to the target desktop
    public func highlightDesktop(at index: Int) {
        // Built-in buttons
        for (i, button) in desktopButtons.enumerated() {
            button.setSwipeTarget(i == index, swipeMode: true)
        }

        // Custom views
        if let renderer = DockKit.customDesktopRenderer {
            for (i, view) in customDesktopViews.enumerated() {
                renderer.setSwipeTarget(i == index, swipeMode: true, on: view)
            }
        }
    }

    /// Clear swipe highlighting (called when swipe ends)
    public func clearSwipeHighlight() {
        // Built-in buttons
        for button in desktopButtons {
            button.setSwipeTarget(false, swipeMode: false)
        }

        // Custom views
        if let renderer = DockKit.customDesktopRenderer {
            for view in customDesktopViews {
                renderer.setSwipeTarget(false, swipeMode: false, on: view)
            }
        }
    }

    /// Set thumbnail mode for desktop buttons
    /// Returns the required header height for the new mode
    @discardableResult
    public func setThumbnailMode(_ enabled: Bool) -> CGFloat {
        isThumbnailMode = enabled

        // Update stack view height
        stackHeightConstraint.constant = enabled ? DockDesktopButton.thumbnailHeight : 28

        for button in desktopButtons {
            button.setThumbnailMode(enabled)
        }
        return enabled ? Self.thumbnailHeaderHeight : Self.headerHeight
    }

    /// Set thumbnails for each desktop
    public func setThumbnails(_ thumbnails: [NSImage?]) {
        // Built-in buttons
        for (index, button) in desktopButtons.enumerated() {
            if index < thumbnails.count {
                button.setThumbnail(thumbnails[index])
            }
        }

        // Custom views
        if let renderer = DockKit.customDesktopRenderer {
            for (index, view) in customDesktopViews.enumerated() {
                if index < thumbnails.count {
                    renderer.setThumbnail(thumbnails[index], on: view)
                }
            }
        }
    }

    /// Set thumbnail for a specific desktop
    public func setThumbnail(_ thumbnail: NSImage?, at index: Int) {
        // Built-in buttons
        if index >= 0 && index < desktopButtons.count {
            desktopButtons[index].setThumbnail(thumbnail)
        }

        // Custom views
        if let renderer = DockKit.customDesktopRenderer,
           index >= 0 && index < customDesktopViews.count {
            renderer.setThumbnail(thumbnail, on: customDesktopViews[index])
        }
    }

    // MARK: - Private Methods

    private func clearAllViews() {
        desktopButtons.forEach { $0.removeFromSuperview() }
        desktopButtons.removeAll()
        customDesktopViews.forEach { $0.removeFromSuperview() }
        customDesktopViews.removeAll()
        // Keep the add button but remove it temporarily so it can be re-added at the end
        addDesktopButton.removeFromSuperview()
    }

    private func rebuildButtons() {
        clearAllViews()

        // Determine effective mode
        let effectiveMode: DesktopDisplayMode
        if displayMode == .custom && DockKit.customDesktopRenderer != nil {
            effectiveMode = .custom
        } else if displayMode == .custom {
            effectiveMode = .tabs  // Fallback
        } else {
            effectiveMode = displayMode
        }

        switch effectiveMode {
        case .tabs, .thumbnails:
            rebuildBuiltInButtons()
        case .custom:
            rebuildCustomViews()
        }

        updateButtonStates()
    }

    private func rebuildBuiltInButtons() {
        // Create new buttons
        for (index, desktop) in desktops.enumerated() {
            let button = DockDesktopButton(desktop: desktop, index: index)
            button.onSelect = { [weak self] idx in
                self?.handleDesktopSelected(at: idx)
            }
            button.onTabDrop = { [weak self] idx, tabInfo in
                guard let self = self else { return }
                self.delegate?.desktopHeader(self, didReceiveTab: tabInfo, onDesktopAt: idx)
            }
            button.setThumbnailMode(isThumbnailMode)
            desktopButtons.append(button)
            stackView.addArrangedSubview(button)
        }
        // Re-add the (+) button at the end
        stackView.addArrangedSubview(addDesktopButton)
    }

    private func rebuildCustomViews() {
        guard let renderer = DockKit.customDesktopRenderer else {
            rebuildBuiltInButtons()
            return
        }

        // Update header height for custom renderer
        stackHeightConstraint.constant = renderer.headerHeight - 8  // Account for padding

        // Create custom views
        for (index, desktop) in desktops.enumerated() {
            let view = renderer.createDesktopView(for: desktop, index: index, isActive: index == activeIndex)
            view.onSelect = { [weak self] idx in
                self?.handleDesktopSelected(at: idx)
            }
            view.desktopIndex = index
            customDesktopViews.append(view)
            stackView.addArrangedSubview(view)
        }
        // Re-add the (+) button at the end
        stackView.addArrangedSubview(addDesktopButton)
    }

    private func updateButtonStates() {
        // Update built-in buttons
        for (index, button) in desktopButtons.enumerated() {
            button.setActive(index == activeIndex)
        }

        // Update custom views
        if let renderer = DockKit.customDesktopRenderer {
            for (index, view) in customDesktopViews.enumerated() {
                guard index < desktops.count else { continue }
                renderer.updateDesktopView(view, for: desktops[index], index: index, isActive: index == activeIndex)
            }
        }
    }

    private func handleDesktopSelected(at index: Int) {
        guard index != activeIndex else { return }
        delegate?.desktopHeader(self, didSelectDesktopAt: index)
    }
}

// MARK: - DockDesktopButton

/// Individual desktop button in the header - supports icon+title or thumbnail mode
public class DockDesktopButton: NSView, DockDesktopView {
    public var onSelect: ((Int) -> Void)?
    public var onTabDrop: ((Int, DockTabDragInfo) -> Void)?
    public var desktopIndex: Int

    private let desktop: Desktop
    private var isDragTarget: Bool = false

    // Icon+Title mode views
    private var contentStack: NSStackView!
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?

    // Thumbnail mode views
    private var thumbnailView: NSImageView!
    private var thumbnailTitleLabel: NSTextField!
    private var thumbnailContainer: NSView!

    // Shared views
    private var indicatorView: NSView!
    private var selectionBorder: NSView!

    // State
    private var isActive: Bool = false
    private var isSwipeTarget: Bool = false
    private var isInSwipeMode: Bool = false
    private var isHovering: Bool = false
    private var isThumbnailMode: Bool = false

    // Constraints that change with mode
    private var normalWidthConstraint: NSLayoutConstraint!
    private var thumbnailWidthConstraint: NSLayoutConstraint!
    private var normalHeightConstraint: NSLayoutConstraint!
    private var thumbnailHeightConstraint: NSLayoutConstraint!

    /// Thumbnail size
    public static let thumbnailWidth: CGFloat = 120
    public static let thumbnailHeight: CGFloat = 80

    public init(desktop: Desktop, index: Int) {
        self.desktop = desktop
        self.desktopIndex = index
        super.init(frame: .zero)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        // Selection border (for thumbnail mode)
        selectionBorder = NSView()
        selectionBorder.wantsLayer = true
        selectionBorder.layer?.cornerRadius = 8
        selectionBorder.layer?.borderWidth = 2
        selectionBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorder.isHidden = true
        selectionBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionBorder)

        // === Icon+Title Mode (Normal) ===
        contentStack = NSStackView()
        contentStack.orientation = .horizontal
        contentStack.spacing = 4
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        if let iconName = desktop.iconName {
            let icon = NSImageView()
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: desktop.title) {
                icon.image = image
            }
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            contentStack.addArrangedSubview(icon)
            iconView = icon
        }

        let title = desktop.title ?? "Desktop \(desktopIndex + 1)"
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(label)
        titleLabel = label

        // === Thumbnail Mode ===
        thumbnailContainer = NSView()
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.isHidden = true
        addSubview(thumbnailContainer)

        thumbnailView = NSImageView()
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(thumbnailView)

        thumbnailTitleLabel = NSTextField(labelWithString: title)
        thumbnailTitleLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        thumbnailTitleLabel.textColor = .secondaryLabelColor
        thumbnailTitleLabel.alignment = .center
        thumbnailTitleLabel.lineBreakMode = .byTruncatingTail
        thumbnailTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(thumbnailTitleLabel)

        // Active indicator dot
        indicatorView = NSView()
        indicatorView.wantsLayer = true
        indicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicatorView.layer?.cornerRadius = 2
        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.isHidden = true
        addSubview(indicatorView)

        // Size constraints for different modes
        normalWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        thumbnailWidthConstraint = widthAnchor.constraint(equalToConstant: Self.thumbnailWidth)
        thumbnailWidthConstraint.isActive = false

        normalHeightConstraint = heightAnchor.constraint(equalToConstant: 28)
        thumbnailHeightConstraint = heightAnchor.constraint(equalToConstant: Self.thumbnailHeight)
        thumbnailHeightConstraint.isActive = false

        NSLayoutConstraint.activate([
            // Selection border
            selectionBorder.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectionBorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            selectionBorder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            selectionBorder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            // Normal mode content
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Thumbnail container
            thumbnailContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            thumbnailContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            // Thumbnail image
            thumbnailView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: thumbnailTitleLabel.topAnchor, constant: -2),

            // Thumbnail title
            thumbnailTitleLabel.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailTitleLabel.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailTitleLabel.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),
            thumbnailTitleLabel.heightAnchor.constraint(equalToConstant: 12),

            // Indicator
            indicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            indicatorView.widthAnchor.constraint(equalToConstant: 4),
            indicatorView.heightAnchor.constraint(equalToConstant: 4),

            // Size
            normalWidthConstraint,
            normalHeightConstraint
        ])

        // Tracking area
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        // Register for tab drops
        registerForDraggedTypes([.dockTab])
    }

    public func setActive(_ active: Bool) {
        isActive = active
        updateAppearance()
    }

    public func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool) {
        isSwipeTarget = isTarget
        isInSwipeMode = swipeMode
        updateAppearance()
    }

    public func setThumbnailMode(_ enabled: Bool) {
        guard isThumbnailMode != enabled else { return }
        isThumbnailMode = enabled

        contentStack.isHidden = enabled
        thumbnailContainer.isHidden = !enabled

        normalWidthConstraint.isActive = !enabled
        thumbnailWidthConstraint.isActive = enabled
        normalHeightConstraint.isActive = !enabled
        thumbnailHeightConstraint.isActive = enabled

        updateAppearance()
    }

    public func setThumbnail(_ image: NSImage?) {
        thumbnailView.image = image
    }

    private func updateAppearance() {
        let shouldHighlight = isSwipeTarget || isActive

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15

            if isThumbnailMode {
                // Thumbnail mode appearance
                selectionBorder.isHidden = !shouldHighlight
                if shouldHighlight {
                    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
                    thumbnailTitleLabel?.animator().textColor = .labelColor
                } else if isHovering {
                    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
                    thumbnailTitleLabel?.animator().textColor = .secondaryLabelColor
                } else {
                    layer?.backgroundColor = NSColor.clear.cgColor
                    thumbnailTitleLabel?.animator().textColor = .secondaryLabelColor
                }
            } else {
                // Normal mode appearance
                selectionBorder.isHidden = true
                if shouldHighlight {
                    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                    titleLabel?.animator().textColor = .labelColor
                } else if isHovering {
                    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
                    titleLabel?.animator().textColor = .secondaryLabelColor
                } else {
                    layer?.backgroundColor = NSColor.clear.cgColor
                    titleLabel?.animator().textColor = .secondaryLabelColor
                }
            }

            let showIndicator: Bool
            if isInSwipeMode {
                showIndicator = isSwipeTarget
            } else {
                showIndicator = isActive
            }
            indicatorView.animator().isHidden = !showIndicator
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
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
    }

    public override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?(desktopIndex)
        }
        updateAppearance()
    }

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            return []
        }
        isDragTarget = true
        updateDragAppearance()
        return .move
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            return []
        }
        return .move
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTarget = false
        updateDragAppearance()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTarget = false
        updateDragAppearance()

        guard let data = sender.draggingPasteboard.data(forType: .dockTab),
              let dragInfo = try? JSONDecoder().decode(DockTabDragInfo.self, from: data) else {
            return false
        }

        onTabDrop?(desktopIndex, dragInfo)
        return true
    }

    private func updateDragAppearance() {
        if isDragTarget {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            selectionBorder.isHidden = false
            selectionBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            updateAppearance()
        }
    }
}
