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
        let layoutPanelsById = Dictionary(uniqueKeysWithValues: layout.panels.map { ($0.id, $0) })
        let actualWindowsById = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })

        // Check for missing/extra windows
        let layoutPanelIds = Set(layout.panels.map { $0.id })
        let actualWindowIds = Set(windows.map { $0.windowId })

        // Panels in layout but not in actual
        for panelId in layoutPanelIds.subtracting(actualWindowIds) {
            mismatches.append(LayoutMismatch(
                path: "panels[\(panelId.uuidString.prefix(8))]",
                expected: "window exists",
                actual: "window missing",
                severity: .error
            ))
        }

        // Windows in actual but not in layout
        for windowId in actualWindowIds.subtracting(layoutPanelIds) {
            mismatches.append(LayoutMismatch(
                path: "panels[\(windowId.uuidString.prefix(8))]",
                expected: "window missing",
                actual: "window exists",
                severity: .error
            ))
        }

        // Verify each window that exists in both
        for panelId in layoutPanelIds.intersection(actualWindowIds) {
            guard let layoutPanel = layoutPanelsById[panelId],
                  let actualWindow = actualWindowsById[panelId] else { continue }

            let windowPath = "panels[\(panelId.uuidString.prefix(8))]"
            mismatches.append(contentsOf: verifyWindow(
                layoutPanel: layoutPanel,
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
        layoutPanel: Panel,
        actual: DockWindow,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Verify frame
        if let layoutFrame = layoutPanel.frame {
            let frameMatch = framesApproximatelyEqual(layoutFrame, actual.frame)
            if !frameMatch {
                mismatches.append(LayoutMismatch(
                    path: "\(path).frame",
                    expected: frameString(layoutFrame),
                    actual: frameString(actual.frame),
                    severity: .warning
                ))
            }
        }

        // Verify fullscreen state
        let actualIsFullScreen = actual.styleMask.contains(.fullScreen)
        let layoutIsFullScreen = layoutPanel.isFullScreen ?? false
        if layoutIsFullScreen != actualIsFullScreen {
            mismatches.append(LayoutMismatch(
                path: "\(path).isFullScreen",
                expected: "\(layoutIsFullScreen)",
                actual: "\(actualIsFullScreen)",
                severity: .error
            ))
        }

        // Verify panel tree
        if let rootVC = actual.rootViewController {
            mismatches.append(contentsOf: verifyPanel(
                layout: layoutPanel,
                actual: rootVC,
                path: "\(path).root"
            ))
        } else {
            mismatches.append(LayoutMismatch(
                path: "\(path).root",
                expected: "root view controller",
                actual: "nil",
                severity: .error
            ))
        }

        return mismatches
    }

    // MARK: - Panel Verification

    private static func verifyPanel(
        layout: Panel,
        actual: NSViewController,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        guard let group = layout.group else {
            // Content panel - nothing to verify at the view controller level
            return mismatches
        }

        switch (group.style, actual) {
        case (.split, let splitVC as DockSplitViewController):
            mismatches.append(contentsOf: verifySplit(
                layout: layout,
                layoutGroup: group,
                actual: splitVC,
                path: path
            ))

        case (.tabs, let tabGroupVC as DockTabGroupViewController),
             (.thumbnails, let tabGroupVC as DockTabGroupViewController):
            mismatches.append(contentsOf: verifyTabGroup(
                layout: layout,
                layoutGroup: group,
                actual: tabGroupVC,
                path: path
            ))

        case (.stages, let stageHostVC as DockStageHostViewController):
            // Verify stage host ID matches
            if layout.id != stageHostVC.stagePanel.id {
                mismatches.append(LayoutMismatch(
                    path: "\(path).id",
                    expected: layout.id.uuidString.prefix(8).description,
                    actual: stageHostVC.stagePanel.id.uuidString.prefix(8).description,
                    severity: .error
                ))
            }

        case (.split, _):
            mismatches.append(LayoutMismatch(
                path: path,
                expected: "DockSplitViewController (split style)",
                actual: String(describing: type(of: actual)),
                severity: .error
            ))

        case (.tabs, _), (.thumbnails, _):
            mismatches.append(LayoutMismatch(
                path: path,
                expected: "DockTabGroupViewController (tabs/thumbnails style)",
                actual: String(describing: type(of: actual)),
                severity: .error
            ))

        case (.stages, _):
            mismatches.append(LayoutMismatch(
                path: path,
                expected: "DockStageHostViewController (stages style)",
                actual: String(describing: type(of: actual)),
                severity: .error
            ))
        }

        return mismatches
    }

    // MARK: - Split Verification

    private static func verifySplit(
        layout: Panel,
        layoutGroup: PanelGroup,
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
        let actualGroup = actual.panel.group
        if layoutGroup.axis != actualGroup?.axis {
            mismatches.append(LayoutMismatch(
                path: "\(path).axis",
                expected: "\(layoutGroup.axis)",
                actual: "\(actualGroup?.axis.rawValue ?? "nil")",
                severity: .error
            ))
        }

        // Verify proportions (with tolerance)
        if !proportionsApproximatelyEqual(layoutGroup.proportions, actual.getProportions()) {
            mismatches.append(LayoutMismatch(
                path: "\(path).proportions",
                expected: proportionsString(layoutGroup.proportions),
                actual: proportionsString(actual.getProportions()),
                severity: .warning
            ))
        }

        // Verify children count
        let actualChildren = actual.splitViewItems.map { $0.viewController }
        if layoutGroup.children.count != actualChildren.count {
            mismatches.append(LayoutMismatch(
                path: "\(path).children.count",
                expected: "\(layoutGroup.children.count)",
                actual: "\(actualChildren.count)",
                severity: .error
            ))
            return mismatches
        }

        // Verify each child
        for (index, (layoutChild, actualChild)) in zip(layoutGroup.children, actualChildren).enumerated() {
            mismatches.append(contentsOf: verifyPanel(
                layout: layoutChild,
                actual: actualChild,
                path: "\(path).children[\(index)]"
            ))
        }

        return mismatches
    }

    // MARK: - Tab Group Verification

    private static func verifyTabGroup(
        layout: Panel,
        layoutGroup: PanelGroup,
        actual: DockTabGroupViewController,
        path: String
    ) -> [LayoutMismatch] {
        var mismatches: [LayoutMismatch] = []

        // Verify ID
        if layout.id != actual.panel.id {
            mismatches.append(LayoutMismatch(
                path: "\(path).id",
                expected: layout.id.uuidString.prefix(8).description,
                actual: actual.panel.id.uuidString.prefix(8).description,
                severity: .error
            ))
        }

        // Verify active index
        if layoutGroup.activeIndex != actual.activeIndex {
            mismatches.append(LayoutMismatch(
                path: "\(path).activeIndex",
                expected: "\(layoutGroup.activeIndex)",
                actual: "\(actual.activeIndex)",
                severity: .warning
            ))
        }

        // Verify children count
        let actualChildren = actual.group?.children ?? []
        if layoutGroup.children.count != actualChildren.count {
            mismatches.append(LayoutMismatch(
                path: "\(path).children.count",
                expected: "\(layoutGroup.children.count)",
                actual: "\(actualChildren.count)",
                severity: .error
            ))
            return mismatches
        }

        // Verify each child
        for (index, (layoutChild, actualChild)) in zip(layoutGroup.children, actualChildren).enumerated() {
            let childPath = "\(path).children[\(index)]"

            if layoutChild.id != actualChild.id {
                mismatches.append(LayoutMismatch(
                    path: "\(childPath).id",
                    expected: layoutChild.id.uuidString.prefix(8).description,
                    actual: actualChild.id.uuidString.prefix(8).description,
                    severity: .error
                ))
            }

            if layoutChild.title != actualChild.title {
                mismatches.append(LayoutMismatch(
                    path: "\(childPath).title",
                    expected: layoutChild.title ?? "(nil)",
                    actual: actualChild.title ?? "(nil)",
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
