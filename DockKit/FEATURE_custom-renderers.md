# DockKit Custom Renderers

DockKit provides a renderer system that allows host apps to completely customize the visual appearance of tabs, desktop indicators, and drop zone overlays while keeping the underlying docking behavior intact.

## Renderer Types

DockKit supports three types of custom renderers:

1. **Tab Renderer** (`DockTabRenderer`) - Customizes tab appearance in tab bars
2. **Desktop Renderer** (`DockDesktopRenderer`) - Customizes desktop indicator appearance in headers
3. **Drop Zone Renderer** (`DockDropZoneRenderer`) - Customizes drop preview styling

## Configuration

### Global Registration

Custom renderers are registered globally via the `DockKit` namespace:

```swift
// Register custom renderers at app launch
DockKit.customTabRenderer = MyTabRenderer()
DockKit.customDesktopRenderer = MyDesktopRenderer()
DockKit.customDropZoneRenderer = MyDropZoneRenderer()
```

### Per-Window Display Mode

Each desktop host window can toggle between three display modes via the `displayMode` property:

```swift
// Programmatically
window.displayMode = .custom  // Use custom renderer
window.displayMode = .tabs    // Use built-in tab style
window.displayMode = .thumbnails  // Use built-in thumbnail style
```

The display mode is also persisted in the layout JSON via `DesktopHostWindowState.displayMode`:

```json
{
  "displayMode": "custom",
  "desktops": [...]
}
```

**Fallback behavior:** If `displayMode` is set to `.custom` but no custom renderer is registered, DockKit falls back to `.tabs` mode.

## Protocol Reference

### DockTabRenderer

```swift
public protocol DockTabRenderer: AnyObject {
    /// Height of the tab bar in points
    var tabBarHeight: CGFloat { get }

    /// Create a view for a single tab
    func createTabView(for tab: DockTab, isSelected: Bool) -> DockTabView

    /// Update an existing tab view with new data
    func updateTabView(_ view: DockTabView, for tab: DockTab, isSelected: Bool)

    /// Set focus state on a tab view
    func setFocused(_ focused: Bool, on view: DockTabView)

    /// Create the "add tab" button (return nil to hide)
    func createAddButton() -> NSView?
}
```

Tab views must conform to `DockTabView`:

```swift
public protocol DockTabView: NSView {
    var onSelect: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onDragBegan: ((NSEvent) -> Void)? { get set }
}
```

### DockDesktopRenderer

```swift
public protocol DockDesktopRenderer: AnyObject {
    /// Height of the header bar in points
    var headerHeight: CGFloat { get }

    /// Create a view for a desktop indicator
    func createDesktopView(for desktop: Desktop, index: Int, isActive: Bool) -> DockDesktopView

    /// Update an existing desktop view
    func updateDesktopView(_ view: DockDesktopView, for desktop: Desktop, index: Int, isActive: Bool)

    /// Set swipe target highlight during gestures
    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockDesktopView)

    /// Set a thumbnail image on a desktop view
    func setThumbnail(_ image: NSImage?, on view: DockDesktopView)
}
```

Desktop views must conform to `DockDesktopView`:

```swift
public protocol DockDesktopView: NSView {
    var onSelect: ((Int) -> Void)? { get set }
    var desktopIndex: Int { get set }
}
```

### DockDropZoneRenderer

```swift
public protocol DockDropZoneRenderer: AnyObject {
    /// Background color for the overlay
    var overlayBackgroundColor: NSColor { get }

    /// Background color for the preview rectangle
    var previewBackgroundColor: NSColor { get }

    /// Border color for the preview rectangle
    var previewBorderColor: NSColor { get }

    /// Border width (default: 2)
    var previewBorderWidth: CGFloat { get }

    /// Corner radius (default: 4)
    var previewCornerRadius: CGFloat { get }

    /// Create a custom preview view (return nil for default rectangle)
    func createPreviewView() -> NSView?

    /// Update custom preview view for a zone
    func updatePreviewView(_ view: NSView, for zone: DockDropZone?, in bounds: CGRect)
}
```

## Example

A complete example demonstrating custom renderers with a "Modern Minimal" design theme is available at:

```
./DockKit-custom-renderer-example
```

To run the example:

```bash
cd DockKit-custom-renderer-example
swift run
```

The example demonstrates:
- **Pill-shaped tabs** with gradient backgrounds and hover effects
- **Card-style desktop indicators** with scale animations and glow effects
- **Frosted glass drop zones** with animated dashed borders

Use the View menu (Cmd+1/2/3) to toggle between tabs, thumbnails, and custom modes.
