import AppKit

/// Protocol for custom stage indicator rendering in DockKit stage host windows
///
/// Implement this protocol to create a completely custom look for stage
/// selection indicators in the header bar. The renderer is responsible for
/// creating and updating stage views, handling selection/active state,
/// swipe preview highlighting, and thumbnail display.
///
/// ## Example
/// ```swift
/// class MyStageRenderer: DockStageRenderer {
///     var headerHeight: CGFloat { 48 }
///
///     func createStageView(for stage: Stage, index: Int, isActive: Bool) -> DockStageView {
///         let view = MyStageIndicator()
///         view.configure(stage: stage, index: index, isActive: isActive)
///         return view
///     }
///
///     func updateStageView(_ view: DockStageView, for stage: Stage, index: Int, isActive: Bool) {
///         (view as? MyStageIndicator)?.configure(stage: stage, index: index, isActive: isActive)
///     }
///
///     func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockStageView) {
///         (view as? MyStageIndicator)?.setSwipeTarget(isTarget, swipeMode: swipeMode)
///     }
///
///     func setThumbnail(_ image: NSImage?, on view: DockStageView) {
///         (view as? MyStageIndicator)?.thumbnail = image
///     }
/// }
/// ```
public protocol DockStageRenderer: AnyObject {
    /// Create a view for a stage indicator
    ///
    /// - Parameters:
    ///   - stage: The stage data to display
    ///   - index: The index of this stage (0-based)
    ///   - isActive: Whether this stage is currently active/selected
    /// - Returns: A view conforming to DockStageView protocol
    func createStageView(for stage: Stage, index: Int, isActive: Bool) -> DockStageView

    /// Update an existing stage view with new data
    ///
    /// - Parameters:
    ///   - view: The view to update (previously created by createStageView)
    ///   - stage: The updated stage data
    ///   - index: The index of this stage
    ///   - isActive: Whether this stage is currently active
    func updateStageView(_ view: DockStageView, for stage: Stage, index: Int, isActive: Bool)

    /// Set swipe target highlight on a stage view
    ///
    /// During swipe gestures, the target stage (where the user will switch to)
    /// is highlighted. This is separate from the active state.
    ///
    /// - Parameters:
    ///   - isTarget: Whether this stage is the swipe target
    ///   - swipeMode: Whether a swipe gesture is currently in progress
    ///   - view: The view to update
    func setSwipeTarget(_ isTarget: Bool, swipeMode: Bool, on view: DockStageView)

    /// Set a thumbnail image on a stage view
    ///
    /// Thumbnails are captured from the stage's content and can be displayed
    /// to give users a visual preview of each stage's layout.
    ///
    /// - Parameters:
    ///   - image: The thumbnail image, or nil to clear
    ///   - view: The view to update
    func setThumbnail(_ image: NSImage?, on view: DockStageView)

    /// Height of the header bar in points
    ///
    /// The header view will be constrained to this height.
    var headerHeight: CGFloat { get }
}

/// Protocol for custom stage views created by DockStageRenderer
///
/// Stage views must conform to this protocol to integrate with DockKit's
/// click and interaction handling.
public protocol DockStageView: NSView {
    /// Called when the stage indicator is clicked
    /// The parameter is the stage index
    var onSelect: ((Int) -> Void)? { get set }

    /// The index of this stage view
    var stageIndex: Int { get set }
}

/// Default extension to make standard NSView usable as DockStageView
/// Custom implementations should provide their own stored properties
extension DockStageView {
    public var onSelect: ((Int) -> Void)? {
        get { nil }
        set { }
    }

    public var stageIndex: Int {
        get { 0 }
        set { }
    }
}
