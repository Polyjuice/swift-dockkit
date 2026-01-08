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
type DockLayoutNode = SplitLayoutNode | TabGroupLayoutNode | StageHostLayoutNode

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

interface StageHostLayoutNode {
  type: "stageHost"
  id: string
  title?: string
  iconName?: string
  activeStageIndex: number
  stages: Stage[]
  displayMode?: "tabs" | "thumbnails"
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

## Nested Stage Host Node (Version 3)

Stage hosts can be nested within layouts using the `stageHost` type. This enables recursive virtual workspaces - for example, a "Coding" stage containing a nested "Projects" stage host with Project A, B, C workspaces.

```json
{
  "type": "stageHost",
  "id": "nested-projects",
  "title": "Projects",
  "iconName": "folder.fill.badge.gearshape",
  "activeStageIndex": 0,
  "displayMode": "thumbnails",
  "stages": [
    { "id": "project-a", "title": "Project A", "layout": { ... } },
    { "id": "project-b", "title": "Project B", "layout": { ... } },
    { "id": "project-c", "title": "Project C", "layout": { ... } }
  ]
}
```

**Gesture Bubbling:**
When a user swipes to switch stages, gestures are handled by the innermost stage host first. When that container reaches its edge (first or last stage), the gesture automatically "bubbles up" to the parent stage host. This creates an intuitive experience where inner workspaces are navigated first, then outer workspaces.

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

type DockLayoutNode = SplitLayoutNode | TabGroupLayoutNode | StageHostLayoutNode

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

type StageHostLayoutNode = {
  type: "stageHost"
  id: string
  title?: string
  iconName?: string
  activeStageIndex: number
  stages: Stage[]
  displayMode?: "tabs" | "thumbnails"
}

type TabLayoutState = {
  id: string
  title: string
  iconName?: string
  cargo?: Record<string, unknown>
}
```

---

## Stage Host Layouts

Stage hosts provide multiple virtual workspaces within a single window. See [Stage Hosts](../docs/DESKTOP_HOSTS.md) for usage details.

**Nesting (Version 3):** Stage hosts can be nested within layouts using the `stageHost` node type. When nested, gesture bubbling ensures the innermost stage host handles swipes first, then passes gestures up the hierarchy when at the edge.

### Stage

A single virtual workspace with its own layout tree:

```typescript
type Stage = {
  id: string
  title?: string      // Display name in header
  iconName?: string   // SF Symbol name for header
  layout: DockLayoutNode
}
```

### StageHostWindowState

State for a window containing multiple stages:

```typescript
type StageHostWindowState = {
  id: string
  frame: CGRect
  isFullScreen: boolean
  activeStageIndex: number
  stages: Stage[]
}
```

### Example: Multi-Stage Layout

```json
{
  "id": "stage-host-window",
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
        "id": "coding-root",
        "axis": "horizontal",
        "proportions": [0.2, 0.8],
        "children": [
          {
            "type": "tabGroup",
            "id": "explorer-group",
            "activeTabIndex": 0,
            "tabs": [
              { "id": "explorer-tab", "title": "Explorer", "iconName": "folder" }
            ]
          },
          {
            "type": "split",
            "id": "editor-area",
            "axis": "vertical",
            "proportions": [0.7, 0.3],
            "children": [
              {
                "type": "tabGroup",
                "id": "editor-group",
                "activeTabIndex": 0,
                "tabs": [
                  { "id": "editor-tab", "title": "main.swift", "iconName": "doc.text" }
                ]
              },
              {
                "type": "tabGroup",
                "id": "terminal-group",
                "activeTabIndex": 0,
                "tabs": [
                  { "id": "terminal-tab", "title": "Terminal", "iconName": "terminal" }
                ]
              }
            ]
          }
        ]
      }
    },
    {
      "id": "design-stage",
      "title": "Design",
      "iconName": "paintbrush.fill",
      "layout": {
        "type": "split",
        "id": "design-root",
        "axis": "horizontal",
        "proportions": [0.15, 0.85],
        "children": [
          {
            "type": "tabGroup",
            "id": "layers-group",
            "activeTabIndex": 0,
            "tabs": [
              { "id": "layers-tab", "title": "Layers", "iconName": "square.3.layers.3d" }
            ]
          },
          {
            "type": "tabGroup",
            "id": "canvas-group",
            "activeTabIndex": 0,
            "tabs": [
              { "id": "canvas-tab", "title": "Canvas", "iconName": "paintbrush" }
            ]
          }
        ]
      }
    }
  ]
}
```

### Complete TypeScript Schema (with Stages)

```typescript
// Stage Host types
type Stage = {
  id: string
  title?: string
  iconName?: string
  layout: DockLayoutNode
}

type StageHostWindowState = {
  id: string
  frame: CGRect
  isFullScreen: boolean
  activeStageIndex: number
  stages: Stage[]
}

// Nested Stage Host (Version 3)
// Can be used as a DockLayoutNode within splits/stages
type StageHostLayoutNode = {
  type: "stageHost"
  id: string
  title?: string
  iconName?: string
  activeStageIndex: number
  stages: Stage[]
  displayMode?: "tabs" | "thumbnails"
}
```
