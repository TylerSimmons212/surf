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

@Suite("Pop-out placement")
struct PopOutPlacementTests {

    /// A 1512x982 screen with the menu bar taken off the top.
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let wide = CGSize(width: 1920, height: 1080)

    @Test("With nothing remembered it opens in the bottom trailing corner")
    func firstTime() {
        let f = PopOutSizing.placement(remembered: nil, forVideo: wide, onVisible: visible)
        #expect(f.maxX == visible.maxX - PopOutSizing.margin)
        #expect(f.minY == visible.minY + PopOutSizing.margin)
    }

    @Test("A remembered frame is honoured, position and size both")
    func remembered() {
        // y chosen so the whole panel fits: 500 + 337.5 is inside 949. The
        // first draft used 700, which does not, and the clamp was right to
        // pull it back.
        let saved = CGRect(x: 60, y: 500, width: 600, height: 337.5)
        let f = PopOutSizing.placement(remembered: saved, forVideo: wide, onVisible: visible)
        #expect(f.origin == saved.origin)
        #expect(f.size == saved.size)
    }

    @Test("A different shape keeps the corner but takes its own size")
    func differentAspect() {
        // Sized for 16:9, now opening a 9:16 clip. Reusing the box would make
        // the panel fight its own aspect lock.
        let saved = CGRect(x: 60, y: 700, width: 600, height: 337.5)
        let tall = CGSize(width: 1080, height: 1920)
        let f = PopOutSizing.placement(remembered: saved, forVideo: tall, onVisible: visible)
        #expect(f.origin.x == saved.origin.x)
        #expect(f.size == PopOutSizing.panelSize(forVideo: tall))
    }

    @Test("A frame left on a screen that is gone comes back on")
    func offScreen() {
        // Remembered on a second display off to the right.
        let saved = CGRect(x: 2400, y: 1400, width: 600, height: 337.5)
        let f = PopOutSizing.placement(remembered: saved, forVideo: wide, onVisible: visible)
        #expect(visible.contains(f))
    }

    @Test("A remembered size too big for this screen is not used")
    func tooBig() {
        let saved = CGRect(x: 0, y: 0, width: 3000, height: 1687.5)
        let f = PopOutSizing.placement(remembered: saved, forVideo: wide, onVisible: visible)
        #expect(f.size == PopOutSizing.panelSize(forVideo: wide))
        #expect(visible.contains(f))
    }

    @Test("Negative origins are pulled back inside")
    func negative() {
        let saved = CGRect(x: -400, y: -300, width: 600, height: 337.5)
        let f = PopOutSizing.placement(remembered: saved, forVideo: wide, onVisible: visible)
        #expect(f.minX == visible.minX)
        #expect(f.minY == visible.minY)
    }
}
