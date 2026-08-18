import CoreGraphics
import Testing

@testable import GlassCore

@Suite("Performance metrics")
struct PerformanceMetricTests {

    /// The rating table has to match everyone else's, or a number here means
    /// something different from the same number in Lighthouse.
    @Test("Metrics rate against the Core Web Vitals thresholds")
    func ratings() {
        #expect(PerformanceMetric(kind: .lcp, value: 2000).rating == .good)
        #expect(PerformanceMetric(kind: .lcp, value: 3000).rating == .needsWork)
        #expect(PerformanceMetric(kind: .lcp, value: 5000).rating == .poor)
        #expect(PerformanceMetric(kind: .cls, value: 0.05).rating == .good)
        #expect(PerformanceMetric(kind: .cls, value: 0.3).rating == .poor)
        #expect(PerformanceMetric(kind: .inp, value: 150).rating == .good)
    }

    /// An approximation is still the best answer available on this engine.
    /// Leaving it unrated would invite ignoring it, which defeats computing it.
    @Test("An approximated metric is still rated")
    func approximationsRate() {
        let cls = PerformanceMetric(
            kind: .cls, value: 0.4, source: .approximated("watched for movement")
        )
        #expect(cls.rating == .poor)
        #expect(cls.source.note == "watched for movement")
        #expect(!cls.source.isMeasured)
    }

    /// A metric with no value can't be rated, and one the platform can't
    /// provide must never look like a good score.
    @Test("Absent and unavailable metrics are unrated")
    func unrated() {
        #expect(PerformanceMetric(kind: .lcp).rating == .unrated)
        #expect(
            PerformanceMetric(kind: .cls, value: 0, source: .unavailable("not implemented"))
                .rating == .unrated
        )
    }

    @Test("Values read in the unit that suits them")
    func display() {
        #expect(PerformanceMetric(kind: .fcp, value: 850).display == "850 ms")
        #expect(PerformanceMetric(kind: .lcp, value: 2500).display == "2.50 s")
        #expect(PerformanceMetric(kind: .cls, value: 0.125).display == "0.125")
        #expect(PerformanceMetric(kind: .lcp).display == "—")
    }
}

@Suite("Cumulative layout shift")
struct CumulativeLayoutShiftTests {

    private func shift(at: Double, _ value: Double) -> LayoutShift {
        LayoutShift(at: at, value: value)
    }

    /// The mistake a naive implementation makes. CLS is the largest session
    /// window, not a running total — summing everything makes any long-lived
    /// page score arbitrarily badly just for staying open.
    @Test("A one-second gap starts a new window rather than accumulating")
    func sessionWindows() {
        let shifts = [
            shift(at: 0, 0.1), shift(at: 200, 0.1),
            // A gap of more than a second: everything after is a new window.
            shift(at: 5_000, 0.05),
        ]
        #expect(CumulativeLayoutShift.score(shifts) == 0.2)
    }

    @Test("A window closes after five seconds even without a gap")
    func fiveSecondCap() {
        // Shifts every 500 ms for twelve seconds: no gap ever reaches a second,
        // so only the cap can end a window.
        let shifts = stride(from: 0.0, through: 12_000, by: 500).map { shift(at: $0, 0.01) }
        let score = CumulativeLayoutShift.score(shifts)
        #expect(score < 0.12)
        #expect(score > 0)
    }

    @Test("The largest window wins, not the last one")
    func largestWindow() {
        let shifts = [
            shift(at: 0, 0.3),
            shift(at: 4_000, 0.01),
            shift(at: 8_000, 0.02),
        ]
        #expect(CumulativeLayoutShift.score(shifts) == 0.3)
    }

    @Test("No shifts is a score of zero, not an absent one")
    func empty() {
        #expect(CumulativeLayoutShift.score([]) == 0)
    }

    @Test("Shifts reported out of order still group correctly")
    func unordered() {
        let shifts = [shift(at: 5_000, 0.05), shift(at: 0, 0.1), shift(at: 200, 0.1)]
        #expect(CumulativeLayoutShift.score(shifts) == 0.2)
    }

    // MARK: - The impact formula

    /// Both factors matter. A small element crossing the screen and a full-width
    /// banner nudging one pixel are very different, and either factor alone
    /// would call one of them fine.
    @Test("A shift is scored on how much moved and how far")
    func impactFormula() {
        let viewport = CGSize(width: 1000, height: 1000)

        // Half the viewport, moved a tenth of it.
        let big = CumulativeLayoutShift.impact(
            before: CGRect(x: 0, y: 0, width: 1000, height: 400),
            after: CGRect(x: 0, y: 100, width: 1000, height: 400),
            viewport: viewport
        )
        // Union is 1000×500 = 0.5 impact; distance 100/1000 = 0.1.
        #expect(abs(big - 0.05) < 0.0001)

        // A tiny element moving the same distance scores far less.
        let small = CumulativeLayoutShift.impact(
            before: CGRect(x: 0, y: 0, width: 10, height: 10),
            after: CGRect(x: 0, y: 100, width: 10, height: 10),
            viewport: viewport
        )
        #expect(small < big)

        // A big element that barely moves also scores far less.
        let nudge = CumulativeLayoutShift.impact(
            before: CGRect(x: 0, y: 0, width: 1000, height: 400),
            after: CGRect(x: 0, y: 1, width: 1000, height: 400),
            viewport: viewport
        )
        #expect(nudge < big)
    }

    @Test("A degenerate viewport scores nothing rather than dividing by zero")
    func zeroViewport() {
        #expect(
            CumulativeLayoutShift.impact(
                before: .zero, after: CGRect(x: 0, y: 10, width: 10, height: 10),
                viewport: .zero
            ) == 0
        )
    }
}

@Suite("Total blocking time")
struct TotalBlockingTimeTests {

    /// Only the part past 50 ms counts — that's the metric's definition, and
    /// summing whole task durations would roughly double a typical score.
    @Test("Only the time past fifty milliseconds counts")
    func pastTheThreshold() {
        #expect(BlockingEvent(at: 0, duration: 120).blockingTime == 70)
        #expect(BlockingEvent(at: 0, duration: 50).blockingTime == 0)
        #expect(BlockingEvent(at: 0, duration: 20).blockingTime == 0)
    }

    @Test("The total adds up each task's excess")
    func total() {
        let events = [
            BlockingEvent(at: 0, duration: 120),
            BlockingEvent(at: 300, duration: 80),
            BlockingEvent(at: 600, duration: 30),
        ]
        #expect(TotalBlockingTime.total(events) == 100)
    }

    @Test("No long tasks is zero blocking time")
    func none() {
        #expect(TotalBlockingTime.total([]) == 0)
    }
}
