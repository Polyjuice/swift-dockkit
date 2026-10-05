import XCTest
@testable import DockKit

final class LayoutCodableTests: XCTestCase {
    /// Two windows: a split (tabs | thumbnails) on one screen, full screen;
    /// a tab group on another. Cargo of every JSON shape.
    private func sampleLayout() -> DockLayout {
        let cargo: [String: AnyCodable] = [
            "type": "television",
            "host": "tv-7--desktop.burpa.net",
            "zoom": 1.25,
            "count": 3,
            "one": 1,
            "zero": 0,
            "enabled": true,
            "muted": false,
            "nothing": nil,
            "tags": ["a", 2, 0.5, true],
            "nested": ["size": ["w": 640, "h": 480.5], "list": [], "map": [:]],
        ]
        let a = Panel.contentPanel(title: "A", iconName: "tv", cargo: cargo)
        let b = Panel.contentPanel(title: "B", cargo: ["type": "terminal", "cwd": "/tmp"])
        let c = Panel.contentPanel(title: "C")
        let d = Panel.contentPanel(title: "D", cargo: [:])
        let tabs = Panel(title: "left", content: .group(PanelGroup(
            children: [a, b], activeIndex: 1, style: .tabs,
            addActions: [PanelAddAction(id: "tv", iconName: "tv", tooltip: "New TV")])))
        let thumbs = Panel(content: .group(PanelGroup(
            children: [c], activeIndex: 0, style: .thumbnails, headerStyle: .tabs)))
        let split = Panel(
            cargo: ["window": "main"],
            content: .group(PanelGroup(children: [tabs, thumbs], axis: .vertical,
                                       proportions: [0.3125, 0.6875], style: .split)),
            isTopLevelWindow: true,
            frame: CGRect(x: -1440.5, y: 22.25, width: 1280, height: 777.75),
            isFullScreen: true,
            screenId: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        let single = Panel(
            content: .group(PanelGroup(children: [d], style: .tabs)),
            isTopLevelWindow: true,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400),
            isFullScreen: false)
        return DockLayout(panels: [split, single])
    }

    func testRoundTripIsLossless() throws {
        let layout = sampleLayout()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        let decoded = try JSONDecoder().decode(DockLayout.self, from: data)

        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(try encoder.encode(decoded), data)

        // Spot checks on what the store depends on
        XCTAssertEqual(decoded.panels[0].frame, CGRect(x: -1440.5, y: 22.25, width: 1280, height: 777.75))
        XCTAssertEqual(decoded.panels[0].isFullScreen, true)
        XCTAssertEqual(decoded.panels[0].screenId, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertNil(decoded.panels[1].screenId)
        let cargo = try XCTUnwrap(decoded.panels[0].group?.children[0].group?.children[0].cargo)
        XCTAssertEqual(cargo["one"]?.intValue, 1)
        XCTAssertEqual(cargo["enabled"]?.boolValue, true)
        XCTAssertEqual(cargo["zoom"]?.doubleValue, 1.25)
        XCTAssertEqual(cargo["nested"]?["size"]?["h"]?.doubleValue, 480.5)
        XCTAssertTrue(cargo["nothing"]?.isNull ?? false)
        XCTAssertEqual(DockLayout.fromJSON(layout.toJSON()!), layout)
    }

    func testLayoutWithoutScreenIdStillDecodes() throws {
        let layout = sampleLayout()
        let data = try JSONEncoder().encode(layout)
        // Strip screenId everywhere: the shape older DockKit wrote
        func strip(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                dict.removeValue(forKey: "screenId")
                return dict.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let old = try JSONSerialization.data(withJSONObject: strip(try JSONSerialization.jsonObject(with: data)))
        let decoded = try JSONDecoder().decode(DockLayout.self, from: old)
        var expected = layout
        expected.panels[0].screenId = nil
        XCTAssertEqual(decoded, expected)
    }

    // MARK: - Root identity (model level)

    func testSplittingARootKeepsItsIdAndFrame() {
        let a = Panel.contentPanel(title: "A"), b = Panel.contentPanel(title: "B")
        let root = Panel.simpleWindow(frame: CGRect(x: 300, y: 200, width: 700, height: 500), children: [a, b])
        let layout = DockLayout(panels: [root])

        let split = layout.splitting(groupId: root.id, direction: .right, withChild: b)

        XCTAssertEqual(split.panels.count, 1)
        let newRoot = split.panels[0]
        XCTAssertEqual(newRoot.id, root.id)
        XCTAssertEqual(newRoot.frame, root.frame)
        XCTAssertEqual(newRoot.isTopLevelWindow, true)
        XCTAssertEqual(newRoot.group?.style, .split)
        let groups = newRoot.group?.children ?? []
        XCTAssertEqual(groups.map { $0.allContentIds() }, [[a.id], [b.id]])
        XCTAssertFalse(groups.contains { $0.id == root.id }, "the old root, now a child, needs an id of its own")
        XCTAssertEqual(groups[0].isTopLevelWindow, false, "the old root is no longer a window")
        XCTAssertNil(groups[0].frame)
        XCTAssertNil(groups[0].isFullScreen)
    }

    func testOnlyTheRootAMutationEmptiesIsRemoved() {
        let a = Panel.contentPanel(title: "A"), b = Panel.contentPanel(title: "B"), c = Panel.contentPanel(title: "C")
        let empty = Panel.simpleWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let full = Panel.simpleWindow(children: [a, b])
        let single = Panel.simpleWindow(children: [c])
        let layout = DockLayout(panels: [empty, full, single])

        XCTAssertEqual(layout.removingChild(c.id).panels.map(\.id), [empty.id, full.id])
        XCTAssertEqual(layout.movingChild(c.id, toGroupId: full.id, at: 0).panels.map(\.id), [empty.id, full.id])
        XCTAssertEqual(layout.splitting(groupId: full.id, direction: .left, withChild: c).panels.map(\.id), [empty.id, full.id])
        // Into the empty window: it fills, the source empties
        let filled = layout.movingChild(c.id, toGroupId: empty.id, at: 0)
        XCTAssertEqual(filled.panels.map(\.id), [empty.id, full.id])
        XCTAssertEqual(filled.panels[0].allContentIds(), [c.id])
    }

    func testSplittingOntoAnUnknownGroupKeepsThePanel() {
        let a = Panel.contentPanel(title: "A"), b = Panel.contentPanel(title: "B")
        let layout = DockLayout(panels: [Panel.simpleWindow(children: [a, b])])
        let result = layout.splitting(groupId: UUID(), direction: .right, withChild: b)
        XCTAssertEqual(result, layout)
    }

    func testCollapsingARootKeepsItsIdAndFrame() {
        let a = Panel.contentPanel(title: "A"), b = Panel.contentPanel(title: "B")
        let root = Panel.simpleWindow(frame: CGRect(x: 300, y: 200, width: 700, height: 500), children: [a, b])
        let split = DockLayout(panels: [root]).splitting(groupId: root.id, direction: .right, withChild: b)
        let firstGroup = split.panels[0].group!.children[0]

        // Move B back next to A: the split is left with one child and collapses
        let collapsed = split.movingChild(b.id, toGroupId: firstGroup.id, at: 1)
        XCTAssertEqual(collapsed.panels[0].id, root.id)
        XCTAssertEqual(collapsed.panels[0].frame, root.frame)
        XCTAssertEqual(collapsed.panels[0].group?.style, .tabs)
        XCTAssertEqual(collapsed.panels[0].allContentIds(), [a.id, b.id])

        // Removing B instead collapses the same way
        let removed = split.removingChild(b.id)
        XCTAssertEqual(removed.panels[0].id, root.id)
        XCTAssertEqual(removed.panels[0].frame, root.frame)
        XCTAssertEqual(removed.panels[0].allContentIds(), [a.id])
    }
}
