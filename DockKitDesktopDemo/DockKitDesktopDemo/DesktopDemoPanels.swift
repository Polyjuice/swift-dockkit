import AppKit
import DockKit

// MARK: - Base Panel

class BaseDesktopPanel: DockablePanel {
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

        let label = NSTextField(wrappingLabelWithString: content)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])

        self.contentView = view
    }
}

// MARK: - Coding Desktop Panels

class CodeEditorPanel: BaseDesktopPanel {
    init(filename: String) {
        super.init(
            title: filename,
            icon: NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Code"),
            backgroundColor: NSColor.systemIndigo.withAlphaComponent(0.1),
            content: "📝 Code Editor\n\n\(filename)\n\nEdit your code here.\nDrag tabs to rearrange."
        )
    }
}

class TerminalPanel: BaseDesktopPanel {
    init(name: String) {
        super.init(
            title: name,
            icon: NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Terminal"),
            backgroundColor: NSColor.black.withAlphaComponent(0.8),
            content: "💻 Terminal: \(name)\n\n$ echo 'Hello from Desktop Demo!'\nHello from Desktop Demo!\n\n$_"
        )
    }
}

class FileExplorerPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Files",
            icon: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Files"),
            backgroundColor: NSColor.systemBlue.withAlphaComponent(0.1),
            content: "📁 File Explorer\n\n├── src/\n│   ├── main.swift\n│   └── App.swift\n├── tests/\n└── README.md"
        )
    }
}

class GitPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Git",
            icon: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git"),
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.1),
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
            backgroundColor: NSColor.systemPink.withAlphaComponent(0.1),
            content: "🎨 Design Canvas\n\n\(name)\n\nCreate beautiful designs here.\nSwipe left/right to switch desktops!"
        )
    }
}

class LayersPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Layers",
            icon: NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Layers"),
            backgroundColor: NSColor.systemPurple.withAlphaComponent(0.1),
            content: "📚 Layers\n\n▶ Background\n▶ Shape 1\n▶ Text Layer\n▶ Icon Group\n▶ Overlay"
        )
    }
}

class ColorsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Colors",
            icon: NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Colors"),
            backgroundColor: NSColor.systemYellow.withAlphaComponent(0.15),
            content: "🎨 Color Palette\n\n🔴 Primary: #FF5733\n🔵 Secondary: #3366FF\n🟢 Accent: #33FF57\n⚪ Background: #FFFFFF"
        )
    }
}

class AssetsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Assets",
            icon: NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Assets"),
            backgroundColor: NSColor.systemTeal.withAlphaComponent(0.1),
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
            backgroundColor: NSColor.systemYellow.withAlphaComponent(0.1),
            content: "📝 Notes List\n\n• Meeting Notes (Today)\n• Project Ideas\n• Shopping List\n• Book Recommendations\n• Travel Plans"
        )
    }
}

class NoteEditorPanel: BaseDesktopPanel {
    init(title: String) {
        super.init(
            title: title,
            icon: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit"),
            backgroundColor: NSColor.white.withAlphaComponent(0.9),
            content: "✏️ \(title)\n\n─────────────────\n\nStart typing your note here...\n\nDesktop Demo showcases:\n• Multiple virtual workspaces\n• Swipe gesture navigation\n• Independent layouts per desktop"
        )
    }
}

class TagsPanel: BaseDesktopPanel {
    init() {
        super.init(
            title: "Tags",
            icon: NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Tags"),
            backgroundColor: NSColor.systemGreen.withAlphaComponent(0.1),
            content: "🏷️ Tags\n\n🔴 Work (15)\n🟡 Personal (8)\n🔵 Ideas (12)\n🟢 Projects (6)\n⚪ Archive (42)"
        )
    }
}
