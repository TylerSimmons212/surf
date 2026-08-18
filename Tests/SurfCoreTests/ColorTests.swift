import Foundation
import Testing

@testable import SurfCore

/// A spread of colours to run properties over: the primaries and secondaries,
/// the greys, and a few real brand colours the transform must not mangle.
private let sampleColors: [SRGB] = [
    "#000000", "#ffffff", "#808080", "#f7f7f7", "#1a1a1a",
    "#ff0000", "#00ff00", "#0000ff", "#ffff00", "#00ffff", "#ff00ff",
    "#1db954",  // Spotify green
    "#635bff",  // Stripe purple
    "#ff5a5f",  // Airbnb coral
    "#1d9bf0",  // a link blue
    "#4b2e83", "#fef3c7", "#0a0e27",
].map { SRGB(hex: $0)! }

@Suite("sRGB")
struct SRGBTests {

    @Test("Hex parses in every form it appears on the web")
    func hexForms() {
        #expect(SRGB(hex: "#ffffff") == SRGB.white)
        #expect(SRGB(hex: "ffffff") == SRGB.white)       // no hash
        #expect(SRGB(hex: "#FFFFFF") == SRGB.white)      // uppercase
        // Shorthand doubles each digit: #abc is #aabbcc, not #0abc.
        #expect(SRGB(hex: "#fff") == SRGB.white)
        #expect(SRGB(hex: "#f00") == SRGB(hex: "#ff0000"))
        // Alpha is parsed and dropped rather than rejected — the colour still
        // has to be transformed.
        #expect(SRGB(hex: "#ff0000ff") == SRGB(hex: "#ff0000"))
        #expect(SRGB(hex: "#f00f") == SRGB(hex: "#ff0000"))
    }

    @Test("Nonsense is rejected rather than half-parsed")
    func hexRejects() {
        #expect(SRGB(hex: "") == nil)
        #expect(SRGB(hex: "#gg0000") == nil)
        #expect(SRGB(hex: "#ff000") == nil)    // 5 digits is not a form
        #expect(SRGB(hex: "#ff0000f") == nil)  // nor is 7
        // ...but 4 is: #ff00 is the RGBA shorthand for yellow at zero alpha,
        // and dropping the alpha is what the parser is documented to do.
        #expect(SRGB(hex: "#ff00") == SRGB(hex: "#ffff00"))
        #expect(SRGB(hex: "rebeccapurple") == nil)
    }

    @Test("Hex round-trips", arguments: sampleColors)
    func hexRoundTrip(color: SRGB) {
        #expect(SRGB(hex: color.hex) == color)
    }

    @Test("Compositing resolves translucency against what's behind it")
    func compositing() {
        let half = SRGB.black.composited(over: .white, alpha: 0.5)
        #expect(abs(half.r - 0.5) < 1e-9)
        // The same colour over different backdrops is different to the eye,
        // which is the entire reason contrast can't be measured before this.
        let overBlack = SRGB.white.composited(over: .black, alpha: 0.5)
        #expect(abs(overBlack.r - 0.5) < 1e-9)
        // The ends are pass-throughs.
        #expect(SRGB.black.composited(over: .white, alpha: 1) == .black)
        #expect(SRGB.black.composited(over: .white, alpha: 0) == .white)
    }
}

@Suite("OKLCH")
struct OKLCHTests {

    @Test("Black and white sit at the ends of the lightness axis")
    func endpoints() {
        #expect(abs(OKLCH(SRGB.white).l - 1) < 1e-6)
        #expect(abs(OKLCH(SRGB.black).l - 0) < 1e-6)
        // Neither has a hue worth speaking of.
        #expect(OKLCH(SRGB.white).isNeutral)
        #expect(OKLCH(SRGB.black).isNeutral)
        #expect(OKLCH(SRGB(hex: "#808080")!).isNeutral)
    }

    @Test("Matches the reference values for the sRGB primaries")
    func referenceValues() {
        // From the CSS Color 4 conversion samples. Tolerance is loose enough
        // for published rounding, tight enough to catch a transposed matrix
        // coefficient — which is the realistic way this breaks.
        let red = OKLCH(SRGB(hex: "#ff0000")!)
        #expect(abs(red.l - 0.6280) < 0.001)
        #expect(abs(red.c - 0.2577) < 0.001)
        #expect(abs(red.h - 29.23) < 0.1)

        let green = OKLCH(SRGB(hex: "#00ff00")!)
        #expect(abs(green.l - 0.8664) < 0.001)
        #expect(abs(green.c - 0.2948) < 0.001)
        #expect(abs(green.h - 142.50) < 0.1)

        let blue = OKLCH(SRGB(hex: "#0000ff")!)
        #expect(abs(blue.l - 0.4520) < 0.001)
        #expect(abs(blue.c - 0.3132) < 0.001)
        #expect(abs(blue.h - 264.05) < 0.1)
    }

    @Test("Perceptual lightness ranks colours the way the eye does")
    func perceptualOrdering() {
        // The reason for this space over HSL: all three are HSL lightness 50%,
        // and they are nothing like equally bright. Anything that inverts the
        // HSL number treats them as interchangeable, and they are not.
        let yellow = OKLCH(SRGB(hex: "#ffff00")!).l
        let green = OKLCH(SRGB(hex: "#00ff00")!).l
        let red = OKLCH(SRGB(hex: "#ff0000")!).l
        let blue = OKLCH(SRGB(hex: "#0000ff")!).l
        #expect(yellow > green)
        #expect(green > red)
        #expect(red > blue)
        // And the spread is large — not a rounding difference.
        #expect(yellow - blue > 0.5)
    }

    @Test("Converts back to where it came from", arguments: sampleColors)
    func roundTrip(color: SRGB) {
        let back = OKLCH(color).rgb
        // 1e-5, not 1e-6: the published matrix coefficients are given to ten
        // digits, and de-linearising a channel that lands near zero multiplies
        // whatever residue is left by 12.92. This is still 400x tighter than
        // one step of an 8-bit channel, so nothing visible rides on it.
        #expect(abs(back.r - color.r) < 1e-5)
        #expect(abs(back.g - color.g) < 1e-5)
        #expect(abs(back.b - color.b) < 1e-5)
        // What actually has to hold: the colour you get back is the same colour.
        #expect(back.hex == color.hex)
    }

    @Test("Hue is normalised into a single turn")
    func hueNormalisation() {
        #expect(abs(OKLCH(l: 0.5, c: 0.1, h: 370).h - 10) < 1e-9)
        #expect(abs(OKLCH(l: 0.5, c: 0.1, h: -10).h - 350) < 1e-9)
        #expect(abs(OKLCH(l: 0.5, c: 0.1, h: 720).h - 0) < 1e-9)
    }
}

@Suite("Gamut mapping")
struct GamutTests {

    @Test("A displayable colour is left alone", arguments: sampleColors)
    func inGamutUntouched(color: SRGB) {
        let lch = OKLCH(color)
        let mapped = lch.gamutMapped()
        #expect(abs(mapped.c - lch.c) < 1e-6)
        #expect(abs(mapped.l - lch.l) < 1e-6)
    }

    @Test("An impossible colour is pulled back without moving its hue")
    func preservesHue() {
        // Far more chroma than sRGB can carry at any lightness. This is the
        // case brand preservation actually hits: hold the chroma of a saturated
        // colour, move its lightness, and it leaves the cube.
        for hue in stride(from: 0.0, to: 360.0, by: 15) {
            let impossible = OKLCH(l: 0.5, c: 0.5, h: hue)
            let mapped = impossible.gamutMapped()
            #expect(mapped.rgb.isInGamut)
            // Hue is the promise. It must not move at all.
            #expect(mapped.h == impossible.h)
            #expect(abs(mapped.l - impossible.l) < 1e-9)
            #expect(mapped.c < impossible.c)
        }
    }

    @Test("Channel clipping would have moved the hue, which is why we don't")
    func clippingWouldShiftHue() {
        // The motivating comparison, made concrete: clamp the channels of an
        // out-of-gamut blue and the hue swings; map it properly and it doesn't.
        let impossible = OKLCH(l: 0.5, c: 0.5, h: 264)
        let clipped = OKLCH(impossible.rgb.clamped)
        let mapped = impossible.gamutMapped()
        #expect(abs(clipped.h - 264) > 3)       // visibly purple
        #expect(abs(mapped.h - 264) < 1e-9)     // still blue
    }

    @Test("Only grey survives at the extremes of lightness")
    func extremes() {
        #expect(OKLCH(l: 0, c: 0.3, h: 120).gamutMapped().c == 0)
        #expect(OKLCH(l: 1, c: 0.3, h: 120).gamutMapped().c == 0)
        // And lightness outside the axis is brought back onto it.
        #expect(OKLCH(l: 1.5, c: 0.1, h: 120).gamutMapped().l == 1)
        #expect(OKLCH(l: -0.5, c: 0.1, h: 120).gamutMapped().l == 0)
    }

    @Test("The chroma ceiling is real and hue-dependent")
    func chromaCeiling() {
        // Yellow can hold far more chroma when light; blue when dark. Knowing
        // the ceiling is what turns "desaturate until it fits" into a decision.
        let yellowHigh = OKLCH(l: 0.9, c: 0, h: 110).maxChromaInGamut
        let yellowLow = OKLCH(l: 0.2, c: 0, h: 110).maxChromaInGamut
        #expect(yellowHigh > yellowLow)

        for hue in stride(from: 0.0, to: 360.0, by: 30) {
            let ceiling = OKLCH(l: 0.6, c: 0, h: hue).maxChromaInGamut
            #expect(ceiling > 0)
            #expect(OKLCH(l: 0.6, c: ceiling, h: hue).rgb.isInGamut)
        }
    }
}

@Suite("Contrast")
struct ContrastTests {

    @Test("The extremes are the documented extremes")
    func knownRatios() {
        #expect(abs(Contrast.ratio(.black, .white) - 21) < 0.01)
        #expect(abs(Contrast.ratio(.white, .white) - 1) < 1e-9)
    }

    @Test("Matches the textbook borderline greys")
    func borderlineGreys() {
        // #767676 is the lightest grey that passes AA on white, and #777777 is
        // the first that fails. Any drift in the luminance curve moves this.
        let passes = Contrast.ratio(SRGB(hex: "#767676")!, .white)
        let fails = Contrast.ratio(SRGB(hex: "#777777")!, .white)
        #expect(passes >= 4.5)
        #expect(fails < 4.5)
    }

    @Test("Order doesn't matter", arguments: sampleColors)
    func symmetry(color: SRGB) {
        #expect(abs(Contrast.ratio(color, .white) - Contrast.ratio(.white, color)) < 1e-12)
    }

    @Test("Thresholds are the WCAG AA ones")
    func thresholds() {
        #expect(Contrast.Requirement.normalText.minimumRatio == 4.5)
        #expect(Contrast.Requirement.largeText.minimumRatio == 3)
        #expect(Contrast.Requirement.nonText.minimumRatio == 3)
    }

    @Test("Legibility is strictly stricter than the ratio alone")
    func legibilityIsStricter() {
        // The whole point of the second constraint: it can only ever reject
        // more, so it cannot cause a WCAG 2 regression.
        for fg in sampleColors {
            for bg in sampleColors {
                for requirement in Contrast.Requirement.allCases {
                    if Contrast.isLegible(requirement, foreground: fg, background: bg) {
                        #expect(Contrast.meetsRatio(requirement, foreground: fg, background: bg))
                    }
                }
            }
        }
    }

    @Test("It catches the equiluminant chromatic pair the ratio flatters")
    func equiluminantWeakness() {
        // Found by searching the space, not invented: this pair clears 4.5:1
        // and is close to unreadable, because luminance separates them while
        // perceived lightness barely does.
        let background = SRGB(hex: "#16d724")!
        let foreground = SRGB(hex: "#0300f9")!
        #expect(Contrast.meetsRatio(.normalText, foreground: foreground, background: background))
        #expect(!Contrast.isLegible(.normalText, foreground: foreground, background: background))
    }

    @Test("The floor never turns away a grey pair that passes the ratio")
    func greysAreNeverRejected() {
        // The calibration claim, enforced. Greys bottom out near 0.37 of
        // perceptual separation at 4.5:1, so both floors sit safely under them —
        // the second constraint exists for chromatic pairs and must stay out of
        // the way of everything else.
        let steps = stride(from: 0.0, through: 1.0, by: 0.02)
        for a in steps {
            for b in steps {
                let fg = SRGB(r: a, g: a, b: a)
                let bg = SRGB(r: b, g: b, b: b)
                for requirement in Contrast.Requirement.allCases
                where Contrast.meetsRatio(requirement, foreground: fg, background: bg) {
                    #expect(Contrast.isLegible(requirement, foreground: fg, background: bg))
                }
            }
        }
    }

    @Test("The comfortable dark pair passes both constraints")
    func comfortableDarkPair() {
        // What the synthesised theme actually aims at: short of white-on-black,
        // clearing AA with room to spare, and past the perceptual bar too.
        let surface = OKLCH(l: Perceptual.darkSurface, c: 0, h: 0).displayable
        let text = OKLCH(l: Perceptual.darkForeground, c: 0, h: 0).displayable
        #expect(Contrast.isLegible(.normalText, foreground: text, background: surface))
        let ratio = Contrast.ratio(text, surface)
        #expect(ratio > 12)
        // And deliberately not the maximum — halation is a real cost.
        #expect(ratio < 21)
    }
}
