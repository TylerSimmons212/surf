import CoreGraphics

/// How big a mini window opens.
///
/// The sibling of `PopOutSizing`, and the opposite problem. That one is told
/// the video's shape and has to honour it; this one is told nothing at all —
/// a link is a link — so the only thing to size against is the display.
///
/// A share of the screen rather than a fixed rectangle, because "big enough to
/// read, small enough to still read as a panel" is not a number of points. It
/// was 1000×680 flat, which is two thirds of a laptop screen and a quarter of
/// a 6K one: the same window reading as *almost the whole desktop* in one place
/// and *a postage stamp* in the other. The clamps are what keep the share
/// honest at both ends.
public enum MiniWindowSizing {

    /// Of the screen's usable rectangle, per axis.
    public static let fraction: CGFloat = 0.55

    /// Below this a page starts reflowing to its mobile layout, which is not
    /// what the link looked like wherever it was sent from.
    public static let minimum = CGSize(width: 820, height: 560)

    /// Above this it stops being a panel and starts being a second browser
    /// window you now have to tidy up.
    public static let maximum = CGSize(width: 1180, height: 800)

    /// The opening size on a screen with this much usable room.
    ///
    /// The share is taken first, then the clamps, then the screen itself has
    /// the last word — a floor of 820 points means nothing on a display 800
    /// wide, and a window wider than its screen has its own edges somewhere
    /// unreachable.
    public static func size(forVisible visible: CGRect) -> CGSize {
        CGSize(
            width: axis(visible.width, min: minimum.width, max: maximum.width),
            height: axis(visible.height, min: minimum.height, max: maximum.height)
        )
    }

    private static func axis(_ available: CGFloat, min floor: CGFloat, max ceiling: CGFloat)
        -> CGFloat
    {
        let share = (available * fraction).rounded()
        return Swift.min(Swift.max(Swift.min(share, ceiling), floor), available)
    }
}
