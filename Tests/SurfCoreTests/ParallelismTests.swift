import Foundation
import Testing
@testable import SurfCore

@Suite("Parallelism")
struct ParallelismTests {

    /// Feeds a whole window at one rate, in MB/s, and returns the new count.
    private func window(
        _ parallelism: inout Parallelism, mbPerSecond: Double, segments: Int = Parallelism.window
    ) -> Int {
        var allowed = parallelism.allowed
        for _ in 0..<segments {
            let bytes = 4 * 1_048_576
            allowed = parallelism.completed(
                bytes: bytes, seconds: Double(bytes) / (mbPerSecond * 1_048_576)
            )
        }
        return allowed
    }

    // MARK: - Where it starts

    @Test("It starts at four and will not exceed eight")
    func bounds() {
        #expect(Parallelism().allowed == 4)
        #expect(Parallelism.start == 4)
        #expect(Parallelism.ceiling == 8)
    }

    @Test("A nonsense configuration is clamped rather than obeyed", arguments: [
        (0, 8, 1), (-5, 8, 1), (99, 8, 8), (4, 0, 1), (4, 2, 2),
    ])
    func clamping(_ start: Int, _ maximum: Int, _ expected: Int) {
        // Zero would ask for nothing forever, which is a hang rather than an
        // error.
        #expect(Parallelism(start: start, maximum: maximum).allowed == expected)
    }

    // MARK: - Judging needs a window, not a segment

    @Test("One segment is latency and decides nothing")
    func oneSampleDecidesNothing() {
        var parallelism = Parallelism()
        #expect(parallelism.completed(bytes: 1_048_576, seconds: 0.1) == 4)
        #expect(parallelism.allowed == 4)
    }

    @Test("Nonsense samples are ignored", arguments: [
        (0, 1.0), (-1, 1.0), (1_048_576, 0.0), (1_048_576, -1.0),
    ])
    func rejectsNonsense(_ bytes: Int, _ seconds: Double) {
        var parallelism = Parallelism()
        for _ in 0..<20 { _ = parallelism.completed(bytes: bytes, seconds: seconds) }
        // Never moved, and never divided by zero on the way.
        #expect(parallelism.allowed == 4)
    }

    @Test("An infinite duration is ignored")
    func rejectsInfinity() {
        var parallelism = Parallelism()
        for _ in 0..<20 {
            _ = parallelism.completed(bytes: 1_048_576, seconds: .infinity)
        }
        #expect(parallelism.allowed == 4)
    }

    // MARK: - Climbing

    @Test("The first window is a baseline and buys one step")
    func firstWindowProbes() {
        var parallelism = Parallelism()
        #expect(window(&parallelism, mbPerSecond: 10) == 5)
    }

    @Test("A rise that pays for itself is kept, and tried again")
    func keepsWhatPays() {
        var parallelism = Parallelism()
        _ = window(&parallelism, mbPerSecond: 10)
        #expect(parallelism.allowed == 5)
        // Each window clearly faster than the last, so it keeps climbing to the
        // ceiling and stops there.
        _ = window(&parallelism, mbPerSecond: 20)
        #expect(parallelism.allowed == 6)
        _ = window(&parallelism, mbPerSecond: 40)
        #expect(parallelism.allowed == 7)
        _ = window(&parallelism, mbPerSecond: 80)
        #expect(parallelism.allowed == 8)
        _ = window(&parallelism, mbPerSecond: 160)
        #expect(parallelism.allowed == 8)
    }

    @Test("A rise that bought nothing is given back")
    func revertsWhatDoesNotPay() {
        var parallelism = Parallelism()
        _ = window(&parallelism, mbPerSecond: 10)
        #expect(parallelism.allowed == 5)
        // Same speed at five as at four: the extra connection did nothing.
        _ = window(&parallelism, mbPerSecond: 10)
        #expect(parallelism.allowed == 4)
    }

    @Test("A rise within the noise does not count as paying")
    func marginsBelowThresholdDoNotCount() {
        // Ten per cent is indistinguishable from the variance between two windows
        // of the same download. Keeping a connection that bought noise is how you
        // reach the ceiling by accident.
        var parallelism = Parallelism()
        _ = window(&parallelism, mbPerSecond: 10)
        _ = window(&parallelism, mbPerSecond: 11)
        #expect(parallelism.allowed == 4)
    }

    @Test("Climbing stops for good once it has failed")
    func stopsClimbingPermanently() {
        var parallelism = Parallelism()
        _ = window(&parallelism, mbPerSecond: 10)
        _ = window(&parallelism, mbPerSecond: 10)
        #expect(parallelism.allowed == 4)
        // A link does not get faster later in the same download. Probing again
        // against a server that already said no is how a back-off becomes a
        // sawtooth.
        for rate in [100.0, 200.0, 400.0] {
            _ = window(&parallelism, mbPerSecond: rate)
        }
        #expect(parallelism.allowed == 4)
    }

    @Test("It never climbs past the maximum it was given")
    func respectsMaximum() {
        var parallelism = Parallelism(start: 2, maximum: 3)
        for rate in [10.0, 100.0, 1000.0, 10000.0] {
            _ = window(&parallelism, mbPerSecond: rate)
        }
        #expect(parallelism.allowed == 3)
    }

    // MARK: - Giving ground

    @Test("Pushback halves rather than stepping down")
    func throttlingHalves() {
        // Being throttled costs more than being one connection short, so ground is
        // given faster than it was taken.
        var parallelism = Parallelism(start: 8)
        #expect(parallelism.throttled() == 4)
        #expect(parallelism.throttled() == 2)
        #expect(parallelism.throttled() == 1)
        #expect(parallelism.throttled() == 1)
    }

    @Test("Pushback also stops the climbing")
    func throttlingStopsClimbing() {
        var parallelism = Parallelism()
        _ = parallelism.throttled()
        #expect(parallelism.allowed == 2)
        for rate in [100.0, 200.0, 400.0] {
            _ = window(&parallelism, mbPerSecond: rate)
        }
        #expect(parallelism.allowed == 2)
    }

    @Test("Pushback discards the half-window it was judging")
    func throttlingDiscardsSamples() {
        // Otherwise the samples from before the back-off are averaged with the
        // ones after it, and the comparison is against a rate that no longer
        // describes anything.
        var parallelism = Parallelism()
        _ = window(&parallelism, mbPerSecond: 10, segments: Parallelism.window - 1)
        _ = parallelism.throttled()
        #expect(parallelism.allowed == 2)
        _ = parallelism.completed(bytes: 1_048_576, seconds: 0.01)
        #expect(parallelism.allowed == 2)
    }

    // MARK: - Which statuses mean "fewer connections"

    @Test("Statuses that mean back off", arguments: [429, 503])
    func throttlingStatuses(_ status: Int) {
        #expect(Parallelism.isThrottling(status: status))
    }

    @Test("Statuses that do not", arguments: [200, 206, 301, 400, 401, 403, 404, 500, 502])
    func nonThrottlingStatuses(_ status: Int) {
        // 403 most of all. It means this URL is not for us, and no amount of
        // backing off changes that — treating it as pushback would quietly crawl
        // to one connection and then still fail.
        #expect(!Parallelism.isThrottling(status: status))
    }
}
