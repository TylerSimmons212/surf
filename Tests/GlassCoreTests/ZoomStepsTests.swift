import Testing

@testable import GlassCore

@Suite("Zoom steps")
struct ZoomStepsTests {

    @Test("Stepping up and back down returns to where it started")
    func roundTrip() {
        // The reason for a fixed ladder: a multiplier never lands back on 100%.
        var level = ZoomSteps.standard
        level = ZoomSteps.zoomingIn(from: level)
        level = ZoomSteps.zoomingOut(from: level)
        #expect(ZoomSteps.isStandard(level))
    }

    @Test("Each step moves exactly one stop")
    func singleStop() {
        #expect(ZoomSteps.zoomingIn(from: 1.0) == 1.1)
        #expect(ZoomSteps.zoomingIn(from: 1.1) == 1.25)
        #expect(ZoomSteps.zoomingOut(from: 1.0) == 0.9)
        #expect(ZoomSteps.zoomingOut(from: 0.9) == 0.8)
    }

    @Test("An off-ladder value moves to the nearest stop, not to the end")
    func offLadder() {
        #expect(ZoomSteps.zoomingIn(from: 1.02) == 1.1)
        #expect(ZoomSteps.zoomingOut(from: 1.02) == 1.0)
        #expect(ZoomSteps.zoomingIn(from: 0.55) == 0.67)
    }

    @Test("The ladder has ends and stays on them")
    func clamped() {
        let top = ZoomSteps.levels.last!
        let bottom = ZoomSteps.levels.first!
        #expect(ZoomSteps.zoomingIn(from: top) == top)
        #expect(ZoomSteps.zoomingIn(from: 99) == top)
        #expect(ZoomSteps.zoomingOut(from: bottom) == bottom)
        #expect(ZoomSteps.zoomingOut(from: 0.01) == bottom)
    }

    @Test("A stop doesn't step onto itself through floating-point drift")
    func tolerates() {
        // 0.1 + 0.2 style drift is exactly how a level arrives slightly off.
        #expect(ZoomSteps.zoomingIn(from: 1.0000001) == 1.1)
        #expect(ZoomSteps.zoomingOut(from: 0.9999999) == 0.9)
    }

    @Test("Every level is reachable by stepping up from the bottom")
    func ladderIsConnected() {
        var level = ZoomSteps.levels.first!
        var visited = [level]
        while level != ZoomSteps.levels.last! {
            let next = ZoomSteps.zoomingIn(from: level)
            #expect(next > level)
            level = next
            visited.append(level)
        }
        #expect(visited == ZoomSteps.levels)
    }

    @Test("Labels read as percentages", arguments: [
        (0.5, "50%"), (1.0, "100%"), (1.25, "125%"), (0.67, "67%"), (3.0, "300%"),
    ])
    func labels(level: Double, expected: String) {
        #expect(ZoomSteps.label(for: level) == expected)
    }
}

@Suite("Find status")
struct FindStatusTests {

    @Test("Says nothing until something is typed")
    func emptyQuery() {
        #expect(FindStatus.summary(query: "", matches: 0).isEmpty)
        #expect(FindStatus.summary(query: "   ", matches: 0).isEmpty)
        // Even with a stale count from a previous query.
        #expect(FindStatus.summary(query: "", matches: 9).isEmpty)
    }

    @Test("Counts read naturally", arguments: [
        (0, "No results"), (1, "1 match"), (2, "2 matches"), (48, "48 matches"),
    ])
    func counts(matches: Int, expected: String) {
        #expect(FindStatus.summary(query: "swift", matches: matches) == expected)
    }

    @Test("Results are only claimed when there is a query and a match")
    func hasResults() {
        #expect(FindStatus.hasResults(query: "swift", matches: 3))
        #expect(!FindStatus.hasResults(query: "swift", matches: 0))
        #expect(!FindStatus.hasResults(query: "", matches: 3))
    }
}
