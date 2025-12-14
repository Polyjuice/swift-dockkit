import Foundation

// MARK: - Log Level

/// Log level for console entries
public enum LogLevel: String {
    case log = "log"
    case warn = "warn"
    case error = "error"
}

// MARK: - Console Log Entry

/// A single console log entry
public struct ConsoleLogEntry: Identifiable {
    public let id = UUID()
    public let level: LogLevel
    public let message: String
    public let timestamp: Date
    public let source: String?

    public init(level: LogLevel, message: String, source: String? = nil) {
        self.level = level
        self.message = message
        self.timestamp = Date()
        self.source = source
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a new log entry is added
    static let consoleLogAdded = Notification.Name("DockKit.ConsoleLogAdded")
    /// Posted when the console is cleared
    static let consoleCleared = Notification.Name("DockKit.ConsoleCleared")
}

// MARK: - Console

/// App-wide console logging service (browser-style console)
/// Usage: Console.log("message"), Console.warn("message"), Console.error("message")
@MainActor
public final class Console {

    /// Shared singleton instance
    public static let shared = Console()

    /// All buffered log entries
    public private(set) var entries: [ConsoleLogEntry] = []

    /// Maximum number of entries to keep (circular buffer)
    public var maxEntries: Int = 1000

    private init() {}

    // MARK: - Static Convenience API

    /// Log a message (default level)
    /// Can be called from any context - writes to file synchronously for debugging
    nonisolated public static func log(_ message: String, source: String? = nil) {
        // Write to file synchronously first (for crash debugging)
        if let fileURL = logFileURL {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let fileLine = "[\(timestamp)] [LOG] \(message)\n"
            if let data = fileLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
        // Also dispatch to main actor for UI
        Task { @MainActor in
            shared.addEntry(.log, message: message, source: source)
        }
    }

    /// Log a warning message
    /// Can be called from any context - dispatches to main actor internally
    nonisolated public static func warn(_ message: String, source: String? = nil) {
        Task { @MainActor in
            shared.addEntry(.warn, message: message, source: source)
        }
    }

    /// Log an error message
    /// Can be called from any context - dispatches to main actor internally
    nonisolated public static func error(_ message: String, source: String? = nil) {
        Task { @MainActor in
            shared.addEntry(.error, message: message, source: source)
        }
    }

    // MARK: - Entry Management

    /// File URL for persistent logging (set to enable file logging)
    nonisolated(unsafe) public static var logFileURL: URL?

    /// Add a new log entry
    private func addEntry(_ level: LogLevel, message: String, source: String?) {
        let entry = ConsoleLogEntry(level: level, message: message, source: source)
        entries.append(entry)

        // Trim to max size (circular buffer)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Post notification for any listening ConsolePanel instances
        NotificationCenter.default.post(
            name: .consoleLogAdded,
            object: self,
            userInfo: ["entry": entry]
        )

        // Format the log line
        let levelPrefix: String
        switch level {
        case .log:
            levelPrefix = "[LOG]"
        case .warn:
            levelPrefix = "[WARN]"
        case .error:
            levelPrefix = "[ERROR]"
        }
        let logLine = "\(levelPrefix) \(message)"

        // Print to stdout for Xcode console visibility
        print(logLine)

        // Write to file if enabled
        if let fileURL = Console.logFileURL {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let fileLine = "[\(timestamp)] \(logLine)\n"
            if let data = fileLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    /// Clear all log entries
    public func clear() {
        entries.removeAll()
        NotificationCenter.default.post(
            name: .consoleCleared,
            object: self
        )
    }
}
