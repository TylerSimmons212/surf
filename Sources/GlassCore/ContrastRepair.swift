import Foundation

/// Re-seats a colour against the background it ends up on.
///
/// The transform moves surfaces and text but deliberately leaves accents where
/// they are, because a brand colour is identity rather than lighting. That
/// leaves a gap: a brand colour chosen to sit on white may be unreadable on the
/// charcoal that white became. Nobody picked that pairing — it's an artefact of
/// the theme change — so something has to reconcile it.
///
/// This is that step, and the order it tries things in is the whole design:
///
/// 1. **Move lightness.** Hue and chroma are untouched, so the colour is still
///    recognisably itself. This is enough almost every time.
/// 2. **Give up chroma.** Only when no lightness at that saturation can reach
///    the requirement. The colour desaturates toward its own hue rather than
///    drifting to a different one.
/// 3. **Move the background instead.** Chosen by the caller, and often the
///    right answer for a brand element: darkening the plate behind a logo
///    preserves it perfectly, where altering the logo does not.
///
/// Hue is never changed at any stage. A red button that cannot meet contrast
/// becomes a lighter red, then a duller red, and never an orange one.
public enum ContrastRepair {

    /// Which of the two colours is allowed to move.
    public enum Side: String, CaseIterable, Sendable {
        case foreground
        case background
    }

    public struct Outcome: Equatable, Sendable {
        public var foreground: OKLCH
        public var background: OKLCH
        /// Whether the pair satisfies both of `Contrast`'s constraints.
        public var isLegible: Bool
        /// Chroma surrendered to get there. Zero means the brand came through
        /// untouched, which is the outcome worth reporting on.
        public var chromaLost: Double
    }

    /// How finely lightness is searched. 0.002 is about half a step of an 8-bit
    /// channel — finer than the output can represent, so the answer is the
    /// smallest move that exists rather than the smallest the loop happened to
    /// land on.
    private static let step = 0.002

    /// The ladder of chroma retained before the search gives up on saturation.
    /// Ends at zero because a neutral can always reach black or white, which is
    /// what makes the guarantee below total.
    private static let chromaLadder = [1.0, 0.85, 0.7, 0.55, 0.4, 0.25, 0.1, 0.0]

    /// Brings a pair up to the requirement, moving one side.
    ///
    /// Always returns a usable pair. When even a neutral can't satisfy both
    /// constraints — possible only for `background` colours in the middle of the
    /// lightness range, where nothing contrasts adequately — it returns the best
    /// available pairing with `isLegible` false, so the caller can decide to move
    /// the other side rather than being handed a silent failure.
    public static func repair(
        foreground: OKLCH,
        background: OKLCH,
        requirement: Contrast.Requirement = .normalText,
        moving side: Side = .foreground
    ) -> Outcome {
        let fixed = (side == .foreground ? background : foreground).displayable
        let movable = side == .foreground ? foreground : background

        if Contrast.isLegible(requirement, foreground: foreground.displayable,
                              background: background.displayable) {
            return outcome(moved: movable, side: side, other: side == .foreground
                ? background : foreground, original: movable, isLegible: true)
        }

        for factor in chromaLadder {
            let candidate = OKLCH(l: movable.l, c: movable.c * factor, h: movable.h)
            guard let solved = nearestLightness(
                for: candidate, against: fixed, requirement: requirement,
                preferBrighterThan: fixed
            ) else { continue }
            return outcome(moved: solved, side: side, other: side == .foreground
                ? background : foreground, original: movable, isLegible: true)
        }

        // Nothing at this hue reaches the requirement. Hand back whichever
        // extreme separates them most, and say so.
        let best = maximisingContrast(hue: movable.h, against: fixed)
        return outcome(moved: best, side: side, other: side == .foreground
            ? background : foreground, original: movable, isLegible: false)
    }

    /// Repairs a pair, preferring to move the background when the foreground is
    /// carrying the brand.
    ///
    /// Tries the foreground first anyway — a small lightness nudge that costs no
    /// chroma is better than repainting a surface. Falls back to moving the
    /// background when the foreground would have to surrender saturation, which
    /// is exactly the "darken the plate rather than ruin the logo" case.
    public static func repairPreservingBrand(
        brand: OKLCH,
        background: OKLCH,
        requirement: Contrast.Requirement = .normalText,
        chromaBudget: Double = 0.02
    ) -> Outcome {
        let movingForeground = repair(
            foreground: brand, background: background,
            requirement: requirement, moving: .foreground
        )
        if movingForeground.isLegible, movingForeground.chromaLost <= chromaBudget {
            return movingForeground
        }

        let movingBackground = repair(
            foreground: brand, background: background,
            requirement: requirement, moving: .background
        )
        // Only prefer it if it actually worked and kept the brand whole.
        if movingBackground.isLegible, movingBackground.foreground == brand {
            return movingBackground
        }
        return movingForeground
    }

    // MARK: -

    /// The closest lightness to the colour's own that satisfies the requirement.
    ///
    /// Walks outward from where the colour already is, so the result is the
    /// smallest change that works rather than a jump to an extreme. The side to
    /// try first is whichever leads away from the fixed colour — on a dark
    /// surface that means going lighter, which is also what reads best.
    private static func nearestLightness(
        for color: OKLCH,
        against fixed: SRGB,
        requirement: Contrast.Requirement,
        preferBrighterThan reference: SRGB
    ) -> OKLCH? {
        let goUpFirst = color.l >= OKLCH(reference).l
        var offset = 0.0
        while offset <= 1.0 {
            let candidates = goUpFirst
                ? [color.l + offset, color.l - offset]
                : [color.l - offset, color.l + offset]
            for lightness in candidates where (0...1).contains(lightness) {
                let trial = OKLCH(l: lightness, c: color.c, h: color.h)
                if Contrast.isLegible(requirement, foreground: trial.displayable,
                                      background: fixed) {
                    return trial.gamutMapped()
                }
            }
            offset += step
        }
        return nil
    }

    /// The neutral at this hue that sits furthest from the fixed colour.
    private static func maximisingContrast(hue: Double, against fixed: SRGB) -> OKLCH {
        let dark = OKLCH(l: 0, c: 0, h: hue)
        let light = OKLCH(l: 1, c: 0, h: hue)
        return Contrast.ratio(dark.displayable, fixed) >= Contrast.ratio(light.displayable, fixed)
            ? dark : light
    }

    private static func outcome(
        moved: OKLCH, side: Side, other: OKLCH, original: OKLCH, isLegible: Bool
    ) -> Outcome {
        Outcome(
            foreground: side == .foreground ? moved : other,
            background: side == .foreground ? other : moved,
            isLegible: isLegible,
            chromaLost: max(0, original.c - moved.c)
        )
    }
}
