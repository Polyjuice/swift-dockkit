import AppKit
import DockKit

enum PanelType {
    case explorer
    case editor
    case console
    case inspector
}

class MainWindowController: NSWindowController {

    private let layoutManager = DockLayoutManager()
    private var panelRegistry: [UUID: any DockablePanel] = [:]
    private var panelCounter: [PanelType: Int] = [:]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockKit Example"
        window.center()

        self.init(window: window)

        setupLayoutManager()
        setupInitialLayout()
    }

    private func setupLayoutManager() {
        layoutManager.panelProvider = { [weak self] id in
            self?.panelRegistry[id]
        }
        layoutManager.delegate = self
    }

    private func setupInitialLayout() {
        // Create initial panels
        let explorer = createPanel(type: .explorer)
        let editor1 = createPanel(type: .editor)
        let editor2 = createPanel(type: .editor)
        let console = createPanel(type: .console)
        let inspector = createPanel(type: .inspector)

        // Register panels
        [explorer, editor1, editor2, console, inspector].forEach {
            panelRegistry[$0.panelId] = $0
        }

        // Build a VS Code-like layout:
        // [Explorer | [Editor1, Editor2] | Inspector]
        //           [      Console       ]

        let explorerGroup = Panel(
            content: .group(PanelGroup(
                children: [Panel.contentPanel(id: explorer.panelId, title: explorer.panelTitle)],
                activeIndex: 0,
                style: .tabs
            ))
        )

        // The editor group demonstrates multiple "+" buttons, each creating a
        // different panel type. Other groups keep the default single "+".
        let editorGroup = Panel(
            content: .group(PanelGroup(
                children: [
                    Panel.contentPanel(id: editor1.panelId, title: editor1.panelTitle),
                    Panel.contentPanel(id: editor2.panelId, title: editor2.panelTitle)
                ],
                activeIndex: 0,
                style: .tabs,
                addActions: [
                    PanelAddAction(id: "editor",   iconName: "doc.text", tooltip: "New Editor"),
                    PanelAddAction(id: "terminal", iconName: "terminal", tooltip: "New Terminal"),
                    PanelAddAction(id: "inspector", iconName: "info.circle", tooltip: "New Inspector"),
                ]
            ))
        )

        let consoleGroup = Panel(
            content: .group(PanelGroup(
                children: [Panel.contentPanel(id: console.panelId, title: console.panelTitle)],
                activeIndex: 0,
                style: .tabs
            ))
        )

        let inspectorGroup = Panel(
            content: .group(PanelGroup(
                children: [Panel.contentPanel(id: inspector.panelId, title: inspector.panelTitle)],
                activeIndex: 0,
                style: .tabs
            ))
        )

        // Top row: Explorer | Editors | Inspector
        let topRow = Panel(
            content: .group(PanelGroup(
                children: [explorerGroup, editorGroup, inspectorGroup],
                axis: .horizontal,
                proportions: [0.2, 0.6, 0.2],
                style: .split
            ))
        )

        // Main split: Top row / Console
        let windowPanel = Panel(
            content: .group(PanelGroup(
                children: [topRow, consoleGroup],
                axis: .vertical,
                proportions: [0.75, 0.25],
                style: .split
            )),
            isTopLevelWindow: true,
            frame: window?.frame ?? CGRect(x: 100, y: 100, width: 1200, height: 800),
            isFullScreen: false
        )

        let layout = DockLayout(panels: [windowPanel])
        layoutManager.updateLayout(layout)
    }

    // MARK: - Panel Creation

    private func createPanel(type: PanelType) -> any DockablePanel {
        let count = (panelCounter[type] ?? 0) + 1
        panelCounter[type] = count

        switch type {
        case .explorer:
            return ExplorerPanel(number: count)
        case .editor:
            return EditorPanel(number: count)
        case .console:
            return ConsolePanel(number: count)
        case .inspector:
            return InspectorPanel(number: count)
        }
    }

    // MARK: - Public Methods

    func addPanel(type: PanelType) {
        let panel = createPanel(type: type)
        panelRegistry[panel.panelId] = panel
        layoutManager.addPanel(panel)
    }

    func createNewWindow() {
        let editor = createPanel(type: .editor)
        panelRegistry[editor.panelId] = editor

        let contentPanel = Panel.contentPanel(id: editor.panelId, title: editor.panelTitle)
        let rootPanel = Panel(
            content: .group(PanelGroup(
                children: [contentPanel],
                activeIndex: 0,
                style: .tabs
            ))
        )
        layoutManager.createWindow(
            rootPanel: rootPanel,
            frame: NSRect(x: 150, y: 150, width: 800, height: 600)
        )
    }
}

// MARK: - DockLayoutManagerDelegate

extension MainWindowController: DockLayoutManagerDelegate {
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager) {
        NSApp.terminate(nil)
    }

    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        manager.detachPanel(panel, at: screenPoint)
    }

    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager) {
        // Could auto-save layout here
    }

    /// Dispatch on `actionId` to create the right panel type. The editor group
    /// declares three add actions (editor / terminal / inspector); other groups
    /// fall through with `actionId == nil` and get a default panel.
    func layoutManager(_ manager: DockLayoutManager, didRequestNewPanelIn groupId: UUID, actionId: String?, windowId: UUID) {
        let type: PanelType
        switch actionId {
        case "editor":    type = .editor
        case "terminal":  type = .console
        case "inspector": type = .inspector
        case "explorer":  type = .explorer
        default:          type = .editor
        }
        let panel = createPanel(type: type)
        panelRegistry[panel.panelId] = panel
        manager.addPanel(panel, to: windowId, groupId: groupId, activate: true)
    }
}
