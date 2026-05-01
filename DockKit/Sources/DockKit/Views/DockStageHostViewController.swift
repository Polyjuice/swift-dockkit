import AppKit

/// A view controller that hosts a nested stage host within a layout tree.
/// This is used when a stage host is embedded as a node in another layout,
/// enabling recursive nesting of virtual workspaces (Version 3 feature).
///
/// Accepts a `Panel` with `.group(PanelGroup)` content where `style == .stages`.
public class DockStageHostViewController: NSViewController, DockStageHostViewDelegate, DockStageReconcilable {

    // MARK: - Properties

    /// The stage host view this controller manages
    public let hostView: DockStageHostView

    /// The panel configuration (must have .group content with style .stages)
    public let stagePanel: Panel

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Delegate for bubbling swipe gestures to parent stage host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            hostView.swipeGestureDelegate = swipeGestureDelegate
        }
    }

    // MARK: - Initialization

    public init(panel: Panel, panelProvider: ((UUID) -> (any DockablePanel)?)? = nil) {
        self.stagePanel = panel
        self.panelProvider = panelProvider

        // Create the host view
        self.hostView = DockStageHostView(
            id: panel.id,
            panel: panel,
            panelProvider: panelProvider
        )

        super.init(nibName: nil, bundle: nil)

        hostView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    public override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)

        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
    }

    // MARK: - Reconciliation

    /// Apply a new Panel to the nested stage host. Forwards to
    /// `DockStageHostView.updateStageHostPanel`, which drives the reconciling
    /// `DockStageContainerView.setStages` downstream.
    public func reconcile(newPanel: Panel) {
        hostView.updateStageHostPanel(newPanel)
    }

    // MARK: - DockStageHostViewDelegate

    public func stageHostView(_ view: DockStageHostView, didSwitchToStageAt index: Int) {
        // Could notify parent if needed
    }

    public func stageHostView(_ view: DockStageHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Could forward to parent if needed
    }

    public func stageHostView(_ view: DockStageHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool {
        // Default: allow tearing
        return true
    }

    public func stageHostView(_ view: DockStageHostView, didTearPanel panel: any DockablePanel, to newWindow: DockStageHostWindow) {
        // Could notify parent if needed
    }

    public func stageHostView(_ view: DockStageHostView, wantsToSplit direction: DockSplitDirection, withPanelId panelId: UUID, in tabGroup: DockTabGroupViewController) {
        // Could forward to parent if needed
    }

    public func stageHostView(_ view: DockStageHostView, didRequestNewPanelIn groupId: UUID, actionId: String?) {
        // Bubble the tab strip "+" click up to the enclosing DockStageHostWindow's
        // stageDelegate. Without this, the protocol-extension no-op default
        // would silently swallow the click for any tab group living inside a
        // nested substage host (e.g. a session's tab group inside a project's
        // agent-session-set).
        if let window = view.window as? DockStageHostWindow {
            window.stageDelegate?.stageHostWindow(window, didRequestNewPanelIn: groupId, actionId: actionId)
        }
    }

    public func stageHostView(_ view: DockStageHostView, didRequestClosePanel panelId: UUID) {
        // Bubble the tab "X" click up to the enclosing window's stageDelegate so
        // the host app (governor-controlled) can decide whether to actually
        // remove the panel. The protocol-extension default would call
        // `view.controller.handleChildClosed(panelId)` LOCALLY, which mutates
        // only the substage's in-memory layout — the governor never finds out,
        // so its next push restores the tab and the user sees it "come back".
        if let window = view.window as? DockStageHostWindow {
            window.stageDelegate?.stageHostWindow(window, didRequestClosePanel: panelId)
        }
    }

    public func stageHostView(_ view: DockStageHostView, didRequestCloseStageAt index: Int) {
        // Same rationale as didRequestClosePanel: bubble up so the host app
        // owns the close. Default would remove the stage locally and lose the
        // round trip to the governor.
        if let window = view.window as? DockStageHostWindow {
            window.stageDelegate?.stageHostWindow(window, didRequestCloseStageAt: index)
        }
    }
}
