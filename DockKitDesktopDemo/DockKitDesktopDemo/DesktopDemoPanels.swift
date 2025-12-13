import AppKit
import DockKit

// MARK: - Colored Panel View Controller

class ColoredPanelViewController: NSViewController {
    private let panelColor: NSColor
    private let contentText: String

    init(backgroundColor: NSColor, content: String) {
        self.panelColor = backgroundColor
        self.contentText = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = panelColor.cgColor

        let label = NSTextField(wrappingLabelWithString: contentText)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40)
        ])

        self.view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Ensure layer background is applied after layout
        view.layer?.backgroundColor = panelColor.cgColor
    }
}

// MARK: - Base Panel

class BaseDesktopPanel: DockablePanel {
    let panelId = UUID()
    let panelTitle: String
    let panelIcon: NSImage?

    private let _viewController: ColoredPanelViewController

    var panelViewController: NSViewController { _viewController }

    init(title: String, icon: NSImage?, backgroundColor: NSColor, content: String) {
        self.panelTitle = title
        self.panelIcon = icon
        self._viewController = ColoredPanelViewController(backgroundColor: backgroundColor, content: content)
    }
}

// MARK: - Coding Desktop Panels

class CodeEditorPanel: BaseDesktopPanel {
    init(filename: String) {
        super.init(
            title: filename,
            icon: NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Code"),
            backgroundColor: NSColor.systemBlue.withAlphaComponent(0.4),
            content: "📝 Code Editor\n\n\(filename)\n\nEdit your code here.\nDrag tabs to rearrange."
        )
    }
}

class TerminalPanel: BaseDesktopPanel {
    init(name: String) {
        super.init(
            title: name,
            icon: NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Terminal"),
            backgroundColor: NSColor.systemIndigo.withAlphaComponent(0.5),
            content: "💻 Terminal: \(name)\n\n$ echo 'Hello from Desktop Demo!'\nHello from Desktop Demo!\n\n$_"
        )
    }
}

class FileExplorerPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Files",
            icon: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Files"),
            backgroundColor: NSColor.systemCyan.withAlphaComponent(0.4),
            content: "📁 File Explorer\n\n├── src/\n│   ├── main.swift\n│   └── App.swift\n├── tests/\n└── README.md"
        )
    }
}

class GitPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Git",
            icon: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git"),
            backgroundColor: NSColor.systemTeal.withAlphaComponent(0.4),
            content: "🔀 Git Status\n\nOn branch: main\n✓ 3 commits ahead\n• 2 files modified\n+ 1 file staged"
        )
    }
}

// MARK: - Design Desktop Panels

class CanvasPanel: BaseDesktopPanel {
    init(name: String) {
        super.init(
            title: name,
            icon: NSImage(systemSymbolName: "paintbrush.fill", accessibilityDescription: "Canvas"),
            backgroundColor: NSColor.systemPink.withAlphaComponent(0.4),
            content: "🎨 Design Canvas\n\n\(name)\n\nCreate beautiful designs here.\nSwipe left/right to switch desktops!"
        )
    }
}

class LayersPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Layers",
            icon: NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Layers"),
            backgroundColor: NSColor.systemPurple.withAlphaComponent(0.4),
            content: "📚 Layers\n\n▶ Background\n▶ Shape 1\n▶ Text Layer\n▶ Icon Group\n▶ Overlay"
        )
    }
}

class ColorsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Colors",
            icon: NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Colors"),
            backgroundColor: NSColor.systemRed.withAlphaComponent(0.4),
            content: "🎨 Color Palette\n\n🔴 Primary: #FF5733\n🔵 Secondary: #3366FF\n🟢 Accent: #33FF57\n⚪ Background: #FFFFFF"
        )
    }
}

class AssetsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Assets",
            icon: NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Assets"),
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.4),
            content: "🖼️ Assets Library\n\n📷 Photos (24)\n🎬 Videos (8)\n🎵 Audio (12)\n📄 Documents (36)"
        )
    }
}

// MARK: - Notes Desktop Panels

class NotesListPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "All Notes",
            icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes"),
            backgroundColor: NSColor.systemYellow.withAlphaComponent(0.4),
            content: "📝 Notes List\n\n• Meeting Notes (Today)\n• Project Ideas\n• Shopping List\n• Book Recommendations\n• Travel Plans"
        )
    }
}

class NoteEditorPanel: BaseDesktopPanel {
    init(title: String) {
        super.init(
            title: title,
            icon: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit"),
            backgroundColor: NSColor.systemGreen.withAlphaComponent(0.4),
            content: "✏️ \(title)\n\n─────────────────\n\nStart typing your note here...\n\nDesktop Demo showcases:\n• Multiple virtual workspaces\n• Swipe gesture navigation\n• Independent layouts per desktop"
        )
    }
}

class TagsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Tags",
            icon: NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Tags"),
            backgroundColor: NSColor.systemMint.withAlphaComponent(0.4),
            content: "🏷️ Tags\n\n🔴 Work (15)\n🟡 Personal (8)\n🔵 Ideas (12)\n🟢 Projects (6)\n⚪ Archive (42)"
        )
    }
}
