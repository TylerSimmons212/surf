import Foundation
import Testing

@testable import SurfCore

@Suite("Viewport emulation")
struct ViewportEmulationTests {

    @Test("A smaller viewport centers in the container")
    func centered() {
        let frame = ViewportEmulation.frame(
            for: CGSize(width: 400, height: 600),
            in: CGSize(width: 1000, height: 800)
        )
        #expect(frame == CGRect(x: 300, y: 100, width: 400, height: 600))
    }

    @Test("A taller viewport pins its top edge, not its middle")
    func tallPinsTop() {
        let frame = ViewportEmulation.frame(
            for: CGSize(width: 390, height: 844),
            in: CGSize(width: 1000, height: 500)
        )
        // AppKit origin is bottom-left: top pinned means maxY == container top.
        #expect(frame.maxY == CGFloat(500))
        #expect(frame.minY == CGFloat(500 - 844))
        #expect(frame.width == CGFloat(390))
    }

    @Test("The size is never scaled to fit")
    func neverScaled() {
        let frame = ViewportEmulation.frame(
            for: CGSize(width: 1280, height: 800),
            in: CGSize(width: 600, height: 400)
        )
        #expect(frame.width == 1280)
        #expect(frame.height == 800)
    }

    @Test("Offsets land on whole pixels")
    func wholePixels() {
        let frame = ViewportEmulation.frame(
            for: CGSize(width: 391, height: 845),
            in: CGSize(width: 1000, height: 1000)
        )
        #expect(frame.origin.x == frame.origin.x.rounded())
        #expect(frame.origin.y == frame.origin.y.rounded())
    }

    @Test("Every preset names a size someone designs for")
    func presetsSane() {
        #expect(!ViewportEmulation.presets.isEmpty)
        for preset in ViewportEmulation.presets {
            #expect(preset.size.width >= 320)
            #expect(preset.size.height >= 480)
            #expect(preset.label.contains("\(Int(preset.size.width))"))
        }
        // Distinct names, or the menu shows twins.
        let names = ViewportEmulation.presets.map(\.name)
        #expect(Set(names).count == names.count)
    }
}
