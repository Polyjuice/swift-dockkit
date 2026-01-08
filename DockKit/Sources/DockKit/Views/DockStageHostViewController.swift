import AppKit

/// A view controller that hosts a nested stage host within a layout tree.
/// This is used when a stage host is embedded as a node in another layout,
/// enabling recursive nesting of virtual workspaces (Version 3 feature).
public class DockStageHostViewController: NSViewController, DockStageHostViewDelegate {

    // MARK: - Properties

    /// The stage host view this controller manages
    public let hostView: DockStageHostView

    /// The layout node configuration
    public let layoutNode: StageHostLayoutNode

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Delegate for bubbling swipe gestures to parent stage host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            hostView.swipeGestureDelegate = swipeGestureDelegate
        }
    }

    // MARK: - Initialization

    public init(layoutNode: StageHostLayoutNode, panelProvider: ((UUID) -> (any DockablePanel)?)? = nil) {
        self.layoutNode = layoutNode
        self.panelProvider = panelProvider

        // Create the stage host state from the layout node
        let state = layoutNode.toStageHostWindowState()

        // Create the host view
        self.hostView = DockStageHostView(
            id: layoutNode.id,
            stageHostState: state,
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

    public func stageHostView(_ view: DockStageHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Could forward to parent if needed
    }
}
