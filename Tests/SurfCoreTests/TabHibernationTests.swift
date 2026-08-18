import Foundation
import Testing
@testable import SurfCore

@Suite("Tab hibernation")
struct TabHibernationTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Minutes before `now`, for readable ages.
    private func ago(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    private func tab(
        _ id: UUID = UUID(),
        viewed: Date?,
        live: Bool = true,
        protected: Bool = false
    ) -> TabHibernation.Candidate {
        TabHibernation.Candidate(
            id: id, lastViewedAt: viewed, isLive: live, isProtected: protected
        )
    }

    // MARK: - Staleness

    @Test("A tab looked at recently is left alone")
    func recentTabSurvives() {
        let candidates = [tab(viewed: ago(5)), tab(viewed: ago(1))]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now).isEmpty)
    }

    @Test("A tab unviewed past the threshold is slept")
    func staleTabSleeps() {
        let stale = UUID()
        let candidates = [tab(stale, viewed: ago(45)), tab(viewed: ago(2))]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now) == [stale])
    }

    @Test("The threshold is inclusive — exactly stale counts as stale")
    func thresholdIsInclusive() {
        let edge = UUID()
        let candidates = [tab(edge, viewed: now.addingTimeInterval(-TabHibernation.idleThreshold))]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now) == [edge])
    }

    @Test("A tab that has never been shown is slept first — it holds a view that drew nothing")
    func neverViewedSleepsFirst() {
        let never = UUID()
        let candidates = [tab(viewed: ago(2)), tab(never, viewed: nil)]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now) == [never])
    }

    // MARK: - Protection

    @Test("A protected tab is never slept, however stale")
    func protectedTabSurvivesAnyAge() {
        // The selected tab, a tab playing audio, and a popped-out one all arrive
        // here as `isProtected`. Sleeping one would blank the page being read or
        // cut off the track being listened to.
        let candidates = [tab(viewed: ago(600), protected: true)]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now).isEmpty)
    }

    @Test("A tab already asleep is not slept again")
    func sleepingTabIsNotReturned() {
        let candidates = [tab(viewed: ago(999), live: false)]
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now).isEmpty)
    }

    // MARK: - Budget

    @Test("Recent tabs beyond the budget are slept oldest-first")
    func budgetSleepsOldestFirst() {
        // All well within the idle threshold, so only the budget can catch them.
        let ids = (0..<5).map { _ in UUID() }
        let candidates = ids.enumerated().map { index, id in
            tab(id, viewed: ago(Double(5 - index)))  // ids[0] oldest
        }

        let slept = TabHibernation.tabsToSleep(
            among: candidates, now: now, liveBudget: 3
        )

        #expect(slept.count == 2)
        #expect(slept == [ids[0], ids[1]])
    }

    @Test("Protected tabs count against the budget even though they can't be slept")
    func protectedTabsConsumeBudget() {
        // Two protected + three sleepable, budget of 3. The protected pair
        // occupies two of the three slots, so two of the three must go — not
        // one, which is what ignoring them would give.
        let sleepable = (0..<3).map { _ in UUID() }
        var candidates = [
            tab(viewed: ago(1), protected: true),
            tab(viewed: ago(2), protected: true),
        ]
        candidates += sleepable.enumerated().map { index, id in
            tab(id, viewed: ago(Double(10 - index)))  // sleepable[0] oldest
        }

        let slept = TabHibernation.tabsToSleep(
            among: candidates, now: now, liveBudget: 3
        )

        #expect(slept == [sleepable[0], sleepable[1]])
    }

    @Test("Under budget and all fresh, nothing is slept")
    func quietSessionIsUntouched() {
        let candidates = (0..<5).map { _ in tab(viewed: ago(1)) }
        #expect(TabHibernation.tabsToSleep(among: candidates, now: now, liveBudget: 20).isEmpty)
    }

    @Test("Stale and over-budget together produce no duplicates")
    func reasonsDoNotDoubleCount() {
        let ids = (0..<4).map { _ in UUID() }
        let candidates = [
            tab(ids[0], viewed: ago(90)),   // stale
            tab(ids[1], viewed: ago(80)),   // stale
            tab(ids[2], viewed: ago(3)),    // fresh
            tab(ids[3], viewed: ago(2)),    // fresh
        ]

        let slept = TabHibernation.tabsToSleep(
            among: candidates, now: now, liveBudget: 1
        )

        #expect(Set(slept).count == slept.count)
        // Both stale ones go, plus one fresh to get the live count down to 1.
        #expect(slept.count == 3)
        #expect(!slept.contains(ids[3]))  // the newest survives
    }

    @Test("An empty session asks for nothing")
    func emptyIsSafe() {
        #expect(TabHibernation.tabsToSleep(among: [], now: now).isEmpty)
    }
}
