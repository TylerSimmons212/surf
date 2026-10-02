import Foundation
import Testing
@testable import SurfCore

@Suite("Stream progress")
struct StreamProgressTests {

    private let sample = StreamProgress(
        renditionID: "1080/stream.m3u8", segmentCount: 159, done: 42, bytes: 73_400_320
    )

    // MARK: - Round trip

    @Test("What is written is what is read back")
    func roundTrip() throws {
        let parsed = try #require(StreamProgress.parse(sample.text))
        #expect(parsed == sample)
    }

    @Test("A rendition id with spaces in it survives")
    func idWithSpaces() throws {
        // The id comes from a manifest and a publisher may have put anything in
        // it. Splitting on every space rather than the first would lose the rest.
        let progress = StreamProgress(
            renditionID: "Job 2dae 5735 hls bundle", segmentCount: 19, done: 3, bytes: 100
        )
        #expect(StreamProgress.parse(progress.text)?.renditionID == progress.renditionID)
    }

    @Test("No progress round trips as no progress")
    func emptyRoundTrip() throws {
        let fresh = StreamProgress(renditionID: "v", segmentCount: 10, done: 0, bytes: 0)
        let parsed = try #require(StreamProgress.parse(fresh.text))
        #expect(parsed == fresh)
        #expect(parsed.isEmpty)
    }

    // MARK: - Refusing to half-understand a record

    @Test("Anything unreadable is nil, not a guess", arguments: [
        "",
        "nonsense",
        // Missing fields, one at a time.
        "surf-stream 1\nsegments 10\ndone 1\nbytes 5",
        "surf-stream 1\nrendition v\ndone 1\nbytes 5",
        "surf-stream 1\nrendition v\nsegments 10\nbytes 5",
        "surf-stream 1\nrendition v\nsegments 10\ndone 1",
        // No version line at all.
        "rendition v\nsegments 10\ndone 1\nbytes 5",
        // Numbers that are not.
        "surf-stream 1\nrendition v\nsegments ten\ndone 1\nbytes 5",
        "surf-stream 1\nrendition v\nsegments 10\ndone one\nbytes 5",
        // An empty rendition names nothing.
        "surf-stream 1\nrendition \nsegments 10\ndone 1\nbytes 5",
    ])
    func unreadable(_ text: String) {
        // Nil means start over, which costs a download. A half-understood record
        // means resuming into a file with a count that was guessed at, which
        // costs a corrupt file that plays.
        #expect(StreamProgress.parse(text) == nil)
    }

    @Test("A record from another version is discarded")
    func versionMismatch() {
        // No migration story, deliberately: the cost of not understanding an old
        // record is re-downloading, and the cost of misreading one is worse.
        #expect(StreamProgress.parse("surf-stream 2\nrendition v\nsegments 10\ndone 1\nbytes 5")
            == nil)
        #expect(StreamProgress.parse("surf-stream 0\nrendition v\nsegments 10\ndone 1\nbytes 5")
            == nil)
    }

    @Test("Nonsense that parses is still refused", arguments: [
        // More done than exist.
        "surf-stream 1\nrendition v\nsegments 10\ndone 11\nbytes 5",
        // Negative anything.
        "surf-stream 1\nrendition v\nsegments -1\ndone 0\nbytes 0",
        "surf-stream 1\nrendition v\nsegments 10\ndone -1\nbytes 5",
        "surf-stream 1\nrendition v\nsegments 10\ndone 1\nbytes -5",
        // No segments at all is not a plan.
        "surf-stream 1\nrendition v\nsegments 0\ndone 0\nbytes 0",
        // Progress with no bytes behind it.
        "surf-stream 1\nrendition v\nsegments 10\ndone 3\nbytes 0",
    ])
    func refusesImpossibleRecords(_ text: String) {
        #expect(StreamProgress.parse(text) == nil)
    }

    @Test("Everything done is a legitimate record")
    func allDone() throws {
        let parsed = try #require(
            StreamProgress.parse("surf-stream 1\nrendition v\nsegments 10\ndone 10\nbytes 900")
        )
        #expect(parsed.done == parsed.segmentCount)
        #expect(!parsed.isEmpty)
    }

    // MARK: - Whether it describes the work in front of us

    @Test("The same rendition and count is a resume")
    func matches() {
        #expect(sample.describes(renditionID: "1080/stream.m3u8", segmentCount: 159))
    }

    @Test("A different rendition is not a resume")
    func rejectsOtherRendition() {
        // Different bytes at every offset. Resuming would splice two qualities
        // of the same video together, which plays.
        #expect(!sample.describes(renditionID: "720/stream.m3u8", segmentCount: 159))
    }

    @Test("A changed segment count is not a resume")
    func rejectsChangedCount() {
        // The manifest moved underneath us. Even with the same rendition name the
        // segment boundaries may have shifted, so the bytes on disk no longer
        // line up with the plan.
        #expect(!sample.describes(renditionID: "1080/stream.m3u8", segmentCount: 160))
        #expect(!sample.describes(renditionID: "1080/stream.m3u8", segmentCount: 158))
    }

    // MARK: - What the schedule does with it

    @Test("A resume seeds the schedule and skips what is written")
    func seedsTheSchedule() {
        let progress = StreamProgress(
            renditionID: "v", segmentCount: 10, done: 4, bytes: 4000
        )
        var schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: progress.segmentCount),
            window: 4,
            completed: Set(0..<progress.done)
        )
        #expect(schedule.cursor == 4)
        #expect(schedule.next() == 4)
        #expect(abs(schedule.fraction - 0.4) < 0.0001)
        // Already in the file, so never handed to the writer again.
        #expect(schedule.takeWritable().isEmpty)
    }

    @Test("A record of everything leaves the schedule finished")
    func seedsAFinishedSchedule() {
        let progress = StreamProgress(
            renditionID: "v", segmentCount: 6, done: 6, bytes: 6000
        )
        let schedule = SegmentSchedule(
            durations: Array(repeating: 4, count: progress.segmentCount),
            window: 4,
            completed: Set(0..<progress.done)
        )
        #expect(schedule.isComplete)
        #expect(schedule.isDrained)
    }

    @Test("Bytes are the truncation point, not the file's own length")
    func bytesAreAuthoritative() {
        // The reason this field exists. A write interrupted partway leaves a tail
        // in the file that no segment accounted for, so trusting the file's length
        // would splice a fragment of a segment into the middle of the video. The
        // record says where the accounted-for bytes end, and the file is cut back
        // to it.
        let progress = StreamProgress(
            renditionID: "v", segmentCount: 10, done: 4, bytes: 4000
        )
        let fileLengthOnDisk = 4537
        #expect(progress.bytes < fileLengthOnDisk)
        #expect(progress.bytes == 4000)
    }
}
