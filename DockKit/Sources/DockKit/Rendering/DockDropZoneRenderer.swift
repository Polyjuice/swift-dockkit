import AppKit

/// Protocol for custom drop zone rendering in DockKit
///
/// Implement this protocol to customize the visual appearance of drop zone
/// overlays that appear during drag-and-drop operations. The renderer controls
/// the overlay background, zone preview styling, and can provide completely
/// custom preview views.
///
/// Note: The drop zone detection logic (25% edge threshold) is not customizable.
/// This protocol only controls the visual appearance.
///
/// ## Example
/// ```swift
/// class MyDropZoneRenderer: DockDropZoneRenderer {
///     var overlayBackgroundColor: NSColor {
///         NSColor.black.withAlphaComponent(0.1)
///     }
///
///     var previewBackgroundColor: NSColor {
///         NSColor.systemBlue.withAlphaComponent(0.2)
///     }
///
///     var previewBorderColor: NSColor {
///         NSColor.systemBlue
///     }
///
///     var previewBorderWidth: CGFloat { 3 }
///
///     var previewCornerRadius: CGFloat { 8 }
///
///     func createPreviewView() -> NSView? {
///         // Return nil to use default rectangle, or custom view
///         return MyAnimatedPreviewView()
///     }
///
///     func updatePreviewView(_ view: NSView, for zone: DockDropZone, in bounds: CGRect) {
///         (view as? MyAnimatedPreviewView)?.animateTo(zone: zone, bounds: bounds)
///     }
/// }
/// ```
public protocol DockDropZoneRenderer: AnyObject {
    /// Background color for the entire overlay view
    ///
    /// This tints the drop target area to indicate it can receive drops.
    /// Typically a semi-transparent dark color.
    var overlayBackgroundColor: NSColor { get }

    /// Background color for the zone preview rectangle
    ///
    /// This fills the rectangle showing where content will be placed.
    var previewBackgroundColor: NSColor { get }

    /// Border color for the zone preview rectangle
    var previewBorderColor: NSColor { get }

    /// Border width for the zone preview rectangle
    var previewBorderWidth: CGFloat { get }

    /// Corner radius for the zone preview rectangle
    var previewCornerRadius: CGFloat { get }

    /// Create a custom preview view (optional)
    ///
    /// Return nil to use the default rectangle-based preview.
    /// If you return a custom view, you must implement `updatePreviewView`
    /// to position and animate it.
    ///
    /// - Returns: A custom preview view, or nil for default behavior
    func createPreviewView() -> NSView?

    /// Update the custom preview view for a zone
    ///
    /// Only called if `createPreviewView()` returned a non-nil view.
    /// Use this to animate or position your custom preview based on the
    /// currently hovered zone.
    ///
    /// - Parameters:
    ///   - view: The preview view (created by createPreviewView)
    ///   - zone: The currently hovered zone, or nil if no zone is active
    ///   - bounds: The bounds of the overlay view
    func updatePreviewView(_ view: NSView, for zone: DockDropZone?, in bounds: CGRect)
}

/// Default implementations for optional protocol methods
public extension DockDropZoneRenderer {
    var previewBorderWidth: CGFloat { 2 }

    var previewCornerRadius: CGFloat { 4 }

    func createPreviewView() -> NSView? {
        nil
    }

    func updatePreviewView(_ view: NSView, for zone: DockDropZone?, in bounds: CGRect) {
        // Default: no-op, using rectangle-based preview
    }
}
