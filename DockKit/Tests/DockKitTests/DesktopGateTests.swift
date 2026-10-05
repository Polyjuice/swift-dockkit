import XCTest
import AppKit
@testable import DockKit

/// The M1 gate (always-on docs/desktop.plan.md): a desktop with no main
/// window, worked by hand through DockKit's defaults, survives a save and a
/// reload with nothing lost.
final class DesktopGateTests: DockKitTestCase {
    private let tabBar = DockTabBarView()

    func testDesktopSurvivesSaveAndReload() throws {
        let p = makePanels("TV 1", "Terminal", "Browser", "TV 2", "Log")
        let (tv1, terminal, browser, tv2, log) = (p[0], p[1], p[2], p[3], p[4])

        // Three panels in three windows (the first with a second tab)
        let first = openWindow([tv1, log], slot: 0)
        let second = openWindow([terminal], slot: 2)
        let third = openWindow([tv2], slot: 4)
        let changes = delegate.layoutChanges

        // Drag a tab into another window
        tabGroups(in: second)[0].tabBar(tabBar, didReceiveDroppedTab: dragInfo(log), at: 0)
        XCTAssertEqual(second.rootPanel.allContentIds(), [log.panelId, terminal.panelId])

        // Tear one off
        manager.createWindow(rootPanel: tabGroupRoot([browser]), frame: frame(slot: 6))
        tabGroups(in: second)[0].tabBar(tabBar, didInitiateTearOff: 1, at: NSPoint(x: screen.minX + 700, y: screen.maxY - 80))
        let torn = try XCTUnwrap(window(containing: terminal))
        XCTAssertFalse(torn === second)

        // Split: TV 2 dropped on the right half of the first window (its own window closes)
        tabGroups(in: first)[0].dropOverlay(DockDropOverlayView(), didSelectZone: .right, withTab: dragInfo(tv2))
        XCTAssertFalse(manager.windows.contains { $0 === third })
        XCTAssertEqual(first.rootPanel.group?.style, .split)
        spin()

        // Move the divider, switch tabs (the commit a swipe makes), move a window
        let split = try XCTUnwrap(first.rootViewController as? DockSplitViewController)
        split.splitView.setPosition(split.splitView.bounds.width * 0.6, ofDividerAt: 0)
        manager.addPanel(TestPanel("unused"), to: torn.windowId)  // unresolvable extra tab, then closed again
        manager.removePanel(torn.rootPanel.allContentIds().last!)
        tabGroups(in: second)[0].tabBar(tabBar, didSelectTabAt: 0)
        second.setFrameOrigin(NSPoint(x: second.frame.minX + 33, y: second.frame.minY + 11))
        spin()
        assertConsistent()
        XCTAssertGreaterThan(delegate.layoutChanges, changes)

        // Save
        let saved = manager.getLayout()
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(saved.panels.count, 4)

        // Quit: the windows go away
        for window in manager.windows { window.close() }
        spin()

        // Relaunch: a new manager restores the saved layout
        manager = DockLayoutManager()
        delegate = RecordingDelegate()
        manager.delegate = delegate
        manager.panelProvider = { [unowned self] id in self.panels[id] }
        let restored = try JSONDecoder().decode(DockLayout.self, from: data)
        XCTAssertEqual(restored, saved)
        manager.updateLayout(restored)
        spin(0.2)

        // Compare
        let reloaded = manager.getLayout()
        XCTAssertEqual(reloaded.roundingProportions(), saved.roundingProportions())
        XCTAssertEqual(reloaded.panels.map(\.frame), saved.panels.map(\.frame))
        for panel in p {
            XCTAssertNotNil(panel.window, "\(panel.panelTitle) lost")
        }
        assertConsistent()
    }
}

/// The stage-host path (DockStageHostWindow) shares the tab group; it still shows its panels.
final class StageHostSmokeTests: DockKitTestCase {
    func testStageHostWindowShowsItsPanels() throws {
        let p = makePanels("A", "B")
        let stage = Panel(title: "One", content: .group(PanelGroup(children: p.map(\.tab), activeIndex: 1, style: .tabs)))
        let root = Panel(content: .group(PanelGroup(children: [stage], style: .stages)))
        let window = DockStageHostWindow(panel: root, frame: frame(slot: 0), panelProvider: { [unowned self] id in self.panels[id] })
        window.makeKeyAndOrderFront(nil)
        spin()
        XCTAssertTrue(p[1].window === window)
        window.close()
    }
}
