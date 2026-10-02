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

    /// Runs the arc to a full lap. Only for a load that arrived: a stub fading
    /// from wherever it stopped looks like a failure, which is exactly what a
    /// failed load should look like — see `ending(shownFor:failed:)`.
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

// MARK: - How a load ends

extension LoadProgress {

    /// How long a load runs before anything is drawn.
    ///
    /// Under about a tenth of a second a load reads as instant, and a lap
    /// drawn for it is a flicker around the window on every cached page and
    /// same-site click. A load that finishes inside this draws nothing at all.
    public static let grace: Duration = .milliseconds(120)

    /// How long an arc stays up before its lap may close.
    ///
    /// A load that finishes just after the grace period would otherwise
    /// appear and close in the same breath, which is the flicker again with
    /// extra steps.
    public static let minimumShown: Duration = .milliseconds(300)

    public enum Ending: Equatable, Sendable {
        /// Finished before anything was drawn; there's nothing to end.
        case unseen
        /// Close the lap once `after` has passed, then wash out.
        case closeLap(after: Duration)
        /// The load failed: fade the arc where it stopped.
        case fade
    }

    /// What the indicator does when the engine stops loading.
    ///
    /// - Parameters:
    ///   - shownFor: How long the arc has been on screen, or nil if the grace
    ///     period never ran out.
    ///   - failed: Whether the load ended in an error.
    public static func ending(shownFor: Duration?, failed: Bool) -> Ending {
        guard let shownFor else { return .unseen }
        if failed { return .fade }
        return .closeLap(after: max(.zero, minimumShown - shownFor))
    }
}
