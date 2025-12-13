import AppKit

/// Drop zones for the overlay
public enum DockDropZone {
    case center   // Add as tab
    case left     // Split left
    case right    // Split right
    case top      // Split top
    case bottom   // Split bottom
}

/// Delegate for drop overlay events
public protocol DockDropOverlayViewDelegate: AnyObject {
    func dropOverlay(_ overlay: DockDropOverlayView, didSelectZone zone: DockDropZone, withTab tabInfo: DockTabDragInfo)
}

/// Visual overlay shown during drag operations to indicate drop zones
/// Uses edge-based detection: 25% edges for splits, center for tabs
public class DockDropOverlayView: NSView {
    public weak var delegate: DockDropOverlayViewDelegate?

    /// Currently highlighted zone
    private var highlightedZone: DockDropZone?

    /// Preview overlay that shows where content will go (built-in)
    private var previewView: NSView!

    /// Custom preview view (when using custom renderer)
    private var customPreviewView: NSView?

    /// Configuration
    private let edgeThreshold: CGFloat = 0.25  // 25% of width/height for edge zones

    /// Default styling (used when no custom renderer)
    private var overlayBackgroundColor: NSColor {
        DockKit.customDropZoneRenderer?.overlayBackgroundColor ?? NSColor.black.withAlphaComponent(0.05)
    }

    private var previewBackgroundColor: NSColor {
        DockKit.customDropZoneRenderer?.previewBackgroundColor ?? NSColor.black.withAlphaComponent(0.3)
    }

    private var previewBorderColor: NSColor {
        DockKit.customDropZoneRenderer?.previewBorderColor ?? NSColor.controlAccentColor
    }

    private var previewBorderWidth: CGFloat {
        DockKit.customDropZoneRenderer?.previewBorderWidth ?? 2
    }

    private var previewCornerRadius: CGFloat {
        DockKit.customDropZoneRenderer?.previewCornerRadius ?? 4
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupDragAndDrop()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupDragAndDrop()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = overlayBackgroundColor.cgColor

        // Check for custom preview view
        if let customView = DockKit.customDropZoneRenderer?.createPreviewView() {
            customPreviewView = customView
            customView.isHidden = true
            addSubview(customView)
        } else {
            // Built-in preview view
            previewView = NSView()
            previewView.wantsLayer = true
            previewView.layer?.backgroundColor = previewBackgroundColor.cgColor
            previewView.layer?.borderColor = previewBorderColor.cgColor
            previewView.layer?.borderWidth = previewBorderWidth
            previewView.layer?.cornerRadius = previewCornerRadius
            previewView.isHidden = true
            addSubview(previewView)
        }
    }

    /// Refresh styling from renderer (call when renderer changes)
    public func refreshStyling() {
        layer?.backgroundColor = overlayBackgroundColor.cgColor

        if let preview = previewView {
            preview.layer?.backgroundColor = previewBackgroundColor.cgColor
            preview.layer?.borderColor = previewBorderColor.cgColor
            preview.layer?.borderWidth = previewBorderWidth
            preview.layer?.cornerRadius = previewCornerRadius
        }
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([.dockTab])
    }

    // MARK: - Zone Detection (Edge-based)

    /// Detect zone based on cursor position using 25% edge threshold
    private func zoneAt(point: NSPoint) -> DockDropZone {
        let width = bounds.width
        let height = bounds.height

        // Calculate relative position (0-1)
        let relX = point.x / width
        let relY = point.y / height

        // Check edges first (25% threshold)
        // Note: macOS uses bottom-left origin, so "top" is higher Y values
        if relY > (1 - edgeThreshold) {
            return .top
        }
        if relY < edgeThreshold {
            return .bottom
        }
        if relX < edgeThreshold {
            return .left
        }
        if relX > (1 - edgeThreshold) {
            return .right
        }

        // Default to center (tab drop)
        return .center
    }

    /// Update the preview rectangle for the given zone
    private func updatePreview(for zone: DockDropZone?) {
        highlightedZone = zone

        // Handle custom preview view
        if let customView = customPreviewView {
            if let renderer = DockKit.customDropZoneRenderer {
                customView.isHidden = (zone == nil)
                renderer.updatePreviewView(customView, for: zone, in: bounds)
            }
            return
        }

        // Built-in preview
        guard let zone = zone else {
            previewView.isHidden = true
            return
        }

        previewView.isHidden = false
        previewView.frame = frameForZone(zone)
    }

    /// Calculate frame for a given zone
    private func frameForZone(_ zone: DockDropZone) -> NSRect {
        let margin: CGFloat = 4

        switch zone {
        case .center:
            // Full pane - adding as tab
            return bounds.insetBy(dx: margin, dy: margin)

        case .left:
            // Left half
            return NSRect(
                x: margin,
                y: margin,
                width: bounds.width / 2 - margin * 1.5,
                height: bounds.height - margin * 2
            )

        case .right:
            // Right half
            return NSRect(
                x: bounds.width / 2 + margin / 2,
                y: margin,
                width: bounds.width / 2 - margin * 1.5,
                height: bounds.height - margin * 2
            )

        case .top:
            // Top half (higher Y in macOS coordinates)
            return NSRect(
                x: margin,
                y: bounds.height / 2 + margin / 2,
                width: bounds.width - margin * 2,
                height: bounds.height / 2 - margin * 1.5
            )

        case .bottom:
            // Bottom half (lower Y in macOS coordinates)
            return NSRect(
                x: margin,
                y: margin,
                width: bounds.width - margin * 2,
                height: bounds.height / 2 - margin * 1.5
            )
        }
    }

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            return []
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = zoneAt(point: location)
        updatePreview(for: zone)

        return .move
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.dockTab) == true else {
            updatePreview(for: nil)
            return []
        }

        let location = convert(sender.draggingLocation, from: nil)
        let zone = zoneAt(point: location)
        updatePreview(for: zone)

        return .move
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        updatePreview(for: nil)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let zone = highlightedZone,
              let data = sender.draggingPasteboard.data(forType: .dockTab),
              let tabInfo = try? JSONDecoder().decode(DockTabDragInfo.self, from: data) else {
            updatePreview(for: nil)
            return false
        }

        // Clear preview first
        updatePreview(for: nil)

        // IMPORTANT: Defer delegate call to next run loop to avoid crashes
        // The delegate callback may trigger layout changes that destroy this view
        // while we're still inside the drag operation handling
        let capturedDelegate = delegate
        DispatchQueue.main.async {
            capturedDelegate?.dropOverlay(self, didSelectZone: zone, withTab: tabInfo)
        }

        return true
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        updatePreview(for: nil)
    }
}
