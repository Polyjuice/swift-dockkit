import XCTest
import AppKit
@testable import DockKit

/// A renderer that only sets the bar's height; its tabs are bare views.
private final class TallRenderer: DockTabRenderer {
    let height: CGFloat
    init(height: CGFloat) { self.height = height }
    var tabBarHeight: CGFloat { height }
    func createTabView(for panel: Panel, isSelected: Bool) -> DockTabView { BareTab() }
    func updateTabView(_ view: DockTabView, for panel: Panel, isSelected: Bool) {}
    func setFocused(_ focused: Bool, on view: DockTabView) {}
    func createAddButton(for action: PanelAddAction?) -> NSView? { nil }
}

private final class BareTab: NSView, DockTabView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?
}

/// A container's tab bar in a view of the host's, its renderer per container.
final class TabBarHostTests: XCTestCase {
    private var window: NSWindow!
    private var panels: [UUID: TestPanel] = [:]

    override func setUpWithError() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("needs a screen") }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        DockKit.customTabRenderer = nil
        window?.close()
        window = nil
        panels = [:]
    }

    /// A container showing `titles` as one tab group, laid out in the window
    /// under a 46 pt host strip of the test's own.
    private func make(_ titles: [String]) -> (container: DockContainerViewController, host: NSView) {
        let container = DockContainerViewController()
        let host = NSView()
        let content = window.contentView!
        host.translatesAutoresizingMaskIntoConstraints = false
        container.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        content.addSubview(container.view)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: content.topAnchor), host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor), host.heightAnchor.constraint(equalToConstant: 46),
            container.view.topAnchor.constraint(equalTo: host.bottomAnchor), container.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: content.trailingAnchor), container.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for title in titles {
            let panel = TestPanel(title)
            panels[panel.panelId] = panel
            container.addPanel(panel, activate: false)
        }
        content.layoutSubtreeIfNeeded()
        return (container, host)
    }

    private func rootGroup(_ container: DockContainerViewController) -> DockTabGroupViewController? {
        container.children.first as? DockTabGroupViewController
    }

    private func bar(in view: NSView) -> DockTabBarView? {
        if let bar = view as? DockTabBarView { return bar }
        for sub in view.subviews { if let bar = bar(in: sub) { return bar } }
        return nil
    }

    func testRootTabBarLivesInTheHostAndSurvivesARebuild() throws {
        let (container, host) = make(["A", "B"])
        let group = try XCTUnwrap(rootGroup(container))
        XCTAssertTrue(group.tabBarSuperview === group.view, "without a host the bar is over the content")

        container.rootTabBarHost = host
        XCTAssertTrue(group.tabBarSuperview === host, "the bar moved into the host")
        window.contentView!.layoutSubtreeIfNeeded()
        let hosted = try XCTUnwrap(bar(in: host))
        XCTAssertEqual(hosted.frame.height, 46, accuracy: 0.5, "the bar fills the host")
        XCTAssertEqual(hosted.frame.width, 600, accuracy: 0.5)

        // Closing a tab rebuilds the root group: the new group's bar is in the host, the old one gone.
        let gone = try XCTUnwrap(panels.values.first { $0.panelTitle == "A" }).panelId
        container.removePanel(gone)
        let rebuilt = try XCTUnwrap(rootGroup(container))
        XCTAssertFalse(rebuilt === group)
        XCTAssertTrue(rebuilt.tabBarSuperview === host)
        XCTAssertEqual(host.subviews.filter { $0 is DockTabBarView }.count, 1, "one bar in the host")

        container.rootTabBarHost = nil
        XCTAssertTrue(rebuilt.tabBarSuperview === rebuilt.view, "nil puts the bar back over the content")
        XCTAssertNil(bar(in: host))
    }

    func testARendererSetsTheBarHeightAndIsPerContainer() throws {
        DockKit.customTabRenderer = TallRenderer(height: 40)
        let (plain, _) = make(["A"])
        let (own, _) = make(["B"])
        own.tabRenderer = TallRenderer(height: 32)
        window.contentView!.layoutSubtreeIfNeeded()
        let plainBar = try XCTUnwrap(bar(in: plain.view))
        let ownBar = try XCTUnwrap(bar(in: own.view))
        XCTAssertEqual(plainBar.frame.height, 40, accuracy: 0.5, "the process-wide renderer's height")
        XCTAssertEqual(ownBar.frame.height, 32, accuracy: 0.5, "the container's own renderer's height")
        XCTAssertTrue(ownBar.activeRenderer === own.tabRenderer)
        XCTAssertTrue(plainBar.activeRenderer === DockKit.customTabRenderer)

        DockKit.customTabRenderer = nil
        plain.rebuildLayout()
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(bar(in: plain.view)).frame.height, 28, accuracy: 0.5, "no renderer: 28")
    }

    func testTheAddButtonCanBeTurnedOff() throws {
        let (container, _) = make(["A"])
        XCTAssertFalse(try XCTUnwrap(bar(in: container.view)).showAddButton == false)
        container.showsAddButton = false
        XCTAssertFalse(try XCTUnwrap(bar(in: container.view)).showAddButton)
    }

    func testTheBarDoesNotMoveTheWindow() {
        XCTAssertFalse(DockTabBarView().mouseDownCanMoveWindow)
    }
}
