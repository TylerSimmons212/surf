import CoreGraphics

/// How big the pop-out panel should be for a given video.
///
/// The rule that matters: **the video's own proportions are never altered**.
/// Every limit below is applied by scaling both axes together, because
/// clamping one of them on its own silently changes the shape — which is how a
/// vertical video ended up looking square until it was resized and snapped back
/// to the ratio the panel had been enforcing all along.
public enum PopOutSizing {

    /// Matched by *area* rather than width, so a tall video and a wide one get
    /// panels of similar presence. Width-matching makes a 9:16 clip tower over
    /// a 16:9 one that's nominally the same size.
    public static let targetArea: CGFloat = 480 * 270

    /// The box a panel should try to sit inside.
    public static let maxWidth: CGFloat = 720
    public static let maxHeight: CGFloat = 620

    /// Below this, the chrome has nowhere to sit.
    public static let minShorterSide: CGFloat = 132

    public static let fallback = CGSize(width: 480, height: 270)

    public static func panelSize(forVideo video: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0 else { return fallback }

        let scale = (targetArea / (video.width * video.height)).squareRoot()
        var size = CGSize(width: video.width * scale, height: video.height * scale)

        // Fit the box.
        let shrink = min(1, min(maxWidth / size.width, maxHeight / size.height))
        size = CGSize(width: size.width * shrink, height: size.height * shrink)

        // Then rescue anything that came out too small to hold the controls.
        // This can push a very lopsided video back outside the box, which is
        // the right trade: a panel slightly larger than intended is usable, a
        // panel 60 points wide is not.
        let grow = max(1, minShorterSide / min(size.width, size.height))
        return CGSize(width: size.width * grow, height: size.height * grow)
    }

    /// The floor for interactive resizing. Also ratio-preserving: a floor of a
    /// different shape is reconciled against the aspect ratio by AppKit, and
    /// the panel stops squarely short of where the user is dragging.
    public static func minimumSize(forVideo video: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0 else {
            return CGSize(width: 240, height: 135)
        }
        let scale = minShorterSide / min(video.width, video.height)
        return CGSize(width: video.width * scale, height: video.height * scale)
    }

    /// Whether two sizes describe the same shape, within a tolerance that
    /// ignores sub-pixel drift in the measured video rect.
    /// How far a panel sits from the screen edge when it has nowhere
    /// remembered to go.
    public static let margin: CGFloat = 24

    /// Where the panel should open: where you left it, or the bottom trailing
    /// corner the first time.
    ///
    /// A floating window you have deliberately placed and then sized is a
    /// window you have said something about, and reopening it in the corner
    /// every time throws that away once per video.
    ///
    /// The size is kept only when the shape matches. A panel you widened for a
    /// 16:9 clip is the wrong box for a 9:16 one, and the panel's aspect lock
    /// would fight it the moment it opened — so a different shape gets the
    /// size its own proportions ask for, and keeps the corner you chose.
    ///
    /// Everything is clamped back onto `visible`, because the screen it was
    /// left on may be smaller now, or gone.
    public static func placement(
        remembered: CGRect?,
        forVideo video: CGSize,
        onVisible visible: CGRect
    ) -> CGRect {
        let natural = panelSize(forVideo: video)
        guard visible.width > 0, visible.height > 0 else {
            return CGRect(origin: .zero, size: natural)
        }

        var size = natural
        if let remembered, aspectMatches(remembered.size, natural),
           remembered.width <= visible.width, remembered.height <= visible.height {
            size = remembered.size
        }
        // A natural size can still be too big for a small screen.
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)

        let corner = CGPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
        guard let remembered else {
            return CGRect(origin: clamped(corner, size: size, in: visible), size: size)
        }
        return CGRect(origin: clamped(remembered.origin, size: size, in: visible), size: size)
    }

    /// How near a corner the panel has to be let go for it to settle there.
    ///
    /// Generous, because a corner is nearly always where somebody flinging a
    /// small window is aiming, and a magnet you have to be accurate for is a
    /// magnet that reads as broken.
    public static let snapReach: CGFloat = 140

    /// The corner this panel should settle into, or nil when it was let go too
    /// far from any of them.
    ///
    /// Nil is the interesting half. The system's own Picture-in-Picture always
    /// goes to a corner, which works because it has nothing to say and no
    /// controls to reach — this panel is resizable, carries a scrubber, and is
    /// a reasonable thing to park beside the thing you are reading. So the
    /// corners pull, and the middle of the screen is still somewhere you are
    /// allowed to leave it.
    public static func snapped(
        _ frame: CGRect, onVisible visible: CGRect, within reach: CGFloat = snapReach
    ) -> CGRect? {
        guard visible.width > 0, visible.height > 0 else { return nil }

        let left = visible.minX + margin
        let right = visible.maxX - frame.width - margin
        let bottom = visible.minY + margin
        let top = visible.maxY - frame.height - margin

        let corners = [
            CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom),
            CGPoint(x: left, y: top), CGPoint(x: right, y: top),
        ]
        let nearest = corners.min {
            distance($0, frame.origin) < distance($1, frame.origin)
        }
        guard let nearest, distance(nearest, frame.origin) <= reach else { return nil }
        return CGRect(origin: nearest, size: frame.size)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// An origin that keeps the whole panel on screen.
    private static func clamped(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }

    public static func aspectMatches(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 0.02) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let left = a.width / a.height
        let right = b.width / b.height
        return abs(left - right) / max(left, right) <= tolerance
    }
}
