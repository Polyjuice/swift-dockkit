import AppKit
import DockKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var desktopWindow: DockDesktopHostWindow?
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        createDesktopHostWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Desktop Host Window Setup

    private func createDesktopHostWindow() {
        // Create panels for each desktop
        let codingPanels = createCodingDesktopPanels()
        let designPanels = createDesignDesktopPanels()
        let notesPanels = createNotesDesktopPanels()

        // Register all panels
        for panel in codingPanels + designPanels + notesPanels {
            panelRegistry[panel.panelId] = panel
        }

        // Create desktop layouts
        let codingDesktop = createCodingDesktop(with: codingPanels)
        let designDesktop = createDesignDesktop(with: designPanels)
        let notesDesktop = createNotesDesktop(with: notesPanels)

        // Create the desktop host state
        let desktopHostState = DesktopHostWindowState(
            frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
            activeDesktopIndex: 0,
            desktops: [codingDesktop, designDesktop, notesDesktop]
        )

        // Create the window
        desktopWindow = DockDesktopHostWindow(
            desktopHostState: desktopHostState,
            frame: desktopHostState.frame
        )

        desktopWindow?.panelProvider = { [weak self] id in
            self?.panelRegistry[id]
        }

        desktopWindow?.center()
        desktopWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel Creation

    private func createCodingDesktopPanels() -> [any DockablePanel] {
        return [
            FileExplorerPanel(),
            CodeEditorPanel(filename: "main.swift"),
            CodeEditorPanel(filename: "App.swift"),
            TerminalPanel(name: "Build"),
            GitPanel()
        ]
    }

    private func createDesignDesktopPanels() -> [any DockablePanel] {
        return [
            CanvasPanel(name: "Homepage Design"),
            CanvasPanel(name: "Mobile Layout"),
            LayersPanel(),
            ColorsPanel(),
            AssetsPanel()
        ]
    }

    private func createNotesDesktopPanels() -> [any DockablePanel] {
        return [
            NotesListPanel(),
            NoteEditorPanel(title: "Meeting Notes"),
            NoteEditorPanel(title: "Project Ideas"),
            TagsPanel()
        ]
    }

    // MARK: - Desktop Layout Creation

    private func createCodingDesktop(with panels: [any DockablePanel]) -> Desktop {
        // Layout: [Explorer | [Editor1, Editor2] / Terminal] | Git
        let explorer = panels[0]
        let editor1 = panels[1]
        let editor2 = panels[2]
        let terminal = panels[3]
        let git = panels[4]

        let explorerGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: explorer.panelId, title: explorer.panelTitle)],
            activeTabIndex: 0
        )

        let editorGroup = TabGroupLayoutNode(
            tabs: [
                TabLayoutState(id: editor1.panelId, title: editor1.panelTitle),
                TabLayoutState(id: editor2.panelId, title: editor2.panelTitle)
            ],
            activeTabIndex: 0
        )

        let terminalGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: terminal.panelId, title: terminal.panelTitle)],
            activeTabIndex: 0
        )

        let gitGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: git.panelId, title: git.panelTitle)],
            activeTabIndex: 0
        )

        // Editor area: editors on top, terminal on bottom
        let editorArea = SplitLayoutNode(
            axis: .vertical,
            children: [
                .tabGroup(editorGroup),
                .tabGroup(terminalGroup)
            ],
            proportions: [0.7, 0.3]
        )

        // Main split: Explorer | Editor Area | Git
        let mainSplit = SplitLayoutNode(
            axis: .horizontal,
            children: [
                .tabGroup(explorerGroup),
                .split(editorArea),
                .tabGroup(gitGroup)
            ],
            proportions: [0.2, 0.6, 0.2]
        )

        return Desktop(
            title: "Coding",
            iconName: "chevron.left.forwardslash.chevron.right",
            layout: .split(mainSplit)
        )
    }

    private func createDesignDesktop(with panels: [any DockablePanel]) -> Desktop {
        // Layout: [Layers | [Canvas1, Canvas2] | Colors / Assets]
        let canvas1 = panels[0]
        let canvas2 = panels[1]
        let layers = panels[2]
        let colors = panels[3]
        let assets = panels[4]

        let layersGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: layers.panelId, title: layers.panelTitle)],
            activeTabIndex: 0
        )

        let canvasGroup = TabGroupLayoutNode(
            tabs: [
                TabLayoutState(id: canvas1.panelId, title: canvas1.panelTitle),
                TabLayoutState(id: canvas2.panelId, title: canvas2.panelTitle)
            ],
            activeTabIndex: 0
        )

        let colorsGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: colors.panelId, title: colors.panelTitle)],
            activeTabIndex: 0
        )

        let assetsGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: assets.panelId, title: assets.panelTitle)],
            activeTabIndex: 0
        )

        // Right sidebar: Colors on top, Assets on bottom
        let rightSidebar = SplitLayoutNode(
            axis: .vertical,
            children: [
                .tabGroup(colorsGroup),
                .tabGroup(assetsGroup)
            ],
            proportions: [0.5, 0.5]
        )

        // Main split: Layers | Canvas | Right Sidebar
        let mainSplit = SplitLayoutNode(
            axis: .horizontal,
            children: [
                .tabGroup(layersGroup),
                .tabGroup(canvasGroup),
                .split(rightSidebar)
            ],
            proportions: [0.15, 0.65, 0.2]
        )

        return Desktop(
            title: "Design",
            iconName: "paintbrush.fill",
            layout: .split(mainSplit)
        )
    }

    private func createNotesDesktop(with panels: [any DockablePanel]) -> Desktop {
        // Layout: [Notes List | [Note Editor 1, Note Editor 2] | Tags]
        let notesList = panels[0]
        let noteEditor1 = panels[1]
        let noteEditor2 = panels[2]
        let tags = panels[3]

        let notesListGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: notesList.panelId, title: notesList.panelTitle)],
            activeTabIndex: 0
        )

        let editorsGroup = TabGroupLayoutNode(
            tabs: [
                TabLayoutState(id: noteEditor1.panelId, title: noteEditor1.panelTitle),
                TabLayoutState(id: noteEditor2.panelId, title: noteEditor2.panelTitle)
            ],
            activeTabIndex: 0
        )

        let tagsGroup = TabGroupLayoutNode(
            tabs: [TabLayoutState(id: tags.panelId, title: tags.panelTitle)],
            activeTabIndex: 0
        )

        // Main split: Notes List | Editors | Tags
        let mainSplit = SplitLayoutNode(
            axis: .horizontal,
            children: [
                .tabGroup(notesListGroup),
                .tabGroup(editorsGroup),
                .tabGroup(tagsGroup)
            ],
            proportions: [0.2, 0.6, 0.2]
        )

        return Desktop(
            title: "Notes",
            iconName: "note.text",
            layout: .split(mainSplit)
        )
    }

    // MARK: - Menu Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Desktop Demo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Desktop Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Desktop menu
        let desktopMenuItem = NSMenuItem()
        mainMenu.addItem(desktopMenuItem)
        let desktopMenu = NSMenu(title: "Desktop")
        desktopMenuItem.submenu = desktopMenu
        desktopMenu.addItem(withTitle: "Switch to Coding", action: #selector(switchToCoding(_:)), keyEquivalent: "1")
        desktopMenu.addItem(withTitle: "Switch to Design", action: #selector(switchToDesign(_:)), keyEquivalent: "2")
        desktopMenu.addItem(withTitle: "Switch to Notes", action: #selector(switchToNotes(_:)), keyEquivalent: "3")
        desktopMenu.addItem(NSMenuItem.separator())
        desktopMenu.addItem(withTitle: "Previous Desktop", action: #selector(previousDesktop(_:)), keyEquivalent: "[")
        desktopMenu.addItem(withTitle: "Next Desktop", action: #selector(nextDesktop(_:)), keyEquivalent: "]")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Swipe left/right to switch desktops", action: nil, keyEquivalent: "")
        helpMenu.addItem(withTitle: "Click header buttons to switch desktops", action: nil, keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Menu Actions

    @objc private func switchToCoding(_ sender: Any?) {
        desktopWindow?.switchToDesktop(at: 0, animated: true)
    }

    @objc private func switchToDesign(_ sender: Any?) {
        desktopWindow?.switchToDesktop(at: 1, animated: true)
    }

    @objc private func switchToNotes(_ sender: Any?) {
        desktopWindow?.switchToDesktop(at: 2, animated: true)
    }

    @objc private func previousDesktop(_ sender: Any?) {
        guard let window = desktopWindow else { return }
        let current = window.desktopHostState.activeDesktopIndex
        if current > 0 {
            window.switchToDesktop(at: current - 1, animated: true)
        }
    }

    @objc private func nextDesktop(_ sender: Any?) {
        guard let window = desktopWindow else { return }
        let current = window.desktopHostState.activeDesktopIndex
        if current < window.desktopHostState.desktops.count - 1 {
            window.switchToDesktop(at: current + 1, animated: true)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.close()
    }
}
