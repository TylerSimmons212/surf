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
    public static func aspectMatches(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 0.02) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let left = a.width / a.height
        let right = b.width / b.height
        return abs(left - right) / max(left, right) <= tolerance
    }
}
