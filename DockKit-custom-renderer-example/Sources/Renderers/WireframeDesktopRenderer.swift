import AppKit
import DockKit

/// Wireframe desktop renderer - minimalist, barebone style
/// Matches the WireframeTabRenderer aesthetic: bold font, black border, white background
class WireframeDesktopRenderer: DockDesktopRenderer {

    var headerHeight: CGFloat { 44 }

    func createDesktopView(for desktop: Desktop, index: Int, isActive: Bool) -> DockDesktopView {
        let view = WireframeDesktopView(desktop: desktop, index: index)
        view.setActive(isActive)
        return view
    }

    func updateDesktopView(_ view: DockDesktopView, for desktop: Desktop, index: Int, isActive: Bool) {
        (view as? WireframeDesktopView)?.setActive(isActive)
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockDesktopView) {
        (view as? WireframeDesktopView)?.setSwipeTarget(isTarget, swipeMode: swipeMode)
    }

    func setThumbnail(_ image: NSImage?, on view: DockDesktopView) {
        // Wireframe doesn't use thumbnails - just text
    }
}

// MARK: - WireframeDesktopView

class WireframeDesktopView: NSView, DockDesktopView {
    var onSelect: ((Int) -> Void)?
    var desktopIndex: Int

    private var titleLabel: NSTextField!
    private var indexLabel: NSTextField!
    private var isActive: Bool = false
    private var isSwipeTarget: Bool = false
    private var isHovering: Bool = false

    init(desktop: Desktop, index: Int) {
        self.desktopIndex = index
        super.init(frame: .zero)
        setupUI(desktop: desktop, index: index)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(desktop: Desktop, index: Int) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.black.cgColor
        layer?.borderWidth = 2

        // Index number (top-right corner)
        indexLabel = NSTextField(labelWithString: "\(index + 1)")
        indexLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        indexLabel.textColor = .white
        indexLabel.alignment = .center
        indexLabel.wantsLayer = true
        indexLabel.layer?.backgroundColor = NSColor.black.cgColor
        indexLabel.layer?.cornerRadius = 8
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indexLabel)

        // Title
        titleLabel = NSTextField(labelWithString: (desktop.title ?? "DESKTOP").uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .black
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            // Index badge top-right
            indexLabel.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            indexLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            indexLabel.widthAnchor.constraint(equalToConstant: 16),
            indexLabel.heightAnchor.constraint(equalToConstant: 16),

            // Title centered
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

            // Size
            widthAnchor.constraint(equalToConstant: 80),
            heightAnchor.constraint(equalToConstant: 32)
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

    func setActive(_ active: Bool) {
        isActive = active
        updateAppearance()
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool) {
        isSwipeTarget = isTarget
        updateAppearance()
    }

    private func updateAppearance() {
        let shouldHighlight = isActive || isSwipeTarget

        if shouldHighlight {
            layer?.backgroundColor = NSColor.black.cgColor
            titleLabel.textColor = .white
            indexLabel.layer?.backgroundColor = NSColor.white.cgColor
            indexLabel.textColor = .black
        } else if isHovering {
            layer?.backgroundColor = NSColor(white: 0.9, alpha: 1.0).cgColor
            titleLabel.textColor = .black
            indexLabel.layer?.backgroundColor = NSColor.black.cgColor
            indexLabel.textColor = .white
        } else {
            layer?.backgroundColor = NSColor.white.cgColor
            titleLabel.textColor = .black
            indexLabel.layer?.backgroundColor = NSColor.black.cgColor
            indexLabel.textColor = .white
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
        layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        titleLabel.textColor = .white
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?(desktopIndex)
        }
        updateAppearance()
    }
}
