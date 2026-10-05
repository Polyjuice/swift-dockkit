import XCTest
import AppKit
@testable import DockKit

/// Item 2, 5, 6: window identity, exact frames, panel provider at build time.
final class WindowTests: DockKitTestCase {
    func testCreateWindowFrameIsExact() {
        let (a, b) = { let p = makePanels("A", "B"); return (p[0], p[1]) }()
        let requested = frame(slot: 1, size: NSSize(width: 733, height: 457))
        let window = manager.createWindow(rootPanel: tabGroupRoot([a, b]), frame: requested)
        XCTAssertEqual(window.frame, requested)
        spin()
        XCTAssertEqual(window.frame, requested)
        XCTAssertEqual(manager.getLayout().panels[0].frame, requested)

        // A rebuild (closing a tab rebuilds the window) neither moves nor resizes it
        manager.removePanel(b.panelId)
        XCTAssertEqual(window.frame, requested)
    }

    func testRestoredFrameIsExact() {
        let a = makePanels("A")[0]
        var root = tabGroupRoot([a])
        root.isTopLevelWindow = true
        root.frame = frame(slot: 2, size: NSSize(width: 640, height: 410))
        manager.updateLayout(DockLayout(panels: [root]))
        spin()
        XCTAssertEqual(manager.windows.first?.frame, root.frame)
        XCTAssertEqual(manager.getLayout().panels.first?.frame, root.frame)
    }

    func testRestoredSplitProportionsAreHonored() throws {
        let p = makePanels("A", "B", "C")
        let left = Panel(content: .group(PanelGroup(children: [p[0].tab], style: .tabs)))
        let right = Panel(content: .group(PanelGroup(children: [p[1].tab, p[2].tab], activeIndex: 1, style: .tabs)))
        let root = Panel(
            content: .group(PanelGroup(children: [left, right], axis: .horizontal, proportions: [0.3, 0.7], style: .split)),
            isTopLevelWindow: true,
            frame: frame(slot: 1, size: NSSize(width: 900, height: 500)))
        manager.updateLayout(DockLayout(panels: [root]))
        spin(0.2)
        let restored = try XCTUnwrap(manager.getLayout().panels.first?.group)
        XCTAssertEqual(restored.proportions[0], 0.3, accuracy: 0.01)
        XCTAssertEqual(restored.proportions[1], 0.7, accuracy: 0.01)
        XCTAssertEqual(restored.children[1].group?.activeIndex, 1)
        XCTAssertEqual(manager.windows[0].frame, root.frame)
    }

    func testSplitByGestureStartsEven() throws {
        let p = makePanels("A", "B")
        let window = openWindow(p, slot: 0)
        manager.dockWindow(window, wantsToSplit: .right, withPanelId: p[1].panelId, in: tabGroups(in: window)[0])
        spin(0.2)
        let proportions = try XCTUnwrap(manager.getLayout().panels.first?.group?.proportions)
        XCTAssertEqual(proportions[0], 0.5, accuracy: 0.01)
    }

    func testWindowIdIsRootPanelId() {
        let p = makePanels("A", "B", "C")
        let created = openWindow([p[0], p[1]], slot: 0)
        XCTAssertEqual(created.windowId, created.rootPanel.id)

        let detached = manager.detachPanel(p[1], at: NSPoint(x: screen.midX, y: screen.midY))
        XCTAssertEqual(detached.windowId, detached.rootPanel.id)

        let fromLayout = Panel.simpleWindow(frame: frame(slot: 3), children: [p[2].tab])
        manager.updateLayout(manager.getLayout().addingPanel(fromLayout))
        XCTAssertEqual(manager.windows.last?.windowId, fromLayout.id)
        assertConsistent()
    }

    func testPanelsAreShownInWindowsTheManagerCreates() {
        let p = makePanels("A", "B", "C")
        openWindow([p[0]], slot: 0)
        var root = tabGroupRoot([p[1]])
        root.frame = frame(slot: 1)
        manager.updateLayout(manager.getLayout().addingPanel(root))
        // A bare content root restored by updateLayout gets the provider too
        var bare = p[2].tab
        bare.frame = frame(slot: 2)
        manager.updateLayout(manager.getLayout().addingPanel(bare))
        spin()
        for panel in p {
            XCTAssertNotNil(panel.window, "\(panel.panelTitle) is not shown")
        }
        XCTAssertTrue(p[2].window === manager.windows[2])
        XCTAssertEqual(manager.getLayout().panels[2].id, p[2].panelId, "a bare content root stays itself")
    }

    func testCreateWindowPutsABareContentRootInATabGroup() throws {
        let p = makePanels("A", "B")
        let window = manager.createWindow(rootPanel: p[0].tab, frame: frame(slot: 1))
        openWindow([p[1]], slot: 2)
        XCTAssertEqual(window.rootPanel.group?.style, .tabs)
        XCTAssertEqual(window.rootPanel.allContentIds(), [p[0].panelId])
        XCTAssertTrue(p[0].window === window)

        // The group is in the layout, so a drop into the window lands
        let group = try XCTUnwrap(tabGroups(in: window).first)
        XCTAssertEqual(group.panel.id, window.windowId)
        group.tabBar(DockTabBarView(), didReceiveDroppedTab: dragInfo(p[1]), at: 1)
        XCTAssertEqual(window.rootPanel.allContentIds(), [p[0].panelId, p[1].panelId])
        assertConsistent()
    }

    func testNestedUpdateLayoutKeepsTheOuterUpdateQuiet() {
        let p = makePanels("A", "B")
        let first = openWindow([p[0]], slot: 0)
        let firstId = first.windowId
        spin()
        // While the outer update closes the first window, A's detach hook
        // runs a nested update (it moves that window)
        p[0].onWillDetach = { [unowned self] in
            p[0].onWillDetach = nil
            self.manager.updateLayout(self.manager.getLayout().updatingPanelFrame(firstId, frame: self.frame(slot: 3)))
        }
        var replacement = tabGroupRoot([p[1]])
        replacement.frame = frame(slot: 1)
        manager.updateLayout(DockLayout(panels: [replacement]))

        XCTAssertEqual(manager.windows.map(\.windowId), [replacement.id])
        XCTAssertEqual(delegate.allWindowsClosed, 0, "the outer update was told all windows closed mid-way")
    }

    func testSettingPanelProviderLaterResolvesPanels() {
        let a = makePanels("A")[0]
        let window = DockWindow(rootPanel: tabGroupRoot([a]), frame: frame(slot: 0))
        XCTAssertNil(a.window)
        window.panelProvider = { [unowned self] id in self.panels[id] }
        XCTAssertTrue(a.window === window)
        window.close()
    }
}
