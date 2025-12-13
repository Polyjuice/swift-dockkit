# Panel Operations

This guide covers the three core panel operations in DockKit: **docking** (adding tabs), **splitting** (creating new panes), and **tearing** (detaching panels).

## Overview

DockKit uses an immutable layout pattern. All operations return new `DockLayout` instances rather than mutating in place:

```swift
let newLayout = layout.addingTab(tab, toGroupId: groupId)
layoutManager.updateLayout(newLayout)
```

---

## Docking Panels

Docking adds a tab to an existing tab group.

### Adding a Tab Programmatically

```swift
// Create the tab state
let tab = TabLayoutState(
    id: panel.panelId,
    title: panel.panelTitle,
    iconName: "doc.text",
    cargo: ["type": AnyCodable("editor"), "path": AnyCodable("/file.swift")]
)

// Add to an existing group
let newLayout = layout.addingTab(tab, toGroupId: targetGroupId, at: 0)
layoutManager.updateLayout(newLayout)
```

**Parameters:**
- `tab`: The `TabLayoutState` to add
- `toGroupId`: UUID of the target `TabGroupLayoutNode`
- `at`: Optional insertion index (defaults to end)

### Via DockLayoutManager

```swift
layoutManager.addPanel(panel, to: tabGroupViewController)
```

### DockablePanel Callback

When a panel is docked, implement the protocol callback:

```swift
func panelDidDock(at position: DockPosition) {
    // Called after docking completes
    // Use to restore focus, start processes, etc.
}
```

### Moving Tabs Between Groups

```swift
let newLayout = layout.movingTab(tabId, toGroupId: targetGroupId, at: insertIndex)
```

This handles:
1. Removing the tab from its source group
2. Adding it to the target group
3. Cleaning up empty groups automatically

---

## Splitting Panels

Splitting creates a new split container, dividing space between the original content and the dropped tab.

### Split Directions

```swift
enum DockSplitDirection {
    case left    // New panel on left
    case right   // New panel on right
    case top     // New panel on top
    case bottom  // New panel on bottom
}
```

### Creating a Split Programmatically

```swift
let tab = TabLayoutState(id: panel.panelId, title: panel.panelTitle)

// Split the target group, placing the new tab on the right
let newLayout = layout.splitting(
    groupId: existingGroupId,
    direction: .right,
    withTab: tab
)
layoutManager.updateLayout(newLayout)
```

**What happens:**
1. The existing tab group becomes one child of a new split
2. A new tab group containing the dropped tab becomes the other child
3. Proportions default to 50/50

### Split Result Structure

Before:
```
┌─────────────────┐
│   Tab Group A   │
│  [Tab1] [Tab2]  │
└─────────────────┘
```

After splitting with `direction: .right`:
```
┌─────────┬───────┐
│ Group A │ New   │
│  [T1,T2]│ [Tab] │
└─────────┴───────┘
```

The resulting layout node:
```json
{
  "type": "split",
  "axis": "horizontal",
  "proportions": [0.5, 0.5],
  "children": [
    { "type": "tabGroup", "tabs": [...original tabs...] },
    { "type": "tabGroup", "tabs": [{ "id": "new-tab", ... }] }
  ]
}
```

### Axis Mapping

| Direction | Axis | New Panel Position |
|-----------|------|-------------------|
| `.left` | horizontal | First child |
| `.right` | horizontal | Second child |
| `.top` | vertical | First child |
| `.bottom` | vertical | Second child |

### Adjusting Split Proportions

```swift
let newLayout = layout.updatingSplitProportions(splitId, proportions: [0.3, 0.7])
```

Proportions must:
- Have the same count as children
- Sum to 1.0

---

## Tearing (Detaching) Panels

Tearing removes a tab from its current location and creates a floating window.

### DockablePanel Callback

```swift
func panelWillDetach() {
    // Called before detachment
    // Use to save state, pause processes, etc.
}
```

### Drag-to-Tear Workflow

DockKit handles drag-to-tear automatically:

1. User starts dragging a tab
2. Tab is moved outside any valid drop zone
3. `panelWillDetach()` is called
4. New floating window is created with the tab
5. Original group is cleaned up (removed if empty)

### Creating a Floating Window Programmatically

```swift
// Create a new window with the panel
let windowState = WindowState.simple(
    frame: CGRect(x: 200, y: 200, width: 600, height: 400),
    tabs: [TabLayoutState(id: panel.panelId, title: panel.panelTitle)],
    activeTabIndex: 0
)

let newLayout = layout.addingWindow(windowState)
layoutManager.updateLayout(newLayout)
```

### Removing a Tab (Tear Without New Window)

```swift
let newLayout = layout.removingTab(tabId)
```

This:
1. Removes the tab from its group
2. Cleans up empty groups
3. Removes empty windows automatically

### Re-Docking a Torn Panel

A floating panel can be re-docked by:
1. Dragging its tab to a drop zone in another window
2. Programmatically moving the tab:

```swift
let newLayout = layout.movingTab(tabId, toGroupId: targetGroupId, at: index)
```

---

## Layout Cleanup

DockKit automatically handles cleanup after operations:

- **Empty tab groups** are removed from splits
- **Splits with one child** collapse to that child
- **Empty windows** are closed

The `cleanedUp()` method handles this recursively:

```swift
// Usually called automatically, but can be invoked manually
let cleanedLayout = layout.windows[0].rootNode.cleanedUp()
```

---

## Query Helpers

Find tabs and groups in the layout:

```swift
// Find a tab by ID
if let info = layout.findTab(tabId) {
    print("Tab \(info.tab.title) is in group \(info.groupId)")
}

// Find a tab group
if let groupInfo = layout.findTabGroup(groupId) {
    print("Group has \(groupInfo.group.tabs.count) tabs")
}

// Get all tab IDs
let allTabs = layout.getAllTabIds()

// Get all group IDs
let allGroups = layout.getAllTabGroupIds()
```

---

## Example: Building an IDE Layout

```swift
// Create panels
let explorer = ExplorerPanel()
let editor = EditorPanel()
let terminal = TerminalPanel()

// Build the layout tree
let editorGroup = TabGroupLayoutNode(tabs: [
    TabLayoutState(id: editor.panelId, title: "main.swift")
])

let terminalGroup = TabGroupLayoutNode(tabs: [
    TabLayoutState(id: terminal.panelId, title: "Terminal")
])

let explorerGroup = TabGroupLayoutNode(tabs: [
    TabLayoutState(id: explorer.panelId, title: "Explorer")
])

// Editor area: editor on top, terminal on bottom
let editorArea = SplitLayoutNode(
    axis: .vertical,
    children: [.tabGroup(editorGroup), .tabGroup(terminalGroup)],
    proportions: [0.7, 0.3]
)

// Main split: explorer on left, editor area on right
let rootSplit = SplitLayoutNode(
    axis: .horizontal,
    children: [.tabGroup(explorerGroup), .split(editorArea)],
    proportions: [0.2, 0.8]
)

let window = WindowState(
    id: UUID(),
    frame: CGRect(x: 100, y: 100, width: 1200, height: 800),
    isFullScreen: false,
    rootNode: .split(rootSplit)
)

let layout = DockLayout(version: 1, windows: [window])
layoutManager.updateLayout(layout)
```

---

## See Also

- [Layout Schema](../DockKit/layout-schema.md) - JSON structure reference
- [Desktop Hosts](DESKTOP_HOSTS.md) - Multiple virtual desktops
- [ARCHITECTURE.md](../ARCHITECTURE.md) - System overview
