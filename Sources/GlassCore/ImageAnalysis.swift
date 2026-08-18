import Foundation

/// What a sampled image turned out to be.
public struct ImageVerdict: Equatable, Sendable {
    /// Share of pixels transparent enough to show whatever is behind them.
    public var transparentFraction: Double
    /// Share of the opaque pixels carrying no meaningful colour.
    public var achromaticFraction: Double
    /// The average colour of the pixels that aren't transparent.
    public var artwork: SRGB

    public var hasTransparency: Bool {
        transparentFraction >= ImageAnalysis.transparencyThreshold
    }

    /// Whether the artwork is colourless — ink rather than a picture.
    ///
    /// Measured per pixel and not from the average, which is the whole point.
    /// A logo of a red circle beside a green one averages to a muddy grey and
    /// would pass any test of its mean, and inverting it would be exactly the
    /// damage this is meant to avoid.
    public var isAchromatic: Bool {
        achromaticFraction >= ImageAnalysis.achromaticMajority
    }
}

/// Decides whether an image is a colourless mark that has to be inverted to
/// stay visible.
///
/// The rule is still that artwork is not recoloured. This is the one exception
/// the rule can afford, and it is narrow by construction: an image is inverted
/// only when it carries **no colour at all**. A black wordmark becomes a white
/// one, which is what its designers drew for their own dark mode; there is no
/// hue to shift, no brand to mangle, and nothing to get subtly wrong. Anything
/// with colour in it is left exactly as it was.
///
/// A plate behind the mark was the earlier answer and was worse: a background
/// colour fills the element's whole box, so on a transparent logo it arrived as
/// a rectangle the design never had. Inverting touches only the pixels that
/// were already being drawn, and leaves transparency transparent.
public enum ImageAnalysis {

    /// Below this alpha a pixel shows what's behind it rather than itself.
    public static let alphaFloor = 0.1

    /// Colour is judged in proportion to how much of a pixel there is.
    ///
    /// Sampled pixels arrive unpremultiplied, so a barely-there pixel has had
    /// its colour divided by a tiny alpha and whatever rounding was in the
    /// stored value amplified with it — the soft edge of a black wordmark comes
    /// back as scattered navy. Counting every pixel equally lets that noise
    /// outvote the artwork.
    ///
    /// A hard threshold is the obvious fix and is worse: a wordmark's letter
    /// strokes are thin, so downsampling leaves most of them part-transparent,
    /// and discarding those throws away the letters and keeps whatever solid
    /// blobs remain. Weighting by alpha keeps the strokes, in proportion, while
    /// giving the noise almost no say.

    /// How much of an image must be transparent before it counts as a mark
    /// floating on nothing rather than a picture with soft edges.
    public static let transparencyThreshold = 0.12

    /// Chroma below which a pixel carries no colour worth preserving.
    public static let achromaticChroma = 0.03

    /// How much of the artwork must be colourless for the whole to count as
    /// ink. Deliberately near-total: a mark with any real colour in it is one
    /// we keep our hands off.
    public static let achromaticMajority = 0.9

    /// Reads a downsampled RGBA buffer.
    public static func verdict(rgba bytes: [UInt8]) -> ImageVerdict? {
        guard !bytes.isEmpty, bytes.count % 4 == 0 else { return nil }

        var transparent = 0
        var weight = 0.0
        var achromaticWeight = 0.0
        var sum = (r: 0.0, g: 0.0, b: 0.0)

        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[pixel + 3]) / 255
            if alpha < alphaFloor {
                transparent += 1
                continue
            }
            let color = SRGB(
                r: Double(bytes[pixel]) / 255,
                g: Double(bytes[pixel + 1]) / 255,
                b: Double(bytes[pixel + 2]) / 255
            )
            weight += alpha
            if OKLCH(color).c < achromaticChroma { achromaticWeight += alpha }
            sum.r += color.r * alpha
            sum.g += color.g * alpha
            sum.b += color.b * alpha
        }

        let total = bytes.count / 4
        guard weight > 0 else { return nil }

        return ImageVerdict(
            transparentFraction: Double(transparent) / Double(total),
            achromaticFraction: achromaticWeight / weight,
            artwork: SRGB(r: sum.r / weight, g: sum.g / weight, b: sum.b / weight)
        )
    }

    /// Whether a mark carrying colour would be lost on the given surface.
    ///
    /// The rescue for these is an inversion that holds hue rather than a plain
    /// one. Plain inversion is what makes automatic dark modes infamous: it
    /// takes a complement, so Wikipedia's blue badge would arrive orange and a
    /// green logotype pink. The hue-preserving form flips lightness and leaves
    /// the hue where it was — `#0e65c0` becomes a lighter blue rather than
    /// another colour entirely.
    ///
    /// Still only for marks on transparency, and still only when they would
    /// otherwise be lost. A logo that reads perfectly well is not improved by
    /// being turned inside out.
    public static func shouldInvertPreservingHue(
        _ verdict: ImageVerdict, on surface: SRGB
    ) -> Bool {
        guard verdict.hasTransparency, !verdict.isAchromatic else { return false }
        return !Contrast.isLegible(
            .nonText, foreground: verdict.artwork, background: surface
        )
    }

    /// Whether this mark would be lost on the given surface, and can be
    /// inverted without losing anything.
    ///
    /// Symmetric by construction: a white mark on a page being forced to light
    /// fails the same test and inverts to black, which is the same rescue in
    /// the other direction.
    public static func shouldInvert(_ verdict: ImageVerdict, on surface: SRGB) -> Bool {
        guard verdict.hasTransparency, verdict.isAchromatic else { return false }
        return !Contrast.isLegible(
            .nonText, foreground: verdict.artwork, background: surface
        )
    }
}
