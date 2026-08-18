import Testing
@testable import GlassCore

@Suite("Chrome reveal arbitration")
struct ChromeRevealTests {

    // MARK: - Nothing to reveal

    @Test("An idle pointer reveals nothing")
    func idle() {
        #expect(ChromeReveal.resolve(ChromePointer(), current: .none) == .none)
    }

    @Test("Leaving every zone puts revealed chrome away")
    func leavingEverything() {
        #expect(ChromeReveal.resolve(ChromePointer(), current: .sidebar) == .none)
        #expect(ChromeReveal.resolve(ChromePointer(), current: .trafficLights) == .none)
    }

    // MARK: - The overlap

    @Test("The corner beats the edge, which covers the same top-left territory")
    func cornerBeatsEdge() {
        // The edge strip runs the full height of the window, so every approach
        // to the lights is also inside it. Resolving to the sidebar here is the
        // exact bug this arbitration exists to prevent.
        let pointer = ChromePointer(inCorner: true, inEdge: true)
        #expect(ChromeReveal.resolve(pointer, current: .none) == .trafficLights)
    }

    @Test("Travelling up the edge to the corner lands on the lights, not the sidebar")
    func travelUpTheEdge() {
        var target = ChromeReveal.resolve(ChromePointer(inEdge: true), current: .none)
        #expect(target == .sidebar)

        // ...but the pointer keeps going and reaches the corner before the
        // sidebar's open delay has elapsed, so nothing was committed yet.
        target = ChromeReveal.resolve(ChromePointer(inCorner: true, inEdge: true), current: .none)
        #expect(target == .trafficLights)
    }

    @Test("The edge alone still reveals the sidebar")
    func edgeAlone() {
        #expect(ChromeReveal.resolve(ChromePointer(inEdge: true), current: .none) == .sidebar)
    }

    // MARK: - Possession

    @Test("An open sidebar keeps the corner while the pointer is inside it")
    func openSidebarKeepsTheCorner() {
        // Reaching for the pin button at the top of an open panel puts the
        // pointer in the corner zone too. Handing the corner to the lights
        // there would collapse the panel out from under the pointer.
        let pointer = ChromePointer(inCorner: true, inSidebar: true)
        #expect(ChromeReveal.resolve(pointer, current: .sidebar) == .sidebar)
    }

    @Test("A closed sidebar has nothing to keep, so the corner wins")
    func closedSidebarYieldsTheCorner() {
        let pointer = ChromePointer(inCorner: true, inSidebar: true)
        #expect(ChromeReveal.resolve(pointer, current: .none) == .trafficLights)
    }

    @Test("Leaving the panel for the corner hands over to the lights")
    func leavingThePanelForTheCorner() {
        let pointer = ChromePointer(inCorner: true, inSidebar: false)
        #expect(ChromeReveal.resolve(pointer, current: .sidebar) == .trafficLights)
    }

    @Test("Possession does not resurrect a sidebar the pointer has already left")
    func possessionNeedsThePointer() {
        #expect(ChromeReveal.resolve(ChromePointer(), current: .sidebar) == .none)
    }

    // MARK: - Holds

    @Test("A hold outranks everything, including the corner")
    func holdWins() {
        // A popover the sidebar opened is on screen; dismissing it to show
        // three buttons is never what was meant.
        let pointer = ChromePointer(inCorner: true, sidebarHeld: true)
        #expect(ChromeReveal.resolve(pointer, current: .trafficLights) == .sidebar)
    }

    @Test("A hold keeps the sidebar even with the pointer nowhere near it")
    func holdSurvivesThePointerLeaving() {
        let pointer = ChromePointer(sidebarHeld: true)
        #expect(ChromeReveal.resolve(pointer, current: .sidebar) == .sidebar)
    }

    // MARK: - Timing

    @Test("Opening is quick and closing is forgiving")
    func delaysAreAsymmetric() {
        // Closing has to outlast the gap between a zone and what it revealed,
        // or crossing that gap dismisses the thing you're reaching for.
        #expect(ChromeReveal.delay(revealing: .none) > ChromeReveal.delay(revealing: .sidebar))
        #expect(ChromeReveal.delay(revealing: .trafficLights) == ChromeReveal.openDelay)
        #expect(ChromeReveal.delay(revealing: .none) == ChromeReveal.closeDelay)
    }

    // MARK: - Geometry

    @Test("The corner zone is larger than the buttons it guards")
    func cornerZoneIsForgiving() {
        // The three buttons span roughly x 7…72 in a 28pt row.
        #expect(ChromeReveal.cornerZone.width > 72)
        #expect(ChromeReveal.cornerZone.height > ChromeReveal.lightsRowHeight)
    }
}
