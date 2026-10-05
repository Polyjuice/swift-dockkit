import XCTest
import AppKit
@testable import DockKit

/// A panel whose content is a plain view, so tests can see which window shows it.
final class TestPanel: DockablePanel {
    let panelId: UUID
    let panelTitle: String
    var panelIcon: NSImage? { nil }
    lazy var panelViewController: NSViewController = {
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        return vc
    }()
    private(set) var detachCount = 0
    private(set) var floatingDockCount = 0

    init(_ title: String, id: UUID = UUID()) {
        panelId = id
        panelTitle = title
    }

    /// Runs inside panelWillDetach (the reconciler calls it mid-update).
    var onWillDetach: (() -> Void)?

    func panelWillDetach() {
        detachCount += 1
        onWillDetach?()
    }
    func panelDidDock(at position: DockPosition) {
        if position == .floating { floatingDockCount += 1 }
    }

    /// The window this panel's view is in, if any.
    var window: NSWindow? { panelViewController.view.window }

    /// A tab entry for this panel, with cargo the round trip must keep.
    var tab: Panel {
        Panel.contentPanel(id: panelId, title: panelTitle, cargo: ["kind": "test", "title": AnyCodable(panelTitle)])
    }
}

/// Counts what the manager tells its delegate; every proposal takes DockKit's default.
final class RecordingDelegate: DockLayoutManagerDelegate {
    var layoutChanges = 0
    var allWindowsClosed = 0
    func layoutManagerDidChangeLayout(_ manager: DockLayoutManager) { layoutChanges += 1 }
    func layoutManagerDidCloseAllWindows(_ manager: DockLayoutManager) { allWindowsClosed += 1 }
}

/// Refuses every tear-off.
final class RefusingDelegate: DockLayoutManagerDelegate {
    var proposals = 0
    func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
        proposals += 1
    }
}

class DockKitTestCase: XCTestCase {
    var manager: DockLayoutManager!
    var delegate: RecordingDelegate!
    var panels: [UUID: TestPanel] = [:]

    override func setUpWithError() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("needs a screen") }
        manager = DockLayoutManager()
        delegate = RecordingDelegate()
        manager.delegate = delegate
        manager.panelProvider = { [unowned self] id in self.panels[id] }
    }

    override func tearDown() {
        for window in manager?.windows ?? [] { window.close() }
        spin()
        manager = nil
        delegate = nil
        panels = [:]
    }

    /// The visible frame of the main screen; test windows live inside it.
    var screen: NSRect { NSScreen.main!.visibleFrame }

    /// A window-sized frame inside the screen, offset by `slot`.
    func frame(slot: Int, size: NSSize = NSSize(width: 520, height: 380)) -> NSRect {
        NSRect(x: screen.minX + 40 + CGFloat(slot) * 60,
               y: screen.minY + 40 + CGFloat(slot) * 30,
               width: size.width, height: size.height)
    }

    func makePanels(_ titles: String...) -> [TestPanel] {
        titles.map { title in
            let panel = TestPanel(title)
            panels[panel.panelId] = panel
            return panel
        }
    }

    func tabGroupRoot(_ tabs: [TestPanel], active: Int = 0) -> Panel {
        Panel(content: .group(PanelGroup(children: tabs.map(\.tab), activeIndex: active, style: .tabs)))
    }

    @discardableResult
    func openWindow(_ tabs: [TestPanel], slot: Int, active: Int = 0) -> DockWindow {
        manager.createWindow(rootPanel: tabGroupRoot(tabs, active: active), frame: frame(slot: slot))
    }

    /// Run the main run loop briefly (coalesced notifications, layout passes).
    func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Perform `action` and wait for at least one layoutManagerDidChangeLayout.
    func assertNotifiesLayoutChange(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ action: () -> Void) {
        spin()
        let before = delegate.layoutChanges
        action()
        let deadline = Date(timeIntervalSinceNow: 2)
        while delegate.layoutChanges == before && Date() < deadline { spin(0.01) }
        XCTAssertGreaterThan(delegate.layoutChanges, before, "\(what) did not notify the delegate", file: file, line: line)
    }

    func window(containing panel: TestPanel) -> DockWindow? {
        manager.windows.first { $0.containsPanel(panel.panelId) }
    }

    func tabGroups(in window: DockWindow) -> [DockTabGroupViewController] {
        func collect(_ vc: NSViewController?) -> [DockTabGroupViewController] {
            if let tabGroup = vc as? DockTabGroupViewController { return [tabGroup] }
            if let split = vc as? DockSplitViewController { return split.splitViewItems.flatMap { collect($0.viewController) } }
            return []
        }
        return collect(window.rootViewController)
    }

    func tabGroup(containing panel: TestPanel) -> DockTabGroupViewController? {
        manager.windows.flatMap { tabGroups(in: $0) }.first { $0.childPanels.contains { $0.id == panel.panelId } }
    }

    func dragInfo(_ panel: TestPanel) -> DockTabDragInfo {
        DockTabDragInfo(tabId: panel.panelId, sourceGroupId: tabGroup(containing: panel)!.panel.id,
                        title: panel.panelTitle, iconName: nil)
    }

    /// The invariants every gesture must keep: window id == root panel id,
    /// the layout lists exactly the windows, and each docked panel is shown
    /// in the window whose layout holds it.
    func assertConsistent(file: StaticString = #filePath, line: UInt = #line) {
        let layout = manager.getLayout()
        XCTAssertEqual(layout.panels.map(\.id), manager.windows.map(\.windowId), "layout roots != windows", file: file, line: line)
        for window in manager.windows {
            XCTAssertEqual(window.windowId, window.rootPanel.id, "window id != root panel id", file: file, line: line)
            for id in window.rootPanel.allContentIds() {
                if let panel = panels[id] {
                    XCTAssertTrue(panel.window === window, "\(panel.panelTitle) not shown in its window", file: file, line: line)
                }
            }
        }
        XCTAssertTrue(DockLayoutDiff.compute(from: layout, to: manager.getLayout()).isEmpty, file: file, line: line)
    }
}

extension DockLayout {
    /// Proportions are re-derived from pixel sizes when a split lays out;
    /// round them so layouts compare equal across a save and reload.
    func roundingProportions() -> DockLayout {
        func round(_ panel: Panel) -> Panel {
            guard case .group(var group) = panel.content else { return panel }
            group.proportions = group.proportions.map { ($0 * 100).rounded() / 100 }
            group.children = group.children.map(round)
            var rounded = panel
            rounded.content = .group(group)
            return rounded
        }
        return DockLayout(panels: panels.map(round))
    }
}
