import AppKit

/// Delegate for desktop header events
public protocol DockDesktopHeaderViewDelegate: AnyObject {
    /// Called when user clicks a desktop to switch to it
    func desktopHeader(_ header: DockDesktopHeaderView, didSelectDesktopAt index: Int)

    /// Called when user reorders desktops (optional)
    func desktopHeader(_ header: DockDesktopHeaderView, didMoveDesktopFrom fromIndex: Int, to toIndex: Int)
}

/// Default implementations
public extension DockDesktopHeaderViewDelegate {
    func desktopHeader(_ header: DockDesktopHeaderView, didMoveDesktopFrom fromIndex: Int, to toIndex: Int) {}
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

    /// Height of the header
    public static let headerHeight: CGFloat = 36

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

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.heightAnchor.constraint(equalToConstant: 28)
        ])
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

/// Individual desktop button in the header
private class DockDesktopButton: NSView {

    var onSelect: ((Int) -> Void)?

    private let desktop: Desktop
    private let index: Int

    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var indicatorView: NSView!

    private var isActive: Bool = false
    private var isSwipeTarget: Bool = false
    private var isInSwipeMode: Bool = false  // True when any button is swipe target
    private var isHovering: Bool = false

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

        // Create content stack
        let contentStack = NSStackView()
        contentStack.orientation = .horizontal
        contentStack.spacing = 4
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        // Icon (if available)
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

        // Title (if available, or default)
        let title = desktop.title ?? "Desktop \(index + 1)"
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(label)
        titleLabel = label

        // Active indicator dot
        indicatorView = NSView()
        indicatorView.wantsLayer = true
        indicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicatorView.layer?.cornerRadius = 2
        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.isHidden = true
        addSubview(indicatorView)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            indicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            indicatorView.widthAnchor.constraint(equalToConstant: 4),
            indicatorView.heightAnchor.constraint(equalToConstant: 4),

            widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
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

    func setActive(_ active: Bool) {
        isActive = active
        updateAppearance()
    }

    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool) {
        isSwipeTarget = isTarget
        isInSwipeMode = swipeMode
        updateAppearance()
    }

    private func updateAppearance() {
        // During swipe, swipeTarget takes precedence for both highlight and indicator
        let shouldHighlight = isSwipeTarget || isActive

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15

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

            // During swipe mode, indicator follows swipe target only
            // When not swiping, indicator follows active
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
        // Visual feedback
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
