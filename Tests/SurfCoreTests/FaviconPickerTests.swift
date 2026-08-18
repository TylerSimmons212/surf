import Testing
@testable import SurfCore

@Suite("Favicon selection")
struct FaviconPickerTests {

    private let origin = "https://example.com"

    @Test("No declared icons falls back to /favicon.ico")
    func fallback() {
        #expect(FaviconPicker.best(from: [], origin: origin) == "https://example.com/favicon.ico")
    }

    @Test("Blank hrefs are ignored and fall back")
    func blankHrefs() {
        let candidates = [FaviconCandidate(href: "", sizes: "32x32")]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "https://example.com/favicon.ico")
    }

    @Test("An exact 32x32 beats a 16x16")
    func prefersRetinaSize() {
        let candidates = [
            FaviconCandidate(href: "/small.png", sizes: "16x16"),
            FaviconCandidate(href: "/right.png", sizes: "32x32"),
        ]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/right.png")
    }

    @Test("Scalable SVG wins outright")
    func prefersSVG() {
        let candidates = [
            FaviconCandidate(href: "/icon.png", sizes: "32x32"),
            FaviconCandidate(href: "/icon.svg", sizes: "any"),
        ]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/icon.svg")
    }

    @Test("Oversized is preferred over undersized by the same margin")
    func downscaleBeatsUpscale() {
        // 512 is 480 over; 16 is 16 under. Halving the oversize penalty still
        // leaves 240 > 16, so the small one wins here...
        #expect(
            FaviconPicker.best(
                from: [
                    FaviconCandidate(href: "/huge.png", sizes: "512x512"),
                    FaviconCandidate(href: "/tiny.png", sizes: "16x16"),
                ],
                origin: origin
            ) == "/tiny.png"
        )
        // ...but at equal distance, the larger one wins, because downscaling
        // looks better than upscaling.
        #expect(
            FaviconPicker.best(
                from: [
                    FaviconCandidate(href: "/48.png", sizes: "48x48"),
                    FaviconCandidate(href: "/16.png", sizes: "16x16"),
                ],
                origin: origin
            ) == "/48.png"
        )
    }

    @Test("A multi-size attribute uses its largest entry")
    func multiSize() {
        let candidates = [
            FaviconCandidate(href: "/multi.ico", sizes: "16x16 32x32"),
            FaviconCandidate(href: "/small.png", sizes: "16x16"),
        ]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/multi.ico")
    }

    @Test("An undeclared size is used when it's the only option")
    func undeclaredOnly() {
        let candidates = [FaviconCandidate(href: "/favicon.ico")]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/favicon.ico")
    }

    @Test("A well-sized icon beats one with no declared size")
    func declaredBeatsUndeclared() {
        let candidates = [
            FaviconCandidate(href: "/unknown.ico"),
            FaviconCandidate(href: "/good.png", sizes: "32x32"),
        ]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/good.png")
    }

    @Test("Garbage size attributes don't crash the parse")
    func garbageSizes() {
        let candidates = [FaviconCandidate(href: "/weird.png", sizes: "banana")]
        #expect(FaviconPicker.best(from: candidates, origin: origin) == "/weird.png")
    }
}
