import AppKit
import DockKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var stageWindow: DockStageHostWindow?
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        createStageHostWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Stage Host Window Setup

    private func createStageHostWindow() {
        // Create panels for each stage
        let codingPanels = createCodingStagePanels()
        let designPanels = createDesignStagePanels()
        let notesPanels = createNotesStagePanels()
        let nestedProjectPanels = createNestedProjectPanels()

        // Register all panels
        for panel in codingPanels + designPanels + notesPanels + nestedProjectPanels {
            panelRegistry[panel.panelId] = panel
        }

        // Create nested stage host for Projects (Version 3 feature)
        let nestedProjectsHost = createNestedProjectsHost(with: nestedProjectPanels)

        // Create stage layouts
        let codingStage = createCodingStage(with: codingPanels, nestedProjectsHost: nestedProjectsHost)
        let designStage = createDesignStage(with: designPanels)
        let notesStage = createNotesStage(with: notesPanels)

        // Create the root panel with stages group style
        let rootPanel = Panel(
            content: .group(PanelGroup(
                children: [codingStage, designStage, notesStage],
                activeIndex: 0,
                style: .stages
            )),
            isTopLevelWindow: true,
            frame: CGRect(x: 100, y: 100, width: 1200, height: 800),
            isFullScreen: false
        )

        // Create the window with panel provider available during init
        stageWindow = DockStageHostWindow(
            panel: rootPanel,
            frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
            panelProvider: { [weak self] id in
                self?.panelRegistry[id]
            }
        )

        // Enable full screen support
        stageWindow?.collectionBehavior = [.fullScreenPrimary, .managed]

        stageWindow?.center()
        stageWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel Creation

    private func createCodingStagePanels() -> [any DockablePanel] {
        return [
            FileExplorerPanel(),
            CodeEditorPanel(filename: "main.swift"),
            CodeEditorPanel(filename: "App.swift"),
            TerminalPanel(name: "Build"),
            GitPanel(),
            DebugConsolePanel()  // Console panel for debug output
        ]
    }

    /// Create panels for the nested "Projects" stage host inside Coding stage
    private func createNestedProjectPanels() -> [any DockablePanel] {
        return [
            // Project A panels
            CodeEditorPanel(filename: "ProjectA/main.swift"),
            TerminalPanel(name: "Project A Build"),
            // Project B panels
            CodeEditorPanel(filename: "ProjectB/app.swift"),
            TerminalPanel(name: "Project B Build"),
            // Project C panels
            CodeEditorPanel(filename: "ProjectC/index.swift"),
            TerminalPanel(name: "Project C Build")
        ]
    }

    private func createDesignStagePanels() -> [any DockablePanel] {
        return [
            CanvasPanel(name: "Homepage Design"),
            CanvasPanel(name: "Mobile Layout"),
            LayersPanel(),
            ColorsPanel(),
            AssetsPanel()
        ]
    }

    private func createNotesStagePanels() -> [any DockablePanel] {
        return [
            NotesListPanel(),
            NoteEditorPanel(title: "Meeting Notes"),
            NoteEditorPanel(title: "Project Ideas"),
            TagsPanel()
        ]
    }

    // MARK: - Helper: Content Panel from DockablePanel

    private func contentPanel(for dockable: any DockablePanel) -> Panel {
        Panel.contentPanel(id: dockable.panelId, title: dockable.panelTitle)
    }

    // MARK: - Helper: Tabs Group Panel

    private func tabsGroup(from dockables: [any DockablePanel], activeIndex: Int = 0) -> Panel {
        Panel(content: .group(PanelGroup(
            children: dockables.map { contentPanel(for: $0) },
            activeIndex: activeIndex,
            style: .tabs
        )))
    }

    // MARK: - Nested Stage Host Creation (Version 3 Feature)

    /// Create a nested stage host containing multiple project workspaces
    private func createNestedProjectsHost(with panels: [any DockablePanel]) -> Panel {
        // Project A: editor + terminal (vertical split)
        let projectAEditor = panels[0]
        let projectATerminal = panels[1]
        let projectALayout = Panel(content: .group(PanelGroup(
            children: [
                tabsGroup(from: [projectAEditor]),
                tabsGroup(from: [projectATerminal])
            ],
            axis: .vertical,
            proportions: [0.7, 0.3],
            style: .split
        )))

        // Project B: editor + terminal (vertical split)
        let projectBEditor = panels[2]
        let projectBTerminal = panels[3]
        let projectBLayout = Panel(content: .group(PanelGroup(
            children: [
                tabsGroup(from: [projectBEditor]),
                tabsGroup(from: [projectBTerminal])
            ],
            axis: .vertical,
            proportions: [0.7, 0.3],
            style: .split
        )))

        // Project C: editor + terminal (vertical split)
        let projectCEditor = panels[4]
        let projectCTerminal = panels[5]
        let projectCLayout = Panel(content: .group(PanelGroup(
            children: [
                tabsGroup(from: [projectCEditor]),
                tabsGroup(from: [projectCTerminal])
            ],
            axis: .vertical,
            proportions: [0.7, 0.3],
            style: .split
        )))

        // Create nested stages for each project -- each "stage" is a Panel
        // whose content is the project's layout (a group)
        let projectAStage = Panel(
            title: "Project A",
            iconName: "a.circle.fill",
            content: projectALayout.content
        )
        let projectBStage = Panel(
            title: "Project B",
            iconName: "b.circle.fill",
            content: projectBLayout.content
        )
        let projectCStage = Panel(
            title: "Project C",
            iconName: "c.circle.fill",
            content: projectCLayout.content
        )

        // The nested stage host is a Panel with .group(style: .stages)
        return Panel(
            title: "Projects",
            iconName: "folder.fill.badge.gearshape",
            content: .group(PanelGroup(
                children: [projectAStage, projectBStage, projectCStage],
                activeIndex: 0,
                style: .stages
            ))
        )
    }

    // MARK: - Stage Layout Creation

    private func createCodingStage(with panels: [any DockablePanel], nestedProjectsHost: Panel) -> Panel {
        // Layout: [Explorer | [Nested Projects Host] / [Terminal, Console]] | Git
        // The nested projects host replaces the editor tabs, showing a swipeable workspace
        let explorer = panels[0]
        let terminal = panels[3]
        let git = panels[4]
        let console = panels[5]

        let explorerGroup = tabsGroup(from: [explorer])

        // Terminal and Console share bottom area as tabs
        let bottomGroup = Panel(content: .group(PanelGroup(
            children: [contentPanel(for: terminal), contentPanel(for: console)],
            activeIndex: 1,  // Start with Console active to see cursor logs
            style: .tabs
        )))

        let gitGroup = tabsGroup(from: [git])

        // Center area: Nested stage host on top, terminal/console on bottom
        // The nested host allows swiping between Project A, B, C workspaces
        let centerArea = Panel(content: .group(PanelGroup(
            children: [
                nestedProjectsHost,  // Version 3: Nested stage host!
                bottomGroup
            ],
            axis: .vertical,
            proportions: [0.7, 0.3],
            style: .split
        )))

        // Main split: Explorer | Center Area (with nested host) | Git
        let mainSplit = Panel(content: .group(PanelGroup(
            children: [
                explorerGroup,
                centerArea,
                gitGroup
            ],
            axis: .horizontal,
            proportions: [0.2, 0.6, 0.2],
            style: .split
        )))

        return Panel(
            title: "Coding",
            iconName: "chevron.left.forwardslash.chevron.right",
            content: mainSplit.content
        )
    }

    private func createDesignStage(with panels: [any DockablePanel]) -> Panel {
        // Layout: [Layers | [Canvas1, Canvas2] | Colors / Assets]
        let canvas1 = panels[0]
        let canvas2 = panels[1]
        let layers = panels[2]
        let colors = panels[3]
        let assets = panels[4]

        let layersGroup = tabsGroup(from: [layers])
        let canvasGroup = tabsGroup(from: [canvas1, canvas2])
        let colorsGroup = tabsGroup(from: [colors])
        let assetsGroup = tabsGroup(from: [assets])

        // Right sidebar: Colors on top, Assets on bottom
        let rightSidebar = Panel(content: .group(PanelGroup(
            children: [colorsGroup, assetsGroup],
            axis: .vertical,
            proportions: [0.5, 0.5],
            style: .split
        )))

        // Main split: Layers | Canvas | Right Sidebar
        let mainSplit = Panel(content: .group(PanelGroup(
            children: [layersGroup, canvasGroup, rightSidebar],
            axis: .horizontal,
            proportions: [0.15, 0.65, 0.2],
            style: .split
        )))

        return Panel(
            title: "Design",
            iconName: "paintbrush.fill",
            content: mainSplit.content
        )
    }

    private func createNotesStage(with panels: [any DockablePanel]) -> Panel {
        // Layout: [Notes List | [Note Editor 1, Note Editor 2] | Tags]
        let notesList = panels[0]
        let noteEditor1 = panels[1]
        let noteEditor2 = panels[2]
        let tags = panels[3]

        let notesListGroup = tabsGroup(from: [notesList])
        let editorsGroup = tabsGroup(from: [noteEditor1, noteEditor2])
        let tagsGroup = tabsGroup(from: [tags])

        // Main split: Notes List | Editors | Tags
        let mainSplit = Panel(content: .group(PanelGroup(
            children: [notesListGroup, editorsGroup, tagsGroup],
            axis: .horizontal,
            proportions: [0.2, 0.6, 0.2],
            style: .split
        )))

        return Panel(
            title: "Notes",
            iconName: "note.text",
            content: mainSplit.content
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
        appMenu.addItem(withTitle: "About Stage Demo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Stage Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Stage menu
        let stageMenuItem = NSMenuItem()
        mainMenu.addItem(stageMenuItem)
        let stageMenu = NSMenu(title: "Stage")
        stageMenuItem.submenu = stageMenu
        stageMenu.addItem(withTitle: "Switch to Coding", action: #selector(switchToCoding(_:)), keyEquivalent: "1")
        stageMenu.addItem(withTitle: "Switch to Design", action: #selector(switchToDesign(_:)), keyEquivalent: "2")
        stageMenu.addItem(withTitle: "Switch to Notes", action: #selector(switchToNotes(_:)), keyEquivalent: "3")
        stageMenu.addItem(NSMenuItem.separator())
        stageMenu.addItem(withTitle: "Previous Stage", action: #selector(previousStage(_:)), keyEquivalent: "[")
        stageMenu.addItem(withTitle: "Next Stage", action: #selector(nextStage(_:)), keyEquivalent: "]")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")

        // Debug menu
        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu
        let slowMotionItem = NSMenuItem(title: "Slow Motion", action: #selector(toggleSlowMotion(_:)), keyEquivalent: "s")
        slowMotionItem.keyEquivalentModifierMask = [.command, .shift]
        debugMenu.addItem(slowMotionItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Swipe left/right to switch stages", action: nil, keyEquivalent: "")
        helpMenu.addItem(withTitle: "Click header buttons to switch stages", action: nil, keyEquivalent: "")
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(withTitle: "Version 3: Nested Stages", action: nil, keyEquivalent: "")
        helpMenu.addItem(withTitle: "  • The Coding stage contains a nested 'Projects' host", action: nil, keyEquivalent: "")
        helpMenu.addItem(withTitle: "  • Swipe inside the nested area to switch projects", action: nil, keyEquivalent: "")
        helpMenu.addItem(withTitle: "  • Gestures bubble up when at edge boundaries", action: nil, keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Menu Actions

    @objc private func switchToCoding(_ sender: Any?) {
        stageWindow?.switchToStage(at: 0, animated: true)
    }

    @objc private func switchToDesign(_ sender: Any?) {
        stageWindow?.switchToStage(at: 1, animated: true)
    }

    @objc private func switchToNotes(_ sender: Any?) {
        stageWindow?.switchToStage(at: 2, animated: true)
    }

    @objc private func previousStage(_ sender: Any?) {
        guard let window = stageWindow else { return }
        let current = window.controller.activeStageIndex
        if current > 0 {
            window.switchToStage(at: current - 1, animated: true)
        }
    }

    @objc private func nextStage(_ sender: Any?) {
        guard let window = stageWindow else { return }
        let current = window.controller.activeStageIndex
        if current < window.controller.stages.count - 1 {
            window.switchToStage(at: current + 1, animated: true)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.close()
    }

    @objc private func toggleSlowMotion(_ sender: NSMenuItem?) {
        guard let window = stageWindow else { return }
        window.slowMotionEnabled.toggle()
        sender?.state = window.slowMotionEnabled ? .on : .off
    }
}
