import Foundation

/// Opt-in diagnostic counter store used to investigate redundant
/// reconciliation work. Off by default — flip `enabled` at host startup
/// to begin recording. Bumps are no-ops when disabled.
public enum DockDiagnostics {
    public static var enabled: Bool = false
    public static let counters = DockDiagnosticsCounters()
}

public final class DockDiagnosticsCounters {
    public static let updatedNotification = Notification.Name("DockDiagnosticsCountersUpdated")

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var displayOrder: [String] = []

    public func bump(_ name: String) {
        guard DockDiagnostics.enabled else { return }
        lock.lock()
        if counts[name] == nil { displayOrder.append(name) }
        counts[name, default: 0] += 1
        lock.unlock()
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
            }
        }
    }

    public func snapshot() -> [(name: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        return displayOrder.map { ($0, counts[$0] ?? 0) }
    }
}
