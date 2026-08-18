import Testing

@testable import SurfCore

@Suite("CSS colour parsing")
struct CSSColorTests {

    @Test("Hex, in every length")
    func hex() {
        #expect(CSSColor(css: "#fff")?.rgb == SRGB.white)
        #expect(CSSColor(css: "#FFFFFF")?.rgb == SRGB.white)
        #expect(CSSColor(css: "#ff0000")?.rgb == SRGB(hex: "#ff0000"))
        // Alpha survives from both the 4- and 8-digit forms.
        #expect(CSSColor(css: "#00000080")?.alpha ?? 1 < 0.51)
        #expect(CSSColor(css: "#0000")?.alpha == 0)
        #expect(CSSColor(css: "#000f")?.alpha == 1)
    }

    @Test("rgb(), legacy and modern")
    func rgbForms() {
        let expected = SRGB(hex: "#ff8000")
        #expect(CSSColor(css: "rgb(255, 128, 0)")?.rgb == expected)
        #expect(CSSColor(css: "rgb(255 128 0)")?.rgb == expected)
        #expect(CSSColor(css: "rgba(255, 128, 0, 1)")?.rgb == expected)
        // Alpha after a slash, as a number or a percentage.
        #expect(CSSColor(css: "rgb(255 128 0 / 0.5)")?.alpha == 0.5)
        #expect(CSSColor(css: "rgb(255 128 0 / 50%)")?.alpha == 0.5)
        // ...and the legacy trailing-alpha form with no slash at all.
        #expect(CSSColor(css: "rgba(255, 128, 0, 0.5)")?.alpha == 0.5)
    }

    @Test("hsl(), including angle units")
    func hslForms() {
        // Pure red sits at hue 0 with full saturation.
        let red = CSSColor(css: "hsl(0, 100%, 50%)")
        #expect(red?.rgb.hex == "#ff0000")
        #expect(CSSColor(css: "hsl(120 100% 50%)")?.rgb.hex == "#00ff00")
        #expect(CSSColor(css: "hsl(240deg 100% 50%)")?.rgb.hex == "#0000ff")
        // A turn is a full circle, so this is red again.
        #expect(CSSColor(css: "hsl(1turn 100% 50%)")?.rgb.hex == "#ff0000")
        // Zero saturation is grey at whatever lightness.
        #expect(CSSColor(css: "hsl(0 0% 50%)")?.rgb.hex == "#808080")
    }

    @Test("Named colours, because stylesheets are full of them")
    func names() {
        #expect(CSSColor(css: "white")?.rgb == SRGB.white)
        #expect(CSSColor(css: "black")?.rgb == SRGB.black)
        #expect(CSSColor(css: "  RED  ")?.rgb.hex == "#ff0000")
        #expect(CSSColor(css: "rebeccapurple")?.rgb.hex == "#663399")
        // Both spellings of grey, which is a real source of misses.
        #expect(CSSColor(css: "gray")?.rgb == CSSColor(css: "grey")?.rgb)
        #expect(CSSColor(css: "darkgray")?.rgb == CSSColor(css: "darkgrey")?.rgb)
    }

    @Test("transparent is a colour with no alpha, not a parse failure")
    func transparentKeyword() {
        let clear = CSSColor(css: "transparent")
        #expect(clear?.alpha == 0)
    }

    @Test("Modern perceptual syntaxes round-trip through the same space we work in")
    func modernForms() {
        // A site already authoring in oklch is one we should meet where it is.
        let red = CSSColor(css: "oklch(0.628 0.2577 29.23)")
        #expect(red != nil)
        #expect(red?.rgb.hex == "#ff0000")
        #expect(CSSColor(css: "oklab(1 0 0)")?.rgb.hex == "#ffffff")
    }

    @Test("What it can't fully understand, it declines")
    func declinesRatherThanGuesses() {
        // The safety contract: unrecognised text is left alone by the caller,
        // so a wrong guess here would become a visible bug on someone's page.
        #expect(CSSColor(css: "currentColor") == nil)
        #expect(CSSColor(css: "inherit") == nil)
        #expect(CSSColor(css: "var(--brand)") == nil)
        #expect(CSSColor(css: "color-mix(in oklab, red 40%, blue)") == nil)
        #expect(CSSColor(css: "") == nil)
        #expect(CSSColor(css: "not-a-colour") == nil)
        #expect(CSSColor(css: "rgb(1, 2)") == nil)
    }

    @Test("Serialises back to something a stylesheet accepts")
    func serialisation() {
        #expect(CSSColor(rgb: SRGB.white).css == "#ffffff")
        // Translucency needs a form that can carry it.
        let half = CSSColor(rgb: .black, alpha: 0.5)
        #expect(half.css == "rgb(0 0 0 / 0.5)")
        #expect(CSSColor(css: half.css)?.alpha == 0.5)
    }

    @Test("Parsing and serialising is a round trip", arguments: [
        "#ff0000", "#1db954", "#635bff", "white", "rgb(10 20 30)", "hsl(200 50% 40%)",
    ])
    func roundTrip(css: String) {
        let parsed = CSSColor(css: css)
        #expect(parsed != nil)
        // Compared at display precision: serialising goes through 8 bits per
        // channel, so an hsl() value carrying more than that legitimately loses
        // the remainder. What has to survive is the colour, not the arithmetic.
        #expect(CSSColor(css: parsed!.css)?.rgb.hex == parsed?.rgb.hex)
    }
}
