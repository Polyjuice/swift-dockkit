import AppKit
import DockKit

/// Polished tab renderer - beautiful, refined design
/// Features: subtle gradients, smooth shadows, elegant animations, modern aesthetics
class PolishedTabRenderer: DockTabRenderer {

    var tabBarHeight: CGFloat { 44 }

    func createTabView(for tab: DockTab, isSelected: Bool) -> DockTabView {
        let view = PolishedTabView()
        view.configure(tab: tab, isSelected: isSelected)
        return view
    }

    func updateTabView(_ view: DockTabView, for tab: DockTab, isSelected: Bool) {
        (view as? PolishedTabView)?.configure(tab: tab, isSelected: isSelected)
    }

    func setFocused(_ focused: Bool, on view: DockTabView) {
        (view as? PolishedTabView)?.setFocused(focused)
    }

    func createAddButton() -> NSView? {
        return PolishedAddButton()
    }
}

// MARK: - PolishedTabView

class PolishedTabView: NSView, DockTabView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?

    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var backgroundView: NSVisualEffectView!
    private var highlightLayer: CAGradientLayer!
    private var focusRing: NSView!

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
        layer?.cornerRadius = 10
        layer?.masksToBounds = false

        // Background with vibrancy
        backgroundView = NSVisualEffectView()
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Gradient highlight layer
        highlightLayer = CAGradientLayer()
        highlightLayer.cornerRadius = 10
        highlightLayer.locations = [0, 0.5, 1]
        highlightLayer.startPoint = CGPoint(x: 0, y: 0)
        highlightLayer.endPoint = CGPoint(x: 1, y: 1)
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)

        // Focus ring (glowing border)
        focusRing = NSView()
        focusRing.wantsLayer = true
        focusRing.layer?.cornerRadius = 11
        focusRing.layer?.borderWidth = 2
        focusRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        focusRing.isHidden = true
        focusRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusRing)

        // Icon with subtle styling
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title with refined typography
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Close button with smooth appearance
        let closeImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton = NSButton(image: closeImage!, target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Background
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            // Focus ring
            focusRing.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: -1),
            focusRing.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: -1),
            focusRing.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 1),
            focusRing.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: 1),

            // Icon
            iconView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            // Size
            heightAnchor.constraint(equalToConstant: 36),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200)
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
        highlightLayer.frame = backgroundView.frame
    }

    func configure(tab: DockTab, isSelected: Bool) {
        self.isSelected = isSelected

        // Set icon with color
        if let icon = tab.icon {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        }
        iconView.contentTintColor = isSelected ? .controlAccentColor : .tertiaryLabelColor

        titleLabel.stringValue = tab.title

        updateAppearance()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        updateAppearance()
    }

    private func updateAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)

            if isSelected {
                // Selected state: vibrant gradient, shadow
                backgroundView.material = .selection
                titleLabel.animator().textColor = .labelColor

                // Gradient overlay
                highlightLayer.colors = [
                    NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor,
                    NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor,
                    NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
                ]
                highlightLayer.opacity = 1

                // Shadow
                layer?.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
                layer?.shadowOpacity = 1
                layer?.shadowOffset = CGSize(width: 0, height: 2)
                layer?.shadowRadius = 8

                // Icon color
                iconView.contentTintColor = .controlAccentColor

            } else if isHovering {
                // Hover state: subtle highlight
                backgroundView.material = .sidebar
                titleLabel.animator().textColor = .secondaryLabelColor

                highlightLayer.colors = [
                    NSColor.labelColor.withAlphaComponent(0.05).cgColor,
                    NSColor.labelColor.withAlphaComponent(0.02).cgColor,
                    NSColor.clear.cgColor
                ]
                highlightLayer.opacity = 1

                layer?.shadowOpacity = 0.3
                layer?.shadowRadius = 4

                iconView.contentTintColor = .secondaryLabelColor

            } else {
                // Default state: minimal
                backgroundView.material = .sidebar
                titleLabel.animator().textColor = .secondaryLabelColor

                highlightLayer.opacity = 0
                layer?.shadowOpacity = 0

                iconView.contentTintColor = .tertiaryLabelColor
            }

            // Focus ring
            focusRing.isHidden = !(isFocused && isSelected)
            if isFocused && isSelected {
                focusRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            }

            // Close button
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
            closeButton.contentTintColor = isSelected ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()

        // Subtle scale on hover
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layer?.setAffineTransform(CGAffineTransform(scaleX: 1.02, y: 1.02))
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()

        // Return to normal scale
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layer?.setAffineTransform(.identity)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Press effect
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
        }

        if event.clickCount == 1 {
            onDragBegan?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Release effect
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            layer?.setAffineTransform(isHovering ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity)
        }

        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?()
        }
    }
}

// MARK: - PolishedAddButton

class PolishedAddButton: NSView {

    private var button: NSButton!
    private var backgroundView: NSVisualEffectView!

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
        layer?.cornerRadius = 8

        // Frosted background
        backgroundView = NSVisualEffectView()
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        let plusImage = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        button = NSButton(image: plusImage!, target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 28),
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

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().contentTintColor = .controlAccentColor
            layer?.setAffineTransform(CGAffineTransform(scaleX: 1.1, y: 1.1))
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().contentTintColor = .tertiaryLabelColor
            layer?.setAffineTransform(.identity)
        }
    }
}
