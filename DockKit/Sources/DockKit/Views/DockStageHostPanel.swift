import AppKit

/// A panel that wraps a stage host view, allowing stage hosts to be nested
/// inside other layouts (Version 3 feature).
///
/// This enables recursive nesting of stage hosts - each level can have multiple
/// stages with their own layouts, and swipe gestures bubble up the hierarchy
/// when at the edge of a nested host's stages.
public class DockStageHostPanel: DockablePanel {

    // MARK: - Properties

    public let panelId: UUID
    public var panelTitle: String
    public var panelIcon: NSImage?

    /// The stage host view this panel wraps
    public let hostView: DockStageHostView

    /// The view controller that provides the panel's content
    public let panelViewController: NSViewController

    /// Panel provider to pass down to the host view
    public var panelProvider: ((UUID) -> (any DockablePanel)?)? {
        get { hostView.panelProvider }
        set { hostView.panelProvider = newValue }
    }

    // MARK: - Initialization

    /// Create a new stage host panel
    /// - Parameters:
    ///   - id: Unique identifier for this panel
    ///   - title: Display title for the panel tab
    ///   - icon: Icon shown in the tab (optional)
    ///   - stageHostState: Initial state for the stage host
    ///   - panelProvider: Provider for looking up panels by ID
    public init(
        id: UUID = UUID(),
        title: String = "Nested Stages",
        icon: NSImage? = nil,
        stageHostState: StageHostWindowState,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        self.panelId = id
        self.panelTitle = title
        self.panelIcon = icon

        // Create the host view
        self.hostView = DockStageHostView(
            id: id,
            stageHostState: stageHostState,
            panelProvider: panelProvider
        )

        // Create a view controller that wraps the host view
        let vc = DockStageHostPanelViewController(hostView: hostView)
        self.panelViewController = vc
    }

    /// Convenience initializer for creating a panel with a single stage
    public convenience init(
        id: UUID = UUID(),
        title: String = "Nested Stages",
        icon: NSImage? = nil,
        singleStageLayout: DockLayoutNode,
        panelProvider: ((UUID) -> (any DockablePanel)?)? = nil
    ) {
        let stage = Stage(
            title: "Stage 1",
            iconName: nil,
            layout: singleStageLayout
        )
        let state = StageHostWindowState(
            frame: .zero, // Frame is managed by parent
            activeStageIndex: 0,
            stages: [stage]
        )
        self.init(
            id: id,
            title: title,
            icon: icon,
            stageHostState: state,
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
        hostView.loadStagesIfNeeded()
    }

    public func panelDidResignActive() {
        // Could pause background updates
    }

    // MARK: - Public API

    /// Get the underlying stage host state
    public var stageHostState: StageHostWindowState {
        hostView.stageHostState
    }

    /// Set the swipe gesture delegate for gesture bubbling
    public var swipeGestureDelegate: SwipeGestureDelegate? {
        get { hostView.swipeGestureDelegate }
        set { hostView.swipeGestureDelegate = newValue }
    }

    /// Switch to a specific stage
    public func switchToStage(at index: Int, animated: Bool = true) {
        hostView.switchToStage(at: index, animated: animated)
    }

    /// Add a new empty stage
    @discardableResult
    public func addNewStage(title: String? = nil, iconName: String? = nil) -> Stage {
        hostView.addNewStage(title: title, iconName: iconName)
    }

    /// Update the stage host state
    public func updateStageHostState(_ state: StageHostWindowState) {
        hostView.updateStageHostState(state)
    }
}

// MARK: - DockStageHostPanelViewController

/// View controller that wraps a DockStageHostView for use as a panel
private class DockStageHostPanelViewController: NSViewController {

    private let hostView: DockStageHostView

    init(hostView: DockStageHostView) {
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

// MARK: - DockStageHostView Extension

extension DockStageHostView {
    /// Reload stages if needed (called when panel becomes active)
    func loadStagesIfNeeded() {
        // Recapture thumbnails if in thumbnail mode
        if stageHostState.displayMode == .thumbnails {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                // Access containerView through reflection since it's private
                // For now, just trigger a layout update
                self.needsLayout = true
            }
        }
    }
}
