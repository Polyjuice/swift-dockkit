# DockKit

A Swift framework for building VS Code-style dockable panel interfaces in macOS applications.

## Features

- **Tab Groups**: Group multiple panels into tabbed containers
- **Drag & Drop**: Drag tabs between groups and windows
- **Split Views**: Create horizontal and vertical splits by dropping tabs on edges
- **Floating Windows**: Tear off tabs into floating windows
- **Stage Hosts**: Multiple virtual workspaces in a single window with swipe navigation
- **Layout Persistence**: JSON-serializable layout state for save/restore
- **Automatic Reconciliation**: Efficient diffing and reconciliation of layout changes

## Requirements

- macOS 13.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add DockKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/polyjuice/swift-dockkit.git", from: "1.0.0")
]
```

Or add it in Xcode via File > Add Package Dependencies.

## Usage

### 1. Implement DockablePanel

Create panels that conform to `DockablePanel`:

```swift
import DockKit

class MyPanel: NSViewController, DockablePanel {
    let panelId = UUID()
    var panelTitle: String { "My Panel" }
    var panelIcon: NSImage? { NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
    var panelViewController: NSViewController { self }

    func canDock(at position: DockPosition) -> Bool { true }
    func panelWillDetach() { }
    func panelDidDock(at position: DockPosition) { }
}
```

### 2. Create a DockContainerViewController

```swift
let container = DockContainerViewController()
window.contentViewController = container

// Add panels
let panel1 = MyPanel()
let panel2 = MyPanel()
container.addPanel(panel1)
container.addPanel(panel2)
```

### 3. Handle Layout Changes

```swift
// Save layout
let layout = container.currentLayout
let data = try JSONEncoder().encode(layout)

// Restore layout
let layout = try JSONDecoder().decode(DockLayout.self, from: data)
container.applyLayout(layout)
```

## Cargo System

Tabs can include a `cargo` object for panel-specific configuration:

```swift
let tab = TabLayoutState(
    id: UUID(),
    title: "Terminal",
    iconName: "terminal",
    cargo: [
        "type": AnyCodable("terminal"),
        "cwd": AnyCodable("/Users/jack/project")
    ]
)
```

Use `ReconciliationCommands` to process layout changes:

```swift
let commands = layoutManager.computeCommands(to: newLayout)

// Create new panels via factory
for cmd in commands.panelsToCreate {
    let panel = myFactory.create(id: cmd.tabId, cargo: cmd.cargo)
    panelRegistry[cmd.tabId] = panel
}

// Remove old panels
for tabId in commands.panelsToRemove {
    panelRegistry[tabId]?.cleanup()
    panelRegistry.removeValue(forKey: tabId)
}

// Apply layout
layoutManager.updateLayout(newLayout)
```

See [Layout Schema](DockKit/layout-schema.md) for detailed JSON structure.

## Panel Operations

DockKit supports three core panel operations:

**Docking** - Add tabs to existing groups:
```swift
let newLayout = layout.addingTab(tab, toGroupId: targetGroupId)
layoutManager.updateLayout(newLayout)
```

**Splitting** - Create new panes:
```swift
let newLayout = layout.splitting(groupId: groupId, direction: .right, withTab: tab)
layoutManager.updateLayout(newLayout)
```

**Tearing** - Detach into floating windows:
```swift
let newLayout = layout.removingTab(tabId)
// Tab is now in its own floating window
```

See [Panel Operations](docs/PANEL_OPERATIONS.md) for complete documentation.

## Stage Hosts

Stage hosts provide multiple virtual workspaces in a single window with swipe gesture navigation:

```swift
let codingStage = Stage(title: "Coding", iconName: "chevron.left.forwardslash.chevron.right", layout: codingLayout)
let designStage = Stage(title: "Design", iconName: "paintbrush.fill", layout: designLayout)

let state = StageHostWindowState(
    frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
    stages: [codingStage, designStage]
)

let window = DockStageHostWindow(stageHostState: state, frame: state.frame)
window.panelProvider = { id in panelRegistry[id] }
```

Features:
- Swipe left/right to switch stages
- Header UI with stage icons and titles
- Apple-style spring physics and rubber band effect
- Independent layout tree per stage

See [Stage Hosts](docs/DESKTOP_HOSTS.md) for complete documentation.

## Architecture

DockKit uses a declarative layout model with automatic reconciliation:

- **DockLayout**: The complete layout state (windows, splits, tab groups)
- **DockNode**: Recursive tree structure (splits contain children, tab groups contain tabs)
- **DockLayoutManager**: Computes layout mutations (moving tabs, splitting, etc.)
- **DockLayoutReconciler**: Diffs layouts and applies minimal view hierarchy changes

See [ARCHITECTURE.md](ARCHITECTURE.md) for system overview.

## Documentation

- [Panel Operations](docs/PANEL_OPERATIONS.md) - Dock, split, and tear panels
- [Stage Hosts](docs/DESKTOP_HOSTS.md) - Multiple virtual workspaces
- [Layout Schema](DockKit/layout-schema.md) - JSON structure reference
- [Swipe Physics](docs/SWIPE_PHYSICS.md) - Gesture handling details
- [Architecture](ARCHITECTURE.md) - System overview

## License

MIT
