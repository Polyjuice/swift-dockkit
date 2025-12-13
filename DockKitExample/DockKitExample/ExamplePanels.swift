import AppKit
import DockKit

// MARK: - Base Panel

class BaseExamplePanel: DockablePanel {
    let panelId = UUID()
    let panelTitle: String
    let panelIcon: NSImage?

    private lazy var viewController: NSViewController = {
        let vc = NSViewController()
        vc.view = contentView
        return vc
    }()

    var panelViewController: NSViewController { viewController }

    private let contentView: NSView

    init(title: String, icon: NSImage?, backgroundColor: NSColor, content: String) {
        self.panelTitle = title
        self.panelIcon = icon

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor

        let label = NSTextField(labelWithString: content)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        self.contentView = view
    }
}

// MARK: - Explorer Panel

class ExplorerPanel: BaseExamplePanel {
    init(number: Int) {
        super.init(
            title: "Explorer",
            icon: NSImage(systemSymbolName: "folder", accessibilityDescription: "Explorer"),
            backgroundColor: NSColor.systemBlue.withAlphaComponent(0.1),
            content: "Explorer Panel #\(number)\n\nDrag tabs to rearrange.\nDrag to edges to split."
        )
    }
}

// MARK: - Editor Panel

class EditorPanel: BaseExamplePanel {
    init(number: Int) {
        super.init(
            title: "Editor \(number)",
            icon: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Editor"),
            backgroundColor: NSColor.systemGreen.withAlphaComponent(0.1),
            content: "Editor Panel #\(number)\n\nThis is where code would be displayed."
        )
    }
}

// MARK: - Console Panel

class ConsolePanel: BaseExamplePanel {
    init(number: Int) {
        super.init(
            title: "Console",
            icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: "Console"),
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.1),
            content: "Console Panel #\(number)\n\nOutput and logs appear here."
        )
    }
}

// MARK: - Inspector Panel

class InspectorPanel: BaseExamplePanel {
    init(number: Int) {
        super.init(
            title: "Inspector",
            icon: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Inspector"),
            backgroundColor: NSColor.systemPurple.withAlphaComponent(0.1),
            content: "Inspector Panel #\(number)\n\nProperties and details shown here."
        )
    }
}
