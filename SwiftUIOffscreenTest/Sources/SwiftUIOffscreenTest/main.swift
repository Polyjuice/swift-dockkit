import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var testWindow: TestWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create and show test window
        testWindow = TestWindow()
        testWindow.makeKeyAndOrderFront(nil)

        // Start automated test sequence after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.testWindow.runAutomatedTests()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
