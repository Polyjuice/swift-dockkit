import AppKit
import DockKit

/// Enum for custom renderer style selection
enum CustomRendererStyle: Int {
    case wireframe = 0
    case polished = 1
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindow: NSWindow?
    var dockWindow: DockStageHostWindow?
    var panels: [UUID: DemoPanel] = [:]
    var controlBar: ModeControlBar?

    // Store both renderer sets
    let wireframeTabRenderer = WireframeTabRenderer()
    let wireframeStageRenderer = WireframeStageRenderer()
    let polishedTabRenderer = PolishedTabRenderer()
    let polishedStageRenderer = ModernStageRenderer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register custom renderers globally (start with wireframe)
        DockKit.customTabRenderer = wireframeTabRenderer
        DockKit.customStageRenderer = wireframeStageRenderer
        DockKit.customDropZoneRenderer = ModernDropZoneRenderer()

        // Create demo panels
        let panel1 = createPanel(title: "Editor", color: .systemBlue)
        let panel2 = createPanel(title: "Terminal", color: .systemGreen)
        let panel3 = createPanel(title: "Preview", color: .systemPurple)

        // Create stages
        let stage1 = Stage(
            title: "Code",
            iconName: "doc.text",
            layout: .tabGroup(TabGroupLayoutNode(
                tabs: [
                    TabLayoutState(id: panel1.panelId, title: panel1.panelTitle),
                    TabLayoutState(id: panel2.panelId, title: panel2.panelTitle)
                ],
                activeTabIndex: 0
            ))
        )

        let stage2 = Stage(
            title: "Design",
            iconName: "paintbrush",
            layout: .tabGroup(TabGroupLayoutNode(
                tabs: [TabLayoutState(id: panel3.panelId, title: panel3.panelTitle)],
                activeTabIndex: 0
            ))
        )

        // Create window state with custom display mode
        let state = StageHostWindowState(
            frame: CGRect(x: 200, y: 200, width: 800, height: 600),
            activeStageIndex: 0,
            stages: [stage1, stage2],
            displayMode: .custom
        )

        // Create dock window
        dockWindow = DockStageHostWindow(
            stageHostState: state,
            frame: state.frame,
            panelProvider: { [weak self] id in
                self?.panels[id]
            }
        )

        // Create main window with control bar
        createMainWindow()

        // Set up menu bar
        setupMenuBar()
    }

    func createMainWindow() {
        guard let dockWindow = dockWindow else { return }

        let windowFrame = CGRect(x: 100, y: 100, width: 900, height: 700)

        mainWindow = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        mainWindow?.title = "DockKit Custom Renderers Demo"
        mainWindow?.minSize = NSSize(width: 600, height: 400)

        // Create container view
        let containerView = NSView()
        containerView.wantsLayer = true

        // Create control bar
        controlBar = ModeControlBar()
        controlBar?.translatesAutoresizingMaskIntoConstraints = false
        controlBar?.onDisplayModeChanged = { [weak self] mode in
            self?.dockWindow?.displayMode = mode
        }
        controlBar?.onRendererStyleChanged = { [weak self] style in
            guard let self = self else { return }
            switch style {
            case .wireframe:
                DockKit.customTabRenderer = self.wireframeTabRenderer
                DockKit.customStageRenderer = self.wireframeStageRenderer
            case .polished:
                DockKit.customTabRenderer = self.polishedTabRenderer
                DockKit.customStageRenderer = self.polishedStageRenderer
            }
            // Force refresh if already in custom mode
            if self.dockWindow?.displayMode == .custom {
                self.dockWindow?.displayMode = .tabs
                self.dockWindow?.displayMode = .custom
            }
        }
        containerView.addSubview(controlBar!)

        // Embed dock window's content
        let dockContentView = dockWindow.contentView!
        dockWindow.contentView = nil
        dockContentView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockContentView)

        NSLayoutConstraint.activate([
            controlBar!.topAnchor.constraint(equalTo: containerView.topAnchor),
            controlBar!.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            controlBar!.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            controlBar!.heightAnchor.constraint(equalToConstant: 44),

            dockContentView.topAnchor.constraint(equalTo: controlBar!.bottomAnchor),
            dockContentView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            dockContentView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            dockContentView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        mainWindow?.contentView = containerView
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.center()
    }

    func createPanel(title: String, color: NSColor) -> DemoPanel {
        let panel = DemoPanel(title: title, color: color)
        panels[panel.panelId] = panel
        return panel
    }

    func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - ModeControlBar

class ModeControlBar: NSView {

    var onDisplayModeChanged: ((StageDisplayMode) -> Void)?
    var onRendererStyleChanged: ((CustomRendererStyle) -> Void)?

    private var displayModeControl: NSSegmentedControl!
    private var displayModeLabel: NSTextField!
    private var rendererStyleControl: NSSegmentedControl!
    private var rendererStyleLabel: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Add bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Display mode label
        displayModeLabel = NSTextField(labelWithString: "Tab Style:")
        displayModeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        displayModeLabel.textColor = .secondaryLabelColor
        displayModeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(displayModeLabel)

        // Display mode segmented control (Standard or Custom tabs only - thumbnails are for stage switching)
        displayModeControl = NSSegmentedControl(labels: ["Standard", "Custom"], trackingMode: .selectOne, target: self, action: #selector(displayModeChanged(_:)))
        displayModeControl.segmentStyle = .rounded
        displayModeControl.selectedSegment = 1  // Custom by default
        displayModeControl.translatesAutoresizingMaskIntoConstraints = false

        // Set segment widths
        displayModeControl.setWidth(80, forSegment: 0)
        displayModeControl.setWidth(70, forSegment: 1)

        addSubview(displayModeControl)

        // Renderer style label
        rendererStyleLabel = NSTextField(labelWithString: "Custom Style:")
        rendererStyleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        rendererStyleLabel.textColor = .secondaryLabelColor
        rendererStyleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rendererStyleLabel)

        // Renderer style segmented control
        rendererStyleControl = NSSegmentedControl(labels: ["Wireframe", "Polished"], trackingMode: .selectOne, target: self, action: #selector(rendererStyleChanged(_:)))
        rendererStyleControl.segmentStyle = .rounded
        rendererStyleControl.selectedSegment = 0  // Wireframe by default
        rendererStyleControl.translatesAutoresizingMaskIntoConstraints = false

        // Set segment widths
        rendererStyleControl.setWidth(80, forSegment: 0)
        rendererStyleControl.setWidth(70, forSegment: 1)

        addSubview(rendererStyleControl)

        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            displayModeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            displayModeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            displayModeControl.leadingAnchor.constraint(equalTo: displayModeLabel.trailingAnchor, constant: 8),
            displayModeControl.centerYAnchor.constraint(equalTo: centerYAnchor),

            rendererStyleLabel.leadingAnchor.constraint(equalTo: displayModeControl.trailingAnchor, constant: 24),
            rendererStyleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rendererStyleControl.leadingAnchor.constraint(equalTo: rendererStyleLabel.trailingAnchor, constant: 8),
            rendererStyleControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            rendererStyleControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    @objc private func displayModeChanged(_ sender: NSSegmentedControl) {
        let mode: StageDisplayMode
        switch sender.selectedSegment {
        case 0: mode = .tabs      // Standard tabs
        case 1: mode = .custom    // Custom renderer
        default: mode = .tabs
        }
        onDisplayModeChanged?(mode)
    }

    @objc private func rendererStyleChanged(_ sender: NSSegmentedControl) {
        let style = CustomRendererStyle(rawValue: sender.selectedSegment) ?? .wireframe
        onRendererStyleChanged?(style)
    }
}
