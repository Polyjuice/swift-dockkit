import AppKit

/// A view controller that hosts a nested desktop host within a layout tree.
/// This is used when a desktop host is embedded as a node in another layout,
/// enabling recursive nesting of virtual workspaces (Version 3 feature).
public class DockDesktopHostViewController: NSViewController, DockDesktopHostViewDelegate {

    // MARK: - Properties

    /// The desktop host view this controller manages
    public let hostView: DockDesktopHostView

    /// The layout node configuration
    public let layoutNode: DesktopHostLayoutNode

    /// Panel provider for looking up panels by ID
    public var panelProvider: ((UUID) -> (any DockablePanel)?)?

    /// Delegate for bubbling swipe gestures to parent desktop host
    public weak var swipeGestureDelegate: SwipeGestureDelegate? {
        didSet {
            hostView.swipeGestureDelegate = swipeGestureDelegate
        }
    }

    // MARK: - Initialization

    public init(layoutNode: DesktopHostLayoutNode, panelProvider: ((UUID) -> (any DockablePanel)?)? = nil) {
        self.layoutNode = layoutNode
        self.panelProvider = panelProvider

        // Create the desktop host state from the layout node
        let state = layoutNode.toDesktopHostWindowState()

        // Create the host view
        self.hostView = DockDesktopHostView(
            id: layoutNode.id,
            desktopHostState: state,
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

    // MARK: - DockDesktopHostViewDelegate

    public func desktopHostView(_ view: DockDesktopHostView, didSwitchToDesktopAt index: Int) {
        // Could notify parent if needed
    }

    public func desktopHostView(_ view: DockDesktopHostView, didReceiveTab tabInfo: DockTabDragInfo, in tabGroup: DockTabGroupViewController, at index: Int) {
        // Could forward to parent if needed
    }

    public func desktopHostView(_ view: DockDesktopHostView, willTearPanel panel: any DockablePanel, at screenPoint: NSPoint) -> Bool {
        // Default: allow tearing
        return true
    }

    public func desktopHostView(_ view: DockDesktopHostView, didTearPanel panel: any DockablePanel, to newWindow: DockDesktopHostWindow) {
        // Could notify parent if needed
    }

    public func desktopHostView(_ view: DockDesktopHostView, wantsToSplit direction: DockSplitDirection, withTab tab: DockTab, in tabGroup: DockTabGroupViewController) {
        // Could forward to parent if needed
    }
}
