# DockKit Architecture

DockKit is a Swift package for building dockable panel interfaces on macOS.
It provides a JSON-based layout system with incremental reconciliation.

## Core Concepts

### JSON as Source of Truth

The entire layout state is represented as a `DockLayout` JSON structure:

```json
{
  "version": 1,
  "windows": [
    {
      "id": "window-uuid",
      "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
      "isFullScreen": false,
      "rootNode": {
        "type": "split",
        "id": "split-uuid",
        "axis": "horizontal",
        "proportions": [0.3, 0.7],
        "children": [
          {
            "type": "tabGroup",
            "id": "group-1-uuid",
            "activeTabIndex": 0,
            "tabs": [
              {
                "id": "tab-uuid",
                "title": "Terminal",
                "iconName": "terminal",
                "cargo": {
                  "type": "terminal",
                  "cwd": "/Users/jack/project"
                }
              }
            ]
          },
          { "type": "tabGroup", "id": "group-2-uuid", "..." }
        ]
      }
    }
  ]
}
```

### Cargo System

Each tab has an optional `cargo` field containing:
- `type`: Panel type identifier (e.g., "terminal", "webkit", "cef")
- Type-specific configuration (e.g., `cwd`, `url`, `devtools`)

**DockKit is cargo-agnostic** - it stores and diffs cargo but doesn't interpret it.
The host application defines panel types and their factories.

### Reconciliation Flow

```
+-------------+     +-------------+     +---------------------+
| Old Layout  |---->|   Diff      |---->| ReconciliationCmds  |
+-------------+     |  Engine     |     +---------------------+
+-------------+     |             |     | - panelsToCreate    |
| New Layout  |---->|             |     | - panelsToRemove    |
+-------------+     +-------------+     | - panelsToUpdate    |
                                        +---------------------+
                                                   |
                          +------------------------+
                          v
+-------------------------------------------------------------+
|                    Host App (Shell)                          |
|  1. Process panelsToCreate -> Factory creates panels         |
|  2. Process panelsToRemove -> Cleanup and deregister         |
|  3. Process panelsToUpdate -> Update in-place or recreate    |
|  4. Call layoutManager.updateLayout() -> View hierarchy sync |
+-------------------------------------------------------------+
```

## API Reference

### DockLayoutManager

The central coordinator for all dock windows and panels.

```swift
let layoutManager = DockLayoutManager()

// Provide panel lookup
layoutManager.panelProvider = { id in panelRegistry[id] }

// Get current layout
let layout = layoutManager.getLayout()

// Compute reconciliation commands
let commands = layoutManager.computeCommands(to: newLayout)

// Apply layout (syncs view hierarchy)
layoutManager.updateLayout(newLayout)
```

### ReconciliationCommands

Extract high-level commands from a layout diff:

```swift
// Get commands for what needs to change
let commands = layoutManager.computeCommands(to: newLayout)

// Or compute directly from two layouts
let commands = DockLayoutDiff.extractCommands(from: oldLayout, to: newLayout)
```

### PanelCreationCommand

```swift
struct PanelCreationCommand {
    let tabId: UUID           // Use as panel ID
    let cargo: [String: AnyCodable]
    let windowId: UUID
    let groupId: UUID
    let title: String
    let iconName: String?

    var panelType: String?    // Convenience: cargo["type"]
}
```

### PanelUpdateCommand

```swift
struct PanelUpdateCommand {
    let tabId: UUID
    let oldCargo: [String: AnyCodable]?
    let newCargo: [String: AnyCodable]?

    var typeChanged: Bool     // True if type field differs
}
```

## ID Linkage Contract

**Critical:** The tab ID in JSON must equal the panel ID at runtime.

```
TabLayoutState.id  ===  DockablePanel.panelId  ===  panelRegistry[key]
```

When creating a panel from `PanelCreationCommand`:
1. Use `cmd.tabId` as the panel's ID
2. Register panel with `cmd.tabId` as the key
3. DockKit's `panelProvider(tabId)` will find it

## Cargo Conventions

Standard cargo fields:

| Field      | Type   | Description                      |
|------------|--------|----------------------------------|
| `type`     | String | **Required.** Panel type identifier |
| `cwd`      | String | Working directory (terminal)     |
| `url`      | String | URL to load (webkit, cef)        |
| `shell`    | String | Shell executable path            |
| `devtools` | Bool   | Enable developer tools           |
| `rootPath` | String | Root path (file browser)         |

Custom fields are allowed - DockKit passes them through unchanged.

## Host App Integration

Typical integration pattern:

```swift
class MainWindowController {
    private var layoutManager: DockLayoutManager!
    private var panels: [UUID: any DockablePanel] = [:]
    private let factoryRegistry = PanelFactoryRegistry()

    func applyLayout(_ newLayout: DockLayout) {
        // 1. Compute what needs to change
        let commands = layoutManager.computeCommands(to: newLayout)

        // 2. Create new panels
        for cmd in commands.panelsToCreate {
            if let panel = factoryRegistry.createPanel(id: cmd.tabId, cargo: cmd.cargo) {
                panels[cmd.tabId] = panel
            }
        }

        // 3. Handle updates
        for cmd in commands.panelsToUpdate {
            if cmd.typeChanged {
                // Recreate panel
            } else if let panel = panels[cmd.tabId], let cargo = cmd.newCargo {
                _ = factoryRegistry.updatePanel(panel, cargo: cargo)
            }
        }

        // 4. Remove old panels
        for tabId in commands.panelsToRemove {
            panels[tabId]?.cleanup()
            panels.removeValue(forKey: tabId)
        }

        // 5. Apply layout (DockKit handles view hierarchy sync)
        layoutManager.updateLayout(newLayout)
    }
}
```

## Remote Operation

The shell can be remotely operated by sending JSON:

```swift
func handleRPCLayoutUpdate(json: String) {
    guard let layout = DockLayout.fromJSON(json) else { return }
    applyLayout(layout)
}
```

This enables:
- **Creating panels**: Add tabs with cargo to JSON
- **Removing panels**: Remove tabs from JSON
- **Rearranging**: Modify split structure in JSON
- **Updating config**: Change cargo values
