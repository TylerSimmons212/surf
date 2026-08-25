import CoreGraphics
import Testing

@testable import SurfCore

@Suite("Main window placement")
struct WindowPlacementTests {

    /// A 14" MacBook Pro, menu bar removed.
    static let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    /// A 27" 5K at its default scaling.
    static let studio = CGRect(x: 0, y: 0, width: 2560, height: 1415)

    // MARK: - Opening

    /// The whole point of the feature: Surf opens at the size of the display
    /// rather than at some fixed rectangle in the corner.
    @Test("A first window fills a laptop screen edge to edge")
    func fillsLaptop() {
        let frame = WindowPlacement.opening(onVisible: Self.laptop)
        #expect(frame == Self.laptop)
    }

    /// Full height is what reading wants. Unbounded width is not: the cap is
    /// the difference between "maximised" and "two feet wide".
    @Test("A first window on a large display takes the height but not the width")
    func capsWidthOnLargeDisplay() {
        let frame = WindowPlacement.opening(onVisible: Self.studio)
        #expect(frame.width == WindowPlacement.maximumWidth)
        #expect(frame.height == Self.studio.height)
    }

    @Test("The leftover width is split evenly, not left on one side")
    func centresTheCappedWindow() {
        let frame = WindowPlacement.opening(onVisible: Self.studio)
        #expect(frame.minX - Self.studio.minX == Self.studio.maxX - frame.maxX)
    }

    /// A second display hangs at an offset, and offsets are where centring
    /// arithmetic goes wrong: a window computed for the origin lands on the
    /// wrong monitor entirely.
    @Test("Placement follows the screen it is given, not the origin")
    func respectsScreenOrigin() {
        let secondary = CGRect(x: -2560, y: 300, width: 2560, height: 1415)
        let frame = WindowPlacement.opening(onVisible: secondary)
        #expect(secondary.contains(frame))
        #expect(frame.minY == secondary.minY)
    }

    @Test("A window never opens on a fractional point")
    func opensOnWholePoints() {
        let odd = CGRect(x: 0, y: 0, width: 2561, height: 1415)
        let frame = WindowPlacement.opening(onVisible: odd)
        #expect(frame.minX == frame.minX.rounded())
    }

    // MARK: - Restoring

    /// The other half of the promise. Opening big is only welcome if it stops
    /// happening once the user has said what they want.
    @Test("A remembered frame is handed back untouched")
    func keepsARememberedFrame() {
        let saved = CGRect(x: 120, y: 90, width: 1000, height: 700)
        #expect(WindowPlacement.restoring(saved, onVisible: Self.laptop) == saved)
    }

    /// What unplugging a monitor looks like: the frame is real, the screen it
    /// was on is gone, and the window would open somewhere with no pixels.
    @Test("A frame saved off the edge is dragged back on")
    func rescuesAnOffscreenFrame() {
        let stranded = CGRect(x: 3000, y: 1800, width: 1000, height: 700)
        let frame = WindowPlacement.restoring(stranded, onVisible: Self.laptop)
        #expect(Self.laptop.contains(frame))
    }

    /// Left on the 5K, reopened on the laptop.
    @Test("A frame larger than the screen is cut down to fit it")
    func shrinksToTheScreen() {
        let huge = CGRect(x: 0, y: 0, width: 2400, height: 1380)
        let frame = WindowPlacement.restoring(huge, onVisible: Self.laptop)
        #expect(frame.width == Self.laptop.width)
        #expect(frame.height == Self.laptop.height)
        #expect(Self.laptop.contains(frame))
    }

    @Test("A frame smaller than the window can be is grown to the minimum")
    func enforcesTheMinimum() {
        let sliver = CGRect(x: 10, y: 10, width: 200, height: 120)
        let frame = WindowPlacement.restoring(sliver, onVisible: Self.laptop)
        #expect(frame.size == WindowPlacement.minimumSize)
    }

    /// The floor and the ceiling contradict each other here. The ceiling has to
    /// win, or the close button is off the screen and the window is a trap.
    @Test("On a screen smaller than the minimum, fitting the screen wins")
    func ceilingBeatsFloor() {
        let tiny = CGRect(x: 0, y: 0, width: 640, height: 400)
        let frame = WindowPlacement.restoring(
            CGRect(x: 0, y: 0, width: 900, height: 700), onVisible: tiny
        )
        #expect(frame == tiny)
    }

    @Test("Nothing remembered falls through to opening")
    func emptyFrameOpensFresh() {
        let frame = WindowPlacement.restoring(.zero, onVisible: Self.laptop)
        #expect(frame == WindowPlacement.opening(onVisible: Self.laptop))
    }

    // MARK: - Choosing a screen

    @Test("A remembered frame goes back to the screen it was on")
    func picksTheOwningScreen() {
        let screens = [Self.laptop, CGRect(x: 1512, y: 0, width: 2560, height: 1415)]
        let onSecond = CGRect(x: 2000, y: 200, width: 1000, height: 700)
        #expect(WindowPlacement.indexOfScreen(holding: onSecond, among: screens) == 1)
    }

    /// Dragged between two displays and left there. It should reopen where most
    /// of it was, not where its bottom-left corner happened to be.
    @Test("A frame straddling two screens goes to the one holding most of it")
    func picksTheMajorityScreen() {
        let screens = [Self.laptop, CGRect(x: 1512, y: 0, width: 2560, height: 1415)]
        let straddling = CGRect(x: 1300, y: 200, width: 1000, height: 700)
        #expect(WindowPlacement.indexOfScreen(holding: straddling, among: screens) == 1)
    }

    @Test("A frame on no screen at all names none")
    func namesNoScreenWhenGone() {
        let far = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        #expect(WindowPlacement.indexOfScreen(holding: far, among: [Self.laptop]) == nil)
    }

    /// Screens touch exactly at their shared edge, and an intersection of zero
    /// area is not the window being on that display.
    @Test("Merely touching an edge is not being on the screen")
    func edgeContactIsNotOverlap() {
        let touching = CGRect(x: 1512, y: 0, width: 800, height: 600)
        #expect(WindowPlacement.indexOfScreen(holding: touching, among: [Self.laptop]) == nil)
    }
}
