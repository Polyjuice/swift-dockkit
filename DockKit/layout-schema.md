# DockKit Layout Schema

DockKit uses a JSON object as the single source of truth for all panels and their layouts. Changes to this layout trigger automatic reconciliation—panels are created, updated, or removed to match the new state.

## Reactive Flow

1. Modify layout JSON
2. DockKit computes diff (ReconciliationCommands)
3. Host app's panel factories create/update/remove panels based on cargo
4. UI updates to match the new layout

## Design Principles

- **All windows are equal** — there is no "main" window concept
- **Tab IDs must match panel IDs** — this linkage enables tracking during drag-drop
- **Cargo-agnostic** — DockKit stores and diffs cargo but doesn't interpret it

---

## Type Definitions

The layout tree uses a discriminated union pattern. Nodes are identified by their `type` field.

```typescript
type DockLayoutNode = SplitLayoutNode | TabGroupLayoutNode

interface SplitLayoutNode {
  type: "split"
  id: string
  axis: "horizontal" | "vertical"
  children: DockLayoutNode[]
  proportions: number[]
}

interface TabGroupLayoutNode {
  type: "tabGroup"
  id: string
  tabs: TabLayoutState[]
  activeTabIndex: number
}

interface TabLayoutState {
  id: string        // Must match DockablePanel.panelId
  title: string
  iconName?: string // SF Symbol name
  cargo?: object    // Panel-specific configuration
}
```

---

## Root Structure

The root `DockLayout` object contains a version number and an array of windows.

```json
{
  "version": 1,
  "windows": [...]
}
```

## Window State

Each window has identical capabilities (splits, tabs, drag-drop). The `frame` uses macOS coordinates where origin is the bottom-left corner.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
  "isFullScreen": false,
  "rootNode": { ... }
}
```

## Split Node

A split container divides space between children. The `axis` determines arrangement:
- `"horizontal"` — children arranged left-to-right
- `"vertical"` — children arranged top-to-bottom

The `proportions` array must have the same length as `children` and sum to 1.0.

```json
{
  "type": "split",
  "id": "split-1",
  "axis": "horizontal",
  "proportions": [0.25, 0.75],
  "children": [
    { "type": "tabGroup", ... },
    { "type": "tabGroup", ... }
  ]
}
```

## Tab Group Node

Tab groups are the leaf nodes containing actual panel tabs. The `activeTabIndex` determines which tab is visible.

```json
{
  "type": "tabGroup",
  "id": "group-1",
  "activeTabIndex": 0,
  "tabs": [
    { "id": "tab-1", "title": "Editor", ... },
    { "id": "tab-2", "title": "Terminal", ... }
  ]
}
```

## Tab State

Each tab has an `id` that **must match** the corresponding `DockablePanel.panelId` at runtime. The optional `iconName` is an SF Symbol name; if omitted, the panel's `panelIcon` is used.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440003",
  "title": "Terminal",
  "iconName": "terminal",
  "cargo": {
    "type": "terminal",
    "cwd": "/Users/jack/project"
  }
}
```

---

## Cargo

Cargo is an arbitrary JSON object for panel-specific configuration. DockKit stores and diffs cargo but doesn't interpret it—the host app's panel factory handles that.

Typical cargo includes a `type` field to identify which factory handles the panel, plus type-specific fields:

```json
{ "type": "terminal", "cwd": "/project" }
```

```json
{ "type": "webview", "url": "https://example.com" }
```

```json
{ "type": "editor", "filePath": "/project/main.swift" }
```

**Cargo patterns:**
- **Creation-only fields** — can only be set when creating (e.g., terminal `cwd`)
- **Updatable fields** — can be changed on existing panels (e.g., webview `url`)

---

## Reconciliation

When layout changes, DockKit computes reconciliation commands:

| Command | Description |
|---------|-------------|
| `panelsToCreate` | New tabs needing panels. Host app calls factory with tab ID and cargo. |
| `panelsToRemove` | Removed tabs. Host app should cleanup and deallocate. |
| `panelsToUpdate` | Existing tabs with changed cargo. Host app updates panel state. |
| `structural` | Tree structure changes. DockKit handles internally. |

---

## Example: Empty Layout

The default starting state—a single window with an empty tab group.

```json
{
  "version": 1,
  "windows": [
    {
      "id": "window-1",
      "frame": { "x": 100, "y": 100, "width": 800, "height": 600 },
      "isFullScreen": false,
      "rootNode": {
        "type": "tabGroup",
        "id": "group-1",
        "tabs": [],
        "activeTabIndex": 0
      }
    }
  ]
}
```

## Example: IDE Layout

A typical IDE layout with sidebar, editor area, and bottom terminal panel.

```
┌─────────────────────────────────────┐
│ ┌───────┬─────────────────────────┐ │
│ │       │                         │ │
│ │ Side  │        Editor           │ │
│ │ bar   │                         │ │
│ │       ├─────────────────────────┤ │
│ │       │       Terminal          │ │
│ └───────┴─────────────────────────┘ │
└─────────────────────────────────────┘
```

```json
{
  "version": 1,
  "windows": [
    {
      "id": "window-1",
      "frame": { "x": 100, "y": 100, "width": 1400, "height": 900 },
      "isFullScreen": false,
      "rootNode": {
        "type": "split",
        "id": "root-split",
        "axis": "horizontal",
        "proportions": [0.2, 0.8],
        "children": [
          {
            "type": "tabGroup",
            "id": "sidebar-group",
            "activeTabIndex": 0,
            "tabs": [
              {
                "id": "explorer-tab",
                "title": "Explorer",
                "iconName": "folder",
                "cargo": { "type": "file-browser", "rootPath": "~" }
              }
            ]
          },
          {
            "type": "split",
            "id": "right-split",
            "axis": "vertical",
            "proportions": [0.7, 0.3],
            "children": [
              {
                "type": "tabGroup",
                "id": "editor-group",
                "activeTabIndex": 0,
                "tabs": [
                  {
                    "id": "editor-1",
                    "title": "main.swift",
                    "iconName": "doc.text",
                    "cargo": { "type": "editor", "filePath": "/project/main.swift" }
                  }
                ]
              },
              {
                "type": "tabGroup",
                "id": "terminal-group",
                "activeTabIndex": 0,
                "tabs": [
                  {
                    "id": "terminal-1",
                    "title": "Terminal",
                    "iconName": "terminal",
                    "cargo": { "type": "terminal", "cwd": "/project" }
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  ]
}
```

## Example: Multi-Window

Multiple windows are supported—useful for floating panels or multi-monitor setups.

```json
{
  "version": 1,
  "windows": [
    {
      "id": "main-window",
      "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
      "isFullScreen": false,
      "rootNode": {
        "type": "tabGroup",
        "id": "main-group",
        "activeTabIndex": 0,
        "tabs": [
          {
            "id": "editor-main",
            "title": "Document.md",
            "iconName": "doc.text",
            "cargo": { "type": "editor", "filePath": "/docs/Document.md" }
          }
        ]
      }
    },
    {
      "id": "floating-window",
      "frame": { "x": 800, "y": 200, "width": 600, "height": 400 },
      "isFullScreen": false,
      "rootNode": {
        "type": "tabGroup",
        "id": "floating-group",
        "activeTabIndex": 0,
        "tabs": [
          {
            "id": "preview-tab",
            "title": "Preview",
            "iconName": "eye",
            "cargo": { "type": "preview", "sourceTabId": "editor-main" }
          }
        ]
      }
    }
  ]
}
```

---

## Complete TypeScript Schema

```typescript
type DockLayout = {
  version: number
  windows: WindowState[]
}

type WindowState = {
  id: string
  frame: CGRect
  isFullScreen: boolean
  rootNode: DockLayoutNode
}

type CGRect = {
  x: number
  y: number
  width: number
  height: number
}

type DockLayoutNode = SplitLayoutNode | TabGroupLayoutNode

type SplitLayoutNode = {
  type: "split"
  id: string
  axis: "horizontal" | "vertical"
  children: DockLayoutNode[]
  proportions: number[]
}

type TabGroupLayoutNode = {
  type: "tabGroup"
  id: string
  tabs: TabLayoutState[]
  activeTabIndex: number
}

type TabLayoutState = {
  id: string
  title: string
  iconName?: string
  cargo?: Record<string, unknown>
}
```
