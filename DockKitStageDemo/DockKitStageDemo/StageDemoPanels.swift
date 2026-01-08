import AppKit
import DockKit

// MARK: - Console Panel (Live Debug Output)

class ConsolePanelViewController: NSViewController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var observer: NSObjectProtocol?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        // Create scroll view with text view
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container

        // Load existing entries
        loadExistingEntries()

        // Observe new log entries
        observer = NotificationCenter.default.addObserver(
            forName: .consoleLogAdded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let entry = notification.userInfo?["entry"] as? ConsoleLogEntry {
                self?.appendEntry(entry)
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func loadExistingEntries() {
        Task { @MainActor in
            for entry in Console.shared.entries {
                appendEntry(entry)
            }
        }
    }

    private func appendEntry(_ entry: ConsoleLogEntry) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeStr = formatter.string(from: entry.timestamp)

        let levelIcon: String
        let levelColor: NSColor
        switch entry.level {
        case .log:
            levelIcon = "●"
            levelColor = .systemGreen
        case .warn:
            levelIcon = "▲"
            levelColor = .systemYellow
        case .error:
            levelIcon = "✖"
            levelColor = .systemRed
        }

        let sourceStr = entry.source.map { "[\($0)] " } ?? ""

        let attributedString = NSMutableAttributedString()

        // Timestamp
        attributedString.append(NSAttributedString(
            string: "\(timeStr) ",
            attributes: [.foregroundColor: NSColor.gray, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]
        ))

        // Level icon
        attributedString.append(NSAttributedString(
            string: "\(levelIcon) ",
            attributes: [.foregroundColor: levelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)]
        ))

        // Source
        if !sourceStr.isEmpty {
            attributedString.append(NSAttributedString(
                string: sourceStr,
                attributes: [.foregroundColor: NSColor.systemCyan, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]
            ))
        }

        // Message
        attributedString.append(NSAttributedString(
            string: "\(entry.message)\n",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
        ))

        textView.textStorage?.append(attributedString)

        // Scroll to bottom
        textView.scrollToEndOfDocument(nil)
    }
}

class DebugConsolePanel: DockablePanel {
    let panelId = UUID()
    let panelTitle = "Console"
    let panelIcon: NSImage? = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Console")

    private lazy var _viewController = ConsolePanelViewController()
    var panelViewController: NSViewController { _viewController }
}

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
        label.isSelectable = false  // Prevents caret cursor on hover
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

class BaseStagePanel: DockablePanel {
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

// MARK: - Coding Stage Panels

class CodeEditorPanel: BaseStagePanel {
    init(filename: String) {
        super.init(
            title: filename,
            icon: NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Code"),
            backgroundColor: NSColor.systemBlue.withAlphaComponent(0.4),
            content: "📝 Code Editor\n\n\(filename)\n\nEdit your code here.\nDrag tabs to rearrange."
        )
    }
}

class TerminalPanel: BaseStagePanel {
    init(name: String) {
        super.init(
            title: name,
            icon: NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Terminal"),
            backgroundColor: NSColor.systemIndigo.withAlphaComponent(0.5),
            content: "💻 Terminal: \(name)\n\n$ echo 'Hello from Stage Demo!'\nHello from Stage Demo!\n\n$_"
        )
    }
}

class FileExplorerPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Files",
            icon: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Files"),
            backgroundColor: NSColor.systemCyan.withAlphaComponent(0.4),
            content: "📁 File Explorer\n\n├── src/\n│   ├── main.swift\n│   └── App.swift\n├── tests/\n└── README.md"
        )
    }
}

class GitPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Git",
            icon: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git"),
            backgroundColor: NSColor.systemTeal.withAlphaComponent(0.4),
            content: "🔀 Git Status\n\nOn branch: main\n✓ 3 commits ahead\n• 2 files modified\n+ 1 file staged"
        )
    }
}

// MARK: - Design Stage Panels

class CanvasPanel: BaseStagePanel {
    init(name: String) {
        super.init(
            title: name,
            icon: NSImage(systemSymbolName: "paintbrush.fill", accessibilityDescription: "Canvas"),
            backgroundColor: NSColor.systemPink.withAlphaComponent(0.4),
            content: "🎨 Design Canvas\n\n\(name)\n\nCreate beautiful designs here.\nSwipe left/right to switch stages!"
        )
    }
}

class LayersPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Layers",
            icon: NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Layers"),
            backgroundColor: NSColor.systemPurple.withAlphaComponent(0.4),
            content: "📚 Layers\n\n▶ Background\n▶ Shape 1\n▶ Text Layer\n▶ Icon Group\n▶ Overlay"
        )
    }
}

class ColorsPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Colors",
            icon: NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Colors"),
            backgroundColor: NSColor.systemRed.withAlphaComponent(0.4),
            content: "🎨 Color Palette\n\n🔴 Primary: #FF5733\n🔵 Secondary: #3366FF\n🟢 Accent: #33FF57\n⚪ Background: #FFFFFF"
        )
    }
}

class AssetsPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Assets",
            icon: NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Assets"),
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.4),
            content: "🖼️ Assets Library\n\n📷 Photos (24)\n🎬 Videos (8)\n🎵 Audio (12)\n📄 Documents (36)"
        )
    }
}

// MARK: - Notes Stage Panels

class NotesListPanel: BaseStagePanel {
    init() {
        super.init(
            title: "All Notes",
            icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes"),
            backgroundColor: NSColor.systemYellow.withAlphaComponent(0.4),
            content: "📝 Notes List\n\n• Meeting Notes (Today)\n• Project Ideas\n• Shopping List\n• Book Recommendations\n• Travel Plans"
        )
    }
}

class NoteEditorPanel: BaseStagePanel {
    init(title: String) {
        super.init(
            title: title,
            icon: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit"),
            backgroundColor: NSColor.systemGreen.withAlphaComponent(0.4),
            content: "✏️ \(title)\n\n─────────────────\n\nStart typing your note here...\n\nStage Demo showcases:\n• Multiple virtual workspaces\n• Swipe gesture navigation\n• Independent layouts per stage"
        )
    }
}

class TagsPanel: BaseStagePanel {
    init() {
        super.init(
            title: "Tags",
            icon: NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Tags"),
            backgroundColor: NSColor.systemMint.withAlphaComponent(0.4),
            content: "🏷️ Tags\n\n🔴 Work (15)\n🟡 Personal (8)\n🔵 Ideas (12)\n🟢 Projects (6)\n⚪ Archive (42)"
        )
    }
}
