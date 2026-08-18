import CoreGraphics
import Testing

@testable import SurfCore

@Suite("Pop-out sizing")
struct PopOutSizingTests {

    /// The whole point: whatever else happens, the shape survives.
    @Test(
        "Panel keeps the video's proportions",
        arguments: [
            CGSize(width: 1920, height: 1080),   // 16:9
            CGSize(width: 1080, height: 1920),   // vertical
            CGSize(width: 1000, height: 1000),   // square
            CGSize(width: 640, height: 480),     // 4:3
            CGSize(width: 3840, height: 1600),   // ultrawide
            CGSize(width: 300, height: 1200),    // extreme portrait
            CGSize(width: 5000, height: 40),     // absurd letterbox
        ]
    )
    func preservesAspect(_ video: CGSize) {
        let panel = PopOutSizing.panelSize(forVideo: video)
        #expect(PopOutSizing.aspectMatches(panel, video, tolerance: 0.001))
    }

    @Test("A 16:9 video gets the reference panel")
    func referenceSize() {
        let panel = PopOutSizing.panelSize(forVideo: CGSize(width: 1920, height: 1080))
        #expect(abs(panel.width - 480) < 0.5)
        #expect(abs(panel.height - 270) < 0.5)
    }

    @Test("A vertical video is tall, not wide")
    func verticalStaysVertical() {
        let panel = PopOutSizing.panelSize(forVideo: CGSize(width: 1080, height: 1920))
        #expect(panel.height > panel.width)
        // Sized by area, so it's the 16:9 panel turned on its side rather than
        // something towering.
        #expect(abs(panel.width - 270) < 0.5)
        #expect(abs(panel.height - 480) < 0.5)
    }

    @Test("A square video gets a square panel")
    func squareStaysSquare() {
        let panel = PopOutSizing.panelSize(forVideo: CGSize(width: 800, height: 800))
        #expect(abs(panel.width - panel.height) < 0.5)
    }

    @Test("Similar area regardless of orientation")
    func comparablePresence() {
        let wide = PopOutSizing.panelSize(forVideo: CGSize(width: 1920, height: 1080))
        let tall = PopOutSizing.panelSize(forVideo: CGSize(width: 1080, height: 1920))
        let wideArea = wide.width * wide.height
        let tallArea = tall.width * tall.height
        #expect(abs(wideArea - tallArea) / wideArea < 0.01)
    }

    @Test(
        "Ordinary videos stay inside the box",
        arguments: [
            CGSize(width: 1920, height: 1080),
            CGSize(width: 1080, height: 1920),
            CGSize(width: 1000, height: 1000),
            CGSize(width: 3840, height: 1600),
        ]
    )
    func fitsBox(_ video: CGSize) {
        let panel = PopOutSizing.panelSize(forVideo: video)
        #expect(panel.width <= PopOutSizing.maxWidth + 0.5)
        #expect(panel.height <= PopOutSizing.maxHeight + 0.5)
    }

    @Test(
        "Nothing comes out too small to hold the controls",
        arguments: [
            CGSize(width: 1920, height: 1080),
            CGSize(width: 300, height: 1200),
            CGSize(width: 5000, height: 40),
        ]
    )
    func minimumIsRespected(_ video: CGSize) {
        let panel = PopOutSizing.panelSize(forVideo: video)
        #expect(min(panel.width, panel.height) >= PopOutSizing.minShorterSide - 0.5)
    }

    @Test("A degenerate measurement falls back rather than dividing by zero")
    func degenerate() {
        #expect(PopOutSizing.panelSize(forVideo: .zero) == PopOutSizing.fallback)
        #expect(PopOutSizing.panelSize(forVideo: CGSize(width: 100, height: 0)) == PopOutSizing.fallback)
    }

    @Test("The resize floor has the same shape as the video")
    func minimumKeepsAspect() {
        let video = CGSize(width: 1080, height: 1920)
        let floor = PopOutSizing.minimumSize(forVideo: video)
        #expect(PopOutSizing.aspectMatches(floor, video, tolerance: 0.001))
        #expect(min(floor.width, floor.height) >= PopOutSizing.minShorterSide - 0.5)
    }

    @Test("Aspect comparison tolerates sub-pixel drift but not reshaping")
    func aspectComparison() {
        #expect(PopOutSizing.aspectMatches(CGSize(width: 640, height: 360),
                                           CGSize(width: 640.4, height: 360.1)))
        #expect(!PopOutSizing.aspectMatches(CGSize(width: 480, height: 540),
                                            CGSize(width: 1080, height: 1920)))
    }
}
