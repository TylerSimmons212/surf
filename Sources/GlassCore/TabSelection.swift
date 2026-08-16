import Foundation

/// Pure index math for the tab strip, kept free of WebKit so it can be tested.
///
/// These are small functions, but they're the ones users notice instantly when
/// they're wrong — closing a tab and landing on the wrong neighbour, or ⌘9
/// jumping somewhere unexpected.
public enum TabSelection {

    /// The index to select after removing the tab at `closedIndex`.
    /// Returns nil when nothing is left.
    ///
    /// The tab that slides into the vacated slot wins; if the last tab was
    /// closed there's nothing to the right, so the new last tab is used.
    public static func indexAfterClosing(closedIndex: Int, originalCount: Int) -> Int? {
        let remaining = originalCount - 1
        guard remaining > 0 else { return nil }
        return min(closedIndex, remaining - 1)
    }

    /// Next/previous with wraparound. `offset` may be any magnitude or sign.
    public static func cycled(from index: Int, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        // Double modulo keeps the result non-negative for negative offsets.
        return ((index + offset) % count + count) % count
    }

    /// ⌘1–⌘8 select by position. ⌘9 means "last tab", matching Safari and
    /// Chrome, rather than the ninth tab.
    public static func index(forOneBased position: Int, count: Int) -> Int? {
        guard count > 0, position >= 1 else { return nil }
        if position >= 9 { return count - 1 }
        let zeroBased = position - 1
        return zeroBased < count ? zeroBased : nil
    }
}
