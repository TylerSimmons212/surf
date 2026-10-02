import Foundation
import Testing
@testable import SurfCore

@Suite("Segment scheduling")
struct SegmentScheduleTests {

    /// Seven four-second segments, matching the fixture playlist.
    private func even(_ count: Int = 7, window: Int = 6) -> SegmentSchedule {
        SegmentSchedule(durations: Array(repeating: 4, count: count), window: window)
    }

    // MARK: - Handing out work

    @Test("At most a window of segments run at once")
    func windowBoundsConcurrency() {
        var schedule = even(20, window: 4)
        var handed: [Int] = []
        while let next = schedule.next() { handed.append(next) }
        #expect(handed == [0, 1, 2, 3])
        // Not because we ran out of segments. Because four are already running.
        #expect(schedule.count == 20)
    }

    @Test("Work is handed out in order")
    func inOrder() {
        var schedule = even(10, window: 3)
        #expect(schedule.next() == 0)
        #expect(schedule.next() == 1)
        #expect(schedule.next() == 2)
        #expect(schedule.next() == nil)
    }

    @Test("A completion alone does not free lookahead; writing does")
    func completionAloneDoesNotFreeLookahead() {
        // My first version of this test expected index 2 straight after
        // completing 0, and that was wrong about the design rather than finding a
        // bug in it. The window bounds finished-but-unwritten segments as well as
        // running ones, so a completion that has not been written still occupies
        // its slot. That is the memory bound doing its job.
        var schedule = even(10, window: 2)
        _ = schedule.next()
        _ = schedule.next()
        #expect(schedule.next() == nil)

        schedule.complete(0, bytes: 100)
        #expect(schedule.next() == nil)

        // Writing it is what moves the cursor, and the window with it.
        #expect(schedule.takeWritable() == [0])
        #expect(schedule.next() == 2)
    }

    @Test("Nothing is handed out twice")
    func noDuplicates() {
        var schedule = even(30, window: 8)
        var handed: Set<Int> = []
        for _ in 0..<100 {
            guard let next = schedule.next() else {
                // Finish one so the window moves on.
                if let lowest = handed.sorted().first(where: { $0 >= schedule.cursor }) {
                    schedule.complete(lowest, bytes: 1)
                    _ = schedule.takeWritable()
                } else { break }
                continue
            }
            #expect(!handed.contains(next))
            handed.insert(next)
        }
        #expect(handed.count == 30)
    }

    // MARK: - The window is measured from the cursor, which is the backpressure

    @Test("A caller that stops writing stops fetching")
    func writingIsBackpressure() {
        // The window is a bound on finished-but-unwritten segments, not just on
        // concurrency. Without that bound a fast network on a slow disk buffers
        // the whole download in memory.
        var schedule = even(100, window: 3)
        for _ in 0..<3 { _ = schedule.next() }
        // Complete 1 and 2 but not 0, so nothing can be written.
        schedule.complete(1, bytes: 1)
        schedule.complete(2, bytes: 1)
        #expect(schedule.takeWritable().isEmpty)
        // 0 is still running, and the window reaches only to 3.
        #expect(schedule.next() == nil)
    }

    @Test("Writing moves the window along")
    func writingMovesTheWindow() {
        var schedule = even(100, window: 3)
        for _ in 0..<3 { _ = schedule.next() }
        schedule.complete(0, bytes: 1)
        schedule.complete(1, bytes: 1)
        schedule.complete(2, bytes: 1)
        #expect(schedule.takeWritable() == [0, 1, 2])
        #expect(schedule.next() == 3)
    }

    // MARK: - Writing is always contiguous

    @Test("Nothing is written before its turn")
    func writesAreOrdered() {
        var schedule = even(5, window: 5)
        for _ in 0..<5 { _ = schedule.next() }
        // Arrive backwards, which is what parallel fetching does.
        schedule.complete(4, bytes: 1)
        schedule.complete(3, bytes: 1)
        #expect(schedule.takeWritable().isEmpty)
        schedule.complete(2, bytes: 1)
        #expect(schedule.takeWritable().isEmpty)
        schedule.complete(1, bytes: 1)
        #expect(schedule.takeWritable().isEmpty)
        // Only once the first one lands does the whole run become writable.
        schedule.complete(0, bytes: 1)
        #expect(schedule.takeWritable() == [0, 1, 2, 3, 4])
    }

    @Test("Writable runs are never handed out twice")
    func writableIsConsumed() {
        var schedule = even(3, window: 3)
        for _ in 0..<3 { _ = schedule.next() }
        schedule.complete(0, bytes: 1)
        #expect(schedule.takeWritable() == [0])
        #expect(schedule.takeWritable().isEmpty)
        schedule.complete(1, bytes: 1)
        #expect(schedule.takeWritable() == [1])
    }

    @Test("Whatever the order, every segment is written exactly once and in order")
    func everyOrderWritesTheSameFile(/* the property that matters */) {
        // The file is the product. However the network interleaves, the sequence
        // of appends has to be 0, 1, 2, ... exactly once each.
        for seed in UInt64(1)...40 {
            var generator = SeededGenerator(seed: seed)
            var schedule = SegmentSchedule(
                durations: Array(repeating: 4, count: 25), window: 5
            )
            var written: [Int] = []
            var running: [Int] = []

            while !schedule.isDrained {
                while let next = schedule.next() { running.append(next) }
                guard !running.isEmpty else { break }
                let pick = Int(generator.next() % UInt64(running.count))
                schedule.complete(running.remove(at: pick), bytes: 10)
                written += schedule.takeWritable()
            }

            #expect(written == Array(0..<25), "interleaving \(seed) wrote \(written.count)")
        }
    }

    // MARK: - Progress

    @Test("Progress is weighted by duration, not by segment count")
    func weightedProgress() {
        // One long segment and three short ones. Counting would call the first
        // one 25% of the download; it is 70% of it.
        var schedule = SegmentSchedule(durations: [70, 10, 10, 10], window: 4)
        _ = schedule.next()
        schedule.complete(0, bytes: 1)
        #expect(abs(schedule.fraction - 0.7) < 0.0001)
    }

    @Test("Progress never goes backwards, whatever the order")
    func progressIsMonotone() {
        for seed in UInt64(1)...25 {
            var generator = SeededGenerator(seed: seed)
            var schedule = SegmentSchedule(
                durations: (1...20).map { Double($0 % 7 + 1) }, window: 6
            )
            var last = 0.0
            var running: [Int] = []
            while !schedule.isDrained {
                while let next = schedule.next() { running.append(next) }
                guard !running.isEmpty else { break }
                let pick = Int(generator.next() % UInt64(running.count))
                schedule.complete(running.remove(at: pick), bytes: 5)
                _ = schedule.takeWritable()
                #expect(schedule.fraction >= last)
                last = schedule.fraction
            }
            #expect(abs(last - 1) < 0.0001)
        }
    }

    @Test("A playlist that declared no durations still reports progress")
    func undeclaredDurations() {
        // Falls back to counting, because a bar that never moves is worse than
        // one weighted slightly wrong.
        var schedule = SegmentSchedule(durations: [0, 0, 0, 0], window: 4)
        _ = schedule.next()
        schedule.complete(0, bytes: 1)
        #expect(abs(schedule.fraction - 0.25) < 0.0001)
    }

    @Test("Nothing to do is already finished")
    func emptySchedule() {
        var schedule = SegmentSchedule(durations: [], window: 4)
        #expect(schedule.fraction == 1)
        #expect(schedule.isComplete)
        #expect(schedule.isDrained)
        #expect(schedule.next() == nil)
        #expect(!schedule.isStalled)
    }

    @Test("Bytes are counted once, even if a completion arrives twice")
    func bytesAreNotDoubleCounted() {
        var schedule = even(3)
        _ = schedule.next()
        schedule.complete(0, bytes: 500)
        schedule.complete(0, bytes: 500)
        #expect(schedule.bytesWritten == 500)
    }

    @Test("An out-of-range index is ignored rather than trusted")
    func outOfRangeIsIgnored() {
        var schedule = even(3)
        schedule.complete(99, bytes: 1_000_000)
        schedule.complete(-1, bytes: 1_000_000)
        #expect(schedule.bytesWritten == 0)
        #expect(!schedule.isComplete)
    }

    // MARK: - Failure

    @Test("A segment is retried up to its limit, then gives up")
    func retriesThenGivesUp() {
        var schedule = SegmentSchedule(durations: [4, 4], window: 2, attemptLimit: 3)
        _ = schedule.next()
        #expect(schedule.fail(0) == .retry(attempt: 1))
        _ = schedule.next()
        #expect(schedule.fail(0) == .retry(attempt: 2))
        _ = schedule.next()
        #expect(schedule.fail(0) == .giveUp)
    }

    @Test("A failed segment is handed out again")
    func failureReturnsWorkToTheQueue() {
        var schedule = even(5, window: 2)
        #expect(schedule.next() == 0)
        _ = schedule.fail(0)
        // Not skipped. The file needs it.
        #expect(schedule.next() == 0)
    }

    @Test("Giving up stalls the schedule rather than completing it")
    func giveUpStalls() {
        // The failure that matters. A download whose last segment gave up must
        // not read as finished, and must not leave the runner waiting on a
        // completion that is never coming.
        var schedule = SegmentSchedule(durations: [4], window: 2, attemptLimit: 1)
        _ = schedule.next()
        #expect(schedule.fail(0) == .giveUp)
        #expect(!schedule.isComplete)
        #expect(!schedule.isDrained)
        #expect(schedule.isStalled)
    }

    @Test("A schedule with work still running is not stalled")
    func runningIsNotStalled() {
        var schedule = even(5, window: 2)
        _ = schedule.next()
        #expect(!schedule.isStalled)
    }

    // MARK: - Resuming

    @Test("A resumed schedule starts where the file left off")
    func resume() {
        var schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: 10), window: 3,
            completed: [0, 1, 2, 3]
        )
        #expect(schedule.cursor == 4)
        #expect(schedule.next() == 4)
        #expect(abs(schedule.fraction - 0.4) < 0.0001)
        // Already in the file, so not offered to the writer again.
        #expect(schedule.takeWritable().isEmpty)
    }

    @Test("Only the leading run of a resume is believed")
    func resumeStopsAtTheFirstGap() {
        // The output is an in-order append, so the file holds 0 and 1 and cannot
        // hold 5. Trusting the whole set would leave a hole in the file.
        var schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: 8), window: 4,
            completed: [0, 1, 5, 6]
        )
        #expect(schedule.cursor == 2)
        #expect(schedule.next() == 2)
        #expect(abs(schedule.fraction - 0.25) < 0.0001)
    }

    @Test("A resume of everything is finished")
    func resumeComplete() {
        let schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: 4), window: 4,
            completed: [0, 1, 2, 3]
        )
        #expect(schedule.isComplete)
        #expect(schedule.isDrained)
        #expect(schedule.fraction == 1)
    }

    @Test("Nonsense in a resume set is discarded")
    func resumeIgnoresGarbage() {
        let schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: 3), window: 2,
            completed: [-5, 99]
        )
        #expect(schedule.cursor == 0)
        #expect(!schedule.isComplete)
    }

    // MARK: - Configuration

    @Test("A window or an attempt limit below one is raised to one")
    func degenerateConfiguration() {
        // Zero would hand out nothing forever, which is a hang rather than an
        // error.
        let schedule = SegmentSchedule(durations: [4], window: 0, attemptLimit: 0)
        #expect(schedule.window == 1)
        #expect(schedule.attemptLimit == 1)
    }
}

/// Reproducible interleavings. A random order that cannot be replayed is not a
/// test, it is an anecdote.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
