import Foundation

/// WCAG 2.2 contrast, plus the extra constraint dark themes need.
///
/// The ratio below is the number every audit, every browser inspector, and
/// every accessibility bug report is written against, so it's the hard
/// constraint here. But it has a known weakness sitting exactly where this
/// feature lives.
///
/// The ratio is computed from luminance, which is close to linear in emitted
/// light, while the eye is closer to its cube root. At the dark end that gap is
/// wide: a pair can differ by the required 4.5x in luminance while barely
/// separating in perceived lightness. Searching the space finds it — the worst
/// passing pairs are saturated and nearly equiluminant, like `#0300f9` text on
/// `#16d724`, which clears 4.5:1 and is close to unreadable.
///
/// Greys never hit this: at 4.5:1 their perceptual separation bottoms out
/// around 0.37, well clear of the floor below. It is specifically chromatic
/// pairs the ratio flatters, and a theme that preserves a site's brand colours
/// generates chromatic pairs on purpose.
///
/// The answer here is not to swap in a different metric. APCA is the usual
/// suggestion and it is not normative anywhere — the March 2026 WCAG 3 draft
/// mentions neither APCA nor Lc — and it ships with patents pending and a
/// right-to-audit clause. So: keep the ratio as the floor, and add a second,
/// unencumbered constraint in Oklab (`Perceptual` below) that catches what the
/// ratio misses. Two constraints, both cheap, and strictly stricter than the
/// ratio alone — so nothing here can cause a WCAG 2 regression.
public enum Contrast {

    /// WCAG relative luminance.
    ///
    /// The 0.04045 threshold is current; 0.03928 appears in older copies of the
    /// spec and in a lot of shipped colour libraries. They agree to about 1e-5,
    /// so it changes nothing numerically — this just uses the one that's
    /// normative today.
    public static func relativeLuminance(_ rgb: SRGB) -> Double {
        let c = rgb.clamped
        return 0.2126 * OKLCH.linearized(c.r)
            + 0.7152 * OKLCH.linearized(c.g)
            + 0.0722 * OKLCH.linearized(c.b)
    }

    /// The ratio between two colours, 1...21. Order doesn't matter.
    public static func ratio(_ a: SRGB, _ b: SRGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// What a given piece of content owes.
    public enum Requirement: String, CaseIterable, Sendable {
        /// Body text. WCAG 1.4.3 AA.
        case normalText
        /// 18pt, or 14pt bold — about 24px and 18.5px respectively.
        case largeText
        /// Borders, icons, focus rings, and control boundaries. WCAG 1.4.11 AA.
        case nonText

        public var minimumRatio: Double {
            switch self {
            case .normalText: 4.5
            case .largeText, .nonText: 3
            }
        }

        /// How far apart the two colours must sit in Oklab lightness, on top of
        /// the ratio.
        ///
        /// Calibrated against the space rather than picked: sampling pairs that
        /// already clear the ratio, a 0.32 floor turns away 0.01% of them — the
        /// equiluminant chromatic ones described above — while leaving every
        /// grey pair alone. A floor of 0.38, which looks just as reasonable
        /// written down, rejects 15% of legitimately readable pairs.
        public var minimumLightnessDelta: Double {
            switch self {
            case .normalText: 0.32
            case .largeText, .nonText: 0.22
            }
        }
    }

    public static func meetsRatio(
        _ requirement: Requirement, foreground: SRGB, background: SRGB
    ) -> Bool {
        ratio(foreground, background) >= requirement.minimumRatio
    }

    /// Both constraints. This is what the transform actually has to satisfy.
    public static func isLegible(
        _ requirement: Requirement, foreground: SRGB, background: SRGB
    ) -> Bool {
        guard meetsRatio(requirement, foreground: foreground, background: background) else {
            return false
        }
        let delta = abs(OKLCH(foreground).l - OKLCH(background).l)
        return delta >= requirement.minimumLightnessDelta
    }
}

/// The perceptual bounds a synthesised theme keeps its colours inside.
///
/// These are the difference between a dark theme and an inverted page. Pure
/// white text on pure black is the most contrasty pair available and one of the
/// least comfortable to read: the glyphs bloom into the background — halation —
/// and the effect is worse for astigmatic readers, who are a large minority
/// rather than an edge case. Maximum contrast is not the goal; sufficient
/// contrast, comfortably delivered, is.
public enum Perceptual {

    /// How dark a synthesised background is allowed to go, and how light a
    /// synthesised foreground is allowed to come back.
    ///
    /// White lands on `darkSurface` rather than on 0, and black on
    /// `darkForeground` rather than on 1. That pair is worth ~15:1 — comfortably
    /// past AA, short of the searing extreme.
    public static let darkSurface = 0.16
    public static let darkForeground = 0.92

    /// The same two bounds for the other direction, forcing a light theme onto
    /// a dark-only site.
    public static let lightSurface = 0.98
    public static let lightForeground = 0.20

    /// Bounds for a target, as (surface, foreground).
    public static func bounds(for target: ColorSchemeTarget) -> (surface: Double, foreground: Double) {
        switch target {
        case .dark: (darkSurface, darkForeground)
        case .light: (lightSurface, lightForeground)
        }
    }
}
