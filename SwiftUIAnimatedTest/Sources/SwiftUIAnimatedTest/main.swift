import AppKit
import SwiftUI

// MARK: - SwiftUI Panel Content

struct PanelContent: View {
    let index: Int
    let colors: [Color] = [.blue, .green, .orange]

    var body: some View {
        ZStack {
            colors[index % colors.count].opacity(0.3)
            VStack(spacing: 8) {
                Text("Panel \(index)")
                    .font(.title)
                    .fontWeight(.bold)
                Text("SwiftUI Text")
                    .font(.body)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(colors[index % colors.count])
            }
        }
    }
}

// MARK: - Test Window

class TestWindow: NSWindow {
    private var clipView: NSView!
    private var contentContainer: NSView!
    private var panels: [NSView] = []

    private let panelWidth: CGFloat = 300
    private let panelHeight: CGFloat = 200
    private let panelCount = 3

    private var testResults: [String] = []

    private var projectPath: String {
        let execPath = Bundle.main.executablePath ?? ""
        if let range = execPath.range(of: "/.build/") {
            return String(execPath[..<range.lowerBound])
        }
        return FileManager.default.currentDirectoryPath
    }

    init() {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Stage Slide Test"
        setupViews()
    }

    private func setupViews() {
        // Clip view - clips content to window
        clipView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        contentView = clipView

        // Content container (like DockKit's contentView)
        contentContainer = NSView()
        contentContainer.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(contentContainer)

        // Constraints for content container
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            contentContainer.heightAnchor.constraint(equalTo: clipView.heightAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: clipView.leadingAnchor)
        ])

        // Create panels with SwiftUI content
        for i in 0..<panelCount {
            let panel = NSView()
            panel.wantsLayer = true
            panel.translatesAutoresizingMaskIntoConstraints = false

            let hostingView = NSHostingView(rootView: PanelContent(index: i))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(hostingView)

            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: panel.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: panel.trailingAnchor)
            ])

            contentContainer.addSubview(panel)
            panels.append(panel)
        }
    }

    // MARK: - Test Runner

    func runAllTests() {
        testResults = ["Stage Slide Test Results", "=" * 40, ""]

        // Clear old screenshots
        let dir = projectPath + "/screenshots"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let tests: [(String, () -> Void)] = [
            // Test 1: Traditional side-by-side (like current DockKit)
            ("01_traditional_panel0", { self.setupTraditional(activePanel: 0) }),
            ("02_traditional_panel1", { self.setupTraditional(activePanel: 1) }),

            // Test 2: Opacity-based (all at 0,0, use opacity)
            ("03_opacity_panel0", { self.setupOpacity(activePanel: 0) }),
            ("04_opacity_panel1", { self.setupOpacity(activePanel: 1) }),

            // Test 3: Simulate slide animation with traditional approach
            ("05_trad_slide_0to1_start", { self.setupTraditionalSlide(from: 0, to: 1, progress: 0.0) }),
            ("06_trad_slide_0to1_mid", { self.setupTraditionalSlide(from: 0, to: 1, progress: 0.5) }),
            ("07_trad_slide_0to1_end", { self.setupTraditionalSlide(from: 0, to: 1, progress: 1.0) }),

            // Test 4: Simulate slide with opacity crossfade
            ("08_opacity_slide_0to1_start", { self.setupOpacitySlide(from: 0, to: 1, progress: 0.0) }),
            ("09_opacity_slide_0to1_mid", { self.setupOpacitySlide(from: 0, to: 1, progress: 0.5) }),
            ("10_opacity_slide_0to1_end", { self.setupOpacitySlide(from: 0, to: 1, progress: 1.0) }),

            // Test 5: Hybrid - frames at origin, layer transforms for visual slide
            ("11_hybrid_slide_start", { self.setupHybridSlide(from: 0, to: 1, progress: 0.0) }),
            ("12_hybrid_slide_mid", { self.setupHybridSlide(from: 0, to: 1, progress: 0.5) }),
            ("13_hybrid_slide_end", { self.setupHybridSlide(from: 0, to: 1, progress: 1.0) }),
        ]

        var index = 0

        func runNext() {
            guard index < tests.count else {
                saveResults()
                print("\n=== ALL TESTS COMPLETE ===")
                print("Results: \(projectPath)/results.txt")
                print("Screenshots: \(projectPath)/screenshots/")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
                return
            }

            let (name, test) = tests[index]
            print("\n--- \(name) ---")
            testResults.append("Test: \(name)")

            test()

            // Force layout
            clipView.layoutSubtreeIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.captureScreenshot(named: name)
                self.logPanelState()
                self.testResults.append("")
                index += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    runNext()
                }
            }
        }

        runNext()
    }

    // MARK: - Test: Traditional Side-by-Side (Current DockKit Approach)

    private func setupTraditional(activePanel: Int) {
        // Reset
        resetAll()

        // Content container spans all panels
        contentContainer.frame = NSRect(x: 0, y: 0,
                                        width: panelWidth * CGFloat(panelCount),
                                        height: panelHeight)

        // Panels side by side
        for (i, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                width: panelWidth, height: panelHeight)
            panel.alphaValue = 1.0
        }

        // Scroll to active panel by moving container
        contentContainer.frame.origin.x = -CGFloat(activePanel) * panelWidth

        testResults.append("  Traditional: panels side-by-side, container scrolls")
        testResults.append("  Active: \(activePanel)")
    }

    // MARK: - Test: Opacity-Based (All at 0,0)

    private func setupOpacity(activePanel: Int) {
        resetAll()

        // Content container same size as clip view
        contentContainer.frame = clipView.bounds

        // All panels at same position (0,0)
        for (i, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            // Only active panel visible
            panel.alphaValue = (i == activePanel) ? 1.0 : 0.0
        }

        testResults.append("  Opacity: all panels at (0,0), opacity controls visibility")
        testResults.append("  Active: \(activePanel)")
    }

    // MARK: - Test: Traditional Slide Animation

    private func setupTraditionalSlide(from: Int, to: Int, progress: CGFloat) {
        resetAll()

        contentContainer.frame = NSRect(x: 0, y: 0,
                                        width: panelWidth * CGFloat(panelCount),
                                        height: panelHeight)

        for (i, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                width: panelWidth, height: panelHeight)
            panel.alphaValue = 1.0
        }

        // Interpolate position
        let startX = -CGFloat(from) * panelWidth
        let endX = -CGFloat(to) * panelWidth
        let currentX = startX + (endX - startX) * progress
        contentContainer.frame.origin.x = currentX

        testResults.append("  Traditional slide: \(from) -> \(to), progress: \(progress)")
    }

    // MARK: - Test: Opacity Crossfade Slide

    private func setupOpacitySlide(from: Int, to: Int, progress: CGFloat) {
        resetAll()

        contentContainer.frame = clipView.bounds

        for (i, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

            if i == from {
                panel.alphaValue = 1.0 - progress
            } else if i == to {
                panel.alphaValue = progress
            } else {
                panel.alphaValue = 0.0
            }
        }

        testResults.append("  Opacity slide: \(from) -> \(to), progress: \(progress)")
    }

    // MARK: - Test: Hybrid Slide (Frames at origin + layer transforms for visual position)

    private func setupHybridSlide(from: Int, to: Int, progress: CGFloat) {
        resetAll()

        contentContainer.frame = clipView.bounds

        // All panels at frame (0,0) so SwiftUI renders text
        // But use layer transforms for visual positioning
        for (i, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

            // Position visually using layer transform
            panel.layer?.transform = CATransform3DMakeTranslation(CGFloat(i) * panelWidth, 0, 0)

            // Only show from/to panels
            if i == from || i == to {
                panel.alphaValue = 1.0
            } else {
                panel.alphaValue = 0.0
            }
        }

        // Slide using sublayerTransform
        let startX = -CGFloat(from) * panelWidth
        let endX = -CGFloat(to) * panelWidth
        let currentX = startX + (endX - startX) * progress
        contentContainer.layer?.sublayerTransform = CATransform3DMakeTranslation(currentX, 0, 0)

        testResults.append("  Hybrid slide: frames at (0,0), layer transforms position, sublayerTransform slides")
        testResults.append("  \(from) -> \(to), progress: \(progress)")
    }

    // MARK: - Helpers

    private func resetAll() {
        contentContainer.frame = clipView.bounds
        for panel in panels {
            panel.layer?.transform = CATransform3DIdentity
            panel.alphaValue = 1.0
        }
        contentContainer.layer?.sublayerTransform = CATransform3DIdentity
    }

    private func logPanelState() {
        for (i, panel) in panels.enumerated() {
            let frame = panel.frame
            let alpha = panel.alphaValue
            let visible = panel.visibleRect
            testResults.append("  Panel \(i): frame.x=\(Int(frame.origin.x)), alpha=\(alpha), visibleRect.width=\(Int(visible.width))")
            print("  Panel \(i): frame.x=\(Int(frame.origin.x)), alpha=\(alpha), visibleRect=\(visible)")
        }
    }

    private func captureScreenshot(named name: String) {
        let dir = projectPath + "/screenshots"
        let filename = "\(dir)/\(name).png"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-l", String(windowNumber), "-x", filename]

        do {
            try task.run()
            task.waitUntilExit()
            print("  Screenshot: \(name).png")
        } catch {
            print("  Screenshot failed: \(error)")
        }
    }

    private func saveResults() {
        let path = projectPath + "/results.txt"
        try? testResults.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func *(lhs: String, rhs: Int) -> String {
    String(repeating: lhs, count: rhs)
}

// MARK: - App Entry

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: TestWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = TestWindow()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.window.runAllTests()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
