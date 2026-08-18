import Testing

@testable import SurfCore

private func color(_ hex: String) -> CSSColor { CSSColor(css: hex)! }

@Suite("Role classification")
struct RoleClassifierTests {

    @Test("The property settles it before anything else is measured")
    func propertyFirst() {
        #expect(RoleClassifier.role(for: .init(color: color("#ffffff"), property: .background))
            == .surface)
        #expect(RoleClassifier.role(for: .init(color: color("#333333"), property: .text))
            == .text)
        // Structure, not prose — and neutral, so it moves with the lighting.
        #expect(RoleClassifier.role(for: .init(color: color("#e5e5e5"), property: .border))
            == .surface)
    }

    @Test("Scale decides whether a coloured background is identity or lighting")
    func areaSeparatesBadgeFromMasthead() {
        // The same blue, twice. On a badge it's the brand and is preserved; as
        // a masthead across the page it's a wall and has to come down.
        let badge = ColorObservation(
            color: color("#1d9bf0"), property: .background, areaFraction: 0.01)
        let masthead = ColorObservation(
            color: color("#1d9bf0"), property: .background, areaFraction: 0.4)
        #expect(RoleClassifier.role(for: badge) == .accent)
        #expect(RoleClassifier.role(for: masthead) == .brandSurface)
    }

    @Test("A button stays a button however large it is")
    func interactiveWinsOverArea() {
        let hugeButton = ColorObservation(
            color: color("#635bff"), property: .background,
            areaFraction: 0.6, isInteractive: true)
        #expect(RoleClassifier.role(for: hugeButton) == .accent)
    }

    @Test("Coloured prose is a brand colour, not text")
    func chromaticTextIsAccent() {
        // Link blue. Inverting it would make it orange, which is the single
        // most obvious way an automatic dark mode announces itself.
        #expect(RoleClassifier.role(for: .init(color: color("#1d9bf0"), property: .text))
            == .accent)
        #expect(RoleClassifier.role(for: .init(color: color("#0a0a0a"), property: .text))
            == .text)
    }

    @Test("A near-neutral tint is still lighting")
    func faintTintsAreSurfaces() {
        #expect(RoleClassifier.role(
            for: .init(color: color("#f8f9fa"), property: .background, areaFraction: 0.9))
            == .surface)
    }
}

@Suite("Theme plan")
struct ThemePlanTests {

    /// A small but realistic light page.
    private var page: [ColorObservation] {
        [
            .init(color: color("#ffffff"), property: .background, areaFraction: 0.95),
            .init(color: color("#f8f9fa"), property: .background, areaFraction: 0.2),
            .init(color: color("#212529"), property: .text, areaFraction: 0.3),
            .init(color: color("#6c757d"), property: .text, areaFraction: 0.05),
            .init(color: color("#1d9bf0"), property: .text, areaFraction: 0.02),
            .init(color: color("#dee2e6"), property: .border, areaFraction: 0.01),
            .init(color: color("#635bff"), property: .background,
                  areaFraction: 0.02, isInteractive: true),
        ]
    }

    @Test("The page comes back dark")
    func pageGoesDark() {
        let plan = ThemePlan.build(from: page, target: .dark)
        #expect(OKLCH(plan.pageBackground.rgb).l < 0.25)
        #expect(!plan.isEmpty)
    }

    @Test("Everything meant to be read is legible on the new ground")
    func readableColorsAreLegible() {
        // The plan-level guarantee: not that the maths is right in isolation,
        // but that what actually lands on the page can be read.
        let plan = ThemePlan.build(from: page, target: .dark)
        for observation in page where !observation.property.isBackground {
            guard let replacement = plan.replacements[observation.key],
                  let parsed = CSSColor(css: replacement)
            else { continue }
            let requirement: Contrast.Requirement = observation.isLargeText
                ? .largeText : observation.property.requirement
            #expect(Contrast.isLegible(
                requirement,
                foreground: parsed.rgb,
                background: plan.pageBackground.rgb
            ))
        }
    }

    @Test("The brand link keeps its hue")
    func brandHuePreserved() {
        let plan = ThemePlan.build(from: page, target: .dark)
        let key = ColorObservation(color: color("#1d9bf0"), property: .text).key
        let replacement = CSSColor(css: plan.replacements[key] ?? "#1d9bf0")!
        #expect(abs(OKLCH(replacement.rgb).h - OKLCH(color("#1d9bf0").rgb).h) < 0.5)
    }

    @Test("A colour maps to one answer wherever it appears")
    func consistentMapping() {
        // Two sightings of the same grey, different sizes. The page must not
        // come back subtly striped because one instance was judged differently.
        let observations: [ColorObservation] = [
            .init(color: color("#ffffff"), property: .background, areaFraction: 0.9),
            .init(color: color("#888888"), property: .text, areaFraction: 0.3),
            .init(color: color("#888888"), property: .text, areaFraction: 0.01),
        ]
        let plan = ThemePlan.build(from: observations, target: .dark)
        let keys = plan.replacements.keys.filter { $0.hasPrefix("text|") }
        #expect(keys.count == 1)
    }

    @Test("Alpha rides through untouched")
    func alphaPreserved() {
        let translucent = CSSColor(css: "rgb(0 0 0 / 0.5)")!
        let plan = ThemePlan.build(
            from: [
                .init(color: color("#ffffff"), property: .background, areaFraction: 0.9),
                .init(color: translucent, property: .text, areaFraction: 0.1),
            ],
            target: .dark
        )
        let key = ColorObservation(color: translucent, property: .text).key
        #expect(CSSColor(css: plan.replacements[key] ?? "")?.alpha == 0.5)
    }

    @Test("Colours that don't move aren't written down")
    func unchangedColorsOmitted() {
        // A brand button is preserved outright, so there is nothing to say
        // about it. Emitting a rule that restates a colour is not harmless: it
        // is a declaration injected over the author's, at higher specificity,
        // that has to keep being right as the page changes underneath it.
        let button = ColorObservation(
            color: color("#635bff"), property: .background,
            areaFraction: 0.02, isInteractive: true)
        let plan = ThemePlan.build(
            from: [
                .init(color: color("#ffffff"), property: .background, areaFraction: 0.95),
                button,
            ],
            target: .dark
        )
        #expect(RoleClassifier.role(for: button) == .accent)
        #expect(plan.replacements[button.key] == nil)
        // The page background still moved, so the plan isn't empty.
        #expect(!plan.isEmpty)
    }

    @Test("A label is judged against the button it sits on, not the page")
    func repairsAgainstOwnBackdrop() {
        // White text on a preserved brand button. Repairing it against the dark
        // page would leave it near-white on purple — comfortably legible on the
        // page it never touches, and short of AA on the thing it's actually on.
        let button = color("#635bff")
        let plan = ThemePlan.build(
            from: [
                .init(color: color("#ffffff"), property: .background, areaFraction: 0.95),
                .init(color: button, property: .background,
                      areaFraction: 0.02, isInteractive: true),
                .init(color: color("#ffffff"), property: .text,
                      areaFraction: 0.01, backdrop: button),
            ],
            target: .dark
        )
        // The button itself is brand, so it is preserved and stays the ground.
        #expect(plan.replacements[
            ColorObservation(color: button, property: .background).key] == nil)

        let key = ColorObservation(color: color("#ffffff"), property: .text).key
        let label = CSSColor(css: plan.replacements[key] ?? "#ffffff")!
        #expect(Contrast.isLegible(.normalText, foreground: label.rgb, background: button.rgb))
    }

    @Test("The plan is keyed by the page's own spelling, not ours")
    func keyedBySource() {
        // The page looks its replacements up with whatever getComputedStyle
        // returns, which is rgb(255, 255, 255) and never #ffffff. Keying on our
        // normalised form yields a plan where every entry is correct and every
        // lookup misses — a failure invisible to any test that builds the key
        // and reads it back through the same function.
        let observations: [ColorObservation] = [
            .init(color: color("#ffffff"), property: .background,
                  areaFraction: 0.9, source: "rgb(255, 255, 255)"),
            .init(color: color("#111827"), property: .text,
                  areaFraction: 0.2, source: "rgb(17, 24, 39)"),
        ]
        let plan = ThemePlan.build(from: observations, target: .dark)
        #expect(plan.replacements["text|rgb(17, 24, 39)"] != nil)
        #expect(plan.replacements["background|rgb(255, 255, 255)"] != nil)
        #expect(plan.replacements["text|#111827"] == nil)
    }

    @Test("A second pass keeps the ground the first one settled on")
    func incrementalKeepsGround() {
        // A sweep over an already-themed page sees only what it hasn't touched,
        // which is panels rather than the page. Re-deriving the ground from
        // that set repaints the whole document with whatever happens to be
        // largest — on stripe.com that was a blue panel, and the page went blue.
        let established = color("#0d0d0d")
        let panel = ColorObservation(
            color: color("#635bff"), property: .background, areaFraction: 0.6)

        let second = ThemePlan.build(
            from: [panel], target: .dark, establishedGround: established)
        #expect(second.pageBackground == established)

        // Without a ground to honour, the same input really would have moved it.
        let first = ThemePlan.build(from: [panel], target: .dark)
        #expect(first.pageBackground != established)
    }

    @Test("A chromatic page background keeps its hue but not its intensity")
    func chromaticGroundCalmed() {
        // Held at full chroma across an entire document, a brand colour stops
        // being a brand and becomes a glare.
        let plan = ThemePlan.build(
            from: [.init(color: color("#635bff"), property: .background, areaFraction: 0.9)],
            target: .dark
        )
        let ground = OKLCH(plan.pageBackground.rgb)
        let original = OKLCH(color("#635bff").rgb)
        #expect(abs(ground.h - original.h) < 1.0)
        #expect(ground.c <= ThemeTransform.brandSurfaceChroma + 1e-9)
        #expect(ground.c < original.c)
        #expect(ground.l < 0.5)
    }

    @Test("An empty page yields an empty plan, not a crash")
    func emptyInput() {
        let plan = ThemePlan.build(from: [], target: .dark)
        #expect(plan.isEmpty)
        // ...but still a usable ground colour to paint with.
        #expect(OKLCH(plan.pageBackground.rgb).l < 0.25)
    }

    @Test("The masthead keeps its hue but loses the shouting")
    func brandSurfaceCalmed() {
        let masthead = ColorObservation(
            color: color("#1d9bf0"), property: .background, areaFraction: 0.4)
        let plan = ThemePlan.build(
            from: [
                .init(color: color("#ffffff"), property: .background, areaFraction: 0.9),
                masthead,
            ],
            target: .dark
        )
        let replacement = CSSColor(css: plan.replacements[masthead.key]!)!
        let before = OKLCH(color("#1d9bf0").rgb)
        let after = OKLCH(replacement.rgb)
        #expect(abs(after.h - before.h) < 1.0)   // still blue
        #expect(after.c < before.c)              // but calmer
        #expect(after.l < 0.5)                   // and dark
    }
}

@Suite("Scheme decision")
struct SchemeDecisionTests {

    @Test("A declared, opaque background is used as written")
    func declaredWins() {
        let ground = SchemeDecision.decisionGround(
            declared: "rgb(248, 249, 250)",
            observations: [.init(color: color("#ff0000"), property: .background, areaFraction: 1)]
        )
        #expect(ground?.rgb.hex == "#f8f9fa")
    }

    @Test("A transparent declaration falls through to what the page paints")
    func transparentFallsThrough() {
        // Both bugs this logic caused start here. Read literally, transparent
        // parses as black and looks dark; assumed white, it looks light. Only
        // what the page actually painted settles it.
        let ground = SchemeDecision.decisionGround(
            declared: "rgba(0, 0, 0, 0)",
            observations: [
                .init(color: color("#f6f6ef"), property: .background, areaFraction: 0.8),
                .init(color: color("#ff6600"), property: .background, areaFraction: 0.05),
            ]
        )
        #expect(ground?.rgb.hex == "#f6f6ef")
    }

    @Test("A page that has painted nothing gives no answer, rather than a guess")
    func nothingPaintedYet() {
        #expect(SchemeDecision.decisionGround(declared: nil, observations: []) == nil)
        #expect(SchemeDecision.decisionGround(declared: "", observations: []) == nil)
        #expect(SchemeDecision.decisionGround(declared: "rgba(0, 0, 0, 0)", observations: []) == nil)
        // Text alone is not a ground — only backgrounds are.
        #expect(SchemeDecision.decisionGround(
            declared: "rgba(0, 0, 0, 0)",
            observations: [.init(color: color("#333333"), property: .text, areaFraction: 0.9)]
        ) == nil)
    }

    @Test("A site already in the requested scheme is left alone")
    func alreadySatisfied() {
        // GitHub's ground, which was being restyled despite having a perfectly
        // good dark mode of its own.
        #expect(SchemeDecision.alreadySatisfies(.dark, ground: color("#0d1117")))
        #expect(SchemeDecision.alreadySatisfies(.light, ground: color("#ffffff")))
        // ...and a light page under a dark target is not.
        #expect(!SchemeDecision.alreadySatisfies(.dark, ground: color("#ffffff")))
        #expect(!SchemeDecision.alreadySatisfies(.light, ground: color("#0d1117")))
    }

    @Test("Transparent read as a colour would have said 'already dark'")
    func theTrapItself() {
        // Pinning the trap: rgba(0,0,0,0) parses to black, and black satisfies
        // dark. Anything that lets a transparent declaration reach this
        // function has already lost.
        let transparent = CSSColor(css: "rgba(0, 0, 0, 0)")!
        #expect(SchemeDecision.alreadySatisfies(.dark, ground: transparent))
        // Which is exactly why decisionGround refuses to return it.
        #expect(SchemeDecision.decisionGround(
            declared: "rgba(0, 0, 0, 0)", observations: []) == nil)
    }
}

@Suite("Masked ink")
struct MaskedInkTests {

    @Test("A masked background is a glyph, not a surface")
    func maskedIsInk() {
        // Wikipedia's toolbar icons: one sprite masked to shape, coloured by
        // background-color. Judged as a surface, the rule that keeps dark
        // surfaces dark leaves them invisible on a dark page.
        let icon = ColorObservation(color: color("#404244"), property: .maskedInk)
        let panel = ColorObservation(color: color("#404244"), property: .background)
        #expect(RoleClassifier.role(for: icon) == .text)
        #expect(RoleClassifier.role(for: panel) == .surface)
    }

    @Test("A dark icon comes back light, where a dark surface stays dark")
    func maskedInkInverts() {
        let observations: [ColorObservation] = [
            .init(color: color("#ffffff"), property: .background, areaFraction: 0.95),
            .init(color: color("#404244"), property: .maskedInk,
                  areaFraction: 0.001, backdrop: color("#ffffff")),
        ]
        let plan = ThemePlan.build(from: observations, target: .dark)
        let key = ColorObservation(color: color("#404244"), property: .maskedInk).key
        let result = CSSColor(css: plan.replacements[key] ?? "#404244")!
        #expect(OKLCH(result.rgb).l > 0.6)
        #expect(Contrast.isLegible(.nonText,
                                   foreground: result.rgb,
                                   background: plan.pageBackground.rgb))
    }

    @Test("The same colour used both ways doesn't collapse into one answer")
    func inkAndSurfaceStaySeparate() {
        let shared = color("#404244")
        let plan = ThemePlan.build(
            from: [
                .init(color: color("#ffffff"), property: .background, areaFraction: 0.95),
                .init(color: shared, property: .background, areaFraction: 0.3),
                .init(color: shared, property: .maskedInk,
                      areaFraction: 0.001, backdrop: color("#ffffff")),
            ],
            target: .dark
        )
        let inkKey = ColorObservation(color: shared, property: .maskedInk).key
        let surfaceKey = ColorObservation(color: shared, property: .background).key
        let ink = CSSColor(css: plan.replacements[inkKey] ?? "#404244")!
        let surface = CSSColor(css: plan.replacements[surfaceKey] ?? "#404244")!
        // The ink lands well clear of the surface — measured at about 0.28 of
        // perceptual lightness apart, which is the difference between a visible
        // icon and one lost against the panel behind it.
        #expect(OKLCH(ink.rgb).l > OKLCH(surface.rgb).l + 0.2)
    }
}
