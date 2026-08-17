/// The zoom ladder, and how to move along it.
///
/// Fixed stops rather than a multiplier: repeatedly multiplying by 1.1 gives
/// values nobody chose (1.331) and never lands back exactly on 100%, so "reset"
/// and "one step down from one step up" stop agreeing.
public enum ZoomSteps {

    /// Roughly Safari's ladder — tighter near 100% where small corrections are
    /// wanted, coarser at the extremes where they aren't.
    public static let levels: [Double] = [
        0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
    ]

    public static let standard: Double = 1.0

    /// The next stop up, or the current one if already at the top.
    ///
    /// Works from any value, not just a stop on the ladder: a page can arrive
    /// at an arbitrary zoom, and the first press should move to the nearest
    /// sensible stop rather than jumping to the end.
    public static func zoomingIn(from current: Double) -> Double {
        levels.first { $0 > current + tolerance } ?? levels.last ?? standard
    }

    public static func zoomingOut(from current: Double) -> Double {
        levels.last { $0 < current - tolerance } ?? levels.first ?? standard
    }

    public static func isStandard(_ level: Double) -> Bool {
        abs(level - standard) < tolerance
    }

    /// Shown while zoomed, so the page's scale is never a mystery.
    public static func label(for level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }

    /// Absorbs floating-point drift so a level that *is* a stop doesn't step
    /// onto itself.
    private static let tolerance = 0.001
}
