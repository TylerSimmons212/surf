import Foundation

/// A colour in OKLCH: perceptual lightness, chroma, and hue.
///
/// The whole theme engine is built on this space rather than HSL, and the
/// reason is that HSL's "lightness" isn't lightness. HSL 50% yellow and HSL 50%
/// blue differ by roughly 3× in the light they actually emit, so inverting that
/// number damages contrast by an amount that depends on hue — which is exactly
/// the bug you can't debug, because it looks fine on the page you tested.
///
/// Oklab is built so equal steps look equal. That buys the one property the
/// feature turns on:
///
/// > **L is the theme axis. C and H are the identity axis.**
///
/// Light and dark are a move along L. A brand colour is a point in (C, H) that
/// has to survive the trip. Keeping them on separate axes is what lets a red
/// button come back red instead of pink, and never cyan.
public struct OKLCH: Equatable, Sendable {
    /// Perceptual lightness, 0 (black) to 1 (white).
    public var l: Double
    /// Distance from grey. 0 is neutral; sRGB tops out near 0.32.
    public var c: Double
    /// Hue angle in degrees, 0..<360.
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h.truncatingRemainder(dividingBy: 360) < 0
            ? h.truncatingRemainder(dividingBy: 360) + 360
            : h.truncatingRemainder(dividingBy: 360)
    }

    /// Below this, hue is meaningless and shouldn't be trusted or preserved.
    ///
    /// Greys arrive with whatever hue rounding left behind, and carrying that
    /// into a transform tints the surfaces of a site that never had a tint.
    public static let neutralChroma = 0.02

    public var isNeutral: Bool { c < Self.neutralChroma }
}

// MARK: - Conversion

extension OKLCH {

    /// sRGB → OKLCH.
    public init(_ rgb: SRGB) {
        // Undo the sRGB transfer function. This is the same curve WCAG uses to
        // linearise, and for the same reason: the stored number is not the
        // light.
        let lr = OKLCH.linearized(rgb.r)
        let lg = OKLCH.linearized(rgb.g)
        let lb = OKLCH.linearized(rgb.b)

        // Linear sRGB → LMS (cone response), then a cube root. The cube root is
        // where the perceptual uniformity comes from.
        let l_ = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m_ = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s_ = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)

        let okL = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let okA = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let okB = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

        let chroma = (okA * okA + okB * okB).squareRoot()
        // atan2 gives (-180, 180]; the initialiser normalises into [0, 360).
        let hue = chroma < 1e-9 ? 0 : atan2(okB, okA) * 180 / .pi

        self.init(l: okL, c: chroma, h: hue)
    }

    /// OKLCH → sRGB. May land outside the cube; see `gamutMapped`.
    public var rgb: SRGB {
        let radians = h * .pi / 180
        let okA = c * cos(radians)
        let okB = c * sin(radians)

        let l_ = l + 0.3963377774 * okA + 0.2158037573 * okB
        let m_ = l - 0.1055613458 * okA - 0.0638541728 * okB
        let s_ = l - 0.0894841775 * okA - 1.2914855480 * okB

        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        return SRGB(
            r: OKLCH.delinearized(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            g: OKLCH.delinearized(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            b: OKLCH.delinearized(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
        )
    }

    /// The sRGB transfer function, and its inverse.
    ///
    /// The linear segment near zero isn't decoration — a pure power curve has
    /// an infinite slope at black, which is numerically hostile exactly where
    /// dark themes spend all their time.
    static func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func delinearized(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }
}

// MARK: - Gamut

extension OKLCH {

    /// The nearest displayable colour **at the same hue**.
    ///
    /// This is the step that makes brand preservation honest. Holding chroma
    /// while moving lightness routinely lands outside sRGB, and the obvious fix
    /// — clamping each channel — is the one thing we can't do: clipping
    /// channels independently swings the hue, which is the exact property the
    /// whole design promises to keep. A clipped saturated blue comes back
    /// visibly purple.
    ///
    /// So hue is held fixed and chroma is walked down until the colour fits,
    /// which is the direction the eye forgives. Lightness is held too: it
    /// carries the contrast guarantee, and trading it away here would quietly
    /// undo the repair pass.
    public func gamutMapped() -> OKLCH {
        var mapped = self
        mapped.l = min(max(l, 0), 1)

        if mapped.rgb.isInGamut { return mapped }

        // At the extremes of lightness only grey is representable, so there is
        // nothing to search for.
        guard mapped.l > 0, mapped.l < 1 else { return OKLCH(l: mapped.l, c: 0, h: h) }

        // Bisection on chroma. The in-gamut set along this line is contiguous
        // from c = 0, so the invariant "low fits, high doesn't" always holds.
        var low = 0.0
        var high = mapped.c
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if OKLCH(l: mapped.l, c: mid, h: h).rgb.isInGamut { low = mid } else { high = mid }
        }
        return OKLCH(l: mapped.l, c: low, h: h)
    }

    /// The most chroma this hue and lightness can carry in sRGB.
    ///
    /// Needed when a brand colour can't reach the contrast it owes: the choice
    /// is between giving up saturation and giving up the hue, and knowing the
    /// ceiling is what makes that a decision rather than a guess.
    public var maxChromaInGamut: Double {
        OKLCH(l: l, c: 0.5, h: h).gamutMapped().c
    }

    /// Convenience for the common "displayable colour, please" case.
    public var displayable: SRGB { gamutMapped().rgb.clamped }
}
