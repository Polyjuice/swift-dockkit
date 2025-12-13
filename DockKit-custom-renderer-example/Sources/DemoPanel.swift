import AppKit
import DockKit

/// Simple demo panel with a colored background and title
class DemoPanel: NSViewController, DockablePanel {
    let panelId: UUID
    let panelTitle: String
    var panelIcon: NSImage? { nil }
    var panelViewController: NSViewController { self }
    let color: NSColor

    private var label: NSTextField!

    init(title: String, color: NSColor) {
        self.panelId = UUID()
        self.panelTitle = title
        self.color = color
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor

        label = NSTextField(labelWithString: panelTitle)
        label.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        self.view = container
    }

    // MARK: - DockablePanel

    func panelWillDetach() {
        print("[\(panelTitle)] Will detach")
    }

    func panelDidDock(at position: DockPosition) {
        print("[\(panelTitle)] Docked at \(position)")
    }
}
