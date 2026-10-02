import Foundation
import SurfCore

/// One stream download, start to finish.
///
/// The analogue of `Extraction`, and deliberately the same shape: owns a scratch
/// directory, reports progress to a `DownloadItem`, answers to a cancel, and
/// hands back either a file or a reason. What it does inside is read a manifest,
/// decide, fetch, assemble and check, in that order.
///
/// Nothing here decides anything. Every choice and every refusal belongs to
/// `StreamPlan`, every ordering question to `SegmentSchedule`, and both are pure
/// and tested. This type is the part that cannot be: the file handles, the task
/// group, the scratch directory.
@MainActor
final class StreamDownload {

    /// How many connections the session is allowed to hold open.
    ///
    /// The ceiling rather than the starting count: `Parallelism` moves the number
    /// actually in use up and down inside this, and a session configured for four
    /// would cap it at four however fast the link turned out to be.
    static let parallelism = Parallelism.ceiling

    /// Where this run's partial output lives. Readable so a failed attempt can
    /// hand it to the next one.
    let workingDirectory: URL
    private var isCancelled = false

    /// What the user is told while this runs, in place of a byte count that means
    /// nothing during the parts that are not fetching.
    private let onDetail: @MainActor (String?) -> Void
    private let onProgress: @MainActor (Double, Int) -> Void

    /// `resuming` is a previous attempt's directory, which makes this one carry
    /// on from what is already in it.
    ///
    /// Passed in rather than derived from the manifest URL, which was the other
    /// option. Deriving it would let a brand-new download resume an abandoned
    /// one, which sounds better than it is: the downloads list is in memory only
    /// and empty on relaunch, so resuming is a within-session idea, and a key
    /// derived from a URL brings collisions and two concurrent downloads fighting
    /// over one file for a capability nothing asked for.
    init(
        resuming: URL? = nil,
        onDetail: @escaping @MainActor (String?) -> Void,
        onProgress: @escaping @MainActor (Double, Int) -> Void
    ) {
        self.workingDirectory = resuming ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-stream-\(UUID().uuidString)", isDirectory: true)
        self.onDetail = onDetail
        self.onProgress = onProgress
    }

    func cancel() { isCancelled = true }

    /// Removes the run's scratch directory.
    ///
    /// This comment used to claim the directory was left behind on failure so a
    /// retry could resume from it, and that the segments on disk were the journal.
    /// Neither is true. Every caller cleans up on failure as well as on success,
    /// and the output is a single appended file, so a directory listing cannot say
    /// how many segments are inside it — the segments are not a record of
    /// anything. Resuming wants a sidecar holding a count and a byte offset, with
    /// the file truncated back to that offset, and that does not exist yet.
    func cleanUp() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - The sequence

    func start(
        manifests: [URL], pageURL: URL?, title: String, tab: Tab?
    ) async -> Result<Produced, StreamRefusal> {
        debugLog("stream: \(manifests.count) candidate(s), first \(manifests.first?.absoluteString ?? "-")")
        let credentials = await SegmentFetcher.credentials(for: tab, page: pageURL)
        let fetcher = SegmentFetcher(credentials: credentials, parallelism: Self.parallelism)

        do {
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true
            )
        } catch {
            return .failure(.unreadable)
        }

        onDetail("Reading the stream")

        // Candidates, tried in order, because what a page fetched is not
        // necessarily one manifest. A page with an advert in it fetched two, and
        // the first is whichever loaded first rather than whichever is the video.
        // Ruling one out costs a single small request.
        //
        // A protected candidate stops the search instead of being skipped. DRM is
        // a refusal, and carrying on to find something downloadable would mean
        // saving the advert instead of the film.
        var found: (index: StreamIndex, pick: StreamPick)?
        var lastRefusal = StreamRefusal.unreadable
        for candidate in manifests {
            guard !isCancelled else { return .failure(.unreadable) }
            guard let text = await fetcher.text(at: candidate),
                  let parsed = StreamManifest.parse(text, baseURL: candidate)
            else { continue }
            switch StreamPlan.pick(from: parsed) {
            case .success(let pick):
                found = (parsed, pick)
            case .failure(let refusal):
                lastRefusal = refusal
                guard refusal.allowsFallback else { return .failure(refusal) }
                continue
            }
            break
        }
        guard let (master, pick) = found else { return .failure(lastRefusal) }

        let videoIndex: StreamIndex
        if let next = pick.video.manifestURL, master.needsSecondPass {
            guard let text = await fetcher.text(at: next),
                  let parsed = StreamManifest.parse(text, baseURL: next)
            else { return .failure(.unreadable) }
            videoIndex = parsed
        } else {
            videoIndex = master
        }

        var audioIndex: StreamIndex?
        if let next = pick.audio?.manifestURL {
            guard let text = await fetcher.text(at: next),
                  let parsed = StreamManifest.parse(text, baseURL: next)
            else { return .failure(.unreadable) }
            audioIndex = parsed
        }

        let plan: StreamPlan
        switch StreamPlan.make(video: videoIndex, audio: audioIndex, labelledBy: pick) {
        case .success(let made): plan = made
        case .failure(let refusal): return .failure(refusal)
        }

        debugLog("stream: \(plan.video.width ?? 0)x\(plan.video.height ?? 0) "
            + "\(plan.segmentCount) segments over \(plan.hosts.sorted().joined(separator: ",")) "
            + "codecs=\(plan.video.codecs ?? "?")")

        guard !isCancelled else { return .failure(.unreadable) }

        // Both tracks share one progress bar, weighted by how much of the
        // download each is. A soundtrack is a tenth the size of its picture, and
        // giving them half the bar each makes the second half appear to finish
        // ten times faster than the first.
        let videoWeight = plan.audio == nil ? 1.0 : 0.9
        var videoFraction = 0.0
        var audioFraction = 0.0
        var videoBytes = 0
        var audioBytes = 0

        let videoFile = workingDirectory.appendingPathComponent("video.mp4")
        let videoResult = await fetch(
            plan.video, into: videoFile, with: fetcher, label: "video",
            onStep: { fraction, bytes in
                videoFraction = fraction
                videoBytes = bytes
                self.onProgress(
                    (videoFraction * videoWeight) + (audioFraction * (1 - videoWeight)),
                    videoBytes + audioBytes
                )
            }
        )
        if case .failure(let refusal) = videoResult { return .failure(refusal) }

        var audioFile: URL?
        if let audio = plan.audio {
            let file = workingDirectory.appendingPathComponent("audio.m4a")
            let audioResult = await fetch(
                audio, into: file, with: fetcher, label: "audio",
                onStep: { fraction, bytes in
                    audioFraction = fraction
                    audioBytes = bytes
                    self.onProgress(
                        (videoFraction * videoWeight) + (audioFraction * (1 - videoWeight)),
                        videoBytes + audioBytes
                    )
                }
            )
            if case .failure(let refusal) = audioResult { return .failure(refusal) }
            audioFile = file
        }

        guard !isCancelled else { return .failure(.unreadable) }

        // Assembly is its own phase and says so. A 4K mux is fast but not
        // instant, and a bar sitting at 100% while it runs reads as a hang.
        let output: URL
        if let audioFile {
            onDetail("Combining audio and video")
            let merged = workingDirectory.appendingPathComponent(
                Self.sanitised(title) + ".mp4"
            )
            switch await StreamAssembler.mux(video: videoFile, audio: audioFile, into: merged) {
            case .success(let url): output = url
            case .failure(let failure):
                debugLog("stream: mux failed — \(failure)")
                // The one refusal that happens after fetching, so the file is
                // discarded before falling back rather than left looking real.
                return .failure(.unsupportedContainer(plan.container))
            }
        } else {
            // A muxed stream needs no muxing. The concatenated segments are
            // already a file AVFoundation reads, so this is a rename.
            let named = workingDirectory.appendingPathComponent(
                Self.sanitised(title) + ".mp4"
            )
            try? FileManager.default.moveItem(at: videoFile, to: named)
            output = FileManager.default.fileExists(atPath: named.path) ? named : videoFile
        }

        onDetail("Checking the file")
        return .success(Produced(url: output, expectation: plan.expectation))
    }

    /// A plain file, fetched in pieces at the same time.
    ///
    /// The whole engine already knows how to fetch a list of segments in parallel
    /// and append them in order. A file split into byte ranges *is* that list, so
    /// this adds a plan and reuses everything else: same schedule, same adaptive
    /// connection count, same in-order write.
    ///
    /// Returns a refusal whenever there is any doubt, and the caller must then
    /// leave the download where it was. The probe is the gate: it runs through the
    /// session this would use, against the URL this would use, so a success means
    /// the credentials work here. WebKit keeps everything else.
    func startProgressive(
        url: URL, pageURL: URL?, title: String, tab: Tab?
    ) async -> Result<Produced, StreamRefusal> {
        let credentials = await SegmentFetcher.credentials(for: tab, page: pageURL)
        let fetcher = SegmentFetcher(credentials: credentials, parallelism: Self.parallelism)

        guard let probe = await fetcher.probe(url) else { return .failure(.unreadable) }
        guard ByteRanges.worthSplitting(
            length: probe.length, acceptRanges: probe.acceptsRanges
        ), let length = probe.length else { return .failure(.unreadable) }

        let ranges = ByteRanges.chunks(of: length, into: Self.parallelism)
        guard ranges.count > 1 else { return .failure(.unreadable) }

        do {
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true
            )
        } catch {
            return .failure(.unreadable)
        }

        debugLog("stream: splitting \(length) bytes into \(ranges.count) pieces")

        // No durations: a plain file has none, so the schedule counts pieces
        // instead of weighting them. They are equal-sized, so counting is right.
        let rendition = StreamRendition(
            id: url.lastPathComponent,
            role: .muxed,
            segments: ranges.map { StreamSegment(url: url, byteRange: $0) }
        )

        let extension_ = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let output = workingDirectory
            .appendingPathComponent(Self.sanitised(title) + "." + extension_)

        let result = await fetch(
            rendition, into: output, with: fetcher, label: "file",
            onStep: { fraction, bytes in self.onProgress(fraction, bytes) }
        )
        if case .failure(let refusal) = result { return .failure(refusal) }

        // No expectation of tracks: this is whatever the page linked to, and a
        // plain file download is not necessarily media at all.
        return .success(Produced(url: output, expectation: nil))
    }

    struct Produced {
        var url: URL
        /// Carried out so `SavedMedia` can check the file against what the
        /// manifest promised, which is the whole reason the plan built one. Nil
        /// for a plain file, where nothing promised anything and the item's own
        /// expectation — the page's — is the better one.
        var expectation: SavedMedia.Expectation?
    }

    // MARK: - Fetching one track

    /// Drives the schedule against the fetcher, appending in order.
    ///
    /// The loop is the interesting part. Work is topped up to the window, the
    /// first completion to arrive is recorded, and whatever is contiguous from
    /// the cursor is appended and dropped. Segments wait in `pending` only
    /// between arriving and their turn, which the window bounds.
    private func fetch(
        _ rendition: StreamRendition,
        into output: URL,
        with fetcher: SegmentFetcher,
        label: String,
        onStep: @escaping @MainActor (Double, Int) -> Void
    ) async -> Result<Void, StreamRefusal> {
        let started = ContinuousClock.now
        let segments = rendition.segments
        let journal = output.appendingPathExtension("progress")

        // What a previous attempt left, if it described this same work. A
        // mismatch — a different rendition, or a manifest whose segment count has
        // moved — starts over rather than splicing bytes that no longer line up.
        let resumed = Self.resumable(
            journal: journal, output: output,
            renditionID: rendition.id, segmentCount: segments.count
        )
        if let resumed {
            debugLog("stream: \(label) resuming at segment \(resumed.done) "
                + "of \(resumed.segmentCount), \(resumed.bytes) bytes")
        }

        guard let handle = try? StreamAssembler.open(output) else {
            debugLog("stream: \(label) couldn't open \(output.path)")
            return .failure(.unreadable)
        }
        defer { try? handle.close() }

        if let resumed {
            // Cut back to the last accounted-for byte. The file may be longer: a
            // write interrupted partway leaves a tail no segment claimed, and
            // appending after it would splice a fragment into the middle of the
            // video.
            guard (try? handle.truncate(atOffset: UInt64(resumed.bytes))) != nil,
                  (try? handle.seekToEnd()) != nil
            else {
                debugLog("stream: \(label) couldn't truncate; starting over")
                return .failure(.unreadable)
            }
        } else {
            // Nothing to resume, so whatever is there is from work that no longer
            // applies.
            try? handle.truncate(atOffset: 0)
            try? FileManager.default.removeItem(at: journal)
        }

        // The header first, and on its own: without it the segments are not a
        // file, and there is nothing to parallelise about one request. Skipped on
        // a resume, where it is already the first thing in the file.
        var written = resumed?.bytes ?? 0
        if resumed == nil, let initSegment = rendition.initSegment {
            guard case .success(let data) = await fetcher.fetch(initSegment) else {
                debugLog("stream: \(label) init segment refused")
                return .failure(.unreadable)
            }
            try? handle.write(contentsOf: data)
            // Counted, which it was not at first. The record is a truncation
            // point into this file, and the header is part of the file: leaving
            // it out made the recorded offset short by exactly the header's
            // length, so resuming would have cut that many bytes off the end of
            // the last good segment. Caught by noticing the file was 706 bytes
            // longer than the record claimed, and that 706 was the header.
            written += data.count
        }
        // The window is the ceiling, so the buffer is bounded once and the
        // connection count moves inside it.
        var schedule = SegmentSchedule(
            durations: segments.map(\.duration), window: Parallelism.ceiling,
            completed: Set(0..<(resumed?.done ?? 0))
        )

        var parallelism = Parallelism()
        var pending: [Int: Data] = [:]
        var peak = parallelism.allowed

        await withTaskGroup(
            of: (Int, Result<Data, SegmentFetcher.Failure>, Double).self
        ) { group in
            fetching: while !schedule.isDrained, !isCancelled {
                while let index = schedule.next(upTo: parallelism.allowed) {
                    let segment = segments[index]
                    group.addTask {
                        // Timed in here rather than around the loop, because
                        // segments overlap: what matters for deciding whether
                        // another connection helped is the rate *per* connection,
                        // and only the task itself knows when its own began.
                        let began = ContinuousClock.now
                        let result = await fetcher.fetch(segment)
                        return (index, result, (ContinuousClock.now - began).seconds)
                    }
                }
                guard let (index, result, elapsed) = await group.next() else { break }

                switch result {
                case .success(let data):
                    pending[index] = data
                    schedule.complete(index, bytes: data.count)
                    peak = max(peak, parallelism.completed(bytes: data.count, seconds: elapsed))

                case .failure(let failure):
                    debugLog("stream: \(label) segment \(index) — \(failure)")
                    if case .status(let status) = failure,
                       Parallelism.isThrottling(status: status) {
                        // The server said there are too many of us, which is not
                        // the same as this segment being broken. Fewer
                        // connections, and ask for it again.
                        let reduced = parallelism.throttled()
                        debugLog("stream: \(label) throttled, down to \(reduced)")
                    }
                    switch schedule.fail(index) {
                    case .giveUp:
                        // Labelled, because a bare `break` here leaves the
                        // `switch` and not the loop.
                        break fetching
                    case .retry(let attempt):
                        // Backing off between attempts, rather than asking three
                        // times in a row as fast as the connection allows — which
                        // is the one retry policy guaranteed to make a struggling
                        // server worse.
                        try? await Task.sleep(for: .milliseconds(250 * (1 << (attempt - 1))))
                    }
                }

                var flushed = false
                for writable in schedule.takeWritable() {
                    if let data = pending.removeValue(forKey: writable) {
                        try? handle.write(contentsOf: data)
                        written += data.count
                        flushed = true
                    }
                }
                if flushed {
                    // After the write, never before: a record claiming bytes that
                    // are not in the file yet is the one way this makes things
                    // worse rather than better.
                    try? handle.synchronize()
                    Self.record(
                        StreamProgress(
                            renditionID: rendition.id, segmentCount: segments.count,
                            done: schedule.cursor, bytes: written
                        ),
                        to: journal
                    )
                }
                onStep(schedule.fraction, schedule.bytesWritten + (resumed?.bytes ?? 0))
            }
            group.cancelAll()
        }

        guard !isCancelled else { return .failure(.unreadable) }
        // A schedule that gave up on a segment is not finished, and this is where
        // that matters: continuing would write a file missing its middle.
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0
            ? String(format: "%.1f MB/s", Double(schedule.bytesWritten) / 1_048_576 / seconds)
            : "instant"
        debugLog("stream: \(label) \(schedule.bytesWritten) bytes in "
            + "\(String(format: "%.1f", seconds))s — \(rate), "
            + "\(segments.count) segments, \(parallelism.allowed) at a time "
            + "(peak \(peak)), drained=\(schedule.isDrained)")
        guard schedule.isDrained else {
            debugLog("stream: \(label) stalled at segment \(schedule.failedSegment ?? -1)")
            // Not `.unreadable`: that falls back to the subprocess, which would
            // discard everything transferred so far. The bytes on disk are worth
            // more than another engine's fresh start.
            return .failure(.interrupted)
        }
        // A whole file has nothing left to resume, and a stale record beside it
        // would be read by the next attempt at the same name.
        try? FileManager.default.removeItem(at: journal)
        return .success(())
    }

    /// Filesystem-safe, and short enough to survive being named.
    private static func sanitised(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "video" : String(cleaned.prefix(180))
    }
}

// MARK: - The resume record

extension StreamDownload {

    /// A previous attempt's progress, when it describes this work and the file it
    /// refers to is still long enough to contain it.
    ///
    /// Both checks are needed. The record can describe different work, and the
    /// file can have been truncated or removed since — on disk they are two
    /// things, and believing one about the other is how a resume starts writing
    /// into a file that is shorter than the offset it was told to continue from.
    static func resumable(
        journal: URL, output: URL, renditionID: String, segmentCount: Int
    ) -> StreamProgress? {
        guard let text = try? String(contentsOf: journal, encoding: .utf8),
              let progress = StreamProgress.parse(text),
              progress.describes(renditionID: renditionID, segmentCount: segmentCount),
              !progress.isEmpty
        else { return nil }

        let length = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size])
            .flatMap { $0 as? Int } ?? 0
        guard length >= progress.bytes else { return nil }
        return progress
    }

    static func record(_ progress: StreamProgress, to journal: URL) {
        try? progress.text.write(to: journal, atomically: true, encoding: .utf8)
    }

    /// Whether there is partial output here worth keeping for a retry.
    ///
    /// Asked on failure, because keeping every failed run's directory would leave
    /// most of a download on disk for every plan that was never going to work —
    /// a protected stream, a container we cannot mux — while keeping none of them
    /// makes resuming unreachable. Progress on disk is the thing that
    /// distinguishes the two.
    var hasPartialOutput: Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workingDirectory, includingPropertiesForKeys: nil
        ) else { return false }
        return entries.contains { $0.pathExtension == "progress" }
    }
}
