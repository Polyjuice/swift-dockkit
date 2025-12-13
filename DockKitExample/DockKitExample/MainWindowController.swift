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

        let explorerGroup = TabGroupLayoutNode(
            id: UUID(),
            tabs: [TabLayoutState(id: explorer.panelId, title: explorer.panelTitle)],
            activeTabIndex: 0
        )

        let editorGroup = TabGroupLayoutNode(
            id: UUID(),
            tabs: [
                TabLayoutState(id: editor1.panelId, title: editor1.panelTitle),
                TabLayoutState(id: editor2.panelId, title: editor2.panelTitle)
            ],
            activeTabIndex: 0
        )

        let consoleGroup = TabGroupLayoutNode(
            id: UUID(),
            tabs: [TabLayoutState(id: console.panelId, title: console.panelTitle)],
            activeTabIndex: 0
        )

        let inspectorGroup = TabGroupLayoutNode(
            id: UUID(),
            tabs: [TabLayoutState(id: inspector.panelId, title: inspector.panelTitle)],
            activeTabIndex: 0
        )

        // Top row: Explorer | Editors | Inspector
        let topRow = SplitLayoutNode(
            id: UUID(),
            axis: .horizontal,
            children: [
                .tabGroup(explorerGroup),
                .tabGroup(editorGroup),
                .tabGroup(inspectorGroup)
            ],
            proportions: [0.2, 0.6, 0.2]
        )

        // Main split: Top row / Console
        let mainSplit = SplitLayoutNode(
            id: UUID(),
            axis: .vertical,
            children: [
                .split(topRow),
                .tabGroup(consoleGroup)
            ],
            proportions: [0.75, 0.25]
        )

        let windowState = WindowState(
            id: UUID(),
            frame: window?.frame ?? NSRect(x: 100, y: 100, width: 1200, height: 800),
            isFullScreen: false,
            rootNode: .split(mainSplit)
        )

        let layout = DockLayout(windows: [windowState])
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

        let tabGroup = TabGroupNode(tabs: [DockTab(from: editor)])
        layoutManager.createWindow(
            rootNode: .tabGroup(tabGroup),
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
}
