# DockKit Custom Renderers

DockKit provides a renderer system that allows host apps to completely customize the visual appearance of tabs, stage indicators, and drop zone overlays while keeping the underlying docking behavior intact.

## Renderer Types

DockKit supports three types of custom renderers:

1. **Tab Renderer** (`DockTabRenderer`) - Customizes tab appearance in tab bars
2. **Stage Renderer** (`DockStageRenderer`) - Customizes stage indicator appearance in headers
3. **Drop Zone Renderer** (`DockDropZoneRenderer`) - Customizes drop preview styling

## Configuration

### Global Registration

Custom renderers are registered globally via the `DockKit` namespace:

```swift
// Register custom renderers at app launch
DockKit.customTabRenderer = MyTabRenderer()
DockKit.customStageRenderer = MyStageRenderer()
DockKit.customDropZoneRenderer = MyDropZoneRenderer()
```

### Per-Window Display Mode

Each stage host window can toggle between display modes via the `displayMode` property:

```swift
// Programmatically
window.displayMode = .tabs    // Use built-in tab style
window.displayMode = .custom  // Use custom renderer
```

**Note:** The `.thumbnails` mode is for stage switching in the header only, not for the tab bar. Tab bars support `.tabs` (standard) or `.custom` modes.

The display mode is also persisted in the layout JSON via `StageHostWindowState.displayMode`:

```json
{
  "displayMode": "custom",
  "stages": [...]
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

### DockStageRenderer

```swift
public protocol DockStageRenderer: AnyObject {
    /// Height of the header bar in points
    var headerHeight: CGFloat { get }

    /// Create a view for a stage indicator
    func createStageView(for stage: Stage, index: Int, isActive: Bool) -> DockStageView

    /// Update an existing stage view
    func updateStageView(_ view: DockStageView, for stage: Stage, index: Int, isActive: Bool)

    /// Set swipe target highlight during gestures
    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockStageView)

    /// Set a thumbnail image on a stage view
    func setThumbnail(_ image: NSImage?, on view: DockStageView)
}
```

Stage views must conform to `DockStageView`:

```swift
public protocol DockStageView: NSView {
    var onSelect: ((Int) -> Void)? { get set }
    var stageIndex: Int { get set }
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

A complete example demonstrating custom renderers is available at:

```
./DockKit-custom-renderer-example
```

To run the example:

```bash
cd DockKit-custom-renderer-example
swift run
```

The example includes two custom renderer styles selectable via the control bar:

### Wireframe Style
A minimalist, barebone design for prototyping and debugging:
- **Bold uppercase text** with black borders on white background
- **Inverted colors** (white-on-black) for selected states
- **Index badges** on stage indicators

### Polished Style
A refined, production-ready design:
- **Frosted glass backgrounds** with vibrancy effects
- **Gradient highlights** and subtle shadows
- **Smooth hover/press animations** with scale effects
- **Focus rings** for accessibility

Both styles include matching tab renderers and stage renderers that switch together.

The control bar at the top allows switching between:
- **Tab Style:** Standard | Custom
- **Custom Style:** Wireframe | Polished (when Custom is selected)
