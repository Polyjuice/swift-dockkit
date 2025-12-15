# SwiftUI Off-Screen Text Rendering Solution

## Problem

SwiftUI doesn't render `Text` views when their containing `NSView` has a frame positioned outside the visible window area. This breaks sliding animations where adjacent panels need to show content while sliding into view.

## Root Cause

SwiftUI uses the **frame position** (not layer transforms) to determine if a view is "on-screen" and should render text. This is standard behavior across UI frameworks:

| Framework | Layout Decision | Visual Transform |
|-----------|----------------|------------------|
| SwiftUI/AppKit | `frame` | `layer.transform` |
| CSS/Browser | `left/top` | `transform: translate()` |
| WPF | Layout position | `RenderTransform` |

## Solution

**Keep frames at origin, use layer transforms for visual positioning.**

```swift
// All panels at frame (0,0) - SwiftUI renders text for all
for (i, panel) in panels.enumerated() {
    panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

    // Position visually using layer transform
    panel.layer?.transform = CATransform3DMakeTranslation(CGFloat(i) * panelWidth, 0, 0)
}

// Slide using parent's sublayerTransform
let offset = -CGFloat(activeIndex) * panelWidth
contentContainer.layer?.sublayerTransform = CATransform3DMakeTranslation(offset, 0, 0)
```

## Key Insight

```
Frame position = SwiftUI's visibility/render decision
Layer transform = GPU visual positioning (independent)
```

SwiftUI decides to render based on frame. Once rendered, the GPU just moves pixels via transform. These are independent operations.

## Implementation Notes

1. **clipView must clip**: `clipView.layer?.masksToBounds = true` to hide panels outside visible area
2. **All frames at origin**: Every panel gets `frame = (0, 0, width, height)`
3. **Individual layer transforms**: Each panel gets `layer.transform = translate(index * width, 0, 0)`
4. **Parent sublayerTransform for sliding**: Animate `contentContainer.layer?.sublayerTransform`
5. **Timing**: May need `DispatchQueue.main.async` after `viewDidMoveToWindow` for proper initialization

## Test Verification

See `screenshots/12_hybrid_slide_mid.png` - shows both panels with text rendering during mid-slide animation.
