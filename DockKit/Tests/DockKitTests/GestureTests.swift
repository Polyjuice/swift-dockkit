import XCTest
import AppKit
@testable import DockKit

/// Items 1, 3, 4: each gesture through the path the UI takes, with DockKit's
/// default delegate behaviour. Each must land in getLayout() and notify.
final class GestureTests: DockKitTestCase {
    /// Stand-in for the tab bar that raised the event (the handlers ignore it).
    private let tabBar = DockTabBarView()

    // MARK: - Tear-off (item 1)

    func testTearOffDetachesIntoNewWindowAtDropPoint() throws {
        let p = makePanels("A", "B", "C")
        let source = openWindow(p, slot: 0, active: 1)
        let sourceFrame = source.frame
        let drop = NSPoint(x: screen.minX + 400, y: screen.maxY - 120)

        assertNotifiesLayoutChange("tear-off") {
            tabGroup(containing: p[1])!.tabBar(tabBar, didInitiateTearOff: 1, at: drop)
        }

        XCTAssertEqual(manager.windows.count, 2)
        let torn = try XCTUnwrap(window(containing: p[1]))
        XCTAssertFalse(torn === source)
        XCTAssertTrue(torn.frame.contains(drop), "the new window opens at the drop point")
        XCTAssertEqual(torn.frame.size, sourceFrame.size)
        XCTAssertEqual(source.frame, sourceFrame)
        XCTAssertEqual(source.rootPanel.allContentIds(), [p[0].panelId, p[2].panelId])
        XCTAssertEqual(torn.rootPanel.allContentIds(), [p[1].panelId])
        XCTAssertEqual(p[1].floatingDockCount, 1)

        let layout = manager.getLayout()
        let tornRoot = try XCTUnwrap(layout.panels.first { $0.id == torn.windowId })
        XCTAssertEqual(tornRoot.frame, torn.frame)
        XCTAssertEqual(tornRoot.group?.children.first?.cargo, p[1].tab.cargo, "the tab keeps its cargo")
        assertConsistent()
    }

    func testTearingOffALoneTabMovesItsWindow() {
        let a = makePanels("A")[0]
        let window = openWindow([a], slot: 0)
        let drop = NSPoint(x: screen.minX + 500, y: screen.maxY - 100)

        assertNotifiesLayoutChange("tear-off of a lone tab") {
            tabGroup(containing: a)!.tabBar(tabBar, didInitiateTearOff: 0, at: drop)
        }
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertTrue(manager.windows[0] === window)
        XCTAssertTrue(window.frame.contains(drop))
        XCTAssertEqual(manager.getLayout().panels[0].frame, window.frame)
        XCTAssertEqual(delegate.allWindowsClosed, 0)
        assertConsistent()
    }

    func testRefusedTearOffKeepsTheTab() {
        let p = makePanels("A", "B")
        let refusing = RefusingDelegate()
        manager.delegate = refusing
        let window = openWindow(p, slot: 0)

        tabGroup(containing: p[1])!.tabBar(tabBar, didInitiateTearOff: 1, at: NSPoint(x: screen.midX, y: screen.midY))
        XCTAssertEqual(refusing.proposals, 1)
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertEqual(window.rootPanel.allContentIds(), p.map(\.panelId))
        XCTAssertTrue(p[1].window === window)
    }

    func testTearOffWithoutDelegate() {
        let p = makePanels("A", "B")
        manager.delegate = nil
        openWindow(p, slot: 0)
        tabGroup(containing: p[0])!.tabBar(tabBar, didInitiateTearOff: 0, at: NSPoint(x: screen.midX, y: screen.midY))
        XCTAssertEqual(manager.windows.count, 2)
        assertConsistent()
    }

    // MARK: - Cross-window move (item 2)

    func testDropIntoAnotherWindowMovesTheTab() throws {
        let p = makePanels("A", "B", "C")
        let first = openWindow([p[0], p[1]], slot: 0)
        let second = openWindow([p[2]], slot: 1)
        let target = try XCTUnwrap(tabGroups(in: first).first)

        // Into the earlier window: the source tab group lets go after the target adopted the view
        assertNotifiesLayoutChange("cross-window move") {
            target.tabBar(tabBar, didReceiveDroppedTab: dragInfo(p[2]), at: 1)
        }
        XCTAssertEqual(first.rootPanel.allContentIds(), [p[0].panelId, p[2].panelId, p[1].panelId])
        XCTAssertFalse(manager.windows.contains { $0 === second }, "the emptied window closes")
        XCTAssertTrue(p[2].window === first)
        XCTAssertEqual(delegate.allWindowsClosed, 0)
        assertConsistent()
    }

    func testDropIntoATornOffWindowMovesTheTab() throws {
        let p = makePanels("A", "B", "C")
        let source = openWindow(p, slot: 0)
        let torn = manager.detachPanel(p[2], at: NSPoint(x: screen.minX + 500, y: screen.maxY - 100))
        let target = try XCTUnwrap(tabGroups(in: torn).first)

        assertNotifiesLayoutChange("move into a torn-off window") {
            manager.dockWindow(torn, didReceiveTab: dragInfo(p[0]), in: target, at: 0)
        }
        XCTAssertEqual(torn.rootPanel.allContentIds(), [p[0].panelId, p[2].panelId])
        XCTAssertEqual(source.rootPanel.allContentIds(), [p[1].panelId])
        XCTAssertTrue(p[0].window === torn)
        assertConsistent()
    }

    // MARK: - Split and collapse keep the window (item 3)

    func testSplitKeepsTheWindowAndItsFrame() throws {
        let p = makePanels("A", "B")
        let window = openWindow(p, slot: 0)
        let frameBefore = window.frame
        let group = try XCTUnwrap(tabGroups(in: window).first)

        assertNotifiesLayoutChange("split") {
            group.dropOverlay(DockDropOverlayView(), didSelectZone: .right, withTab: dragInfo(p[1]))
        }
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertTrue(manager.windows[0] === window)
        XCTAssertEqual(window.frame, frameBefore)
        XCTAssertEqual(window.rootPanel.group?.style, .split)
        XCTAssertEqual(tabGroups(in: window).map { $0.childPanels.map(\.id) }, [[p[0].panelId], [p[1].panelId]])
        XCTAssertEqual(manager.getLayout().panels[0].frame, frameBefore)
        assertConsistent()
    }

    func testCollapseKeepsTheWindowAndItsFrame() throws {
        let p = makePanels("A", "B", "C")
        let window = openWindow(p, slot: 0)
        let frameBefore = window.frame
        manager.dockWindow(window, wantsToSplit: .bottom, withPanelId: p[2].panelId, in: tabGroups(in: window)[0])
        XCTAssertEqual(window.rootPanel.group?.style, .split)

        // Drag C back into the first group: the split collapses
        let first = tabGroups(in: window)[0]
        assertNotifiesLayoutChange("collapse by move") {
            first.tabBar(tabBar, didReceiveDroppedTab: dragInfo(p[2]), at: 2)
        }
        XCTAssertTrue(manager.windows[0] === window)
        XCTAssertEqual(window.frame, frameBefore)
        XCTAssertEqual(window.rootPanel.group?.style, .tabs)
        XCTAssertEqual(window.rootPanel.allContentIds(), p.map(\.panelId))
        assertConsistent()

        // Split again and close the lone tab instead: same collapse
        manager.dockWindow(window, wantsToSplit: .right, withPanelId: p[1].panelId, in: tabGroups(in: window)[0])
        assertNotifiesLayoutChange("collapse by close") {
            tabGroup(containing: p[1])!.tabBar(tabBar, didCloseTabAt: 0)
        }
        XCTAssertTrue(manager.windows[0] === window)
        XCTAssertEqual(window.frame, frameBefore)
        XCTAssertEqual(window.rootPanel.allContentIds(), [p[0].panelId, p[2].panelId])
        assertConsistent()
    }

    // MARK: - Changes in place land in getLayout() (item 4)

    func testTabSelectionIsReflectedAndNotified() {
        let p = makePanels("A", "B", "C")
        openWindow(p, slot: 0)
        assertNotifiesLayoutChange("tab selection") {
            tabGroup(containing: p[0])!.tabBar(tabBar, didSelectTabAt: 2)
        }
        XCTAssertEqual(manager.getLayout().panels[0].group?.activeIndex, 2)
        XCTAssertEqual(manager.windows[0].title, "C")
        assertConsistent()
    }

    func testTabReorderIsReflectedAndNotified() {
        let p = makePanels("A", "B", "C")
        openWindow(p, slot: 0, active: 1)
        // The tab bar reports the final index: A dropped after C
        assertNotifiesLayoutChange("tab reorder") {
            tabGroup(containing: p[0])!.tabBar(tabBar, didReorderTabFrom: 0, to: 2)
        }
        let group = manager.getLayout().panels[0].group
        XCTAssertEqual(group?.children.map(\.id), [p[1].panelId, p[2].panelId, p[0].panelId])
        XCTAssertEqual(group?.activeIndex, 0, "B stays the active tab")

        // C dropped between B and A
        tabGroup(containing: p[0])!.tabBar(tabBar, didReorderTabFrom: 1, to: 0)
        XCTAssertEqual(manager.getLayout().panels[0].group?.children.map(\.id), [p[2].panelId, p[1].panelId, p[0].panelId])
        assertConsistent()
    }

    func testDividerDragIsReflectedAndNotified() throws {
        let p = makePanels("A", "B")
        let window = openWindow(p, slot: 0)
        manager.dockWindow(window, wantsToSplit: .right, withPanelId: p[1].panelId, in: tabGroups(in: window)[0])
        spin()
        let split = try XCTUnwrap(window.rootViewController as? DockSplitViewController)
        let width = split.splitView.bounds.width

        assertNotifiesLayoutChange("divider drag") {
            split.splitView.setPosition(width * 0.4, ofDividerAt: 0)
        }
        let proportions = try XCTUnwrap(manager.getLayout().panels[0].group?.proportions)
        XCTAssertEqual(proportions[0], 0.4, accuracy: 0.02)
        XCTAssertEqual(proportions[1], 0.6, accuracy: 0.02)
        assertConsistent()
    }

    func testWindowMoveAndResizeAreReflectedAndNotified() {
        let a = makePanels("A")[0]
        let window = openWindow([a], slot: 0)
        let moved = frame(slot: 3, size: NSSize(width: 610, height: 420))
        assertNotifiesLayoutChange("window move and resize") {
            window.setFrame(moved, display: true)
        }
        XCTAssertEqual(manager.getLayout().panels[0].frame, moved)

        assertNotifiesLayoutChange("window move") {
            window.setFrameOrigin(NSPoint(x: moved.minX + 15, y: moved.minY + 5))
        }
        XCTAssertEqual(manager.getLayout().panels[0].frame?.origin, NSPoint(x: moved.minX + 15, y: moved.minY + 5))
    }

    func testFullScreenTransitionsNotify() {
        // A real transition needs a Space; the window reports AppKit's notifications
        let window = openWindow(makePanels("A"), slot: 0)
        assertNotifiesLayoutChange("enter full screen") {
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        }
        assertNotifiesLayoutChange("exit full screen") {
            NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        }
        XCTAssertEqual(manager.getLayout().panels[0].isFullScreen, false)
        XCTAssertEqual(manager.getLayout().panels[0].frame, window.frame)
    }

    func testScreenIsRecorded() {
        openWindow(makePanels("A"), slot: 0)
        XCTAssertNotNil(manager.getLayout().panels[0].screenId)
    }

    // MARK: - Closing

    func testClosingTheLastTabClosesTheWindowAndNotifies() {
        let p = makePanels("A", "B")
        openWindow([p[0]], slot: 0)
        let other = openWindow([p[1]], slot: 1)

        assertNotifiesLayoutChange("closing a window's last tab") {
            tabGroup(containing: p[0])!.tabBar(tabBar, didCloseTabAt: 0)
        }
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertTrue(manager.windows[0] === other)
        XCTAssertEqual(manager.getLayout().panels.map(\.id), [other.windowId])
        XCTAssertEqual(delegate.allWindowsClosed, 0)

        assertNotifiesLayoutChange("closing the last window's last tab") {
            tabGroup(containing: p[1])!.tabBar(tabBar, didCloseTabAt: 0)
        }
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(manager.getLayout().panels.isEmpty)
        XCTAssertEqual(delegate.allWindowsClosed, 1)
    }

    func testClosingAWindowNotifies() {
        let p = makePanels("A", "B")
        let window = openWindow([p[0]], slot: 0)
        openWindow([p[1]], slot: 1)
        assertNotifiesLayoutChange("window close") {
            window.performClose(nil)
        }
        XCTAssertEqual(manager.getLayout().panels.count, 1)
        XCTAssertEqual(delegate.allWindowsClosed, 0)
    }

    func testUpdateLayoutClosingEveryWindowReportsAllClosedOnce() {
        openWindow(makePanels("A"), slot: 0)
        openWindow(makePanels("B"), slot: 1)
        manager.updateLayout(DockLayout(panels: []))
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertEqual(delegate.allWindowsClosed, 1)
    }
}
