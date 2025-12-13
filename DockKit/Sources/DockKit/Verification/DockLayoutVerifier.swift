import AppKit

/// Verifies that a DockLayout matches the actual macOS view hierarchy
/// Used for testing and debugging to ensure the JSON source of truth
/// accurately reflects the rendered state
public class DockLayoutVerifier {

    // MARK: - Public API

    /// Verify a layout against the actual windows and view hierarchy
    /// Returns a list of mismatches found
    public static func verify(
        layout: DockLayout,
        against windows: [DockWindow]
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Build maps for quick lookup
        let layoutWindowsById = Dictionary(uniqueKeysWithValues: layout.windows.map { ($0.id, $0) })
        let actualWindowsById = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })

        // Check for missing/extra windows
        let layoutWindowIds = Set(layout.windows.map { $0.id })
        let actualWindowIds = Set(windows.map { $0.windowId })

        // Windows in layout but not in actual
        for windowId in layoutWindowIds.subtracting(actualWindowIds) {
            mismatches.append(LayoutMismatch(
                path: "windows[\(windowId.uuidString.prefix(8))]",
                expected: "window exists",
                actual: "window missing",
                severity: .error
            ))
        }

        // Windows in actual but not in layout
        for windowId in actualWindowIds.subtracting(layoutWindowIds) {
            mismatches.append(LayoutMismatch(
                path: "windows[\(windowId.uuidString.prefix(8))]",
                expected: "window missing",
                actual: "window exists",
                severity: .error
            ))
        }

        // Verify each window that exists in both
        for windowId in layoutWindowIds.intersection(actualWindowIds) {
            guard let layoutWindow = layoutWindowsById[windowId],
                  let actualWindow = actualWindowsById[windowId] else { continue }

            let windowPath = "windows[\(windowId.uuidString.prefix(8))]"
            mismatches.append(contentsOf: verifyWindow(
                layout: layoutWindow,
                actual: actualWindow,
                path: windowPath
            ))
        }

        return mismatches
    }

    /// Verify layout from a DockLayoutManager
    public static func verify(manager: DockLayoutManager) -> [LayoutMismatch] {
        let layout = manager.getLayout()
        return verify(layout: layout, against: manager.windows)
    }

    // MARK: - Window Verification

    private static func verifyWindow(
        layout: WindowState,
        actual: DockWindow,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Verify frame
        let frameMatch = framesApproximatelyEqual(layout.frame, actual.frame)
        if !frameMatch {
            mismatches.append(LayoutMismatch(
                path: "\(path).frame",
                expected: frameString(layout.frame),
                actual: frameString(actual.frame),
                severity: .warning
            ))
        }

        // Verify fullscreen state
        let actualIsFullScreen = actual.styleMask.contains(.fullScreen)
        if layout.isFullScreen != actualIsFullScreen {
            mismatches.append(LayoutMismatch(
                path: "\(path).isFullScreen",
                expected: "\(layout.isFullScreen)",
                actual: "\(actualIsFullScreen)",
                severity: .error
            ))
        }

        // Verify root node
        if let rootVC = actual.rootViewController {
            mismatches.append(contentsOf: verifyNode(
                layout: layout.rootNode,
                actual: rootVC,
                path: "\(path).rootNode"
            ))
        } else {
            mismatches.append(LayoutMismatch(
                path: "\(path).rootNode",
                expected: "root view controller",
                actual: "nil",
                severity: .error
            ))
        }

        return mismatches
    }

    // MARK: - Node Verification

    private static func verifyNode(
        layout: DockLayoutNode,
        actual: NSViewController,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        switch (layout, actual) {
        case (.split(let layoutSplit), let splitVC as DockSplitViewController):
            mismatches.append(contentsOf: verifySplit(
                layout: layoutSplit,
                actual: splitVC,
                path: path
            ))

        case (.tabGroup(let layoutTabGroup), let tabGroupVC as DockTabGroupViewController):
            mismatches.append(contentsOf: verifyTabGroup(
                layout: layoutTabGroup,
                actual: tabGroupVC,
                path: path
            ))

        case (.split, _):
            mismatches.append(LayoutMismatch(
                path: path,
                expected: "DockSplitViewController",
                actual: String(describing: type(of: actual)),
                severity: .error
            ))

        case (.tabGroup, _):
            mismatches.append(LayoutMismatch(
                path: path,
                expected: "DockTabGroupViewController",
                actual: String(describing: type(of: actual)),
                severity: .error
            ))
        }

        return mismatches
    }

    // MARK: - Split Verification

    private static func verifySplit(
        layout: SplitLayoutNode,
        actual: DockSplitViewController,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Verify ID
        if layout.id != actual.nodeId {
            mismatches.append(LayoutMismatch(
                path: "\(path).id",
                expected: layout.id.uuidString.prefix(8).description,
                actual: actual.nodeId.uuidString.prefix(8).description,
                severity: .error
            ))
        }

        // Verify axis
        if layout.axis != actual.splitNode.axis {
            mismatches.append(LayoutMismatch(
                path: "\(path).axis",
                expected: "\(layout.axis)",
                actual: "\(actual.splitNode.axis)",
                severity: .error
            ))
        }

        // Verify proportions (with tolerance)
        if !proportionsApproximatelyEqual(layout.proportions, actual.getProportions()) {
            mismatches.append(LayoutMismatch(
                path: "\(path).proportions",
                expected: proportionsString(layout.proportions),
                actual: proportionsString(actual.getProportions()),
                severity: .warning
            ))
        }

        // Verify children count
        let actualChildren = actual.splitViewItems.map { $0.viewController }
        if layout.children.count != actualChildren.count {
            mismatches.append(LayoutMismatch(
                path: "\(path).children.count",
                expected: "\(layout.children.count)",
                actual: "\(actualChildren.count)",
                severity: .error
            ))
            return mismatches
        }

        // Verify each child
        for (index, (layoutChild, actualChild)) in zip(layout.children, actualChildren).enumerated() {
            mismatches.append(contentsOf: verifyNode(
                layout: layoutChild,
                actual: actualChild,
                path: "\(path).children[\(index)]"
            ))
        }

        return mismatches
    }

    // MARK: - Tab Group Verification

    private static func verifyTabGroup(
        layout: TabGroupLayoutNode,
        actual: DockTabGroupViewController,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Verify ID
        if layout.id != actual.tabGroupNode.id {
            mismatches.append(LayoutMismatch(
                path: "\(path).id",
                expected: layout.id.uuidString.prefix(8).description,
                actual: actual.tabGroupNode.id.uuidString.prefix(8).description,
                severity: .error
            ))
        }

        // Verify active tab index
        if layout.activeTabIndex != actual.tabGroupNode.activeTabIndex {
            mismatches.append(LayoutMismatch(
                path: "\(path).activeTabIndex",
                expected: "\(layout.activeTabIndex)",
                actual: "\(actual.tabGroupNode.activeTabIndex)",
                severity: .warning
            ))
        }

        // Verify tabs count
        if layout.tabs.count != actual.tabGroupNode.tabs.count {
            mismatches.append(LayoutMismatch(
                path: "\(path).tabs.count",
                expected: "\(layout.tabs.count)",
                actual: "\(actual.tabGroupNode.tabs.count)",
                severity: .error
            ))
            return mismatches
        }

        // Verify each tab
        for (index, (layoutTab, actualTab)) in zip(layout.tabs, actual.tabGroupNode.tabs).enumerated() {
            let tabPath = "\(path).tabs[\(index)]"

            if layoutTab.id != actualTab.id {
                mismatches.append(LayoutMismatch(
                    path: "\(tabPath).id",
                    expected: layoutTab.id.uuidString.prefix(8).description,
                    actual: actualTab.id.uuidString.prefix(8).description,
                    severity: .error
                ))
            }

            if layoutTab.title != actualTab.title {
                mismatches.append(LayoutMismatch(
                    path: "\(tabPath).title",
                    expected: layoutTab.title,
                    actual: actualTab.title,
                    severity: .warning
                ))
            }
        }

        return mismatches
    }

    // MARK: - Helpers

    private static func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2.0) -> Bool {
        return abs(a.origin.x - b.origin.x) <= tolerance &&
               abs(a.origin.y - b.origin.y) <= tolerance &&
               abs(a.size.width - b.size.width) <= tolerance &&
               abs(a.size.height - b.size.height) <= tolerance
    }

    private static func proportionsApproximatelyEqual(_ a: [CGFloat], _ b: [CGFloat], tolerance: CGFloat = 0.02) -> Bool {
        guard a.count == b.count else { return false }
        for (va, vb) in zip(a, b) {
            if abs(va - vb) > tolerance {
                return false
            }
        }
        return true
    }

    private static func frameString(_ frame: CGRect) -> String {
        return "(\(Int(frame.origin.x)), \(Int(frame.origin.y)), \(Int(frame.size.width)) x \(Int(frame.size.height)))"
    }

    private static func proportionsString(_ proportions: [CGFloat]) -> String {
        let percentages = proportions.map { "\(Int($0 * 100))%" }
        return "[\(percentages.joined(separator: ", "))]"
    }
}

// MARK: - LayoutMismatch (already defined in DockLayoutManager, but adding debug helpers)

extension LayoutMismatch: CustomStringConvertible {
    public var description: String {
        let severityIcon = severity == .error ? "ERROR" : "WARN"
        return "[\(severityIcon)] \(path): expected \(expected), got \(actual)"
    }
}

extension Array where Element == LayoutMismatch {
    public var hasErrors: Bool {
        return contains { $0.severity == .error }
    }

    public var hasWarnings: Bool {
        return contains { $0.severity == .warning }
    }

    public var errorCount: Int {
        return filter { $0.severity == .error }.count
    }

    public var warningCount: Int {
        return filter { $0.severity == .warning }.count
    }

    public func debugDescription() -> String {
        if isEmpty {
            return "Layout verification passed - no mismatches found"
        }

        var lines = ["Layout verification found \(count) mismatches (\(errorCount) errors, \(warningCount) warnings):"]
        for mismatch in self {
            lines.append("  \(mismatch.description)")
        }
        return lines.joined(separator: "\n")
    }
}
