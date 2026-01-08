# Swipe Gesture Physics: Inertia-Based Stage Switching

## The Problem

Our current implementation uses a **position-based threshold** to determine when to switch stages:
- The stage switches when the user drags past 15% of the screen width
- This ignores the **velocity** of the gesture
- A fast flick and a slow drag are treated identically

macOS uses an **inertia-based** (momentum) system:
- A small, fast gesture can "throw" the stage beyond the threshold
- The physics simulation predicts where the content will land based on velocity
- This feels more natural and responsive

## How macOS Handles Scroll/Swipe Events

### Two-Phase Event Lifecycle

When a user performs a swipe gesture on a trackpad, macOS delivers events in two phases:

**Phase 1: Physical Gesture** (`event.phase`)
```
NSEventPhaseBegan    → User's fingers touch trackpad
NSEventPhaseChanged  → User is dragging (repeated)
NSEventPhaseEnded    → User lifts fingers
```

**Phase 2: Momentum** (`event.momentumPhase`)
```
NSEventPhaseBegan    → System starts momentum scrolling
NSEventPhaseChanged  → Momentum continues (repeated, velocity decreasing)
NSEventPhaseEnded    → Momentum stops
```

The momentum phase is **system-generated** based on the velocity at the moment the user lifts their fingers.

### Key Properties

| Property | Description |
|----------|-------------|
| `scrollingDeltaX` | Horizontal scroll delta in points |
| `scrollingDeltaY` | Vertical scroll delta in points |
| `phase` | Current phase of physical gesture |
| `momentumPhase` | Current phase of momentum scrolling |
| `hasPreciseScrollingDeltas` | Whether deltas are in points (trackpad) vs ticks (mouse) |

## The Physics Model

### Current Implementation (Position-Based)

```
if abs(offset / screenWidth) > 0.15:
    switch to new stage
else:
    bounce back
```

**Problems:**
- Ignores gesture velocity
- Requires dragging a fixed distance regardless of speed
- Doesn't match user expectations from iOS/macOS

### Desired Implementation (Inertia-Based)

The decision should be based on **where the content would land** if released:

```
predicted_position = current_position + velocity * decay_time

if predicted_position crosses threshold:
    switch to new stage
else:
    bounce back
```

### Spring Physics with Momentum

When the user releases:

1. **Calculate final position** using momentum decay:
   ```
   final_position = position + velocity / friction
   ```

2. **Determine target stage** based on final position:
   - If `final_position` crosses the threshold → animate to new stage
   - Otherwise → spring back to current stage

3. **Animate with spring physics**:
   ```
   acceleration = -stiffness * displacement - damping * velocity
   velocity += acceleration * dt
   position += velocity * dt
   ```

## Apple's Built-in API

macOS provides `trackSwipeEventWithOptions:dampenAmountThresholdMin:max:usingHandler:` which:
- Tracks swipe gestures beyond the physical gesture
- Provides pre-calculated elasticity values
- Mimics the behavior of built-in scroll views

However, this API is designed for navigation gestures (back/forward) rather than continuous panning, so we need to implement our own physics.

## Implementation Strategy

### Option 1: Use Momentum Events

Let the system provide momentum via `momentumPhase`:

```swift
override func scrollWheel(with event: NSEvent) {
    if event.phase == .began {
        // User started gesture
        isUserDragging = true
    }

    if event.phase == .ended {
        // User lifted fingers, momentum may follow
        isUserDragging = false
    }

    if event.phase != .none || event.momentumPhase != .none {
        // Apply delta (from user or momentum)
        offset += event.scrollingDeltaX
    }

    if event.momentumPhase == .ended ||
       (event.phase == .ended && event.momentumPhase == .none) {
        // Gesture fully complete, determine final target
        finalizeStageSwitch()
    }
}
```

**Pros:** Uses system momentum physics, feels native
**Cons:** Less control, momentum events may not match our UI needs

### Option 2: Calculate Velocity and Predict

Track velocity ourselves and predict landing position:

```swift
private var lastEventTime: TimeInterval = 0
private var velocity: CGFloat = 0

override func scrollWheel(with event: NSEvent) {
    let now = event.timestamp
    let dt = now - lastEventTime

    if dt > 0 && dt < 0.1 {
        // Calculate instantaneous velocity
        velocity = event.scrollingDeltaX / CGFloat(dt)
    }

    lastEventTime = now
    offset += event.scrollingDeltaX

    if event.phase == .ended {
        // Predict where momentum would take us
        let friction: CGFloat = 0.95
        let predictedFinalOffset = offset + velocity * friction / (1 - friction)

        // Use predicted position to determine target
        targetStage = calculateTarget(from: predictedFinalOffset)
        animateToStage(targetStage)
    }
}
```

**Pros:** Full control, can tune feel precisely
**Cons:** May not match system behavior exactly

### Option 3: Hybrid Approach (Recommended)

1. During physical gesture (`phase != .none`): Track position and velocity
2. When user lifts fingers (`phase == .ended`): Predict final position
3. If momentum events follow (`momentumPhase != .none`): Let system drive
4. When momentum ends: Finalize the switch

This gives us the best of both worlds - predictive switching with system momentum feel.

## References

- [Apple: Handling Trackpad Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
- [Apple: NSEvent.momentumPhase](https://developer.apple.com/documentation/appkit/nsevent/1525439-momentumphase)
- [Apple: trackSwipeEventWithOptions](https://developer.apple.com/documentation/appkit/nsevent/1533300-trackswipeeventwithoptions)
- [David Rector: Detecting Trackpad vs Magic Mouse](https://blog.rectorsquid.com/detecting-trackpad-scroll-vs-magic-mouse-scroll/)
- [Cocoa-dev Mailing List: Phase to MomentumPhase Transition](https://www.mail-archive.com/cocoa-dev@lists.apple.com/msg78497.html)
