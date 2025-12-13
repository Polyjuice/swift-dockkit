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
}

/// Default implementations
public extension DockDesktopHeaderViewDelegate {
    func desktopHeader(_ header: DockDesktopHeaderView, didMoveDesktopFrom fromIndex: Int, to toIndex: Int) {}
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleSlowMotion enabled: Bool) {}
    func desktopHeader(_ header: DockDesktopHeaderView, didToggleThumbnailMode enabled: Bool) {}
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

    /// Desktop indicator buttons
    private var desktopButtons: [DockDesktopButton] = []

    /// Stack view height constraint (changes in thumbnail mode)
    private var stackHeightConstraint: NSLayoutConstraint!

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

    /// Current thumbnail mode state
    private var isThumbnailMode: Bool = false

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

        stackHeightConstraint = stackView.heightAnchor.constraint(equalToConstant: 28)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackHeightConstraint
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
        for (i, button) in desktopButtons.enumerated() {
            button.setSwipeTarget(i == index, swipeMode: true)
        }
    }

    /// Clear swipe highlighting (called when swipe ends)
    public func clearSwipeHighlight() {
        for button in desktopButtons {
            button.setSwipeTarget(false, swipeMode: false)
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
        for (index, button) in desktopButtons.enumerated() {
            if index < thumbnails.count {
                button.setThumbnail(thumbnails[index])
            }
        }
    }

    /// Set thumbnail for a specific desktop
    public func setThumbnail(_ thumbnail: NSImage?, at index: Int) {
        guard index >= 0 && index < desktopButtons.count else { return }
        desktopButtons[index].setThumbnail(thumbnail)
    }

    // MARK: - Private Methods

    private func rebuildButtons() {
        // Remove old buttons
        desktopButtons.forEach { $0.removeFromSuperview() }
        desktopButtons.removeAll()

        // Create new buttons
        for (index, desktop) in desktops.enumerated() {
            let button = DockDesktopButton(desktop: desktop, index: index)
            button.onSelect = { [weak self] idx in
                self?.handleDesktopSelected(at: idx)
            }
            button.setThumbnailMode(isThumbnailMode)
            desktopButtons.append(button)
            stackView.addArrangedSubview(button)
        }

        updateButtonStates()
    }

    private func updateButtonStates() {
        for (index, button) in desktopButtons.enumerated() {
            button.setActive(index == activeIndex)
        }
    }

    private func handleDesktopSelected(at index: Int) {
        guard index != activeIndex else { return }
        delegate?.desktopHeader(self, didSelectDesktopAt: index)
    }
}

// MARK: - DockDesktopButton

/// Individual desktop button in the header - supports icon+title or thumbnail mode
private class DockDesktopButton: NSView {

    var onSelect: ((Int) -> Void)?

    private let desktop: Desktop
    private let index: Int

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
    static let thumbnailWidth: CGFloat = 120
    static let thumbnailHeight: CGFloat = 80

    init(desktop: Desktop, index: Int) {
        self.desktop = desktop
        self.index = index
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
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

        let title = desktop.title ?? "Desktop \(index + 1)"
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
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateAppearance()
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool) {
        isSwipeTarget = isTarget
        isInSwipeMode = swipeMode
        updateAppearance()
    }

    func setThumbnailMode(_ enabled: Bool) {
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

    func setThumbnail(_ image: NSImage?) {
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

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?(index)
        }
        updateAppearance()
    }
}
