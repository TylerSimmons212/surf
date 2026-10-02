import Foundation
import Testing
@testable import SurfCore

@Suite("Byte ranges")
struct ByteRangesTests {

    private let mb = 1 << 20

    // MARK: - Covering the file exactly

    @Test("Pieces are contiguous and cover the whole file", arguments: [
        (100 << 20, 4), (100 << 20, 8), (9 << 20, 4), (1 << 30, 8), (8 << 20, 2),
    ])
    func coverage(_ length: Int, _ count: Int) {
        let ranges = ByteRanges.chunks(of: length, into: count)
        #expect(!ranges.isEmpty)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == length)
        // No gaps and no overlaps: a gap is a file with a hole in it and an
        // overlap is a file that is too long. Both play.
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
        #expect(ranges.reduce(0) { $0 + $1.count } == length)
    }

    @Test("A length that does not divide evenly still ends at the end")
    func remainder() {
        // 100MB + 7 bytes into 8. Integer division loses the remainder, and the
        // last piece has to take it — otherwise the file is a few bytes short,
        // which plays and is wrong.
        let length = (100 << 20) + 7
        let ranges = ByteRanges.chunks(of: length, into: 8)
        #expect(ranges.last?.upperBound == length)
        #expect(ranges.reduce(0) { $0 + $1.count } == length)
    }

    @Test("One piece is asked for and one is given")
    func single() {
        let ranges = ByteRanges.chunks(of: 50 << 20, into: 1)
        #expect(ranges == [0..<(50 << 20)])
    }

    // MARK: - The minimum piece

    @Test("A small file gets fewer pieces than were asked for")
    func honoursMinimum() {
        // Four megabytes into eight pieces would be eight half-megabyte requests,
        // where the overhead is a measurable fraction of the transfer. Four
        // pieces of a megabyte each instead.
        let ranges = ByteRanges.chunks(of: 4 * (1 << 20), into: 8)
        #expect(ranges.count == 4)
        #expect(ranges.allSatisfy { $0.count >= ByteRanges.minimumChunk })
    }

    @Test("A file smaller than one piece is not split")
    func tinyFile() {
        let ranges = ByteRanges.chunks(of: 500_000, into: 8)
        #expect(ranges == [0..<500_000])
    }

    @Test("Every piece is at least the minimum, or there is only one", arguments: [
        1, 1024, 500_000, 1 << 20, (3 << 20) + 11, 9 << 20, 100 << 20,
    ])
    func minimumHolds(_ length: Int) {
        let ranges = ByteRanges.chunks(of: length, into: 8)
        guard ranges.count > 1 else { return }
        // The last piece carries the remainder so it can be larger, never smaller.
        #expect(ranges.dropLast().allSatisfy { $0.count >= ByteRanges.minimumChunk })
    }

    // MARK: - Nothing to divide

    @Test("An unusable length produces nothing to do", arguments: [
        (0, 4), (-1, 4), (100 << 20, 0), (100 << 20, -3),
    ])
    func unusable(_ length: Int, _ count: Int) {
        // Empty, which the caller has to read as "fetch it the ordinary way"
        // rather than "fetch nothing".
        #expect(ByteRanges.chunks(of: length, into: count).isEmpty)
    }

    // MARK: - Whether the server will play along

    @Test("Ranges need both a promise and a length")
    func support() {
        #expect(ByteRanges.areSupported(acceptRanges: "bytes", contentLength: 100 << 20))
        #expect(ByteRanges.areSupported(acceptRanges: "Bytes", contentLength: 100 << 20))
        // A length with no promise. The server may still honour a range, but
        // guessing wrong means a request that returns the whole file where a
        // piece was expected — refused, correctly, after transferring all of it.
        #expect(!ByteRanges.areSupported(acceptRanges: nil, contentLength: 100 << 20))
        #expect(!ByteRanges.areSupported(acceptRanges: "none", contentLength: 100 << 20))
        // A promise with no length. Nothing to divide.
        #expect(!ByteRanges.areSupported(acceptRanges: "bytes", contentLength: nil))
        #expect(!ByteRanges.areSupported(acceptRanges: "bytes", contentLength: 0))
    }

    // MARK: - Whether it is worth it at all

    @Test("A large file with range support is worth splitting")
    func worthIt() {
        #expect(ByteRanges.worthSplitting(length: 300 << 20, acceptRanges: "bytes"))
    }

    @Test("A small file is not, however co-operative the server is")
    func notWorthItWhenSmall() {
        // Changing the most common download in the browser for no measurable gain
        // is not a trade worth making, so under the threshold the existing path
        // through WebKit keeps it.
        #expect(!ByteRanges.worthSplitting(length: 4 << 20, acceptRanges: "bytes"))
        #expect(!ByteRanges.worthSplitting(length: ByteRanges.worthSplitting - 1,
                                           acceptRanges: "bytes"))
        #expect(ByteRanges.worthSplitting(length: ByteRanges.worthSplitting,
                                          acceptRanges: "bytes"))
    }

    @Test("A large file without range support is not")
    func notWorthItWithoutSupport() {
        #expect(!ByteRanges.worthSplitting(length: 300 << 20, acceptRanges: nil))
    }

    @Test("An unknown length is not")
    func notWorthItWithoutLength() {
        // A chunked response has no length, and there is nothing to divide.
        #expect(!ByteRanges.worthSplitting(length: nil, acceptRanges: "bytes"))
    }

    // MARK: - What the schedule will see

    @Test("Ranges become segments the existing schedule can drive")
    func feedsTheSchedule() {
        // The payoff: a plain file turns into the same shape as a segmented
        // stream, so nothing downstream needs to know the difference.
        let ranges = ByteRanges.chunks(of: 100 << 20, into: 8)
        var schedule = SegmentSchedule(
            durations: Array(repeating: 0, count: ranges.count),
            window: Parallelism.ceiling
        )
        var written: [Int] = []
        var running: [Int] = []
        while !schedule.isDrained {
            while let next = schedule.next(upTo: 4) { running.append(next) }
            guard !running.isEmpty else { break }
            // Arrive backwards, which is what parallel fetching does.
            schedule.complete(running.removeLast(), bytes: 1)
            written += schedule.takeWritable()
        }
        #expect(written == Array(0..<ranges.count))
    }

    @Test("A file with no duration still reports progress")
    func progressWithoutDurations() {
        // A plain file has no segment durations to weight by, so the schedule
        // falls back to counting. A bar that never moves would be worse.
        var schedule = SegmentSchedule(durations: Array(repeating: 0, count: 4), window: 4)
        _ = schedule.next()
        schedule.complete(0, bytes: 10)
        #expect(abs(schedule.fraction - 0.25) < 0.0001)
    }
}
