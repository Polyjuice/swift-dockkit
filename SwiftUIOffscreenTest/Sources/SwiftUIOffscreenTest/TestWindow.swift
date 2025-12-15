import AppKit
import SwiftUI

// MARK: - Test Configuration

enum TestConfig: Int, CaseIterable {
    case baselineVisible = 1
    case baselineOffscreen = 2
    case overlappingAll = 3
    case overlappingWithOpacity = 4  // Changed from mask
    case overlappingShowPanel1 = 5   // Show middle panel via z-order
    case parentTransformSlide = 6    // Parent transform to show panel 1
    case preparedContentRect = 7
    case noClipping = 8

    var name: String {
        switch self {
        case .baselineVisible: return "baseline_visible"
        case .baselineOffscreen: return "baseline_offscreen"
        case .overlappingAll: return "overlapping_all"
        case .overlappingWithOpacity: return "overlapping_opacity"
        case .overlappingShowPanel1: return "overlapping_show_panel1"
        case .parentTransformSlide: return "parent_transform_slide"
        case .preparedContentRect: return "prepared_content_rect"
        case .noClipping: return "no_clipping"
        }
    }

    var description: String {
        switch self {
        case .baselineVisible:
            return "Panel 0 at (0,0), visible in window"
        case .baselineOffscreen:
            return "Panel 1 at (300,0), outside 300px window"
        case .overlappingAll:
            return "All 3 panels at (0,0), overlapping, panel 2 on top"
        case .overlappingWithOpacity:
            return "All at (0,0), opacity=0 hides panels 0,2, shows panel 1"
        case .overlappingShowPanel1:
            return "All at (0,0), z-order changed to show panel 1 on top"
        case .parentTransformSlide:
            return "All at (0,0), parent transform slides to show panel 1 slot"
        case .preparedContentRect:
            return "Side-by-side, preparedContentRect override"
        case .noClipping:
            return "Side-by-side, clipsToBounds=false"
        }
    }
}

// MARK: - SwiftUI Test Content

struct TestPanelContent: View {
    let panelIndex: Int
    let colors: [Color] = [.blue, .green, .orange]

    var body: some View {
        ZStack {
            colors[panelIndex % colors.count].opacity(0.3)

            VStack(spacing: 8) {
                Text("Panel \(panelIndex)")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("SwiftUI Text")
                    .font(.body)

                // Add some non-text content for comparison
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(colors[panelIndex % colors.count])

                Text("Idx: \(panelIndex)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Custom View for preparedContentRect override

class PreparedContentView: NSView {
    override func prepareContent(in rect: NSRect) {
        // Tell system to prepare ALL content
        super.prepareContent(in: bounds)
    }

    override var preparedContentRect: NSRect {
        get { return bounds }
        set { }
    }
}

// MARK: - Test Window

class TestWindow: NSWindow {
    private var clipView: NSView!
    private var contentContainer: NSView!
    private var panels: [NSView] = []
    private var hostingViews: [NSHostingView<TestPanelContent>] = []

    private let panelWidth: CGFloat = 300
    private let panelHeight: CGFloat = 200
    private let panelCount = 3

    private var resultsLog: [String] = []
    private var projectPath: String {
        // Get the directory where the executable is, then navigate to project root
        let execPath = Bundle.main.executablePath ?? ""
        // Go up from .build/debug/SwiftUIOffscreenTest to project root
        if let range = execPath.range(of: "/.build/") {
            return String(execPath[..<range.lowerBound])
        }
        return FileManager.default.currentDirectoryPath
    }

    init() {
        let windowRect = NSRect(x: 100, y: 100, width: panelWidth, height: panelHeight)
        super.init(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "SwiftUI Offscreen Text Test"
        setupViews()
    }

    private func setupViews() {
        // Clip view (masks content to window bounds)
        clipView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        contentView = clipView

        // Content container (holds all panels)
        contentContainer = NSView(frame: clipView.bounds)
        contentContainer.wantsLayer = true
        clipView.addSubview(contentContainer)

        // Create 3 panels with SwiftUI content
        for i in 0..<panelCount {
            let panel = NSView(frame: NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                             width: panelWidth, height: panelHeight))
            panel.wantsLayer = true

            let hostingView = NSHostingView(rootView: TestPanelContent(panelIndex: i))
            hostingView.frame = panel.bounds
            hostingView.autoresizingMask = [.width, .height]
            panel.addSubview(hostingView)

            contentContainer.addSubview(panel)
            panels.append(panel)
            hostingViews.append(hostingView)
        }
    }

    // MARK: - Configuration Application

    func applyConfig(_ config: TestConfig) {
        // Reset all transforms, masks, and opacity
        contentContainer.layer?.sublayerTransform = CATransform3DIdentity
        for panel in panels {
            panel.layer?.transform = CATransform3DIdentity
            panel.layer?.mask = nil
            panel.layer?.opacity = 1.0
            panel.alphaValue = 1.0
        }
        clipView.layer?.masksToBounds = true

        switch config {
        case .baselineVisible:
            // Standard side-by-side, showing panel 0
            for (i, panel) in panels.enumerated() {
                panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                     width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = NSRect(x: 0, y: 0,
                                           width: panelWidth * CGFloat(panelCount),
                                           height: panelHeight)

        case .baselineOffscreen:
            // Standard side-by-side, scrolled to show panel 1 area
            // Panel 1 is at x=300, outside visible window
            for (i, panel) in panels.enumerated() {
                panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                     width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = NSRect(x: 0, y: 0,
                                           width: panelWidth * CGFloat(panelCount),
                                           height: panelHeight)

        case .overlappingAll:
            // All panels at (0,0), overlapping - panel 2 is on top
            for panel in panels {
                panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = clipView.bounds

        case .overlappingWithOpacity:
            // All panels at (0,0), use opacity to show only panel 1
            for panel in panels {
                panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = clipView.bounds
            // Hide panels 0 and 2, show panel 1
            panels[0].alphaValue = 0.0
            panels[2].alphaValue = 0.0

        case .overlappingShowPanel1:
            // All panels at (0,0), reorder z-order to put panel 1 on top
            for panel in panels {
                panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = clipView.bounds
            // Bring panel 1 to front
            panels[1].removeFromSuperview()
            contentContainer.addSubview(panels[1])

        case .parentTransformSlide:
            // All panels at (0,0) but each has a layer transform offset
            // Then parent sublayerTransform slides to show panel 1
            for (i, panel) in panels.enumerated() {
                panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
                // Offset each panel in layer space
                panel.layer?.transform = CATransform3DMakeTranslation(CGFloat(i) * panelWidth, 0, 0)
            }
            contentContainer.frame = clipView.bounds
            // Slide to show panel 1 (offset by -panelWidth)
            contentContainer.layer?.sublayerTransform = CATransform3DMakeTranslation(-panelWidth, 0, 0)

        case .preparedContentRect:
            // Side-by-side with preparedContentRect override
            for (i, panel) in panels.enumerated() {
                panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                     width: panelWidth, height: panelHeight)
            }
            contentContainer.frame = NSRect(x: 0, y: 0,
                                           width: panelWidth * CGFloat(panelCount),
                                           height: panelHeight)

        case .noClipping:
            // Side-by-side, but clipsToBounds=false everywhere
            clipView.layer?.masksToBounds = false
            contentContainer.layer?.masksToBounds = false
            for (i, panel) in panels.enumerated() {
                panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                     width: panelWidth, height: panelHeight)
                panel.layer?.masksToBounds = false
            }
            contentContainer.frame = NSRect(x: 0, y: 0,
                                           width: panelWidth * CGFloat(panelCount),
                                           height: panelHeight)
        }

        // Force layout
        clipView.layoutSubtreeIfNeeded()
        contentContainer.layoutSubtreeIfNeeded()
        for panel in panels {
            panel.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Screenshot Capture

    func captureScreenshot(for config: TestConfig) {
        let screenshotDir = projectPath + "/screenshots"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: screenshotDir,
                                                  withIntermediateDirectories: true)

        let filename = "\(screenshotDir)/config_\(config.rawValue)_\(config.name).png"

        // Use screencapture command to capture the window
        let windowID = windowNumber
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-l", String(windowID), "-x", filename]

        do {
            try task.run()
            task.waitUntilExit()
            print("Screenshot saved: \(filename)")
        } catch {
            print("Failed to capture screenshot: \(error)")
        }
    }

    // MARK: - Automated Test Runner

    func runAutomatedTests() {
        resultsLog = []
        resultsLog.append("SwiftUI Offscreen Text Rendering Test Results")
        resultsLog.append("=============================================")
        resultsLog.append("Date: \(Date())")
        resultsLog.append("")

        let configs = TestConfig.allCases
        var currentIndex = 0

        func runNextConfig() {
            guard currentIndex < configs.count else {
                // All tests complete
                saveResults()
                print("\n=== ALL TESTS COMPLETE ===")
                print("Results saved to: \(projectPath)/results.txt")
                print("Screenshots saved to: \(projectPath)/screenshots/")

                // Exit after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
                return
            }

            let config = configs[currentIndex]
            print("\n--- Config \(config.rawValue): \(config.name) ---")
            print(config.description)

            // Apply configuration
            applyConfig(config)

            // Log the configuration
            resultsLog.append("Config \(config.rawValue): \(config.name)")
            resultsLog.append("  Description: \(config.description)")

            // Log panel positions
            for (i, panel) in panels.enumerated() {
                let frame = panel.frame
                let visibleRect = panel.visibleRect
                resultsLog.append("  Panel \(i): frame=\(frame), visibleRect=\(visibleRect)")
                print("  Panel \(i): frame=\(frame), visibleRect=\(visibleRect)")
            }
            resultsLog.append("")

            // Wait for render, then capture screenshot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureScreenshot(for: config)
                currentIndex += 1

                // Small delay before next config
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    runNextConfig()
                }
            }
        }

        runNextConfig()
    }

    private func saveResults() {
        let resultsPath = projectPath + "/results.txt"
        let resultsText = resultsLog.joined(separator: "\n")

        do {
            try resultsText.write(toFile: resultsPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save results: \(error)")
        }
    }
}
