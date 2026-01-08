import AppKit

/// Delegate for stage header events
public protocol DockStageHeaderViewDelegate: AnyObject {
    /// Called when user clicks a stage to switch to it
    func stageHeader(_ header: DockStageHeaderView, didSelectStageAt index: Int)

    /// Called when user reorders stages (optional)
    func stageHeader(_ header: DockStageHeaderView, didMoveStageFrom fromIndex: Int, to toIndex: Int)

    /// Called when slow motion toggle changes
    func stageHeader(_ header: DockStageHeaderView, didToggleSlowMotion enabled: Bool)

    /// Called when thumbnail mode toggle changes
    func stageHeader(_ header: DockStageHeaderView, didToggleThumbnailMode enabled: Bool)

    /// Called when user clicks the (+) button to create a new stage
    func stageHeaderDidRequestNewStage(_ header: DockStageHeaderView)

    /// Called when a tab is dropped on a stage thumbnail
    func stageHeader(_ header: DockStageHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onStageAt index: Int)

    /// Called when user clicks close button on a stage. Return false to prevent closure.
    func stageHeader(_ header: DockStageHeaderView, shouldCloseStageAt index: Int) -> Bool

    /// Called after user requests to close a stage
    func stageHeader(_ header: DockStageHeaderView, didCloseStageAt index: Int)
}

/// Default implementations
public extension DockStageHeaderViewDelegate {
    func stageHeader(_ header: DockStageHeaderView, didMoveStageFrom fromIndex: Int, to toIndex: Int) {}
    func stageHeader(_ header: DockStageHeaderView, didToggleSlowMotion enabled: Bool) {}
    func stageHeader(_ header: DockStageHeaderView, didToggleThumbnailMode enabled: Bool) {}
    func stageHeaderDidRequestNewStage(_ header: DockStageHeaderView) {}
    func stageHeader(_ header: DockStageHeaderView, didReceiveTab tabInfo: DockTabDragInfo, onStageAt index: Int) {}
    func stageHeader(_ header: DockStageHeaderView, shouldCloseStageAt index: Int) -> Bool { true }
    func stageHeader(_ header: DockStageHeaderView, didCloseStageAt index: Int) {}
}

/// A header view showing stage icons/titles for selection
public class DockStageHeaderView: NSView {

    // MARK: - Properties

    public weak var delegate: DockStageHeaderViewDelegate?

    /// The stages being displayed
    private var stages: [Stage] = []

    /// Currently active stage index
    private var activeIndex: Int = 0

    /// Stack view containing stage buttons
    private var stackView: NSStackView!

    /// Stage indicator buttons (built-in)
    private var stageButtons: [DockStageButton] = []

    /// Custom stage views (when using custom renderer)
    private var customStageViews: [DockStageView] = []

    /// Stack view height constraint (changes in thumbnail mode)
    private var stackHeightConstraint: NSLayoutConstraint!

    /// Current display mode
    public var displayMode: StageDisplayMode = .tabs {
        didSet {
            if displayMode != oldValue {
                rebuildButtons()
            }
        }
    }

    /// Trailing items stack (for custom buttons/controls)
    private var trailingItemsStack: NSStackView!

    /// Debug controls container (Thumbs/Slow toggles)
    private var debugControlsStack: NSStackView!

    /// Slow motion toggle switch
    private var slowMotionSwitch: NSSwitch!
    private var slowMotionLabel: NSTextField!

    /// Thumbnail mode toggle switch
    private var thumbnailSwitch: NSSwitch!
    private var thumbnailLabel: NSTextField!

    /// Whether to show debug controls (Thumbs/Slow toggles)
    public var showDebugControls: Bool = true {
        didSet {
            debugControlsStack?.isHidden = !showDebugControls
        }
    }

    /// Height of the header (normal mode)
    public static let headerHeight: CGFloat = 36

    /// Height of the header in thumbnail mode
    public static let thumbnailHeaderHeight: CGFloat = 96

    /// Current thumbnail mode state (default: true for thumbnail mode)
    private var isThumbnailMode: Bool = true

    /// Add stage button (+)
    private var addStageButton: NSButton!

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

        // Create centered stack view for stage indicators
        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 8
        stackView.distribution = .fillEqually
        stackView.alignment = .centerY
        stackView.wantsLayer = true
        stackView.layer?.masksToBounds = false  // Allow close buttons to extend outside
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Default to thumbnail mode height
        stackHeightConstraint = stackView.heightAnchor.constraint(equalToConstant: DockStageButton.thumbnailHeight)

        // Add stage button (+) - styled like Mission Control
        addStageButton = NSButton(frame: .zero)
        addStageButton.bezelStyle = .regularSquare
        addStageButton.isBordered = false
        addStageButton.title = ""
        addStageButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Stage")
        addStageButton.imagePosition = .imageOnly
        addStageButton.imageScaling = .scaleProportionallyDown
        addStageButton.contentTintColor = .secondaryLabelColor
        addStageButton.target = self
        addStageButton.action = #selector(addStageClicked(_:))
        addStageButton.translatesAutoresizingMaskIntoConstraints = false
        addStageButton.wantsLayer = true
        addStageButton.layer?.cornerRadius = 6
        stackView.addArrangedSubview(addStageButton)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Ensure stack doesn't overlap traffic light buttons (close/minimize/zoom)
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 78),
            stackHeightConstraint,
            addStageButton.widthAnchor.constraint(equalToConstant: 44),
            addStageButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Trailing items stack on the right side (contains custom items + debug controls)
        trailingItemsStack = NSStackView()
        trailingItemsStack.orientation = .horizontal
        trailingItemsStack.spacing = 8
        trailingItemsStack.alignment = .centerY
        trailingItemsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingItemsStack)

        // Debug controls stack (Thumbs/Slow toggles)
        debugControlsStack = NSStackView()
        debugControlsStack.orientation = .horizontal
        debugControlsStack.spacing = 4
        debugControlsStack.alignment = .centerY
        debugControlsStack.translatesAutoresizingMaskIntoConstraints = false

        // Thumbnail mode toggle
        thumbnailLabel = NSTextField(labelWithString: "Thumbs")
        thumbnailLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        thumbnailLabel.textColor = .tertiaryLabelColor
        thumbnailLabel.translatesAutoresizingMaskIntoConstraints = false

        thumbnailSwitch = NSSwitch()
        thumbnailSwitch.controlSize = .mini
        thumbnailSwitch.state = .on  // Default to thumbnail mode
        thumbnailSwitch.target = self
        thumbnailSwitch.action = #selector(thumbnailToggled(_:))
        thumbnailSwitch.translatesAutoresizingMaskIntoConstraints = false

        // Slow motion toggle
        slowMotionLabel = NSTextField(labelWithString: "Slow")
        slowMotionLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        slowMotionLabel.textColor = .tertiaryLabelColor
        slowMotionLabel.translatesAutoresizingMaskIntoConstraints = false

        slowMotionSwitch = NSSwitch()
        slowMotionSwitch.controlSize = .mini
        slowMotionSwitch.target = self
        slowMotionSwitch.action = #selector(slowMotionToggled(_:))
        slowMotionSwitch.translatesAutoresizingMaskIntoConstraints = false

        // Add to debug controls stack
        debugControlsStack.addArrangedSubview(thumbnailLabel)
        debugControlsStack.addArrangedSubview(thumbnailSwitch)
        debugControlsStack.addArrangedSubview(slowMotionLabel)
        debugControlsStack.addArrangedSubview(slowMotionSwitch)

        // Add debug controls to trailing items (at the end)
        trailingItemsStack.addArrangedSubview(debugControlsStack)

        NSLayoutConstraint.activate([
            trailingItemsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingItemsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Ensure trailing items don't overlap the center stage stack
            trailingItemsStack.leadingAnchor.constraint(greaterThanOrEqualTo: stackView.trailingAnchor, constant: 16)
        ])
    }

    @objc private func slowMotionToggled(_ sender: NSSwitch) {
        delegate?.stageHeader(self, didToggleSlowMotion: sender.state == .on)
    }

    @objc private func thumbnailToggled(_ sender: NSSwitch) {
        delegate?.stageHeader(self, didToggleThumbnailMode: sender.state == .on)
    }

    @objc private func addStageClicked(_ sender: NSButton) {
        delegate?.stageHeaderDidRequestNewStage(self)
    }

    // MARK: - Window Dragging

    private var eventMonitor: Any?
    private var dragStartLocation: NSPoint?

    /// Title bar height to exclude from drag area (windowed mode only)
    private let titleBarHeight: CGFloat = 28

    /// Check if window is in full screen mode
    private var isInFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

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
            // In full screen mode, traffic lights are in the auto-hiding menu bar, not our content
            // In flipped coordinates, 0 is top. In non-flipped, 0 is bottom.
            let titleBarExclusion: CGFloat = self.isInFullScreen ? 0 : self.titleBarHeight
            let windowHeight = window.frame.height
            let yFromTop = windowHeight - locationInWindow.y
            if yFromTop < titleBarExclusion {
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
        // Everything else (buttons, switches, stage buttons, their subviews) is interactive
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

    /// Set custom trailing items (buttons/controls) to display in the header
    /// These appear to the right of the stage thumbnails/tabs and before debug controls
    /// - Parameter views: Array of NSViews to add as trailing items
    public func setTrailingItems(_ views: [NSView]) {
        // Remove existing custom items (keep debug controls)
        for view in trailingItemsStack.arrangedSubviews where view !== debugControlsStack {
            trailingItemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Insert new custom items before debug controls
        for (index, view) in views.enumerated() {
            trailingItemsStack.insertArrangedSubview(view, at: index)
        }
    }

    /// Add a single trailing item before the debug controls
    /// - Parameter view: The view to add
    public func addTrailingItem(_ view: NSView) {
        // Insert before debug controls (which is at the end)
        let insertIndex = max(0, trailingItemsStack.arrangedSubviews.count - 1)
        trailingItemsStack.insertArrangedSubview(view, at: insertIndex)
    }

    /// Remove all custom trailing items (keeps debug controls)
    public func clearTrailingItems() {
        for view in trailingItemsStack.arrangedSubviews where view !== debugControlsStack {
            trailingItemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// Set the stages to display
    public func setStages(_ newStages: [Stage], activeIndex: Int) {
        stages = newStages
        self.activeIndex = max(0, min(activeIndex, stages.count - 1))
        rebuildButtons()
    }

    /// Update the active stage (visual highlight only)
    public func setActiveIndex(_ index: Int) {
        guard index >= 0 && index < stages.count else { return }
        activeIndex = index
        updateButtonStates()
    }

    /// Highlight a stage during swipe (preview state)
    /// This moves the indicator to the target stage
    public func highlightStage(at index: Int) {
        // Built-in buttons
        for (i, button) in stageButtons.enumerated() {
            button.setSwipeTarget(i == index, swipeMode: true)
        }

        // Custom views
        if let renderer = DockKit.customStageRenderer {
            for (i, view) in customStageViews.enumerated() {
                renderer.setSwipeTarget(i == index, swipeMode: true, on: view)
            }
        }
    }

    /// Clear swipe highlighting (called when swipe ends)
    public func clearSwipeHighlight() {
        // Built-in buttons
        for button in stageButtons {
            button.setSwipeTarget(false, swipeMode: false)
        }

        // Custom views
        if let renderer = DockKit.customStageRenderer {
            for view in customStageViews {
                renderer.setSwipeTarget(false, swipeMode: false, on: view)
            }
        }
    }

    /// Set thumbnail mode for stage buttons
    /// Returns the required header height for the new mode
    @discardableResult
    public func setThumbnailMode(_ enabled: Bool) -> CGFloat {
        isThumbnailMode = enabled

        // Update stack view height
        stackHeightConstraint.constant = enabled ? DockStageButton.thumbnailHeight : 28

        for button in stageButtons {
            button.setThumbnailMode(enabled)
        }
        return enabled ? Self.thumbnailHeaderHeight : Self.headerHeight
    }

    /// Set thumbnails for each stage
    public func setThumbnails(_ thumbnails: [NSImage?]) {
        // Built-in buttons
        for (index, button) in stageButtons.enumerated() {
            if index < thumbnails.count {
                button.setThumbnail(thumbnails[index])
            }
        }

        // Custom views
        if let renderer = DockKit.customStageRenderer {
            for (index, view) in customStageViews.enumerated() {
                if index < thumbnails.count {
                    renderer.setThumbnail(thumbnails[index], on: view)
                }
            }
        }
    }

    /// Set thumbnail for a specific stage
    public func setThumbnail(_ thumbnail: NSImage?, at index: Int) {
        // Built-in buttons
        if index >= 0 && index < stageButtons.count {
            stageButtons[index].setThumbnail(thumbnail)
        }

        // Custom views
        if let renderer = DockKit.customStageRenderer,
           index >= 0 && index < customStageViews.count {
            renderer.setThumbnail(thumbnail, on: customStageViews[index])
        }
    }

    // MARK: - Private Methods

    private func clearAllViews() {
        stageButtons.forEach { $0.removeFromSuperview() }
        stageButtons.removeAll()
        customStageViews.forEach { $0.removeFromSuperview() }
        customStageViews.removeAll()
        // Keep the add button but remove it temporarily so it can be re-added at the end
        addStageButton.removeFromSuperview()
    }

    private func rebuildButtons() {
        clearAllViews()

        // Determine effective mode
        let effectiveMode: StageDisplayMode
        if displayMode == .custom && DockKit.customStageRenderer != nil {
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
        for (index, stage) in stages.enumerated() {
            let button = DockStageButton(stage: stage, index: index)
            button.onSelect = { [weak self] idx in
                self?.handleStageSelected(at: idx)
            }
            button.onTabDrop = { [weak self] idx, tabInfo in
                guard let self = self else { return }
                self.delegate?.stageHeader(self, didReceiveTab: tabInfo, onStageAt: idx)
            }
            button.onClose = { [weak self] in
                guard let self = self else { return }
                if self.delegate?.stageHeader(self, shouldCloseStageAt: index) ?? true {
                    self.delegate?.stageHeader(self, didCloseStageAt: index)
                }
            }
            button.setThumbnailMode(isThumbnailMode)
            stageButtons.append(button)
            stackView.addArrangedSubview(button)
        }
        // Re-add the (+) button at the end
        stackView.addArrangedSubview(addStageButton)
    }

    private func rebuildCustomViews() {
        guard let renderer = DockKit.customStageRenderer else {
            rebuildBuiltInButtons()
            return
        }

        // Update header height for custom renderer
        stackHeightConstraint.constant = renderer.headerHeight - 8  // Account for padding

        // Create custom views
        for (index, stage) in stages.enumerated() {
            let view = renderer.createStageView(for: stage, index: index, isActive: index == activeIndex)
            view.onSelect = { [weak self] idx in
                self?.handleStageSelected(at: idx)
            }
            view.stageIndex = index
            customStageViews.append(view)
            stackView.addArrangedSubview(view)
        }
        // Re-add the (+) button at the end
        stackView.addArrangedSubview(addStageButton)
    }

    private func updateButtonStates() {
        // Update built-in buttons
        for (index, button) in stageButtons.enumerated() {
            button.setActive(index == activeIndex)
        }

        // Update custom views
        if let renderer = DockKit.customStageRenderer {
            for (index, view) in customStageViews.enumerated() {
                guard index < stages.count else { continue }
                renderer.updateStageView(view, for: stages[index], index: index, isActive: index == activeIndex)
            }
        }
    }

    private func handleStageSelected(at index: Int) {
        guard index != activeIndex else { return }
        delegate?.stageHeader(self, didSelectStageAt: index)
    }
}

// MARK: - DockStageButton

/// Individual stage button in the header - supports icon+title or thumbnail mode
public class DockStageButton: NSView, DockStageView {
    public var onSelect: ((Int) -> Void)?
    public var onTabDrop: ((Int, DockTabDragInfo) -> Void)?
    public var onClose: (() -> Void)?
    public var stageIndex: Int

    private let stage: Stage
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
    private var closeButton: NSButton!

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

    public init(stage: Stage, index: Int) {
        self.stage = stage
        self.stageIndex = index
        super.init(frame: .zero)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false  // Allow close button to extend outside bounds
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

        if let iconName = stage.iconName {
            let icon = NSImageView()
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: stage.title) {
                icon.image = image
            }
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            contentStack.addArrangedSubview(icon)
            iconView = icon
        }

        let title = stage.title ?? "Stage \(stageIndex + 1)"
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

        // Close button - Mission Control style (round dark circle with white X)
        closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.title = ""
        // Use xmark.circle.fill for Mission Control style
        if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Stage") {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            closeButton.image = image.withSymbolConfiguration(config)
        }
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0  // Hidden by default, shown on hover only
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

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

            // Close button - Mission Control style at top-left corner
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

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

            // Show close button only on hover (Mission Control style)
            closeButton.animator().alphaValue = isHovering ? 1.0 : 0.0
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
            onSelect?(stageIndex)
        }
        updateAppearance()
    }

    @objc private func closeClicked() {
        onClose?()
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

        onTabDrop?(stageIndex, dragInfo)
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
