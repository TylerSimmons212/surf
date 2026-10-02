import Foundation

/// How long a thing is, and how far into it you are.
///
/// Its own type because two places needed the same answer — the pop-out's
/// scrubber and the sidebar's media row — and a second copy of a formatter is
/// a drift waiting to happen: one of them grows an hours case and the other
/// quietly keeps saying `74:03`.
public enum MediaTime {

    /// `h:mm:ss` when there are hours, `m:ss` otherwise.
    ///
    /// Hours are omitted rather than zero-padded because almost nothing is
    /// over an hour, and `0:03:14` on a three-minute song reads as a clock
    /// rather than a duration.
    public static func display(_ seconds: Double) -> String {
        // A live stream reports infinity and an unloaded one reports nothing.
        // Neither is a failure worth showing a number for, and both used to
        // reach `Int(...)` — where infinity traps rather than returning
        // anything at all.
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Where you are out of how long it is — `2:14 / 10:03`.
    ///
    /// Nil when there is no duration to be out of. A live stream has no end,
    /// and `2:14 / 0:00` says something false about one.
    public static func position(_ elapsed: Double, of duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return nil }
        return "\(display(elapsed)) / \(display(duration))"
    }
}
