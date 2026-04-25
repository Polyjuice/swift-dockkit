import AppKit

/// Tiny live readout of `DockDiagnostics.counters`. Mount via
/// `DockStageHostWindow.addHeaderTrailingItem(...)` from the host app
/// when diagnostics are enabled.
public final class DockDiagnosticsHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: DockDiagnosticsCounters.updatedNotification,
            object: nil
        )
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    @objc private func refresh() {
        let snap = DockDiagnostics.counters.snapshot()
        label.stringValue = snap.isEmpty
            ? "diag: (idle)"
            : snap.map { "\($0.name):\($0.count)" }.joined(separator: " ")
    }
}
