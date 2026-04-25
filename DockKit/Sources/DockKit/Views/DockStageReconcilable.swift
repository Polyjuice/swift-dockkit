import AppKit

/// React-style reconciliation protocol for stage-level view controllers.
/// Implementations apply a new Panel in place — reusing the existing view
/// hierarchy and only diffing what actually changed — so identical panel
/// trees degenerate to a no-op and hosted content (WKWebView, terminals)
/// is never detached from its superview.
public protocol DockStageReconcilable: AnyObject {
    /// Apply `newPanel` to this VC without tearing down the view hierarchy.
    /// Preconditions: `newPanel.id == self.panel.id` and the panel's content
    /// shape is compatible with this VC's type. Callers upstream (e.g.
    /// `DockStageContainerView.setStages`) gate compatibility before calling.
    func reconcile(newPanel: Panel)
}
