import AppKit
import DockKit

/// Modern tab renderer with pill-shaped tabs and smooth animations
class ModernTabRenderer: DockTabRenderer {

    var tabBarHeight: CGFloat { 40 }

    func createTabView(for tab: DockTab, isSelected: Bool) -> DockTabView {
        let view = ModernTabView()
        view.configure(tab: tab, isSelected: isSelected)
        return view
    }

    func updateTabView(_ view: DockTabView, for tab: DockTab, isSelected: Bool) {
        (view as? ModernTabView)?.configure(tab: tab, isSelected: isSelected)
    }

    func setFocused(_ focused: Bool, on view: DockTabView) {
        (view as? ModernTabView)?.setFocused(focused)
    }

    func createAddButton() -> NSView? {
        let button = ModernAddButton()
        return button
    }
}

// MARK: - ModernTabView

class ModernTabView: NSView, DockTabView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?

    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var backgroundLayer: CALayer!
    private var focusIndicator: NSView!

    private var isSelected: Bool = false
    private var isHovering: Bool = false
    private var isFocused: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // Background layer (pill shape)
        backgroundLayer = CALayer()
        backgroundLayer.cornerRadius = 16
        backgroundLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(backgroundLayer)

        // Focus indicator (small colored dot)
        focusIndicator = NSView()
        focusIndicator.wantsLayer = true
        focusIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        focusIndicator.layer?.cornerRadius = 3
        focusIndicator.isHidden = true
        focusIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusIndicator)

        // Icon
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Close button
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Focus indicator
            focusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            focusIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusIndicator.widthAnchor.constraint(equalToConstant: 6),
            focusIndicator.heightAnchor.constraint(equalToConstant: 6),

            // Icon
            iconView.leadingAnchor.constraint(equalTo: focusIndicator.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // Size
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180)
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

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds.insetBy(dx: 2, dy: 4)
    }

    func configure(tab: DockTab, isSelected: Bool) {
        self.isSelected = isSelected

        // Set icon with gradient tint
        if let icon = tab.icon {
            iconView.image = icon
            iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            iconView.contentTintColor = isSelected ? .controlAccentColor : .tertiaryLabelColor
        }

        titleLabel.stringValue = tab.title

        updateAppearance()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        focusIndicator.isHidden = !(focused && isSelected)
    }

    private func updateAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            if isSelected {
                // Selected: gradient background
                backgroundLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                titleLabel.animator().textColor = .labelColor

                // Add subtle shadow
                backgroundLayer.shadowColor = NSColor.controlAccentColor.cgColor
                backgroundLayer.shadowOpacity = 0.2
                backgroundLayer.shadowOffset = CGSize(width: 0, height: 1)
                backgroundLayer.shadowRadius = 4
            } else if isHovering {
                backgroundLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
                titleLabel.animator().textColor = .secondaryLabelColor
                backgroundLayer.shadowOpacity = 0
            } else {
                backgroundLayer.backgroundColor = NSColor.clear.cgColor
                titleLabel.animator().textColor = .secondaryLabelColor
                backgroundLayer.shadowOpacity = 0
            }

            // Close button visibility
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }

        focusIndicator.isHidden = !(isFocused && isSelected)
    }

    @objc private func closeClicked() {
        onClose?()
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
        if event.clickCount == 1 {
            onDragBegan?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?()
        }
    }
}

// MARK: - ModernAddButton

class ModernAddButton: NSView {

    private var button: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 12

        button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")!, target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }
}
