# Desktop Hosts

Desktop hosts provide multiple virtual workspaces within a single window, similar to macOS Mission Control spaces or VS Code's workspaces. Each desktop has its own independent layout tree.

## Overview

```
┌─────────────────────────────────────────┐
│  Desktop Header (selection UI)          │  ← Shows desktop icons/titles
├─────────────────────────────────────────┤
│                                         │
│       Desktop Container                 │  ← Active desktop's layout
│       (swipe to switch)                 │
│                                         │
└─────────────────────────────────────────┘
```

## When to Use Desktop Hosts

**Use desktop hosts when:**
- Users need distinct workspaces (e.g., "Coding", "Design", "Notes")
- You want swipe gesture navigation between layouts
- Layouts are related but shouldn't clutter each other

**Use multi-window instead when:**
- Users need to see multiple layouts simultaneously
- Layouts need independent window frames/positions
- Cross-monitor support is needed

---

## Core Types

### Desktop

A single virtual workspace with its own layout:

```swift
public struct Desktop: Codable, Identifiable {
    public let id: UUID
    public var title: String?       // Shown in header
    public var iconName: String?    // SF Symbol for header
    public var layout: DockLayoutNode
}
```

### DesktopHostWindowState

State for the entire desktop host window:

```swift
public struct DesktopHostWindowState: Codable, Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var isFullScreen: Bool
    public var activeDesktopIndex: Int
    public var desktops: [Desktop]
}
```

---

## Creating a Desktop Host Window

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

### 2. Create Desktop Layouts

```swift
func createCodingDesktop(with panels: [any DockablePanel]) -> Desktop {
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

    return Desktop(
        title: "Coding",
        iconName: "chevron.left.forwardslash.chevron.right",
        layout: .split(mainSplit)
    )
}
```

### 3. Create the Window

```swift
// Build state
let desktopHostState = DesktopHostWindowState(
    frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
    activeDesktopIndex: 0,
    desktops: [codingDesktop, designDesktop, notesDesktop]
)

// Create window
let window = DockDesktopHostWindow(
    desktopHostState: desktopHostState,
    frame: desktopHostState.frame
)

// Provide panel lookup
window.panelProvider = { [weak self] id in
    self?.panelRegistry[id]
}

window.makeKeyAndOrderFront(nil)
```

---

## Desktop Switching

### Programmatic Switching

```swift
// Switch to a specific desktop by index
window.switchToDesktop(at: 1, animated: true)

// Get current active index
let current = window.desktopHostState.activeDesktopIndex
```

### Swipe Gesture Navigation

Swipe gestures are built-in:
- **Two-finger swipe left/right** on trackpad
- Uses Apple-style physics with velocity detection
- Rubber band effect at edges
- 50% drag threshold for slow drags

### Header UI

The header shows clickable buttons for each desktop:
- Icon (SF Symbol) + title
- Active desktop has accent highlight and indicator dot
- Click to switch (animated)

### Delegate Callbacks

```swift
window.desktopDelegate = self

// Implement DockDesktopHostWindowDelegate
func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int) {
    // Called after switch completes
    print("Switched to desktop \(index)")
}
```

---

## Panel Tearing

When you drag a panel outside a desktop host window, a **new desktop host window** is created—not a regular DockWindow. This is a deliberate architectural decision.

### Why Desktop Hosts Spawn Desktop Hosts

```
┌─────────────────────────────────────┐
│  DockDesktopHostWindow (original)   │
│  ┌─────┬─────┬─────┐                │
│  │ D1  │ D2  │ D3  │  ← 3 desktops  │
│  └─────┴─────┴─────┘                │
│  [Panel A] [Panel B] [Panel C]      │
│         ↓ tear Panel B              │
└─────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────┐
│  DockDesktopHostWindow (spawned)    │
│  ┌─────┐                            │
│  │ D1  │  ← starts with 1 desktop   │
│  └─────┘                            │
│  [Panel B]                          │
└─────────────────────────────────────┘
```

**Key benefits:**

1. **Uniform window type** — Your app only has one window type to reason about
2. **Swipe works everywhere** — Once a spawned window has 2+ desktops, swipe navigation works
3. **Symmetric behavior** — Desktop hosts spawn desktop hosts, tearing from the spawned window creates another
4. **Expandable** — Users can add more desktops to any window later

### Comparison with Mission Control

Unlike macOS Mission Control where the three-finger swipe is a global system gesture, desktop host swipe gestures are **captured within each window**. This means:

- Multiple desktop host windows can exist simultaneously
- Each window has independent desktop navigation
- Swiping in one window doesn't affect others
- No conflict with system gestures

### How Tearing Works

1. User drags a tab outside the window bounds
2. The panel is removed from its current desktop
3. A new `DockDesktopHostWindow` is created with:
   - One desktop containing the torn panel
   - Same `panelProvider` as the parent
   - Independent lifecycle
4. The new window appears at the drag location

### Spawned Window Capabilities

The spawned window is fully functional:

- Add more panels via drag-and-drop
- Create splits by dropping on edges
- Add new desktops (if your app exposes this)
- Tear panels to create more windows
- Close to return panels (if drag-back is implemented)

### Tracking Spawned Windows

Desktop host windows automatically track their children:

```swift
// Parent window tracks spawned children
window.spawnedWindows  // [DockDesktopHostWindow]

// Each child knows its spawner
childWindow.spawnerWindow  // DockDesktopHostWindow?
```

When a child window closes, it's automatically removed from the spawner's tracking.

### Customizing Tear Behavior

If you need to intercept or customize tearing:

```swift
window.desktopDelegate = self

func desktopHostWindow(_ window: DockDesktopHostWindow,
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

## Desktop State Management

### Updating State

```swift
// Update the entire state (for reconciliation)
window.updateDesktopHostState(newState)
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
// Get the active desktop's root node
if let rootNode = window.activeDesktopRootNode {
    // Work with the DockNode tree
}

// Get active layout directly
let layout = window.desktopHostState.activeLayout
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

## Layout JSON for Desktops

### Desktop Structure

```json
{
  "id": "desktop-uuid",
  "title": "Coding",
  "iconName": "chevron.left.forwardslash.chevron.right",
  "layout": { ... DockLayoutNode ... }
}
```

### DesktopHostWindowState Structure

```json
{
  "id": "window-uuid",
  "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
  "isFullScreen": false,
  "activeDesktopIndex": 0,
  "desktops": [
    {
      "id": "coding-desktop",
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
      "id": "design-desktop",
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

    private var desktopWindow: DockDesktopHostWindow?
    private var panelRegistry: [UUID: any DockablePanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        createDesktopHostWindow()
    }

    private func createDesktopHostWindow() {
        // Create panels
        let editor = CodeEditorPanel(filename: "main.swift")
        let terminal = TerminalPanel()
        let canvas = CanvasPanel()
        let layers = LayersPanel()

        // Register panels
        [editor, terminal, canvas, layers].forEach {
            panelRegistry[$0.panelId] = $0
        }

        // Create desktops
        let codingDesktop = Desktop(
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

        let designDesktop = Desktop(
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
        let state = DesktopHostWindowState(
            frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
            activeDesktopIndex: 0,
            desktops: [codingDesktop, designDesktop]
        )

        desktopWindow = DockDesktopHostWindow(
            desktopHostState: state,
            frame: state.frame
        )

        desktopWindow?.panelProvider = { [weak self] id in
            self?.panelRegistry[id]
        }

        desktopWindow?.desktopDelegate = self
        desktopWindow?.center()
        desktopWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: DockDesktopHostWindowDelegate {
    func desktopHostWindow(_ window: DockDesktopHostWindow, didSwitchToDesktopAt index: Int) {
        print("Now on desktop \(index)")
    }

    func desktopHostWindow(_ window: DockDesktopHostWindow, didClose: Void) {
        print("Window closed")
    }
}
```

---

## See Also

- [Panel Operations](PANEL_OPERATIONS.md) - Dock, split, and tear operations
- [Layout Schema](../DockKit/layout-schema.md) - JSON structure reference
- [Swipe Physics](SWIPE_PHYSICS.md) - Gesture handling details
