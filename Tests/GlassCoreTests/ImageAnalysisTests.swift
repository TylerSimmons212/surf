import Testing

@testable import GlassCore

/// An RGBA buffer: some pixels of given colours, some fully transparent.
private func buffer(_ hexes: [String], each: Int, transparent: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    for hex in hexes {
        let color = SRGB(hex: hex)!
        let channel = { (v: Double) in UInt8((v * 255).rounded()) }
        for _ in 0..<each {
            bytes += [channel(color.r), channel(color.g), channel(color.b), 255]
        }
    }
    bytes += Array(repeating: 0, count: transparent * 4)
    return bytes
}

private let darkSurface = SRGB(hex: "#0d0d0d")!
private let lightSurface = SRGB(hex: "#ffffff")!

@Suite("Image analysis")
struct ImageAnalysisTests {

    @Test("A black wordmark on transparency inverts")
    func blackWordmarkInverts() {
        // Wikipedia's: colourless ink drawn for a white page, invisible on a
        // dark one, and with no hue to lose by flipping it.
        let verdict = ImageAnalysis.verdict(rgba: buffer(["#111111"], each: 40, transparent: 60))!
        #expect(verdict.hasTransparency)
        #expect(verdict.isAchromatic)
        #expect(ImageAnalysis.shouldInvert(verdict, on: darkSurface))
    }

    @Test("Anything with colour in it is left alone")
    func colouredMarksUntouched() {
        for hex in ["#1db954", "#635bff", "#ff5a5f", "#0f62fe"] {
            let verdict = ImageAnalysis.verdict(rgba: buffer([hex], each: 40, transparent: 60))!
            #expect(!verdict.isAchromatic)
            #expect(!ImageAnalysis.shouldInvert(verdict, on: darkSurface))
        }
    }

    @Test("A colourful mark that averages to grey is still colourful")
    func averagingCannotBeFooled() {
        // The trap this guards: red beside green beside blue averages to a
        // muddy grey, and judging the mean alone would invert a logo made
        // entirely of colour. Measured per pixel, it doesn't.
        let verdict = ImageAnalysis.verdict(
            rgba: buffer(["#ff0000", "#00ff00", "#0000ff"], each: 20, transparent: 60))!
        let mean = OKLCH(verdict.artwork)
        #expect(mean.c < ImageAnalysis.achromaticChroma)   // the mean *is* grey
        #expect(!verdict.isAchromatic)                      // ...and it isn't fooled
        #expect(!ImageAnalysis.shouldInvert(verdict, on: darkSurface))
    }

    @Test("An opaque image is never inverted — it carries its own background")
    func opaqueUntouched() {
        let verdict = ImageAnalysis.verdict(rgba: buffer(["#111111"], each: 100, transparent: 0))!
        #expect(!verdict.hasTransparency)
        #expect(!ImageAnalysis.shouldInvert(verdict, on: darkSurface))
    }

    @Test("A mark that already reads is left as it is")
    func visibleMarksUntouched() {
        // Light ink on a dark page needs nothing.
        let light = ImageAnalysis.verdict(rgba: buffer(["#f0f0f0"], each: 40, transparent: 60))!
        #expect(!ImageAnalysis.shouldInvert(light, on: darkSurface))
        // ...and dark ink on a light page needs nothing either.
        let dark = ImageAnalysis.verdict(rgba: buffer(["#111111"], each: 40, transparent: 60))!
        #expect(!ImageAnalysis.shouldInvert(dark, on: lightSurface))
    }

    @Test("The rescue works in both directions")
    func symmetric() {
        // Forcing a dark-only site to light: a white mark is the one that
        // vanishes, and inverting it is the same fix mirrored.
        let white = ImageAnalysis.verdict(rgba: buffer(["#f8f8f8"], each: 40, transparent: 60))!
        #expect(ImageAnalysis.shouldInvert(white, on: lightSurface))
        #expect(!ImageAnalysis.shouldInvert(white, on: darkSurface))
    }

    @Test("A few soft edges are not transparency")
    func antialiasedEdgesArentMarks() {
        let verdict = ImageAnalysis.verdict(rgba: buffer(["#111111"], each: 97, transparent: 3))!
        #expect(!verdict.hasTransparency)
        #expect(!ImageAnalysis.shouldInvert(verdict, on: darkSurface))
    }

    @Test("Nothing to read is not an answer")
    func degenerateInputs() {
        #expect(ImageAnalysis.verdict(rgba: []) == nil)
        #expect(ImageAnalysis.verdict(rgba: [1, 2, 3]) == nil)
        #expect(ImageAnalysis.verdict(rgba: buffer([], each: 0, transparent: 20)) == nil)
    }
}

@Suite("Sampling robustness")
struct SamplingRobustnessTests {

    /// A black mark whose antialiased edge carries the colour noise that
    /// unpremultiplied sampling produces at low alpha.
    private func softEdgedBlackMark() -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<40 { bytes += [17, 17, 17, 255] }        // solid black ink
        for _ in 0..<20 { bytes += [3, 22, 42, 40] }          // faint edge, reads navy
        for _ in 0..<40 { bytes += [0, 0, 0, 0] }             // transparent
        return bytes
    }

    @Test("A soft edge doesn't make a black mark look coloured")
    func softEdgesDontFakeColour() {
        // Wikipedia's wordmark, measured: 0.78 of its pixels looked chromatic
        // purely from edge noise, which was enough to fail the colourless test
        // and leave the logo dark. Colour is now read only where there is
        // enough alpha to read it.
        let verdict = ImageAnalysis.verdict(rgba: softEdgedBlackMark())!
        #expect(verdict.isAchromatic)
        #expect(verdict.hasTransparency)
        #expect(ImageAnalysis.shouldInvert(verdict, on: SRGB(hex: "#0d0d0d")!))
    }

    @Test("Faint pixels still count towards transparency")
    func faintPixelsStillCountAsShape() {
        // They're excluded from the colour reading, not from the picture.
        let verdict = ImageAnalysis.verdict(rgba: softEdgedBlackMark())!
        #expect(verdict.transparentFraction > 0.35)
    }

    @Test("A genuinely coloured mark is still refused")
    func realColourStillWins() {
        // The safeguard must survive the loosening: solid colour is solid.
        var bytes: [UInt8] = []
        for _ in 0..<40 { bytes += [29, 185, 84, 255] }
        for _ in 0..<60 { bytes += [0, 0, 0, 0] }
        let verdict = ImageAnalysis.verdict(rgba: bytes)!
        #expect(!verdict.isAchromatic)
        #expect(!ImageAnalysis.shouldInvert(verdict, on: SRGB(hex: "#0d0d0d")!))
    }
}
