import Testing

@testable import GlassCore

@Suite("Gradient parsing")
struct GradientParsingTests {

    @Test("A plain two-stop gradient")
    func simple() {
        let gradient = CSSGradient(css: "linear-gradient(#ffffff, #000000)")
        #expect(gradient?.function == "linear-gradient")
        #expect(gradient?.preamble == nil)
        #expect(gradient?.stops.count == 2)
        #expect(gradient?.stops.first?.rgb == SRGB.white)
    }

    @Test("Direction, shape, and interpolation space are kept as written", arguments: [
        "linear-gradient(to bottom, red, blue)",
        "linear-gradient(45deg, red, blue)",
        "linear-gradient(in oklch 45deg, red, blue)",
        "radial-gradient(circle at center, red, blue)",
        "conic-gradient(from 90deg at 50% 50%, red, blue)",
    ])
    func preambles(css: String) {
        let gradient = CSSGradient(css: css)
        #expect(gradient?.preamble != nil)
        #expect(gradient?.stops.count == 2)
        // The preamble is never a colour, so it must survive untouched.
        #expect(gradient?.transformed(to: .dark).preamble == gradient?.preamble)
    }

    @Test("Every gradient function, including prefixed and repeating", arguments: [
        "linear-gradient(red, blue)",
        "repeating-linear-gradient(red, blue)",
        "radial-gradient(red, blue)",
        "repeating-radial-gradient(red, blue)",
        "conic-gradient(red, blue)",
        "-webkit-linear-gradient(red, blue)",
    ])
    func functions(css: String) {
        #expect(CSSGradient(css: css) != nil)
    }

    @Test("Stop positions are preserved exactly, units and all")
    func positions() {
        let gradient = CSSGradient(css: "linear-gradient(red 10%, blue 90%)")
        #expect(gradient?.css.contains("10%") == true)
        #expect(gradient?.transformed(to: .dark).css.contains("90%") == true)
        // Double-position shorthand is a single position string, not two stops.
        let doubled = CSSGradient(css: "linear-gradient(red 10% 20%, blue)")
        #expect(doubled?.stops.count == 2)
        #expect(doubled?.css.contains("10% 20%") == true)
    }

    @Test("Colours with spaces inside them don't confuse the stop parser")
    func functionalColorStops() {
        let gradient = CSSGradient(css: "linear-gradient(rgb(255 0 0) 10%, rgb(0 0 255 / 0.5))")
        #expect(gradient?.stops.count == 2)
        #expect(gradient?.stops.first?.rgb.hex == "#ff0000")
        // Alpha is compositing, not colour — it rides through untransformed.
        #expect(gradient?.stops.last?.alpha == 0.5)
        #expect(gradient?.transformed(to: .dark).stops.last?.alpha == 0.5)
    }

    @Test("Interpolation hints and unresolvable values are handed back verbatim")
    func verbatimItems() {
        // The bare 30% is a colour hint, not a stop.
        let hinted = CSSGradient(css: "linear-gradient(red, 30%, blue)")
        #expect(hinted?.stops.count == 2)
        #expect(hinted?.css.contains("30%") == true)

        // A var() can't be resolved here, so that stop is left exactly alone
        // rather than guessed at.
        let withVar = CSSGradient(css: "linear-gradient(var(--brand), #ffffff)")
        #expect(withVar?.stops.count == 1)
        #expect(withVar?.transformed(to: .dark).css.contains("var(--brand)") == true)
    }

    @Test("Things that aren't gradients are refused")
    func refusals() {
        #expect(CSSGradient(css: "url(a.png)") == nil)
        #expect(CSSGradient(css: "#ffffff") == nil)
        #expect(CSSGradient(css: "linear-gradient(var(--a), var(--b))") == nil)
    }
}

@Suite("Gradient transformation")
struct GradientTransformTests {

    /// The lightnesses of a gradient's stops, in order.
    private func lightnesses(_ css: String, _ target: ColorSchemeTarget) -> [Double] {
        CSSGradient(css: css)!.transformed(to: target).stops.map { OKLCH($0.rgb).l }
    }

    @Test("A light surface gradient comes back dark")
    func surfaceInverts() {
        let result = lightnesses("linear-gradient(to bottom, #ffffff, #eeeeee)", .dark)
        #expect(result.allSatisfy { $0 < 0.5 })
    }

    @Test("The light direction survives — the whole reason stops move together")
    func directionPreserved() {
        // Top lighter than bottom, before and after. Transforming stops one at
        // a time reverses this, because the surface curve descends across the
        // light half; a hero whose highlight jumps to the other edge reads as
        // broken rather than as dark.
        let before = ["#ffffff", "#eeeeee"].map { OKLCH(SRGB(hex: $0)!).l }
        #expect(before[0] > before[1])
        let after = lightnesses("linear-gradient(to bottom, #ffffff, #eeeeee)", .dark)
        #expect(after[0] > after[1])
    }

    @Test("Transforming each stop on its own would have reversed it")
    func perStopWouldReverse() {
        // The bug being avoided, made explicit: run the same two stops through
        // the surface curve individually and the order flips.
        let naive = ["#ffffff", "#eeeeee"].map {
            ThemeTransform.surfaceLightness(OKLCH(SRGB(hex: $0)!).l, target: .dark)
        }
        #expect(naive[0] < naive[1])  // reversed
        let correct = lightnesses("linear-gradient(#ffffff, #eeeeee)", .dark)
        #expect(correct[0] > correct[1])  // preserved
    }

    @Test("Relative spacing between stops is kept")
    func spacingPreserved() {
        // Three evenly spaced stops stay evenly spaced, so the gradient reads
        // as the same shape rather than bunching at one end.
        let result = lightnesses("linear-gradient(#ffffff, #dddddd, #bbbbbb)", .dark)
        let firstGap = result[0] - result[1]
        let secondGap = result[1] - result[2]
        #expect(firstGap > 0 && secondGap > 0)
        #expect(abs(firstGap - secondGap) < 0.02)
    }

    @Test("Stops land inside the surface band")
    func withinBand() {
        let band = ThemeTransform.surfaceBand(for: .dark)
        for css in [
            "linear-gradient(#ffffff, #000000)",
            "linear-gradient(#ffffff, #fefefe)",
            "linear-gradient(#f0f0f0, #cccccc, #999999)",
        ] {
            for l in lightnesses(css, .dark) {
                #expect(l >= band.lowerBound - 0.01)
                #expect(l <= band.upperBound + 0.01)
            }
        }
    }

    @Test("A brand gradient is left alone")
    func brandGradientPreserved() {
        // Stripe purple to Airbnb coral: this is identity, not lighting, and
        // inverting it is the most visible way an automatic dark mode looks
        // wrong. Hue and chroma both have to come through untouched.
        let original = CSSGradient(css: "linear-gradient(90deg, #635bff, #ff5a5f)")!
        let transformed = original.transformed(to: .dark)
        #expect(transformed.stops.map(\.rgb) == original.stops.map(\.rgb))

        for (before, after) in zip(original.stops, transformed.stops) {
            #expect(OKLCH(before.rgb).h == OKLCH(after.rgb).h)
        }
    }

    @Test("Neutral gradients invert, brand gradients don't")
    func classification() {
        #expect(!ThemeTransform.isAccentGradient(["#ffffff", "#eeeeee"].map { OKLCH(SRGB(hex: $0)!) }))
        #expect(ThemeTransform.isAccentGradient(["#635bff", "#ff5a5f"].map { OKLCH(SRGB(hex: $0)!) }))
        // A faint tint is still lighting, not brand.
        #expect(!ThemeTransform.isAccentGradient(["#fdfdfe", "#f8f9fa"].map { OKLCH(SRGB(hex: $0)!) }))
    }

    @Test("Hue is never moved, in either direction", arguments: [ColorSchemeTarget.dark, .light])
    func hueIsInvariant(target: ColorSchemeTarget) {
        let original = CSSGradient(css: "linear-gradient(#8899aa, #223344)")!
        let transformed = original.transformed(to: target)
        for (before, after) in zip(original.stops, transformed.stops) {
            let hueBefore = OKLCH(before.rgb).h
            let hueAfter = OKLCH(after.rgb).h
            // Gamut mapping may shed chroma, which is allowed; hue may not move.
            #expect(abs(hueBefore - hueAfter) < 1.0)
        }
    }

    @Test("A dark gradient inverts when forced the other way")
    func lightDirection() {
        let result = lightnesses("linear-gradient(#000000, #222222)", .light)
        #expect(result.allSatisfy { $0 > 0.5 })
        // And keeps its direction here too.
        #expect(result[0] < result[1])
    }
}

@Suite("Gradient values")
struct GradientValueTests {

    @Test("Several layers in one value are each transformed")
    func layered() {
        // The commas between layers look exactly like the commas between stops,
        // which is why the value is walked with a paren depth rather than split.
        let value = "linear-gradient(#ffffff, #eeeeee), linear-gradient(#fafafa, #f0f0f0)"
        let result = CSSGradient.transformValue(value, to: .dark)
        #expect(result.components(separatedBy: "linear-gradient").count == 3)
        for gradient in result.components(separatedBy: "), ") {
            if let parsed = CSSGradient(css: gradient.hasSuffix(")") ? gradient : gradient + ")") {
                #expect(parsed.stops.allSatisfy { OKLCH($0.rgb).l < 0.5 })
            }
        }
    }

    @Test("Images in the same value are not touched")
    func imagesUntouched() {
        // Deliberate policy: image pixels are never recoloured, so a url() has
        // to come through a value transform exactly as it went in.
        let value = "url(\"hero.png\"), linear-gradient(#ffffff, #eeeeee)"
        let result = CSSGradient.transformValue(value, to: .dark)
        #expect(result.contains("url(\"hero.png\")"))
        #expect(!result.contains("#ffffff"))
    }

    @Test("A comma inside a url() doesn't split the value")
    func commaInsideURL() {
        let value = "url(\"a,b.png\"), linear-gradient(#ffffff, #eeeeee)"
        let result = CSSGradient.transformValue(value, to: .dark)
        #expect(result.contains("url(\"a,b.png\")"))
    }

    @Test("Values with no gradient in them are returned unchanged", arguments: [
        "none", "url(a.png)", "#ffffff", "inherit", "var(--hero)",
    ])
    func passthrough(value: String) {
        #expect(CSSGradient.transformValue(value, to: .dark) == value)
    }
}
