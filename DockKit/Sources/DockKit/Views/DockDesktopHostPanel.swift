import AppKit

/// A panel that wraps a desktop host view, allowing desktop hosts to be nested
/// inside other layouts (Version 3 feature).
///
/// This enables recursive nesting of desktop hosts - each level can have multiple
/// desktops with their own layouts, and swipe gestures bubble up the hierarchy
/// when at the edge of a nested host's desktops.
public class DockDesktopHostPanel: DockablePanel {

    // MARK: - Properties

    public let panelId: UUID
    public var panelTitle: String
    public var panelIcon: NSImage?

    /// The desktop host view this panel wraps
    public let hostView: DockDesktopHostView

    /// The view controller that provides the panel's content
    public let panelViewController: NSViewController

    /// Panel provider to pass down to the host view
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        get { hostView.panelProvider }
        set { hostView.panelProvider = newValue }
    }

    // MARK: - Initialization

    /// Create a new desktop host panel
    /// - Parameters:
    ///   - id: Unique identifier for this panel
    ///   - title: Display title for the panel tab
    ///   - icon: Icon shown in the tab (optional)
    ///   - desktopHostState: Initial state for the desktop host
    ///   - panelProvider: Provider for looking up panels by ID
    public init(
        id: UUID = UUID(),
        title: String = "Nested Desktops",
        icon: NSImage? = nil,
        desktopHostState: DesktopHostWindowState,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.panelId = id
        self.panelTitle = title
        self.panelIcon = icon

        // Create the host view
        self.hostView = DockDesktopHostView(
            id: id,
            desktopHostState: desktopHostState,
            panelProvider: panelProvider
        )

        // Create a view controller that wraps the host view
        let vc = DockDesktopHostPanelViewController(hostView: hostView)
        self.panelViewController = vc
    }

    /// Convenience initializer for creating a panel with a single desktop
    public convenience init(
        id: UUID = UUID(),
        title: String = "Nested Desktops",
        icon: NSImage? = nil,
        singleDesktopLayout: DockLayoutNode,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        let desktop = Desktop(
            title: "Desktop 1",
            iconName: nil,
            layout: singleDesktopLayout
        )
        let state = DesktopHostWindowState(
            frame: .zero, // Frame is managed by parent
            activeDesktopIndex: 0,
            desktops: [desktop]
        )
        self.init(
            id: id,
            title: title,
            icon: icon,
            desktopHostState: state,
            panelProvider: panelProvider
        )
    }

    // MARK: - DockablePanel Protocol

    public var preferredFirstResponder: NSView? {
        hostView
    }

    public func canDock(at position: DockPosition) -> Bool {
        true
    }

    public func panelWillDetach() {
        // Pause expensive rendering if needed
    }

    public func panelDidDock(at position: DockPosition) {
        // Resume rendering if needed
    }

    public func panelDidBecomeActive() {
        // Refresh thumbnails when becoming active
        hostView.loadDesktopsIfNeeded()
    }

    public func panelDidResignActive() {
        // Could pause background updates
    }

    // MARK: - Public API

    /// Get the underlying desktop host state
    public var desktopHostState: DesktopHostWindowState {
        hostView.desktopHostState
    }

    /// Set the swipe gesture delegate for gesture bubbling
    public var swipeGestureDelegate: SwipeGestureDelegate? {
        get { hostView.swipeGestureDelegate }
        set { hostView.swipeGestureDelegate = newValue }
    }

    /// Switch to a specific desktop
    public func switchToDesktop(at index: Int, animated: Bool = true) {
        hostView.switchToDesktop(at: index, animated: animated)
    }

    /// Add a new empty desktop
    @discardableResult
    public func addNewDesktop(title: String? = nil, iconName: String? = nil) -> Desktop {
        hostView.addNewDesktop(title: title, iconName: iconName)
    }

    /// Update the desktop host state
    public func updateDesktopHostState(_ state: DesktopHostWindowState) {
        hostView.updateDesktopHostState(state)
    }
}

// MARK: - DockDesktopHostPanelViewController

/// View controller that wraps a DockDesktopHostView for use as a panel
private class DockDesktopHostPanelViewController: NSViewController {

    private let hostView: DockDesktopHostView

    init(hostView: DockDesktopHostView) {
        self.hostView = hostView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Create a container view
        let container = NSView()
        container.wantsLayer = true

        // Add the host view
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
}

// MARK: - DockDesktopHostView Extension

extension DockDesktopHostView {
    /// Reload desktops if needed (called when panel becomes active)
    func loadDesktopsIfNeeded() {
        // Recapture thumbnails if in thumbnail mode
        if desktopHostState.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                // Access containerView through reflection since it's private
                // For now, just trigger a layout update
                self.needsLayout = true
            }
        }
    }
}
