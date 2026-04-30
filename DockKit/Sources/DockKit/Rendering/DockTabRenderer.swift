import AppKit

/// Protocol for custom tab rendering in DockKit tab bars
///
/// Implement this protocol to create a completely custom look for tabs.
/// The renderer is responsible for creating and updating tab views, handling
/// selection state, focus indicators, and close button behavior.
///
/// ## Example
/// ```swift
/// class MyTabRenderer: DockTabRenderer {
///     var tabBarHeight: CGFloat { 36 }
///
///     func createTabView(for panel: Panel, isSelected: Bool) -> DockTabView {
///         let view = MyCustomTabView()
///         view.configure(panel: panel, isSelected: isSelected)
///         return view
///     }
///
///     func updateTabView(_ view: DockTabView, for panel: Panel, isSelected: Bool) {
///         (view as? MyCustomTabView)?.configure(panel: panel, isSelected: isSelected)
///     }
///
///     func setFocused(_ focused: Bool, on view: DockTabView) {
///         (view as? MyCustomTabView)?.setFocused(focused)
///     }
///
///     func createAddButton(for action: PanelAddAction?) -> NSView? {
///         return MyAddButton(iconName: action?.iconName ?? "plus")
///     }
/// }
/// ```
public protocol DockTabRenderer: AnyObject {
    /// Create a view for a single tab
    ///
    /// - Parameters:
    ///   - panel: The panel data to display (a Panel with content: .content)
    ///   - isSelected: Whether this tab is currently selected
    /// - Returns: A view conforming to DockTabView protocol
    func createTabView(for panel: Panel, isSelected: Bool) -> DockTabView

    /// Update an existing tab view with new data
    ///
    /// - Parameters:
    ///   - view: The view to update (previously created by createTabView)
    ///   - panel: The updated panel data
    ///   - isSelected: Whether this tab is currently selected
    func updateTabView(_ view: DockTabView, for panel: Panel, isSelected: Bool)

    /// Set focus state on a tab view
    ///
    /// Focus indicates the tab's panel currently has keyboard focus.
    /// This is separate from selection - a selected tab may not have focus.
    ///
    /// - Parameters:
    ///   - focused: Whether the tab should show focus indicator
    ///   - view: The view to update
    func setFocused(_ focused: Bool, on view: DockTabView)

    /// Height of the tab bar in points
    ///
    /// The tab bar view will be constrained to this height.
    var tabBarHeight: CGFloat { get }

    /// Create the "add tab" button.
    ///
    /// Called once per `PanelAddAction` declared on the group, in order, when
    /// rendering the trailing edge of the tab bar. When the group declares no
    /// add actions (legacy/default case), this is called once with `action == nil`
    /// and should produce the default single "+" button.
    ///
    /// Return nil to fall back to DockKit's built-in `AddActionButton` for that
    /// action. Returned views should handle their own click events and forward
    /// the click to the appropriate delegate path.
    ///
    /// - Parameter action: The `PanelAddAction` describing the button to render,
    ///   or `nil` for the default/legacy single-button case.
    /// - Returns: A view for the add button, or nil to use the built-in button.
    func createAddButton(for action: PanelAddAction?) -> NSView?
}

/// Protocol for custom tab views created by DockTabRenderer
///
/// Tab views must conform to this protocol to integrate with DockKit's
/// drag-and-drop and event handling system.
public protocol DockTabView: NSView {
    /// Called when the tab is selected (clicked)
    var onSelect: (() -> Void)? { get set }

    /// Called when the close button is clicked
    var onClose: (() -> Void)? { get set }

    /// Called when a drag operation begins on this tab
    var onDragBegan: ((NSEvent) -> Void)? { get set }
}

/// Default extension to make standard NSView usable as DockTabView
/// Custom implementations should provide their own stored properties
extension DockTabView {
    public var onSelect: (() -> Void)? {
        get { nil }
        set { }
    }

    public var onClose: (() -> Void)? {
        get { nil }
        set { }
    }

    public var onDragBegan: ((NSEvent) -> Void)? {
        get { nil }
        set { }
    }
}
