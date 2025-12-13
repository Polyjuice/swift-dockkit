import AppKit

/// Protocol for custom desktop indicator rendering in DockKit desktop host windows
///
/// Implement this protocol to create a completely custom look for desktop
/// selection indicators in the header bar. The renderer is responsible for
/// creating and updating desktop views, handling selection/active state,
/// swipe preview highlighting, and thumbnail display.
///
/// ## Example
/// ```swift
/// class MyDesktopRenderer: DockDesktopRenderer {
///     var headerHeight: CGFloat { 48 }
///
///     func createDesktopView(for desktop: Desktop, index: Int, isActive: Bool) -> DockDesktopView {
///         let view = MyDesktopIndicator()
///         view.configure(desktop: desktop, index: index, isActive: isActive)
///         return view
///     }
///
///     func updateDesktopView(_ view: DockDesktopView, for desktop: Desktop, index: Int, isActive: Bool) {
///         (view as? MyDesktopIndicator)?.configure(desktop: desktop, index: index, isActive: isActive)
///     }
///
///     func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockDesktopView) {
///         (view as? MyDesktopIndicator)?.setSwipeTarget(isTarget, swipeMode: swipeMode)
///     }
///
///     func setThumbnail(_ image: NSImage?, on view: DockDesktopView) {
///         (view as? MyDesktopIndicator)?.thumbnail = image
///     }
/// }
/// ```
public protocol DockDesktopRenderer: AnyObject {
    /// Create a view for a desktop indicator
    ///
    /// - Parameters:
    ///   - desktop: The desktop data to display
    ///   - index: The index of this desktop (0-based)
    ///   - isActive: Whether this desktop is currently active/selected
    /// - Returns: A view conforming to DockDesktopView protocol
    func createDesktopView(for desktop: Desktop, index: Int, isActive: Bool) -> DockDesktopView

    /// Update an existing desktop view with new data
    ///
    /// - Parameters:
    ///   - view: The view to update (previously created by createDesktopView)
    ///   - desktop: The updated desktop data
    ///   - index: The index of this desktop
    ///   - isActive: Whether this desktop is currently active
    func updateDesktopView(_ view: DockDesktopView, for desktop: Desktop, index: Int, isActive: Bool)

    /// Set swipe target highlight on a desktop view
    ///
    /// During swipe gestures, the target desktop (where the user will switch to)
    /// is highlighted. This is separate from the active state.
    ///
    /// - Parameters:
    ///   - isTarget: Whether this desktop is the swipe target
    ///   - swipeMode: Whether a swipe gesture is currently in progress
    ///   - view: The view to update
    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockDesktopView)

    /// Set a thumbnail image on a desktop view
    ///
    /// Thumbnails are captured from the desktop's content and can be displayed
    /// to give users a visual preview of each desktop's layout.
    ///
    /// - Parameters:
    ///   - image: The thumbnail image, or nil to clear
    ///   - view: The view to update
    func setThumbnail(_ image: NSImage?, on view: DockDesktopView)

    /// Height of the header bar in points
    ///
    /// The header view will be constrained to this height.
    var headerHeight: CGFloat { get }
}

/// Protocol for custom desktop views created by DockDesktopRenderer
///
/// Desktop views must conform to this protocol to integrate with DockKit's
/// click and interaction handling.
public protocol DockDesktopView: NSView {
    /// Called when the desktop indicator is clicked
    /// The parameter is the desktop index
    var onSelect: ((Int) -> Void)? { get set }

    /// The index of this desktop view
    var desktopIndex: Int { get set }
}

/// Default extension to make standard NSView usable as DockDesktopView
/// Custom implementations should provide their own stored properties
extension DockDesktopView {
    public var onSelect: ((Int) -> Void)? {
        get { nil }
        set { }
    }

    public var desktopIndex: Int {
        get { 0 }
        set { }
    }
}
