import AppKit

/// Global DockKit configuration namespace for custom renderers
///
/// Custom renderers allow host apps to completely customize the visual appearance
/// of DockKit's UI elements while keeping the underlying behavior intact.
///
/// ## Usage
/// ```swift
/// // Register custom renderers globally
/// DockKit.customTabRenderer = MyTabRenderer()
/// DockKit.customStageRenderer = MyStageRenderer()
/// DockKit.customDropZoneRenderer = MyDropZoneRenderer()
///
/// // Then set display mode to .custom on stage host windows
/// stageHostWindow.displayMode = .custom
/// ```
public enum DockKit {
    /// Custom tab renderer for tab bars
    /// When set, windows with `.custom` display mode will use this renderer for tabs.
    /// If nil and `.custom` mode is selected, falls back to `.tabs` mode.
    public static var customTabRenderer: DockTabRenderer?

    /// Custom stage indicator renderer for stage host window headers
    /// When set, windows with `.custom` display mode will use this renderer for stage indicators.
    /// If nil and `.custom` mode is selected, falls back to `.tabs` mode.
    public static var customStageRenderer: DockStageRenderer?

    /// Custom drop zone renderer for drag-and-drop overlays
    /// When set, all drop overlays will use this renderer for styling.
    /// This is global and not affected by display mode.
    public static var customDropZoneRenderer: DockDropZoneRenderer?
}

/// Display mode for stage host windows
/// Controls how tabs and stage indicators are rendered
public enum StageDisplayMode: String, Codable, CaseIterable {
    /// Standard tab bar style (icon + title)
    case tabs

    /// Thumbnail preview style (visual preview of content)
    case thumbnails

    /// Custom renderer (uses globally registered custom renderer)
    /// Falls back to `.tabs` if no custom renderer is registered
    case custom
}
