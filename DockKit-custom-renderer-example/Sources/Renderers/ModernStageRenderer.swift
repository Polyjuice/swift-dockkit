import AppKit
import DockKit

/// Modern stage renderer with card-style indicators
class ModernStageRenderer: DockStageRenderer {

    var headerHeight: CGFloat { 56 }

    func createStageView(for stage: Stage, index: Int, isActive: Bool) -> DockStageView {
        let view = ModernStageIndicator()
        view.configure(stage: stage, index: index, isActive: isActive)
        return view
    }

    func updateStageView(_ view: DockStageView, for stage: Stage, index: Int, isActive: Bool) {
        (view as? ModernStageIndicator)?.configure(stage: stage, index: index, isActive: isActive)
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockStageView) {
        (view as? ModernStageIndicator)?.setSwipeTarget(isTarget, swipeMode: swipeMode)
    }

    func setThumbnail(_ image: NSImage?, on view: DockStageView) {
        (view as? ModernStageIndicator)?.thumbnail = image
    }
}

// MARK: - ModernStageIndicator

class ModernStageIndicator: NSView, DockStageView {
    var onSelect: ((Int) -> Void)?
    var stageIndex: Int = 0

    var thumbnail: NSImage? {
        didSet {
            thumbnailView.image = thumbnail
        }
    }

    private var backgroundLayer: CALayer!
    private var glowLayer: CALayer!
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var badgeLabel: NSTextField!
    private var thumbnailView: NSImageView!

    private var isActive: Bool = false
    private var isSwipeTarget: Bool = false
    private var isInSwipeMode: Bool = false
    private var isHovering: Bool = false

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
        translatesAutoresizingMaskIntoConstraints = false

        // Glow layer (behind card)
        glowLayer = CALayer()
        glowLayer.cornerRadius = 10
        glowLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        glowLayer.opacity = 0
        layer?.addSublayer(glowLayer)

        // Background layer (card)
        backgroundLayer = CALayer()
        backgroundLayer.cornerRadius = 8
        backgroundLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        backgroundLayer.borderWidth = 1
        backgroundLayer.borderColor = NSColor.separatorColor.cgColor
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.1
        backgroundLayer.shadowOffset = CGSize(width: 0, height: 2)
        backgroundLayer.shadowRadius = 4
        layer?.addSublayer(backgroundLayer)

        // Thumbnail view
        thumbnailView = NSImageView()
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumbnailView.isHidden = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)

        // Icon
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Badge (stage number)
        badgeLabel = NSTextField(labelWithString: "1")
        badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        badgeLabel.layer?.cornerRadius = 8
        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            // Thumbnail
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            thumbnailView.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -4),

            // Icon
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            // Badge
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badgeLabel.widthAnchor.constraint(equalToConstant: 16),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),

            // Size
            widthAnchor.constraint(equalToConstant: 70),
            heightAnchor.constraint(equalToConstant: 48)
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

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        glowLayer.frame = bounds.insetBy(dx: 0, dy: 0)
    }

    func configure(stage: Stage, index: Int, isActive: Bool) {
        self.stageIndex = index
        self.isActive = isActive

        // Set icon
        if let iconName = stage.iconName,
           let image = NSImage(systemSymbolName: iconName, accessibilityDescription: stage.title) {
            iconView.image = image
        } else {
            iconView.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        }
        iconView.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor

        // Set title
        titleLabel.stringValue = stage.title ?? "Stage \(index + 1)"

        // Set badge
        badgeLabel.stringValue = "\(index + 1)"

        updateAppearance()
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool) {
        isSwipeTarget = isTarget
        isInSwipeMode = swipeMode
        updateAppearance()
    }

    private func updateAppearance() {
        let shouldHighlight = isSwipeTarget || isActive

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2

            // Scale animation on hover
            if isHovering && !shouldHighlight {
                layer?.setAffineTransform(CGAffineTransform(scaleX: 1.02, y: 1.02))
            } else {
                layer?.setAffineTransform(.identity)
            }

            // Card appearance
            if shouldHighlight {
                backgroundLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                backgroundLayer.borderColor = NSColor.controlAccentColor.cgColor
                titleLabel.animator().textColor = .labelColor

                // Glow effect
                glowLayer.opacity = 0.3

                // Badge
                badgeLabel.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else if isHovering {
                backgroundLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
                backgroundLayer.borderColor = NSColor.separatorColor.cgColor
                titleLabel.animator().textColor = .secondaryLabelColor
                glowLayer.opacity = 0
                badgeLabel.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            } else {
                backgroundLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
                backgroundLayer.borderColor = NSColor.separatorColor.cgColor
                titleLabel.animator().textColor = .secondaryLabelColor
                glowLayer.opacity = 0
                badgeLabel.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            }
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
        backgroundLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onSelect?(stageIndex)
        }
        updateAppearance()
    }
}
