# DockKit - Architectural Guide

This document captures key architectural decisions for the DockKit docking framework. It serves as context for AI agents and developers working on this codebase.

## Core Design Philosophy: Reactive Framework

DockKit is a **reactive framework**, not a self-contained widget library. This distinction is fundamental to understanding the architecture.

### What This Means

1. **DockKit manages layout and reconciliation** - It handles the complex work of building, serializing, deserializing, and reconciling dock layouts.

2. **Panels are opaque to DockKit** - The framework only knows panel IDs (`UUID`). The actual panel content could be anything: embedded browsers, game engines, terminals, complex editors, etc.

3. **The host app owns panel instantiation** - Only the host application knows how to create its panel types. DockKit cannot instantiate panels itself.

4. **Delegate callbacks are for policy decisions** - When events occur (detachment, drops, splits), DockKit informs the host app, which decides what to do.

### The Panel Provider Pattern

```swift
public var panelProvider: ((UUID) -> (any DockablePanel)?)?
```

When DockKit loads a serialized layout, it encounters panel IDs without corresponding panel objects. It calls `panelProvider` to request the host app instantiate/provide each panel. This is essential for:

- Loading saved layouts from disk
- Restoring window state after restart
- Reconciling layouts received from external sources

The host app's `panelProvider` implementation might:
- Look up existing panels in a registry
- Create new panels on demand
- Decode panel configuration from the `cargo` field
- Return `nil` for panels that should not be restored

## Delegate Callbacks: Policy Control

### Why `wantsToDetachPanel` Exists

The delegate method:
```swift
func layoutManager(_ manager: DockLayoutManager,
                   wantsToDetachPanel panel: any DockablePanel,
                   at screenPoint: NSPoint)
```

This is **not redundant**, even though the typical implementation just calls `manager.detachPanel()`. It exists for **policy control**:

```swift
// Typical implementation - accept default behavior
func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
    manager.detachPanel(panel, at: screenPoint)
}

// Custom policy - prevent certain panels from detaching
func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
    if panel is LockedPanel {
        return  // Refuse detachment
    }
    manager.detachPanel(panel, at: screenPoint)
}

// Custom policy - use different window type
func layoutManager(_ manager: DockLayoutManager, wantsToDetachPanel panel: any DockablePanel, at screenPoint: NSPoint) {
    let customWindow = createCustomFloatingWindow(for: panel)
    // ... custom handling ...
}
```

The host app is **always in control** of what happens. DockKit proposes, the app disposes.

### Callback Flow Pattern

All window types should converge to the same delegate callback:

```
User gesture detected
  → Window notifies DockLayoutManager
    → Manager removes panel from source window
    → Manager calls delegate.wantsToDetachPanel (policy check)
      → App decides and typically calls manager.detachPanel()
        → Manager creates floating DockWindow
```

This keeps policy in one place regardless of which window type the panel came from.

## Window Types

### DockWindow
A window containing a single dock layout tree (splits + tab groups). Managed by `DockLayoutManager`.

### DockStageHostWindow
A window containing multiple "stages" (virtual workspaces), each with its own layout tree. Features:
- Stage switching with swipe gestures
- Header bar showing stage tabs
- Each stage is independent

**Panel Tearing in Stage Hosts:**
When a panel is torn from a DockStageHostWindow, a **new DockStageHostWindow** is created—not a regular DockWindow. This is intentional:

1. **Uniform window type** — Only one window type to reason about
2. **Swipe works everywhere** — Spawned windows can have stages added, enabling swipe
3. **Symmetric behavior** — Stage hosts spawn stage hosts recursively
4. **No global gesture conflicts** — Unlike Mission Control's three-finger swipe which is system-wide, stage host swipe gestures are captured per-window

The spawned window:
- Starts with one stage containing the torn panel
- Inherits the spawner's `panelProvider`
- Is tracked in spawner's `spawnedWindows` array
- Can spawn its own children via tearing

**Self-Contained Tearing:**
Stage hosts handle tearing internally without requiring DockLayoutManager or delegate callbacks. The panel view is simply reparented to a new window. This keeps the common case simple—tearing "just works" without host app involvement.

**Optional Customization:**
Apps that need to intercept or customize tearing can implement `DockStageHostWindowDelegate.willTearPanel(_:at:)` and return `false` to prevent tearing.

### Nested Stage Hosts (Version 3)

Stage hosts can be nested within other stage hosts using the `.stageHost` layout node type. This enables recursive virtual workspaces - for example, a "Coding" stage containing a nested "Projects" stage host with Project A, B, C workspaces.

**Layout Structure:**
```swift
// A stage containing a nested stage host
Stage(
    title: "Coding",
    layout: .split(SplitLayoutNode(
        axis: .vertical,
        children: [
            .stageHost(StageHostLayoutNode(  // Nested stage host!
                title: "Projects",
                stages: [projectA, projectB, projectC]
            )),
            .tabGroup(terminalGroup)
        ]
    ))
)
```

**Gesture Bubbling:**
When a user swipes to switch stages, gestures are handled by the innermost stage host first. When that container reaches its edge (first or last stage), the gesture "bubbles up" to the parent stage host:

1. User swipes left on nested "Project C" (last project)
2. Nested container detects it's at the right edge
3. Nested container passes event to parent via `SwipeGestureDelegate`
4. Parent container handles the gesture and switches from "Coding" to "Design"

This creates an intuitive experience where inner workspaces are navigated first, then outer workspaces.

**Key Components:**
- `SwipeGestureDelegate` - Protocol for gesture bubbling between containers
- `DockStageHostViewController` - Wraps nested host views with gesture delegation
- `DockSplitViewController.swipeGestureDelegate` - Propagates delegate through split hierarchies

## Panel Lifecycle Callbacks

Panels receive lifecycle notifications:

```swift
public protocol DockablePanel {
    func panelWillDetach()           // About to become floating
    func panelDidDock(at: DockPosition)  // Docked somewhere new
}
```

These let panels adapt their UI (e.g., show/hide certain controls when floating vs docked).

## State Model

### DockLayout (Codable)
The serializable state for regular dock windows:
```swift
struct DockLayout: Codable {
    var windows: [WindowState]
}
```

### StageHostWindowState (Codable)
The serializable state for stage host windows:
```swift
struct StageHostWindowState: Codable {
    var frame: CGRect
    var activeStageIndex: Int
    var stages: [Stage]
}
```

These are separate because stage hosts have fundamentally different structure (multiple layouts vs one).

## Key Implementation Notes

### Reconciliation
The `DockLayoutReconciler` handles incremental updates to the view hierarchy when the layout model changes. It:
- Computes diffs between current and target layouts
- Reuses existing views where possible
- Calls `panelProvider` for new panels
- Notifies panels of lifecycle changes

### Tab Cargo
Each tab can carry arbitrary `Codable` data in its `cargo` field:
```swift
struct TabLayoutState: Codable {
    var id: UUID
    var title: String
    var cargo: AnyCodable?  // App-specific data
}
```

This allows the host app to persist panel-specific configuration alongside the layout.

## Common Pitfalls

1. **Don't bypass the delegate pattern** - Even if it seems like extra work, the callbacks exist for extensibility. Future requirements may need that policy control point.

2. **Don't assume panel availability** - Always handle `panelProvider` returning `nil`. Panels may have been deleted, or the layout may reference stale IDs.

3. **Don't mix window types carelessly** - `DockWindow` and `DockStageHostWindow` have different internal structures. Operations that work on one may not directly apply to the other.

4. **Remember the manager tracks windows** - When windows close, they notify the manager. Don't manually remove from arrays or you'll get double-free issues.
