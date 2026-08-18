import Foundation

/// What a sampled image turned out to be.
public struct ImageVerdict: Equatable, Sendable {
    /// Share of pixels transparent enough to show whatever is behind them.
    public var transparentFraction: Double
    /// The average colour of the pixels that aren't — the artwork itself.
    public var artwork: SRGB
    /// Perceptual lightness of that average.
    public var artworkLightness: Double

    public var hasTransparency: Bool {
        transparentFraction >= ImageAnalysis.transparencyThreshold
    }
}

/// Decides whether an image needs a plate painted behind it.
///
/// The rule this exists to serve is that image pixels are **never** recoloured.
/// Inverting a logo is the most visible damage this feature could do and there
/// is no recovering from it — a brand mark in the wrong colours is worse than
/// no dark mode at all.
///
/// But leaving every image alone has one real casualty: artwork drawn as dark
/// ink on transparency. It reads perfectly on the white page it was made for,
/// and on a dark surface it simply disappears. The answer is to give it back
/// the light it was drawn against — painting a plate *behind* it, which leaves
/// every pixel of the artwork exactly as its designer drew it.
///
/// Everything else is left alone. An opaque image carries its own background
/// and was never in danger; light artwork on transparency is already visible;
/// and an image we cannot inspect gets the benefit of the doubt, because the
/// cost of guessing wrong here is so much higher than the cost of doing nothing.
public enum ImageAnalysis {

    /// Below this alpha a pixel shows what's behind it rather than itself.
    public static let alphaFloor = 0.1

    /// How much of an image must be transparent before it counts as artwork on
    /// transparency rather than a picture with soft edges. A photograph with an
    /// antialiased corner is not a logo.
    public static let transparencyThreshold = 0.12

    /// Reads a downsampled RGBA buffer.
    ///
    /// Sampling is enough — this asks whether the artwork is broadly dark, not
    /// what it depicts, and a 16×16 reduction answers that as well as the full
    /// image for a fraction of the work.
    public static func verdict(rgba bytes: [UInt8]) -> ImageVerdict? {
        guard !bytes.isEmpty, bytes.count % 4 == 0 else { return nil }

        var transparent = 0
        var opaqueCount = 0
        var sum = (r: 0.0, g: 0.0, b: 0.0)

        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[pixel + 3]) / 255
            if alpha < alphaFloor {
                transparent += 1
                continue
            }
            opaqueCount += 1
            // Weighted by alpha: a half-transparent pixel contributes half of
            // itself, which is what it actually contributes on screen.
            sum.r += Double(bytes[pixel]) / 255 * alpha
            sum.g += Double(bytes[pixel + 1]) / 255 * alpha
            sum.b += Double(bytes[pixel + 2]) / 255 * alpha
        }

        let total = bytes.count / 4
        guard opaqueCount > 0 else { return nil }

        let artwork = SRGB(
            r: sum.r / Double(opaqueCount),
            g: sum.g / Double(opaqueCount),
            b: sum.b / Double(opaqueCount)
        )
        return ImageVerdict(
            transparentFraction: Double(transparent) / Double(total),
            artwork: artwork,
            artworkLightness: OKLCH(artwork).l
        )
    }

    /// The bar an image has to fall below before we intervene at all.
    ///
    /// Deliberately the low one. Dark artwork on a merely dim surface often
    /// reads perfectly well, and a plate it didn't need is a rectangle on the
    /// page that nobody asked for.
    static let interveneBelow = Contrast.Requirement.nonText

    /// The bar a plate is then built to clear, which is the higher one.
    ///
    /// The asymmetry is the point: intervene rarely, but when you do, do it
    /// properly. A plate that lands on the non-text minimum leaves a mark
    /// technically visible and practically muddy — and a logo usually carries a
    /// wordmark, which is text however it was delivered.
    static let plateTarget = Contrast.Requirement.normalText

    /// Whether this image would be lost on the given surface.
    public static func needsPlate(_ verdict: ImageVerdict, on surface: SRGB) -> Bool {
        guard verdict.hasTransparency else { return false }
        return !Contrast.isLegible(
            interveneBelow, foreground: verdict.artwork, background: surface
        )
    }

    /// The plate to paint behind it.
    ///
    /// Reuses the contrast repair, moving the *background* — which is exactly
    /// the case that machinery was built for: keep the thing that carries the
    /// identity, move what sits behind it. So the plate is the smallest step
    /// from the page's own surface that makes the artwork read, rather than a
    /// slab of white, which would be a worse mark on the page than the logo it
    /// was rescuing.
    public static func plate(for verdict: ImageVerdict, on surface: SRGB) -> SRGB {
        ContrastRepair.repair(
            foreground: OKLCH(verdict.artwork),
            background: OKLCH(surface),
            requirement: plateTarget,
            moving: .background
        ).background.displayable
    }
}
