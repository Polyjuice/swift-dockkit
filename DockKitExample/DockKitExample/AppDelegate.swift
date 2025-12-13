import AppKit
import DockKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // MainWindowController manages DockLayoutManager - it doesn't need its own window shown
        // The dock windows are created by DockLayoutManager
        mainWindowController = MainWindowController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About DockKit Example", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DockKit Example", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Add Explorer Panel", action: #selector(addExplorerPanel(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Add Editor Panel", action: #selector(addEditorPanel(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Add Console Panel", action: #selector(addConsolePanel(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Add Inspector Panel", action: #selector(addInspectorPanel(_:)), keyEquivalent: "4")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu Actions

    @objc private func newWindow(_ sender: Any?) {
        mainWindowController?.createNewWindow()
    }

    @objc private func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.close()
    }

    @objc private func addExplorerPanel(_ sender: Any?) {
        mainWindowController?.addPanel(type: .explorer)
    }

    @objc private func addEditorPanel(_ sender: Any?) {
        mainWindowController?.addPanel(type: .editor)
    }

    @objc private func addConsolePanel(_ sender: Any?) {
        mainWindowController?.addPanel(type: .console)
    }

    @objc private func addInspectorPanel(_ sender: Any?) {
        mainWindowController?.addPanel(type: .inspector)
    }
}
