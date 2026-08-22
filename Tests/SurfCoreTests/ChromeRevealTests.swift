import Testing
@testable import SurfCore

@Suite("Chrome reveal")
struct ChromeRevealTests {

    @Test("An idle pointer reveals nothing")
    func idle() {
        #expect(!ChromeReveal.shouldReveal(ChromePointer()))
    }

    @Test("The edge reveals the sidebar")
    func edge() {
        #expect(ChromeReveal.shouldReveal(ChromePointer(inEdge: true)))
    }

    @Test("The revealed panel keeps itself up")
    func panel() {
        // The panel is wider than the edge strip that summoned it, so the
        // pointer spends most of its time past the strip — the panel has to
        // count as its own zone or it would dismiss under the pointer.
        #expect(ChromeReveal.shouldReveal(ChromePointer(inSidebar: true)))
    }

    @Test("A hold keeps the sidebar with the pointer nowhere near it")
    func holdWins() {
        // A popover the sidebar opened is on screen; reaching into it means
        // leaving the panel, and that must not take the popover's anchor away.
        #expect(ChromeReveal.shouldReveal(ChromePointer(sidebarHeld: true)))
    }

    @Test("Leaving every zone puts the sidebar away")
    func leavingEverything() {
        #expect(!ChromeReveal.shouldReveal(
            ChromePointer(inEdge: false, inSidebar: false, sidebarHeld: false)
        ))
    }

    @Test("Opening is quick and closing is forgiving")
    func delaysAreAsymmetric() {
        // Closing has to outlast the gap between the edge zone and the panel
        // it revealed, or crossing that gap dismisses the thing you're
        // reaching for.
        #expect(ChromeReveal.delay(revealing: true) < ChromeReveal.delay(revealing: false))
        #expect(ChromeReveal.delay(revealing: true) == ChromeReveal.openDelay)
        #expect(ChromeReveal.delay(revealing: false) == ChromeReveal.closeDelay)
    }
}
