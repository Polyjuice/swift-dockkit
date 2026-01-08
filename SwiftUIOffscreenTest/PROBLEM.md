# SwiftUI Off-Screen Text Rendering Problem

## Issue Summary

SwiftUI Text views don't render when their containing NSView is positioned outside the visible window area. This affects stage switching animations where adjacent stages appear blank until they become active.

## Observations

1. **GPU content renders fine**: Icons, Metal textures, game content all render regardless of position
2. **Only SwiftUI Text is affected**: Other SwiftUI views may render, but Text specifically doesn't
3. **Bitmap capture works**: `bitmapImageRepForCachingDisplay` + `cacheDisplay` forces software rendering and captures text
4. **Color mismatch with bitmaps**: Snapshots don't match live view colors due to display color management (True Tone, Night Shift, profiles)

## Hypothesis

SwiftUI checks `NSView.visibleRect` or frame intersection with window bounds. When a view's frame is outside the visible area, SwiftUI skips expensive text rendering as an optimization.

## Test Configurations

| Config | Description | Expected Result |
|--------|-------------|-----------------|
| 1. baseline_visible | Panel at (0,0), visible | Text renders |
| 2. baseline_offscreen | Panel at (600,0), outside 600px window | Text missing |
| 3. overlapping_all | All panels at (0,0), overlapping | All text renders? |
| 4. overlapping_with_mask | All at (0,0), layer masks for slots | All text renders? |
| 5. parent_transform | All at (0,0), parent sublayerTransform | All text renders? |
| 6. prepared_content_rect | Override preparedContentRect | Text renders? |
| 7. no_clipping | clipsToBounds=false everywhere | Text renders? |

## Potential Solutions

### Solution A: Overlapping Frames with Masks
- Keep all panel frames at (0,0) so SwiftUI thinks they're on-screen
- Use CAShapeLayer masks to clip each panel to its visual slot
- Animate mask positions for smooth transitions

### Solution B: Parent Transform Only
- Keep all panels at (0,0)
- Use parent view's `sublayerTransform` to position panels
- SwiftUI might not check parent transforms

### Solution C: Override preparedContentRect
- Tell the system all content should be prepared
- Might not affect SwiftUI's internal optimization

### Solution D: Different Architecture
- Use opacity/isHidden instead of position for inactive panels
- Might have performance implications

## Running the Tests

```bash
cd /Users/jack/evryzin/swift-dockkit/SwiftUIOffscreenTest
swift run
```

Results are saved to:
- `screenshots/config_N.png` - Screenshot for each configuration
- `results.txt` - Test log with configuration details
