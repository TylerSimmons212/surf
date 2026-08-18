import Testing

@testable import GlassCore

/// Builds an RGBA buffer: some pixels of one colour, some fully transparent.
private func buffer(
    _ hex: String, opaque: Int, transparent: Int, alpha: UInt8 = 255
) -> [UInt8] {
    let color = SRGB(hex: hex)!
    let channel = { (v: Double) in UInt8((v * 255).rounded()) }
    var bytes: [UInt8] = []
    for _ in 0..<opaque {
        bytes += [channel(color.r), channel(color.g), channel(color.b), alpha]
    }
    for _ in 0..<transparent {
        bytes += [0, 0, 0, 0]
    }
    return bytes
}

private let darkSurface = SRGB(hex: "#0d0d0d")!
private let lightSurface = SRGB(hex: "#ffffff")!

@Suite("Image analysis")
struct ImageAnalysisTests {

    @Test("A dark logo on transparency, on a dark page, needs backing")
    func darkLogoNeedsPlate() {
        // The one case worth intervening in: black ink drawn for a white page,
        // now invisible on a dark one.
        let verdict = ImageAnalysis.verdict(rgba: buffer("#111111", opaque: 40, transparent: 60))!
        #expect(verdict.hasTransparency)
        #expect(verdict.artworkLightness < 0.3)
        #expect(ImageAnalysis.needsPlate(verdict, on: darkSurface))
    }

    @Test("An opaque image is never touched — it carries its own background")
    func opaqueLeftAlone() {
        // A photograph is dark in places and needs nothing from us.
        let verdict = ImageAnalysis.verdict(rgba: buffer("#111111", opaque: 100, transparent: 0))!
        #expect(!verdict.hasTransparency)
        #expect(!ImageAnalysis.needsPlate(verdict, on: darkSurface))
    }

    @Test("Light artwork on transparency is already visible")
    func lightArtworkLeftAlone() {
        let verdict = ImageAnalysis.verdict(rgba: buffer("#f0f0f0", opaque: 40, transparent: 60))!
        #expect(verdict.hasTransparency)
        #expect(!ImageAnalysis.needsPlate(verdict, on: darkSurface))
    }

    @Test("On a light surface a dark logo needs nothing")
    func darkLogoOnLightSurface() {
        let verdict = ImageAnalysis.verdict(rgba: buffer("#111111", opaque: 40, transparent: 60))!
        #expect(!ImageAnalysis.needsPlate(verdict, on: lightSurface))
    }

    @Test("A few soft edges are not transparency")
    func antialiasedEdgesArentLogos() {
        // A photo with an antialiased corner shouldn't be treated as artwork
        // floating on nothing.
        let verdict = ImageAnalysis.verdict(rgba: buffer("#111111", opaque: 97, transparent: 3))!
        #expect(!verdict.hasTransparency)
        #expect(!ImageAnalysis.needsPlate(verdict, on: darkSurface))
    }

    @Test("The plate makes the artwork read")
    func plateWorks() {
        // The guarantee: whatever we paint behind it, the logo is visible on it.
        for hex in ["#000000", "#111111", "#1a1a2e", "#333333", "#0a0e27"] {
            let verdict = ImageAnalysis.verdict(rgba: buffer(hex, opaque: 40, transparent: 60))!
            let plate = ImageAnalysis.plate(for: verdict, on: darkSurface)
            // Built to the higher bar, not the one that triggered it: a plate
            // landing on the non-text minimum leaves the mark muddy.
            #expect(Contrast.isLegible(.normalText, foreground: verdict.artwork, background: plate))
            #expect(Contrast.ratio(verdict.artwork, plate) >= 4.5)
        }
    }

    @Test("The plate is the smallest step that works, not a slab of white")
    func plateIsMinimal() {
        // A white rectangle behind a logo is a worse mark on the page than the
        // logo it was rescuing.
        let verdict = ImageAnalysis.verdict(rgba: buffer("#111111", opaque: 40, transparent: 60))!
        let plate = ImageAnalysis.plate(for: verdict, on: darkSurface)
        #expect(OKLCH(plate).l < 0.75)
        #expect(plate != SRGB.white)
    }

    @Test("Alpha is weighted, not counted")
    func alphaWeighting() {
        // A half-transparent white pixel contributes half of itself, which is
        // what it actually contributes on screen.
        let solid = ImageAnalysis.verdict(rgba: buffer("#ffffff", opaque: 50, transparent: 50))!
        let faint = ImageAnalysis.verdict(
            rgba: buffer("#ffffff", opaque: 50, transparent: 50, alpha: 128))!
        #expect(faint.artworkLightness < solid.artworkLightness)
    }

    @Test("Nothing to read is not an answer")
    func degenerateInputs() {
        #expect(ImageAnalysis.verdict(rgba: []) == nil)
        #expect(ImageAnalysis.verdict(rgba: [1, 2, 3]) == nil)          // not whole pixels
        #expect(ImageAnalysis.verdict(rgba: buffer("#000000", opaque: 0, transparent: 20)) == nil)
    }
}
