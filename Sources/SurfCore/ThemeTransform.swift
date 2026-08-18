import Foundation

/// What a colour is doing on the page, which decides how it may be changed.
///
/// This is the distinction that keeps a synthesised theme on-brand. Inverting
/// every colour uniformly is what makes automatic dark modes look wrong: it
/// treats a page's background and its brand red as the same kind of thing, and
/// they are not. One is the lighting; the other is the identity.
public enum ColorRole: String, CaseIterable, Sendable {
    /// Backgrounds, cards, borders — the lighting of the page.
    case surface
    /// Anything being read.
    case text
    /// Brand colour: buttons, links, badges, logotype. Preserved, not inverted.
    case accent
    /// A large background that carries brand — a coloured masthead or hero.
    ///
    /// Distinct from `accent` because scale changes what a colour does. A
    /// saturated blue reads as identity on a button and as a wall on a
    /// full-width header: keeping it at full chroma across half the viewport is
    /// fatiguing in dark mode, and inverting its hue would be worse. So it
    /// keeps its hue, moves into the surface band, and gives up most of its
    /// chroma — which is what hand-built dark themes do with a coloured bar.
    case brandSurface
}

/// Turns a page's palette into the other scheme's palette.
///
/// The whole engine rests on one property of OKLCH:
///
/// > **L is the theme axis. C and H are the identity axis.**
///
/// Light and dark are a journey along L. A brand colour is a position in
/// (C, H) that has to survive it. Surfaces and text travel; accents stay put
/// and are re-seated for contrast later, once there's a background to measure
/// them against.
public enum ThemeTransform {

    /// Above this chroma, a colour is carrying brand rather than lighting.
    ///
    /// Well clear of `OKLCH.neutralChroma`: the greys and near-greys that make
    /// up most of a page sit far below, while a real brand colour sits far
    /// above. The gap between the two is wide enough that the threshold isn't
    /// doing delicate work.
    public static let accentChroma = 0.05

    /// The most chroma a large brand surface keeps. Enough that a blue header
    /// is still blue, little enough that it stops shouting.
    public static let brandSurfaceChroma = 0.06

    /// Where a surface may sit in the target scheme.
    ///
    /// A band rather than a point, because a page has more than one surface —
    /// body behind card behind border — and collapsing them all onto a single
    /// value is what produces a flat, unreadable slab. The band is deliberately
    /// narrow at the dark end: the eye separates dark tones poorly, so surfaces
    /// that were crowded together in white need *more* room down here, not less.
    public static func surfaceBand(for target: ColorSchemeTarget) -> ClosedRange<Double> {
        switch target {
        case .dark: 0.06...0.46
        case .light: 0.55...1.0
        }
    }

    /// Remaps lightness for a surface.
    ///
    /// Piecewise, and the fold is the point. Light surfaces invert — that's the
    /// feature. Surfaces that were *already* dark stay dark rather than being
    /// flipped into brightness: a dark footer on a white page is dark because
    /// someone chose that, and turning it white in dark mode inverts a decision
    /// instead of translating it.
    public static func surfaceLightness(_ l: Double, target: ColorSchemeTarget) -> Double {
        let band = surfaceBand(for: target)
        switch target {
        case .dark:
            return l < 0.5
                ? scale(l, from: (0, 0.5), to: (band.lowerBound, band.upperBound))
                : scale(l, from: (0.5, 1), to: (band.upperBound, Perceptual.darkSurface))
        case .light:
            return l > 0.5
                ? scale(l, from: (0.5, 1), to: (band.lowerBound, band.upperBound))
                : scale(l, from: (0, 0.5), to: (Perceptual.lightSurface, band.lowerBound))
        }
    }

    /// Remaps lightness for text, with the same fold and a hard floor.
    ///
    /// The floor is what stops the output landing at the extremes. Black text
    /// comes back at `darkForeground`, not at white: maximum contrast is not the
    /// goal, and white on near-black blooms — halation — which is worse for
    /// astigmatic readers, a large minority rather than an edge case.
    public static func textLightness(_ l: Double, target: ColorSchemeTarget) -> Double {
        switch target {
        case .dark:
            return l > 0.5
                ? scale(l, from: (0.5, 1), to: (0.55, Perceptual.darkForeground))
                : scale(l, from: (0, 0.5), to: (Perceptual.darkForeground, 0.55))
        case .light:
            return l < 0.5
                ? scale(l, from: (0, 0.5), to: (Perceptual.lightForeground, 0.45))
                : scale(l, from: (0.5, 1), to: (0.45, Perceptual.lightForeground))
        }
    }

    /// Transforms one colour in the light of what it's doing.
    ///
    /// Hue is never touched, in any role. Chroma is never touched either — it's
    /// only ever reduced, and only by the gamut mapper, when the new lightness
    /// can't physically carry it.
    public static func transform(
        _ color: OKLCH, role: ColorRole, target: ColorSchemeTarget
    ) -> OKLCH {
        switch role {
        case .surface:
            OKLCH(l: surfaceLightness(color.l, target: target), c: color.c, h: color.h)
                .gamutMapped()
        case .text:
            OKLCH(l: textLightness(color.l, target: target), c: color.c, h: color.h)
                .gamutMapped()
        case .accent:
            // Left exactly as it is. A brand colour that needs moving gets
            // moved by the contrast repair, which knows what it sits on.
            color
        case .brandSurface:
            OKLCH(
                l: surfaceLightness(color.l, target: target),
                c: min(color.c, brandSurfaceChroma),
                h: color.h
            ).gamutMapped()
        }
    }

    /// Guesses a role from the colour alone.
    ///
    /// A fallback for when there's no context — a gradient stop, an unattached
    /// declaration. Where the caller knows what the colour is painting, it
    /// should say so: area and property are far better evidence than chroma,
    /// since the same hex is a surface on a hero and an accent on a badge.
    public static func inferredRole(_ color: OKLCH) -> ColorRole {
        color.c >= accentChroma ? .accent : .surface
    }

    // MARK: - Borders

    /// The most a border may separate from what it sits on.
    ///
    /// A black rule on white is the strongest line a designer can draw, and
    /// reproducing that separation literally in dark mode means a white
    /// hairline — which is harsher on a dark page than the original ever was on
    /// a light one. Emphasis is preserved up to here and compressed beyond it.
    public static let borderEmphasisCap = 0.45

    /// Remaps a border by how far it stood from its background.
    ///
    /// Borders are the one place the surface curve and the contrast repair pull
    /// in opposite directions, and both are wrong. The curve compresses
    /// everything into the surface band, so a black rule and a faint grey one
    /// end up a few percent apart. The repair then lifts whatever it is handed
    /// to the same minimum, so they come back identical — and a deliberately
    /// heavy divider arrives as the same hairline as a decorative one.
    ///
    /// What carries meaning in a border is not its colour but its *separation*
    /// from what it sits on. So that is what is preserved: the perceptual gap
    /// is measured against the original background and re-established against
    /// the new one, which keeps a strong rule strong and a faint one faint.
    ///
    /// Deliberately no minimum. WCAG asks 3:1 of a border that carries state or
    /// boundary information, not of every hairline on the page, and forcing a
    /// decorative 1.2:1 divider up to 3:1 doesn't rescue it — it promotes it
    /// over the content it was drawn to separate.
    public static func transformBorder(
        _ border: OKLCH, on backdrop: OKLCH, newBackdrop: OKLCH
    ) -> OKLCH {
        let separation = min(abs(border.l - backdrop.l), borderEmphasisCap)

        // Away from the background, on whichever side has the room. On a dark
        // page that means lighter, which is also how dark themes are drawn by
        // hand: a rule that reads is one lifted off the surface, not sunk into
        // it.
        let direction: Double = newBackdrop.l < 0.5 ? 1 : -1
        let lightness = min(max(newBackdrop.l + direction * separation, 0), 1)

        return OKLCH(l: lightness, c: border.c, h: border.h).gamutMapped()
    }

    // MARK: - Gradients

    /// Remaps a gradient's stops as one shape rather than one at a time.
    ///
    /// Transforming each stop independently is the obvious approach and it is
    /// wrong, because the surface curve *descends* across the light half: a
    /// gradient running from white to light-grey comes back with its stops in
    /// the opposite order. The gradient inverts. Every sense of depth the
    /// designer built — where the light falls, which edge lifts — reverses, and
    /// on a hero or a card that reads as broken rather than as dark.
    ///
    /// So the gradient is moved as a body. Its mean lightness is transformed,
    /// each stop keeps its signed distance from that mean, and the whole set is
    /// scaled just enough to sit inside the band. Direction, order, and relative
    /// spacing all survive; only the overall level moves.
    ///
    /// A gradient built from brand colours isn't remapped at all — see
    /// `isAccentGradient`.
    public static func transformGradient(
        _ stops: [OKLCH], target: ColorSchemeTarget
    ) -> [OKLCH] {
        guard !stops.isEmpty else { return stops }
        guard !isAccentGradient(stops) else { return stops }

        let lightnesses = stops.map(\.l)
        let mean = lightnesses.reduce(0, +) / Double(stops.count)
        let newMean = surfaceLightness(mean, target: target)
        let deltas = lightnesses.map { $0 - mean }

        // Fit the gradient into the band by *moving* it first and only
        // shrinking it if it still won't fit. Shrinking first is what collapses
        // a white-to-black gradient into a flat slab: its mean lands at the top
        // of the band with no headroom, so every stop scales to the same value
        // and the gradient disappears entirely.
        let band = surfaceBand(for: target)
        let reachDown = -(deltas.min() ?? 0)
        let reachUp = deltas.max() ?? 0
        let span = reachDown + reachUp
        let bandWidth = band.upperBound - band.lowerBound

        var center = newMean
        var scaleFactor = 1.0
        if span > bandWidth {
            // Wider than the band can hold: shrink, then sit it flush.
            scaleFactor = bandWidth / span
            center = band.lowerBound + reachDown * scaleFactor
        } else if span > 0 {
            // Fits at full contrast — just slide it far enough in.
            center = min(max(newMean, band.lowerBound + reachDown), band.upperBound - reachUp)
        }

        return zip(stops, deltas).map { stop, delta in
            OKLCH(l: center + delta * scaleFactor, c: stop.c, h: stop.h).gamutMapped()
        }
    }

    /// Whether a gradient is carrying brand rather than lighting.
    ///
    /// Judged on the mean chroma of its stops. A purple-to-coral hero is the
    /// site's identity and has to come through dark mode recognisably itself;
    /// a white-to-off-white panel is lighting and has to invert. Getting this
    /// backwards is the single most visible way a dark mode looks wrong.
    public static func isAccentGradient(_ stops: [OKLCH]) -> Bool {
        guard !stops.isEmpty else { return false }
        let meanChroma = stops.map(\.c).reduce(0, +) / Double(stops.count)
        return meanChroma >= accentChroma
    }

    // MARK: -

    /// Linear remap between two spans.
    ///
    /// Tuples rather than `ClosedRange`, because half of these remaps run
    /// *backwards* — that inversion is the entire feature — and a ClosedRange
    /// whose lower bound exceeds its upper is a runtime trap, not a range.
    private static func scale(
        _ value: Double, from source: (Double, Double), to target: (Double, Double)
    ) -> Double {
        let span = source.1 - source.0
        guard span != 0 else { return target.0 }
        let t = (value - source.0) / span
        return target.0 + t * (target.1 - target.0)
    }
}
