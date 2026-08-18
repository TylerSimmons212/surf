import CoreGraphics

/// Geometry for the developer-tools panel — the sibling of `PopOutSizing`.
///
/// Pure arithmetic, so the awkward cases (a split pane collapsing to nothing,
/// the fourth panel walking off the bottom of the screen) are settled in tests
/// rather than discovered by dragging things around.
public enum DevToolsLayout {

    /// Wide enough for a DOM row plus a styles pane without either feeling
    /// cramped, and short enough to sit beside a browser window on a laptop.
    public static let defaultSize = CGSize(width: 820, height: 580)

    /// Below this the two-pane layout stops making sense — the styles pane
    /// would be narrower than a single `font-family` value.
    public static let minimumSize = CGSize(width: 480, height: 320)

    /// The narrowest either side of a split may become. Dragging a divider
    /// clean off the edge is never what someone meant.
    public static let minimumPaneWidth: CGFloat = 180

    /// The styles pane's share of the Elements tab when nothing's been dragged.
    public static let defaultStylesFraction: CGFloat = 0.42

    /// Clamps a dragged divider so neither side can be squeezed away.
    ///
    /// When the window itself is too narrow to honour both minimums, the split
    /// lands in the middle: half of not-enough each, which at least keeps both
    /// panes on screen and legible-ish, rather than giving one everything.
    public static func stylesWidth(inTotal total: CGFloat, requested: CGFloat) -> CGFloat {
        guard total > minimumPaneWidth * 2 else { return total / 2 }
        return min(max(requested, minimumPaneWidth), total - minimumPaneWidth)
    }

    /// Where the nth simultaneously-open panel goes.
    ///
    /// Cascaded rather than stacked: opening dev tools on a second tab must not
    /// drop an identical window exactly on top of the first, because then it
    /// looks like nothing happened.
    public static func cascadedOrigin(
        index: Int,
        size: CGSize,
        on screen: CGRect
    ) -> CGPoint {
        let step: CGFloat = 28
        // Wrap before the cascade marches off the screen. Six is where a 28pt
        // step starts to overlap the far edge on a typical display.
        let position = CGFloat(max(0, index) % 6)

        let x = screen.minX + 40 + step * position
        // AppKit's origin is bottom-left, so cascading *downward* on screen
        // means subtracting from the top edge.
        let y = screen.maxY - size.height - 40 - step * position

        // Never place the panel where its title bar would be off-screen and
        // therefore undraggable.
        return CGPoint(
            x: min(x, screen.maxX - size.width),
            y: max(y, screen.minY)
        )
    }
}
