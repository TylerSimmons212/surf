/// The progress value a loading indicator should *draw*, which is not the
/// value WebKit reports.
///
/// Reported progress arrives in jumps, stalls for seconds at a time on a slow
/// page, goes backwards across a redirect, and stops short of 1 when a
/// navigation is abandoned. Rendering it raw gives an indicator that lurches,
/// freezes, rewinds, and ends mid-arc. This keeps a display value that only
/// ever moves forward, keeps creeping while the real number is silent, and
/// always finishes a full lap.
///
/// Pure state, so the behaviour can be tested without a window.
public struct LoadProgress: Equatable, Sendable {

    /// Where creeping stops. Short of 1 by enough to stay honest: the arc must
    /// never look finished while the page isn't.
    public static let ceiling = 0.92

    /// The sliver shown the instant a load starts, so the very beginning is
    /// legible instead of being a point of zero length.
    public static let start = 0.02

    public private(set) var value: Double = 0
    public private(set) var isVisible = false

    public init() {}

    public mutating func begin() {
        value = max(value, Self.start)
        isVisible = true
    }

    /// Takes a value reported by the engine. Backwards reports are dropped —
    /// an arc that retreats reads as something having gone wrong.
    @discardableResult
    public mutating func report(_ reported: Double) -> Bool {
        guard isVisible, reported > value else { return false }
        value = min(reported, 1)
        return true
    }

    /// Closes a fraction of the gap to the ceiling. Each step is smaller than
    /// the last, so repeated ticks keep the arc alive through a stall without
    /// ever arriving.
    @discardableResult
    public mutating func creep(fraction: Double = 0.07) -> Bool {
        guard isVisible, value < Self.ceiling else { return false }
        value += (Self.ceiling - value) * fraction
        return true
    }

    /// Runs the arc to a full lap. Called whether the load succeeded or not:
    /// a stub fading from wherever it stopped looks like a failure even when
    /// the page arrived.
    public mutating func complete() {
        guard isVisible else { return }
        value = 1
    }

    /// Fades out while keeping the completed lap in place. Rewinding and
    /// fading at the same time would show the arc retreating on its way off
    /// screen; the value is only reset once it can't be seen.
    public mutating func hide() {
        isVisible = false
    }

    /// Back to nothing — after the fade, or when switching tabs mid-load.
    public mutating func clear() {
        value = 0
        isVisible = false
    }
}
