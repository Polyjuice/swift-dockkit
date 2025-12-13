import AppKit
import DockKit

/// Modern drop zone renderer with frosted glass effect and animated borders
class ModernDropZoneRenderer: DockDropZoneRenderer {

    var overlayBackgroundColor: NSColor {
        NSColor.black.withAlphaComponent(0.08)
    }

    var previewBackgroundColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.15)
    }

    var previewBorderColor: NSColor {
        NSColor.controlAccentColor
    }

    var previewBorderWidth: CGFloat { 3 }

    var previewCornerRadius: CGFloat { 12 }

    func createPreviewView() -> NSView? {
        return ModernDropPreviewView()
    }

    func updatePreviewView(_ view: NSView, for zone: DockDropZone?, in bounds: CGRect) {
        (view as? ModernDropPreviewView)?.update(for: zone, in: bounds)
    }
}

// MARK: - ModernDropPreviewView

class ModernDropPreviewView: NSView {

    private var visualEffect: NSVisualEffectView!
    private var borderLayer: CAShapeLayer!
    private var iconView: NSImageView!
    private var labelView: NSTextField!

    private var currentZone: DockDropZone?
    private var pulseAnimation: CAAnimation?

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

        // Frosted glass effect
        visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .withinWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)

        // Animated dashed border
        borderLayer = CAShapeLayer()
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = 3
        borderLayer.lineDashPattern = [8, 4]
        borderLayer.cornerRadius = 12
        layer?.addSublayer(borderLayer)

        // Zone icon
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Zone label
        labelView = NSTextField(labelWithString: "")
        labelView.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        labelView.textColor = .controlAccentColor
        labelView.alignment = .center
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        NSLayoutConstraint.activate([
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            labelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8)
        ])
    }

    override func layout() {
        super.layout()
        updateBorderPath()
    }

    private func updateBorderPath() {
        let path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                          cornerWidth: 12, cornerHeight: 12, transform: nil)
        borderLayer.path = path
        borderLayer.frame = bounds
    }

    func update(for zone: DockDropZone?, in bounds: CGRect) {
        guard let zone = zone else {
            stopPulseAnimation()
            self.isHidden = true
            return
        }

        self.isHidden = false
        currentZone = zone

        // Calculate frame for zone
        let margin: CGFloat = 8
        let newFrame: NSRect
        switch zone {
        case .center:
            newFrame = bounds.insetBy(dx: margin, dy: margin)
        case .left:
            newFrame = NSRect(x: margin, y: margin,
                              width: bounds.width / 2 - margin * 1.5,
                              height: bounds.height - margin * 2)
        case .right:
            newFrame = NSRect(x: bounds.width / 2 + margin / 2, y: margin,
                              width: bounds.width / 2 - margin * 1.5,
                              height: bounds.height - margin * 2)
        case .top:
            newFrame = NSRect(x: margin, y: bounds.height / 2 + margin / 2,
                              width: bounds.width - margin * 2,
                              height: bounds.height / 2 - margin * 1.5)
        case .bottom:
            newFrame = NSRect(x: margin, y: margin,
                              width: bounds.width - margin * 2,
                              height: bounds.height / 2 - margin * 1.5)
        }

        // Animate frame change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().frame = newFrame
        }

        // Update icon and label
        updateZoneContent(zone)

        // Start pulse animation
        startPulseAnimation()
    }

    private func updateZoneContent(_ zone: DockDropZone) {
        let iconName: String
        let labelText: String

        switch zone {
        case .center:
            iconName = "plus.rectangle.on.rectangle"
            labelText = "Add Tab"
        case .left:
            iconName = "arrow.left.to.line"
            labelText = "Split Left"
        case .right:
            iconName = "arrow.right.to.line"
            labelText = "Split Right"
        case .top:
            iconName = "arrow.up.to.line"
            labelText = "Split Top"
        case .bottom:
            iconName = "arrow.down.to.line"
            labelText = "Split Bottom"
        }

        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: labelText)
        labelView.stringValue = labelText
    }

    private func startPulseAnimation() {
        // Animate the dash pattern for "marching ants" effect
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = 12
        animation.duration = 0.4
        animation.repeatCount = .infinity
        borderLayer.add(animation, forKey: "dashPhase")

        // Pulse the opacity
        let pulseAnim = CABasicAnimation(keyPath: "opacity")
        pulseAnim.fromValue = 0.8
        pulseAnim.toValue = 1.0
        pulseAnim.duration = 0.5
        pulseAnim.autoreverses = true
        pulseAnim.repeatCount = .infinity
        visualEffect.layer?.add(pulseAnim, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        borderLayer.removeAnimation(forKey: "dashPhase")
        visualEffect.layer?.removeAnimation(forKey: "pulse")
    }
}
