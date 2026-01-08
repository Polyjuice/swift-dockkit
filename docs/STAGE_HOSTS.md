# Stage Hosts

Stage hosts provide multiple virtual workspaces within a single window, similar to macOS Mission Control spaces or VS Code's workspaces. Each stage has its own independent layout tree.

## Overview

```
┌─────────────────────────────────────────┐
│  Stage Header (selection UI)          │  ← Shows stage icons/titles
├─────────────────────────────────────────┤
│                                         │
│       Stage Container                 │  ← Active stage's layout
│       (swipe to switch)                 │
│                                         │
└─────────────────────────────────────────┘
```

## When to Use Stage Hosts

**Use stage hosts when:**
- Users need distinct workspaces (e.g., "Coding", "Design", "Notes")
- You want swipe gesture navigation between layouts
- Layouts are related but shouldn't clutter each other

**Use multi-window instead when:**
- Users need to see multiple layouts simultaneously
- Layouts need independent window frames/positions
- Cross-monitor support is needed

---

## Core Types

### Stage

A single virtual workspace with its own layout:

```swift
public struct Stage: Codable, Identifiable {
    public let id: UUID
    public var title: String?       // Shown in header
    public var iconName: String?    // SF Symbol for header
    public var layout: DockLayoutNode
}
```

### StageHostWindowState

State for the entire stage host window:

```swift
public struct StageHostWindowState: Codable, Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var activeStageIndex: Int
    public var stages: [Stage]
}
```

---

## Creating a Stage Host Window

### 1. Create Panels

```swift
// Create panels for each workspace
let codingPanels = [
    FileExplorerPanel(),
    CodeEditorPanel(filename: "main.swift"),
    TerminalPanel()
]

let designPanels = [
    CanvasPanel(),
    LayersPanel(),
    ColorsPanel()
]

// Register panels
for panel in codingPanels + designPanels {
    panelRegistry[panel.panelId] = panel
}
```

### 2. Create Stage Layouts

```swift
func createCodingStage(with panels: [any DockablePanel]) -> Stage {
    let explorer = panels[0]
    let editor = panels[1]
    let terminal = panels[2]

    let explorerGroup = TabGroupLayoutNode(
        tabs: [TabLayoutState(id: explorer.panelId, title: explorer.panelTitle)]
    )

    let editorGroup = TabGroupLayoutNode(
        tabs: [TabLayoutState(id: editor.panelId, title: editor.panelTitle)]
    )

    let terminalGroup = TabGroupLayoutNode(
        tabs: [TabLayoutState(id: terminal.panelId, title: terminal.panelTitle)]
    )

    // Editor area: editor on top, terminal on bottom
    let editorArea = SplitLayoutNode(
        axis: .vertical,
        children: [.tabGroup(editorGroup), .tabGroup(terminalGroup)],
        proportions: [0.7, 0.3]
    )

    // Main split: explorer | editor area
    let mainSplit = SplitLayoutNode(
        axis: .horizontal,
        children: [.tabGroup(explorerGroup), .split(editorArea)],
        proportions: [0.2, 0.8]
    )

    return Stage(
        title: "Coding",
        iconName: "chevron.left.forwardslash.chevron.right",
        layout: .split(mainSplit)
    )
}
```

### 3. Create the Window

```swift
// Build state
let stageHostState = StageHostWindowState(
    frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
    activeStageIndex: 0,
    stages: [codingStage, designStage, notesStage]
)

// Create window
let window = DockStageHostWindow(
    stageHostState: stageHostState,
    frame: stageHostState.frame
)

// Provide panel lookup
window.panelProvider = { [weak self] id in
    self?.panelRegistry[id]
}

window.makeKeyAndOrderFront(nil)
```

---

## Stage Switching

### Programmatic Switching

```swift
// Switch to a specific stage by index
window.switchToStage(at: 1, animated: true)

// Get current active index
let current = window.stageHostState.activeStageIndex
```

### Swipe Gesture Navigation

Swipe gestures are built-in:
- **Two-finger swipe left/right** on trackpad
- Uses Apple-style physics with velocity detection
- Rubber band effect at edges
- 50% drag threshold for slow drags

### Header UI

The header shows clickable buttons for each stage:
- Icon (SF Symbol) + title
- Active stage has accent highlight and indicator dot
- Click to switch (animated)

### Delegate Callbacks

```swift
window.stageDelegate = self

// Implement DockStageHostWindowDelegate
func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int) {
    // Called after switch completes
    print("Switched to stage \(index)")
}
```

---

## Panel Tearing

When you drag a panel outside a stage host window, a **new stage host window** is created—not a regular DockWindow. This is a deliberate architectural decision.

### Why Stage Hosts Spawn Stage Hosts

```
┌─────────────────────────────────────┐
│  DockStageHostWindow (original)   │
│  ┌─────┬─────┬─────┐                │
│  │ D1  │ D2  │ D3  │  ← 3 stages  │
│  └─────┴─────┴─────┘                │
│  [Panel A] [Panel B] [Panel C]      │
│         ↓ tear Panel B              │
└─────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────┐
│  DockStageHostWindow (spawned)    │
│  ┌─────┐                            │
│  │ D1  │  ← starts with 1 stage   │
│  └─────┘                            │
│  [Panel B]                          │
└─────────────────────────────────────┘
```

**Key benefits:**

1. **Uniform window type** — Your app only has one window type to reason about
2. **Swipe works everywhere** — Once a spawned window has 2+ stages, swipe navigation works
3. **Symmetric behavior** — Stage hosts spawn stage hosts, tearing from the spawned window creates another
4. **Expandable** — Users can add more stages to any window later

### Comparison with Mission Control

Unlike macOS Mission Control where the three-finger swipe is a global system gesture, stage host swipe gestures are **captured within each window**. This means:

- Multiple stage host windows can exist simultaneously
- Each window has independent stage navigation
- Swiping in one window doesn't affect others
- No conflict with system gestures

### How Tearing Works

1. User drags a tab outside the window bounds
2. The panel is removed from its current stage
3. A new `DockStageHostWindow` is created with:
   - One stage containing the torn panel
   - Same `panelProvider` as the parent
   - Independent lifecycle
4. The new window appears at the drag location

### Spawned Window Capabilities

The spawned window is fully functional:

- Add more panels via drag-and-drop
- Create splits by dropping on edges
- Add new stages (if your app exposes this)
- Tear panels to create more windows
- Close to return panels (if drag-back is implemented)

### Tracking Spawned Windows

Stage host windows automatically track their children:

```swift
// Parent window tracks spawned children
window.spawnedWindows  // [DockStageHostWindow]

// Each child knows its spawner
childWindow.spawnerWindow  // DockStageHostWindow?
```

When a child window closes, it's automatically removed from the spawner's tracking.

### Customizing Tear Behavior

If you need to intercept or customize tearing:

```swift
window.stageDelegate = self

func stageHostWindow(_ window: DockStageHostWindow,
                        willTearPanel panel: any DockablePanel,
                        at screenPoint: NSPoint) -> Bool {
    // Return false to prevent tearing
    if panel is LockedPanel {
        return false
    }
    return true
}
```

---

## Stage State Management

### Updating State

```swift
// Update the entire state (for reconciliation)
window.updateStageHostState(newState)
```

### Checking Content

```swift
// Check if a panel exists anywhere
let hasPanel = window.containsPanel(panelId)

// Check if window is empty
let isEmpty = window.isEmpty
```

### Getting Active Layout

```swift
// Get the active stage's root node
if let rootNode = window.activeStageRootNode {
    // Work with the DockNode tree
}

// Get active layout directly
let layout = window.stageHostState.activeLayout
```

---

## Slow Motion Debugging

For debugging swipe gestures:

```swift
// Enable slow motion (10% speed)
window.slowMotionEnabled = true

// Or via menu: Debug > Slow Motion (Cmd+Shift+S)
```

The header also includes a "Slow" toggle switch.

---

## Layout JSON for Stages

### Stage Structure

```json
{
  "id": "stage-uuid",
  "title": "Coding",
  "iconName": "chevron.left.forwardslash.chevron.right",
  "layout": { ... DockLayoutNode ... }
}
```

### StageHostWindowState Structure

```json
{
  "id": "window-uuid",
  "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
  "isFullScreen": false,
  "activeStageIndex": 0,
  "stages": [
    {
      "id": "coding-stage",
      "title": "Coding",
      "iconName": "chevron.left.forwardslash.chevron.right",
      "layout": {
        "type": "split",
        "axis": "horizontal",
        "proportions": [0.2, 0.8],
        "children": [...]
      }
    },
    {
      "id": "design-stage",
      "title": "Design",
      "iconName": "paintbrush.fill",
      "layout": {
        "type": "split",
        ...
      }
    }
  ]
}
```

---

## Complete Example

```swift
import DockKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var stageWindow: DockStageHostWindow?
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        createStageHostWindow()
    }

    private func createStageHostWindow() {
        // Create panels
        let editor = CodeEditorPanel(filename: "main.swift")
        let terminal = TerminalPanel()
        let canvas = CanvasPanel()
        let layers = LayersPanel()

        // Register panels
        [editor, terminal, canvas, layers].forEach {
            panelRegistry[$0.panelId] = $0
        }

        // Create stages
        let codingStage = Stage(
            title: "Coding",
            iconName: "chevron.left.forwardslash.chevron.right",
            layout: .split(SplitLayoutNode(
                axis: .vertical,
                children: [
                    .tabGroup(TabGroupLayoutNode(tabs: [
                        TabLayoutState(id: editor.panelId, title: editor.panelTitle)
                    ])),
                    .tabGroup(TabGroupLayoutNode(tabs: [
                        TabLayoutState(id: terminal.panelId, title: terminal.panelTitle)
                    ]))
                ],
                proportions: [0.7, 0.3]
            ))
        )

        let designStage = Stage(
            title: "Design",
            iconName: "paintbrush.fill",
            layout: .split(SplitLayoutNode(
                axis: .horizontal,
                children: [
                    .tabGroup(TabGroupLayoutNode(tabs: [
                        TabLayoutState(id: layers.panelId, title: layers.panelTitle)
                    ])),
                    .tabGroup(TabGroupLayoutNode(tabs: [
                        TabLayoutState(id: canvas.panelId, title: canvas.panelTitle)
                    ]))
                ],
                proportions: [0.2, 0.8]
            ))
        )

        // Create window
        let state = StageHostWindowState(
            frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
            activeStageIndex: 0,
            stages: [codingStage, designStage]
        )

        stageWindow = DockStageHostWindow(
            stageHostState: state,
            frame: state.frame
        )

        stageWindow?.panelProvider = { [weak self] id in
            self?.panelRegistry[id]
        }

        stageWindow?.stageDelegate = self
        stageWindow?.center()
        stageWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: DockStageHostWindowDelegate {
    func stageHostWindow(_ window: DockStageHostWindow, didSwitchToStageAt index: Int) {
        print("Now on stage \(index)")
    }

    func stageHostWindow(_ window: DockStageHostWindow, didClose: Void) {
        print("Window closed")
    }
}
```

---

## See Also

- [Panel Operations](PANEL_OPERATIONS.md) - Dock, split, and tear operations
- [Layout Schema](../DockKit/layout-schema.md) - JSON structure reference
- [Swipe Physics](SWIPE_PHYSICS.md) - Gesture handling details
