import Testing

@testable import GlassCore

private let palette: [OKLCH] = [
    "#000000", "#ffffff", "#808080", "#1a1a1a", "#f7f7f7", "#767676",
    "#ff0000", "#0000ff", "#00ff00", "#ffd700",
    "#1db954", "#635bff", "#ff5a5f", "#1d9bf0", "#4b2e83", "#0a0e27",
].map { OKLCH(SRGB(hex: $0)!) }

@Suite("Contrast repair")
struct ContrastRepairTests {

    @Test("A pair that already reads is left exactly alone")
    func noopWhenLegible() {
        let text = OKLCH(SRGB(hex: "#ffffff")!)
        let surface = OKLCH(SRGB(hex: "#1a1a1a")!)
        let result = ContrastRepair.repair(foreground: text, background: surface)
        #expect(result.isLegible)
        #expect(result.foreground == text)
        #expect(result.background == surface)
        #expect(result.chromaLost == 0)
    }

    @Test("Every repaired pair reads — the guarantee, enforced")
    func alwaysReachesLegibility() {
        // The accessibility promise of the whole feature, asserted over the
        // product of the palette rather than on a chosen example.
        for foreground in palette {
            for background in palette {
                for requirement in Contrast.Requirement.allCases {
                    for side in ContrastRepair.Side.allCases {
                        let result = ContrastRepair.repair(
                            foreground: foreground, background: background,
                            requirement: requirement, moving: side
                        )
                        #expect(result.isLegible)
                        #expect(Contrast.isLegible(
                            requirement,
                            foreground: result.foreground.displayable,
                            background: result.background.displayable
                        ))
                    }
                }
            }
        }
    }

    @Test("Hue never moves, whatever it costs")
    func hueIsSacred() {
        // A red that can't meet contrast becomes a lighter red, then a duller
        // red — never an orange one. This is the promise that keeps a
        // synthesised theme on-brand.
        for foreground in palette {
            for background in palette {
                let result = ContrastRepair.repair(
                    foreground: foreground, background: background
                )
                #expect(result.foreground.h == foreground.h)
                #expect(result.background.h == background.h)
            }
        }
    }

    @Test("Chroma is only ever given up, never invented")
    func chromaNeverIncreases() {
        for foreground in palette {
            for background in palette {
                let result = ContrastRepair.repair(
                    foreground: foreground, background: background
                )
                #expect(result.foreground.c <= foreground.c + 1e-9)
                #expect(result.chromaLost >= 0)
            }
        }
    }

    @Test("It moves as little as it can get away with")
    func minimalMovement() {
        // A pair that just misses should be nudged, not thrown to an extreme.
        let surface = OKLCH(SRGB(hex: "#1a1a1a")!)
        let dim = OKLCH(SRGB(hex: "#565656")!)
        #expect(!Contrast.isLegible(.normalText, foreground: dim.displayable,
                                    background: surface.displayable))
        let result = ContrastRepair.repair(foreground: dim, background: surface)
        #expect(result.isLegible)
        // Moved upward, and nowhere near white.
        #expect(result.foreground.l > dim.l)
        #expect(result.foreground.l < 0.85)
    }

    @Test("On a dark surface, text is pushed lighter rather than darker")
    func directionFollowsTheSurface() {
        let surface = OKLCH(SRGB(hex: "#141414")!)
        let mid = OKLCH(SRGB(hex: "#4a4a4a")!)
        let result = ContrastRepair.repair(foreground: mid, background: surface)
        #expect(result.foreground.l > mid.l)
    }

    @Test("A brand colour survives being re-seated on the new surface")
    func brandSurvives() {
        // Stripe purple against the charcoal that white became. It has to end
        // up readable and still recognisably purple.
        let brand = OKLCH(SRGB(hex: "#635bff")!)
        let surface = OKLCH(l: Perceptual.darkSurface, c: 0, h: 0)
        let result = ContrastRepair.repair(foreground: brand, background: surface)
        #expect(result.isLegible)
        #expect(result.foreground.h == brand.h)
        // Still saturated — it moved in lightness, not toward grey.
        #expect(result.foreground.c > 0.1)
    }

    @Test("When keeping the brand costs saturation, the surface moves instead")
    func prefersMovingTheSurface() {
        // Gold on white: no lightness keeps that chroma and still clears AA,
        // because dark yellows simply don't exist at that saturation. Rather
        // than dull the brand, the plate behind it darkens.
        let gold = OKLCH(SRGB(hex: "#ffd700")!)
        let white = OKLCH(SRGB(hex: "#ffffff")!)

        let forced = ContrastRepair.repair(foreground: gold, background: white)
        #expect(forced.chromaLost > 0.02)  // moving the brand costs real saturation

        let preferred = ContrastRepair.repairPreservingBrand(brand: gold, background: white)
        #expect(preferred.isLegible)
        #expect(preferred.foreground == gold)      // brand untouched, exactly
        #expect(preferred.background.l < white.l)  // the surface gave way instead
    }

    @Test("A brand that fits is not disturbed at all")
    func brandLeftAloneWhenItFits() {
        let brand = OKLCH(SRGB(hex: "#1db954")!)
        let surface = OKLCH(l: Perceptual.darkSurface, c: 0, h: 0)
        let result = ContrastRepair.repairPreservingBrand(brand: brand, background: surface)
        #expect(result.isLegible)
        #expect(result.foreground == brand)
        #expect(result.background == surface)
    }

    @Test("Large text and UI parts are held to their own bar, not the body one")
    func requirementsDiffer() {
        let surface = OKLCH(SRGB(hex: "#141414")!)
        let grey = OKLCH(SRGB(hex: "#5a5a5a")!)
        let body = ContrastRepair.repair(
            foreground: grey, background: surface, requirement: .normalText)
        let large = ContrastRepair.repair(
            foreground: grey, background: surface, requirement: .largeText)
        // Both legible, but the looser requirement shouldn't travel as far.
        #expect(body.isLegible && large.isLegible)
        #expect(large.foreground.l <= body.foreground.l)
    }
}
