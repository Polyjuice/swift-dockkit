import AppKit

/// A reusable horizontal swipe carousel engine.
///
/// Manages gesture state, rubber-band overscroll, spring-back, flick detection,
/// and bubble-to-parent behavior shared by `DockStageContainerView` (stages) and
/// `DockTabGroupViewController` (tabs). Hosts supply:
///
/// - A `clipView` (determines position width via its bounds).
/// - A `contentView` that is `positionCount` times wider than the clip view and
///   contains the per-position subviews laid out side-by-side.
/// - A leading constraint on the content view, which the engine updates to
///   animate horizontal position.
///
/// Host callbacks report gesture start/end, indicator target during the gesture,
/// and the committed position switch.
public final class SwipeCarouselGesture {

    // MARK: - Host-supplied

    public weak var clipView: NSView?
    public weak var contentView: NSView?
    public var leadingConstraint: NSLayoutConstraint?

    /// Total number of positions (stages or tabs).
    public var positionCount: () -> Int = { 0 }

    /// Currently active position.
    public var activePosition: () -> Int = { 0 }

    /// Delegate for bubbling to a parent carousel.
    public weak var swipeGestureDelegate: SwipeGestureDelegate?

    /// The host NSView (used as the "source" argument when bubbling).
    public weak var source: NSView?

    // MARK: - Callbacks

    /// Fired when a physical gesture begins.
    public var didBeginGesture: () -> Void = {}
    /// Fired when gesture + spring animation fully complete.
    public var didEndGesture: () -> Void = {}
    /// Fired when the target indicator changes during the gesture.
    public var didChangeIndicatorTarget: (Int) -> Void = { _ in }
    /// Fired when the active position is committed (after flick/drag decision).
    /// The engine has already updated its internal active index; the host should
    /// update its own model so `activePosition()` returns the new value.
    public var didCommitPosition: (Int) -> Void = { _ in }

    // MARK: - Tuning

    public var slowMotion: Bool = false
    private var timeScale: CGFloat { slowMotion ? 0.1 : 1.0 }

    private let springStiffness: CGFloat = 300
    private let springDamping: CGFloat = 25
    private let springMass: CGFloat = 1.0
    private let rubberBandCoefficient: CGFloat = 0.55
    private let flickVelocityThreshold: CGFloat = 500
    private let dragPositionThreshold: CGFloat = 0.5

    // MARK: - State

    public private(set) var isGestureActive: Bool = false
    public private(set) var isBubblingToParent: Bool = false

    private var gestureAmount: CGFloat = 0
    private var gestureVelocity: CGFloat = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var swipeOffset: CGFloat = 0
    private var lastIndicatorTarget: Int = -1

    private struct SpringState {
        var position: CGFloat
        var velocity: CGFloat
        var target: CGFloat
    }
    private var springState: SpringState?
    private var displayLink: CVDisplayLink?

    public init() {}

    deinit {
        stopDisplayLink()
    }

    // MARK: - Layout

    /// Call from the host's `layout()` to keep the content view aligned while not
    /// animating. The host is responsible for placing position subviews at their
    /// correct horizontal offsets.
    public func updateContentPositionIfNeeded() {
        guard springState == nil, !isGestureActive else { return }
        applyPosition(offset: 0)
    }

    /// Snap to the given position immediately (no animation). Use when the host
    /// changes active position externally (e.g., user clicks a tab).
    public func setActivePositionImmediate(_ index: Int) {
        stopSpringAnimation()
        swipeOffset = 0
        didCommitPosition(index)
        applyPosition(offset: 0)
    }

    /// Animate to the given position (used for clicked tab selections).
    public func animateToPosition(_ index: Int) {
        // If we're already at target, just snap
        guard index != activePosition() else {
            swipeOffset = 0
            applyPosition(offset: 0)
            return
        }
        stopSpringAnimation()
        let width = positionWidth()
        // The content is currently at activePosition's offset. After committing to
        // `index`, we need swipeOffset to carry the visual continuity before the
        // spring-back.
        swipeOffset = CGFloat(index - activePosition()) * width
        didCommitPosition(index)
        startSpring(targetOffset: 0, initialVelocity: 0)
    }

    private func positionWidth() -> CGFloat {
        clipView?.bounds.width ?? 0
    }

    private func applyPosition(offset: CGFloat) {
        let width = positionWidth()
        guard width > 0 else { return }
        let targetX = -CGFloat(activePosition()) * width + offset
        leadingConstraint?.constant = targetX
    }

    // MARK: - Scroll Handling

    /// Handle a scroll-wheel event. Returns true if the event was consumed.
    @discardableResult
    public func handleScrollWheel(_ event: NSEvent) -> Bool {
        // Only trackpad gesture events
        guard event.phase != [] || event.momentumPhase != [] else { return false }

        // Require horizontal-dominance to activate (but continue if already active)
        let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.5
        if !isHorizontalDominant && !isGestureActive { return false }

        if event.phase == .began {
            beginGesture()
        }

        guard isGestureActive && springState == nil else {
            // Spring is running — ignore stray scroll events
            return isGestureActive
        }

        if event.phase == .changed || event.momentumPhase == .changed {
            processDelta(event)
        }

        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            endGesture()
        }

        if event.phase == .ended && event.momentumPhase == [] {
            // Small window to see if momentum arrives; if not, finalize.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self = self, self.isGestureActive else { return }
                self.endGesture()
            }
        }

        return true
    }

    /// Re-entry for events bubbled up from a nested carousel.
    @discardableResult
    public func handleBubbledScrollEvent(_ event: NSEvent) -> Bool {
        if event.phase == .began ||
            (!isGestureActive && (event.phase == .changed || event.momentumPhase == .changed)) {
            beginGesture()
        }

        guard isGestureActive && springState == nil else { return false }

        if event.phase == .changed || event.momentumPhase == .changed {
            processDelta(event)
        }
        return true
    }

    /// The nested source has ended its bubbling — finalize any state.
    public func nestedDidEnd() {
        guard isGestureActive else { return }
        endGesture()
    }

    // MARK: - Internal

    private func beginGesture() {
        isGestureActive = true
        isBubblingToParent = false
        stopSpringAnimation()
        didBeginGesture()
        gestureVelocity = 0
        lastScrollTime = CACurrentMediaTime()
    }

    private func processDelta(_ event: NSEvent) {
        let width = positionWidth()
        guard width > 0 else { return }
        let deltaX = event.scrollingDeltaX

        if event.phase == .changed {
            let currentTime = CACurrentMediaTime()
            let dt = currentTime - lastScrollTime
            if dt > 0 {
                let instantVelocity = deltaX / CGFloat(dt)
                gestureVelocity = gestureVelocity * 0.7 + instantVelocity * 0.3
            }
            lastScrollTime = currentTime
        }

        // Bubble when at edge and continuing beyond
        let count = positionCount()
        let active = activePosition()
        let isAtLeftEdge = active == 0 && gestureAmount >= 0
        let isAtRightEdge = active == count - 1 && gestureAmount <= 0
        let swipingBeyondLeft = isAtLeftEdge && deltaX > 0
        let swipingBeyondRight = isAtRightEdge && deltaX < 0

        if (swipingBeyondLeft || swipingBeyondRight), let delegate = swipeGestureDelegate, let source = source {
            if !isBubblingToParent {
                isBubblingToParent = true
                gestureAmount = 0
                swipeOffset = 0
                applyPosition(offset: 0)
            }
            _ = delegate.handleBubbledScrollEvent(event, from: source)
            return
        }

        if isBubblingToParent {
            let stopped = (isAtLeftEdge && deltaX < 0) || (isAtRightEdge && deltaX > 0)
            if stopped {
                isBubblingToParent = false
                if let source = source {
                    swipeGestureDelegate?.nestedContainerDidEndGesture(source)
                }
            }
        }

        gestureAmount += deltaX / width

        // Rubber band at edges
        let maxLeft = CGFloat(active)
        let maxRight = CGFloat(count - 1 - active)
        let visualAmount: CGFloat
        if gestureAmount > maxLeft {
            let overshoot = gestureAmount - maxLeft
            visualAmount = maxLeft + rubberBand(overshoot, dimension: 1.0)
        } else if gestureAmount < -maxRight {
            let overshoot = -maxRight - gestureAmount
            visualAmount = -maxRight - rubberBand(overshoot, dimension: 1.0)
        } else {
            visualAmount = gestureAmount
        }

        swipeOffset = visualAmount * width
        applyPosition(offset: swipeOffset)

        updateIndicator()
    }

    private func updateIndicator() {
        let count = positionCount()
        let active = activePosition()
        let target: Int
        if gestureAmount >= dragPositionThreshold && active > 0 {
            target = active - 1
        } else if gestureAmount <= -dragPositionThreshold && active < count - 1 {
            target = active + 1
        } else {
            target = active
        }
        if target != lastIndicatorTarget {
            lastIndicatorTarget = target
            didChangeIndicatorTarget(target)
        }
    }

    private func endGesture() {
        isGestureActive = false
        if isBubblingToParent {
            isBubblingToParent = false
            if let source = source {
                swipeGestureDelegate?.nestedContainerDidEndGesture(source)
            }
        }
        finalizeGesture()
    }

    private func finalizeGesture() {
        lastIndicatorTarget = -1
        let count = positionCount()
        let active = activePosition()
        let maxLeft = CGFloat(active)
        let maxRight = CGFloat(count - 1 - active)
        let clampedAmount = max(-maxRight, min(maxLeft, gestureAmount))

        let velocityBased = abs(gestureVelocity) > flickVelocityThreshold

        var newIndex = active
        if velocityBased {
            if gestureVelocity > 0 && active > 0 {
                newIndex = active - 1
                gestureAmount -= 1.0
            } else if gestureVelocity < 0 && active < count - 1 {
                newIndex = active + 1
                gestureAmount += 1.0
            }
        } else if clampedAmount >= dragPositionThreshold && active > 0 {
            newIndex = active - 1
            gestureAmount -= 1.0
        } else if clampedAmount <= -dragPositionThreshold && active < count - 1 {
            newIndex = active + 1
            gestureAmount += 1.0
        }

        // Visual offset with rubber-band if past edges after commit
        let newMaxLeft = CGFloat(newIndex)
        let newMaxRight = CGFloat(count - 1 - newIndex)
        let visualAmount: CGFloat
        if gestureAmount > newMaxLeft {
            visualAmount = newMaxLeft + rubberBand(gestureAmount - newMaxLeft, dimension: 1.0)
        } else if gestureAmount < -newMaxRight {
            visualAmount = -newMaxRight - rubberBand(-newMaxRight - gestureAmount, dimension: 1.0)
        } else {
            visualAmount = gestureAmount
        }

        let width = positionWidth()
        swipeOffset = visualAmount * width

        // Commit the new position to the host's model
        if newIndex != active {
            // Maintain visual continuity: adjust swipeOffset so the visible position
            // stays the same across the index change.
            swipeOffset += CGFloat(newIndex - active) * width
            didCommitPosition(newIndex)
        }

        gestureAmount = 0
        gestureVelocity = 0

        // Spring back to offset 0 from current swipeOffset
        if abs(swipeOffset) < 1 {
            swipeOffset = 0
            applyPosition(offset: 0)
            didEndGesture()
        } else {
            startSpring(targetOffset: 0, initialVelocity: 0)
        }
    }

    // MARK: - Rubber band

    private func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        let c = rubberBandCoefficient
        return (x * d * c) / (d + c * x)
    }

    // MARK: - Spring

    private func startSpring(targetOffset: CGFloat, initialVelocity: CGFloat) {
        springState = SpringState(position: swipeOffset, velocity: initialVelocity, target: targetOffset)
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            let engine = Unmanaged<SwipeCarouselGesture>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { engine.tickSpring() }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    public func stopSpringAnimation() {
        springState = nil
        stopDisplayLink()
    }

    private func tickSpring() {
        guard var state = springState else {
            stopDisplayLink()
            return
        }
        let dt: CGFloat = (1.0 / 60.0) * timeScale
        let displacement = state.position - state.target
        let springForce = -springStiffness * displacement
        let dampingForce = -springDamping * state.velocity
        let acceleration = (springForce + dampingForce) / springMass
        state.velocity += acceleration * dt
        state.position += state.velocity * dt

        swipeOffset = state.position
        applyPosition(offset: swipeOffset)

        if abs(state.position - state.target) < 0.5 && abs(state.velocity) < 10 {
            swipeOffset = 0
            applyPosition(offset: 0)
            springState = nil
            stopDisplayLink()
            didEndGesture()
        } else {
            springState = state
        }
    }
}
