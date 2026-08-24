import AppKit

/// Protocol for panels that can be docked in the docking system
public protocol DockablePanel: AnyObject {
    /// Unique identifier for this panel instance
    var panelId: UUID { get }

    /// Display title for the panel tab
    var panelTitle: String { get }

    /// Icon shown in the tab (optional)
    var panelIcon: NSImage? { get }

    /// The view controller that provides the panel's content
    var panelViewController: NSViewController { get }

    /// The view that should receive keyboard focus when this panel is activated.
    /// Default implementation returns the panel's view.
    var preferredFirstResponder: NSView? { get }

    /// Whether the panel can be docked at the given position
    /// Default implementation returns true for all positions
    func canDock(at position: DockPosition) -> Bool

    /// Called when the panel is about to be detached (tear-off).
    /// Fires for both terminal removal AND reparenting (drag between windows),
    /// so panels that own external resources (CEF browsers, processes) must
    /// NOT dispose them here — use `panelWillBeDestroyed()` instead.
    func panelWillDetach()

    /// Called when the host has decided this panel is gone for good and will
    /// not be reparented. This is the place to dispose external resources
    /// (close CEF browsers, kill child processes, cancel in-flight Tasks).
    /// Called before `panelWillDetach()` during terminal cleanup. Not called
    /// during reparenting.
    func panelWillBeDestroyed()

    /// Called when the panel is docked into a new location
    func panelDidDock(at position: DockPosition)

    /// Called when the panel becomes the active tab in its group
    func panelDidBecomeActive()

    /// Called when another tab becomes active (this panel goes to background)
    func panelDidResignActive()

    /// Update the panel's display title
    /// Implementations should update their internal title state.
    /// The docking system will re-read panelTitle after calling this.
    func updateTitle(_ newTitle: String)
}

/// Default implementations for optional protocol methods
public extension DockablePanel {
    var preferredFirstResponder: NSView? { panelViewController.view }
    func canDock(at position: DockPosition) -> Bool { true }
    func panelWillDetach() {}
    func panelWillBeDestroyed() {}
    func panelDidDock(at position: DockPosition) {}
    func panelDidBecomeActive() {}
    func panelDidResignActive() {}
    func updateTitle(_ newTitle: String) {}
}

/// Positions where a panel can be docked
public enum DockPosition: Equatable, Codable {
    case left
    case right
    case top
    case bottom
    case center
    case floating
}

/// Direction for splitting a dock area
public enum DockSplitDirection: String, Codable {
    case left
    case right
    case top
    case bottom
}
