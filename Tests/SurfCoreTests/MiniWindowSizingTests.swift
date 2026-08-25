import CoreGraphics
import Testing

@testable import SurfCore

@Suite("Mini window sizing")
struct MiniWindowSizingTests {

    static let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    static let studio = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    static let xdr = CGRect(x: 0, y: 0, width: 3008, height: 1692)

    /// The whole point: the same window used to be two thirds of a laptop
    /// screen and a quarter of a 6K one.
    @Test("A panel stays a panel across wildly different displays")
    func staysAPanel() {
        for screen in [Self.laptop, Self.studio, Self.xdr] {
            let size = MiniWindowSizing.size(forVisible: screen)
            let share = (size.width * size.height) / (screen.width * screen.height)
            #expect(share > 0.15 && share < 0.45, "\(size) is \(share) of \(screen.size)")
        }
    }

    @Test("The share is taken per axis")
    func takesTheShare() {
        // 55% of 2560 is 1408, over the ceiling; 55% of 1415 is 778, under it.
        let size = MiniWindowSizing.size(forVisible: Self.studio)
        #expect(size.width == MiniWindowSizing.maximum.width)
        #expect(size.height == 778)
    }

    @Test("A very large display is capped rather than filled")
    func capsTheCeiling() {
        let size = MiniWindowSizing.size(forVisible: Self.xdr)
        #expect(size == MiniWindowSizing.maximum)
    }

    /// A laptop's 55% of height is 522, below the floor. The floor wins, or the
    /// page starts reflowing to its phone layout.
    @Test("A short display is raised to the floor")
    func raisesToTheFloor() {
        let size = MiniWindowSizing.size(forVisible: Self.laptop)
        #expect(size.height == MiniWindowSizing.minimum.height)
        #expect(size.width == 832)
    }

    /// The floor and the screen contradict each other here. The screen wins —
    /// a window wider than its display has its own edges out of reach.
    @Test("The screen overrules the floor when they disagree")
    func screenBeatsFloor() {
        let small = CGRect(x: 0, y: 0, width: 760, height: 480)
        let size = MiniWindowSizing.size(forVisible: small)
        #expect(size == CGSize(width: 760, height: 480))
    }

    @Test("A size is always whole points")
    func wholePoints() {
        let odd = CGRect(x: 0, y: 0, width: 1727, height: 1103)
        let size = MiniWindowSizing.size(forVisible: odd)
        #expect(size.width == size.width.rounded())
        #expect(size.height == size.height.rounded())
    }

    @Test("Never larger than the screen it opens on")
    func neverLargerThanTheScreen() {
        for screen in [Self.laptop, Self.studio, Self.xdr,
                       CGRect(x: 0, y: 0, width: 640, height: 400)] {
            let size = MiniWindowSizing.size(forVisible: screen)
            #expect(size.width <= screen.width)
            #expect(size.height <= screen.height)
        }
    }
}
