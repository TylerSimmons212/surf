import Testing

@testable import SurfCore

@Suite("Load progress")
struct LoadProgressTests {

    @Test("Nothing is drawn before a load starts")
    func idle() {
        var progress = LoadProgress()
        #expect(progress.value == 0)
        #expect(!progress.isVisible)
        // A stray report from a finished load can't resurrect the indicator.
        let accepted = progress.report(0.5)
        #expect(!accepted)
        #expect(!progress.isVisible)
    }

    @Test("Starting shows a visible sliver immediately")
    func begin() {
        var progress = LoadProgress()
        progress.begin()
        #expect(progress.isVisible)
        #expect(progress.value == LoadProgress.start)
    }

    @Test("Reported progress only ever moves forward")
    func monotonic() {
        var progress = LoadProgress()
        progress.begin()
        progress.report(0.4)
        #expect(progress.value == 0.4)

        // A redirect restarts the engine's estimate from near zero.
        let backwards = progress.report(0.1)
        #expect(!backwards)
        #expect(progress.value == 0.4)

        let forwards = progress.report(0.7)
        #expect(forwards)
        #expect(progress.value == 0.7)
    }

    @Test("Reported progress is clamped to a full lap")
    func clamped() {
        var progress = LoadProgress()
        progress.begin()
        progress.report(1.6)
        #expect(progress.value == 1)
    }

    @Test("Creeping keeps moving during a stall but never claims to be done")
    func creepApproachesCeiling() {
        var progress = LoadProgress()
        progress.begin()

        var previous = progress.value
        for _ in 0..<10_000 {
            progress.creep()
            // Strictly forward, and never past the ceiling — the two properties
            // that make a fake trickle honest.
            #expect(progress.value >= previous)
            #expect(progress.value < LoadProgress.ceiling)
            previous = progress.value
        }

        // Still asymptotically close, so a long load doesn't sit at a third.
        #expect(progress.value > 0.9)
    }

    @Test("Creeping never drags a real report backwards")
    func creepYieldsToReality() {
        var progress = LoadProgress()
        progress.begin()
        progress.report(0.97)
        let crept = progress.creep()
        #expect(!crept)
        #expect(progress.value == 0.97)
    }

    @Test("Finishing always completes the lap", arguments: [0.02, 0.35, 0.92])
    func completeRunsToOne(from reported: Double) {
        var progress = LoadProgress()
        progress.begin()
        progress.report(reported)
        progress.complete()
        #expect(progress.value == 1)
        #expect(progress.isVisible)
    }

    @Test("Hiding keeps the finished lap in place while it fades")
    func hideKeepsValue() {
        var progress = LoadProgress()
        progress.begin()
        progress.complete()
        progress.hide()
        #expect(!progress.isVisible)
        #expect(progress.value == 1)
        // Hidden means inert: a late report can't light it back up.
        let lateReport = progress.report(0.5)
        #expect(!lateReport)
    }

    @Test("Clearing hides the indicator and rewinds it")
    func clear() {
        var progress = LoadProgress()
        progress.begin()
        progress.report(0.8)
        progress.clear()
        #expect(progress.value == 0)
        #expect(!progress.isVisible)
    }

    @Test("A second load starts from a clean lap")
    func restart() {
        var progress = LoadProgress()
        progress.begin()
        progress.report(0.6)
        progress.complete()
        progress.clear()

        progress.begin()
        #expect(progress.value == LoadProgress.start)
    }

    // MARK: - Ending

    @Test("A load that finishes inside the grace period draws nothing", arguments: [false, true])
    func unseenLoad(failed: Bool) {
        // Never revealed, so there's no arc to finish or fade — even for a
        // failure, which the page itself will report.
        #expect(LoadProgress.ending(shownFor: nil, failed: failed) == .unseen)
    }

    @Test("A failed load fades where it stopped instead of closing the lap")
    func failedLoadFades() {
        #expect(LoadProgress.ending(shownFor: .milliseconds(40), failed: true) == .fade)
        #expect(LoadProgress.ending(shownFor: .seconds(3), failed: true) == .fade)
    }

    @Test("A briefly shown arc is held until it has been seen")
    func briefArcIsHeld() {
        let shown: Duration = .milliseconds(100)
        #expect(
            LoadProgress.ending(shownFor: shown, failed: false)
                == .closeLap(after: LoadProgress.minimumShown - shown)
        )
    }

    @Test("An arc that has been on screen long enough closes at once")
    func longArcClosesNow() {
        #expect(LoadProgress.ending(shownFor: .seconds(2), failed: false) == .closeLap(after: .zero))
        #expect(
            LoadProgress.ending(shownFor: LoadProgress.minimumShown, failed: false)
                == .closeLap(after: .zero)
        )
    }
}
