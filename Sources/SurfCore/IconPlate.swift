import Foundation

/// Whether a favicon is drawn on a solid background, and what colour it is.
///
/// The distinction a sticker needs. An icon with a plate — a coloured square
/// with a mark on it, which is most app-style favicons — placed on white vinyl
/// reads as a photograph of a sticker stuck to another sticker: two rectangles,
/// two edges, an obvious seam. Painting the vinyl in the plate's own colour
/// dissolves that seam, and the icon becomes the sticker.
///
/// An icon on transparency has no such seam to begin with — the mark simply
/// sits on whatever it's placed on — so there is nothing to match and the
/// vinyl is free to be what it likes.
///
/// Read from the **border ring** rather than the whole image, because that is
/// where the question actually lives: a plate is a colour that reaches the
/// edges. Averaging the whole icon would answer a different question, and
/// answer it with the mark's colour mixed in.
public enum IconPlate {

    /// How transparent the icon as a whole may be and still be called plated.
    ///
    /// The load-bearing test, and the one the border ring alone cannot make. A
    /// plate *fills* its icon — that is what makes it a background rather than
    /// a shape. A black mark on transparency can perfectly well run out to all
    /// four edges, leaving a border ring that is opaque, flat, and entirely
    /// black; read from the ring alone that is indistinguishable from a black
    /// plate, and calling it one paints the vinyl the same black as the mark
    /// and the icon disappears. Measured over the whole image the two are never
    /// confusable: that icon was 44% transparent, and no plate is.
    ///
    /// Shares `ImageAnalysis`'s threshold, which draws exactly this line
    /// between a mark floating on nothing and a picture with soft edges. Well
    /// clear of what rounded corners cost — a generous radius on a 16px sample
    /// is about 5% of it.
    public static let maximumTransparency = ImageAnalysis.transparencyThreshold

    /// How much of the border ring must be opaque before the icon counts as
    /// plated.
    ///
    /// Not near-total, because a rounded-corner favicon — the house style for
    /// app icons — is genuinely transparent at all four corners, and on a 16px
    /// sample those corners are a real share of the ring. Set below that cost
    /// and far above what a mark floating on transparency ever reaches: such an
    /// icon's border is empty except where a stroke happens to run out to the
    /// edge.
    public static let opaqueBorderMajority = 0.6

    /// How far a border pixel may sit from the ring's mean and still be counted
    /// as part of the same flat colour. Per channel, so a tint shift in any
    /// direction is caught rather than averaged away.
    public static let flatnessTolerance = 0.09

    /// How much of the opaque ring must agree on that colour.
    ///
    /// Short of unanimity on purpose: a mark that bleeds off its own plate, or
    /// a one-pixel darker border drawn around the icon, should not be enough to
    /// call a plainly-plated icon unplated.
    public static let agreementMajority = 0.85

    /// The plate's colour, or nil when the icon isn't plated.
    ///
    /// `bytes` is a square RGBA buffer, `side` pixels on each edge, with
    /// **unpremultiplied** components — the same shape `ImageAnalysis.verdict`
    /// reads.
    public static func detect(rgba bytes: [UInt8], side: Int) -> SRGB? {
        guard side >= 3, bytes.count == side * side * 4 else { return nil }

        // Whole-image gate first: anything meaningfully transparent is a mark
        // on nothing, whatever its edges happen to look like.
        var transparent = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4)
        where Double(bytes[pixel + 3]) / 255 < ImageAnalysis.alphaFloor {
            transparent += 1
        }
        let total = bytes.count / 4
        guard Double(transparent) / Double(total) < maximumTransparency else { return nil }

        var opaque: [SRGB] = []
        var borderCount = 0

        for row in 0..<side {
            let isEdgeRow = row == 0 || row == side - 1
            for column in 0..<side where isEdgeRow || column == 0 || column == side - 1 {
                borderCount += 1
                let pixel = (row * side + column) * 4
                // A part-transparent pixel shows what's behind it, so it isn't
                // plate — and its colour has been mixed with whatever it was
                // composited over, so it isn't worth averaging either.
                guard Double(bytes[pixel + 3]) / 255 >= 1 - ImageAnalysis.alphaFloor else {
                    continue
                }
                opaque.append(
                    SRGB(
                        r: Double(bytes[pixel]) / 255,
                        g: Double(bytes[pixel + 1]) / 255,
                        b: Double(bytes[pixel + 2]) / 255
                    )
                )
            }
        }

        guard borderCount > 0,
              Double(opaque.count) / Double(borderCount) >= opaqueBorderMajority
        else { return nil }

        let mean = SRGB(
            r: opaque.reduce(0) { $0 + $1.r } / Double(opaque.count),
            g: opaque.reduce(0) { $0 + $1.g } / Double(opaque.count),
            b: opaque.reduce(0) { $0 + $1.b } / Double(opaque.count)
        )

        let agreeing = opaque.filter { isFlat($0, against: mean) }
        guard Double(agreeing.count) / Double(opaque.count) >= agreementMajority else {
            return nil
        }

        // Averaged over only the agreeing pixels, so a mark bleeding off the
        // plate can't drag the colour toward itself.
        return SRGB(
            r: agreeing.reduce(0) { $0 + $1.r } / Double(agreeing.count),
            g: agreeing.reduce(0) { $0 + $1.g } / Double(agreeing.count),
            b: agreeing.reduce(0) { $0 + $1.b } / Double(agreeing.count)
        )
    }

    private static func isFlat(_ color: SRGB, against mean: SRGB) -> Bool {
        abs(color.r - mean.r) <= flatnessTolerance
            && abs(color.g - mean.g) <= flatnessTolerance
            && abs(color.b - mean.b) <= flatnessTolerance
    }
}
