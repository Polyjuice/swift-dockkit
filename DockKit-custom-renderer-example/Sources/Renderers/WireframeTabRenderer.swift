import AppKit
import DockKit

/// Wireframe tab renderer - minimalist, barebone style
/// Features: bold font, black border, white background
class WireframeTabRenderer: DockTabRenderer {

    var tabBarHeight: CGFloat { 36 }

    func createTabView(for tab: DockTab, isSelected: Bool) -> DockTabView {
        let view = WireframeTabView()
        view.configure(tab: tab, isSelected: isSelected)
        return view
    }

    func updateTabView(_ view: DockTabView, for tab: DockTab, isSelected: Bool) {
        (view as? WireframeTabView)?.configure(tab: tab, isSelected: isSelected)
    }

    func setFocused(_ focused: Bool, on view: DockTabView) {
        (view as? WireframeTabView)?.setFocused(focused)
    }

    func createAddButton() -> NSView? {
        return WireframeAddButton()
    }
}

// MARK: - WireframeTabView

class WireframeTabView: NSView, DockTabView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?

    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var focusDot: NSView!

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
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.black.cgColor
        layer?.borderWidth = 2

        // Focus dot (left side)
        focusDot = NSView()
        focusDot.wantsLayer = true
        focusDot.layer?.backgroundColor = NSColor.black.cgColor
        focusDot.layer?.cornerRadius = 4
        focusDot.isHidden = true
        focusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusDot)

        // Bold title
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .black
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Close button (simple X)
        closeButton = NSButton(title: "X", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeButton.contentTintColor = .black
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Focus dot
            focusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            focusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusDot.widthAnchor.constraint(equalToConstant: 8),
            focusDot.heightAnchor.constraint(equalToConstant: 8),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: focusDot.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // Size
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160)
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

    func configure(tab: DockTab, isSelected: Bool) {
        self.isSelected = isSelected
        titleLabel.stringValue = tab.title.uppercased()  // Uppercase for wireframe look
        updateAppearance()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        focusDot.isHidden = !(focused && isSelected)
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.black.cgColor
            titleLabel.textColor = .white
            closeButton.contentTintColor = .white
        } else if isHovering {
            layer?.backgroundColor = NSColor(white: 0.9, alpha: 1.0).cgColor
            titleLabel.textColor = .black
            closeButton.contentTintColor = .black
        } else {
            layer?.backgroundColor = NSColor.white.cgColor
            titleLabel.textColor = .black
            closeButton.contentTintColor = .black
        }

        focusDot.layer?.backgroundColor = isSelected ? NSColor.white.cgColor : NSColor.black.cgColor
        focusDot.isHidden = !(isFocused && isSelected)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            closeButton.animator().alphaValue = (isHovering || isSelected) ? 1.0 : 0.0
        }
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

// MARK: - WireframeAddButton

class WireframeAddButton: NSView {

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
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.black.cgColor
        layer?.borderWidth = 2

        button = NSButton(title: "+", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        button.contentTintColor = .black
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
