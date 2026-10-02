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

    /// Keeps the run's working directory, for looking at what it produced.
    ///
    /// A download that finishes and then will not assemble is a question about
    /// two files on disk, and they are deleted before anyone can open them.
    static var keepsScratch: Bool {
        ProcessInfo.processInfo.environment["SURF_KEEP_SCRATCH"] == "1"
    }

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
        guard !Self.keepsScratch else {
            debugLog("stream: keeping \(workingDirectory.path)")
            return
        }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - The sequence

    func start(
        manifests: [URL], pageURL: URL?, title: String, tab: Tab?,
        choosing: DownloadOption? = nil
    ) async -> Result<Produced, StreamRefusal> {
        // A row from the menu, carried as the one thing `pick` needs from it.
        // Nil means the engine decides, which is what it did before the menu
        // existed and still does when the button is pressed rather than held.
        let preference = StreamPreference(renditionID: choosing?.id)
        if let choosing {
            debugLog("stream: asked for \(choosing.title) (\(choosing.id))")
        }
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
            switch StreamPlan.pick(from: parsed, preferring: preference) {
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
        switch StreamPlan.make(
            video: videoIndex, audio: audioIndex, labelledBy: pick,
            preferring: preference
        ) {
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

// MARK: - YouTube

/// One segment of one format, so a re-sent segment can be recognised.
private struct Segment: Hashable {
    var itag: Int
    var number: Int
}

extension StreamDownload {

    /// Downloads a YouTube stream by asking its streaming endpoint, repeatedly.
    ///
    /// The shape is different from every other download here and the difference
    /// is the protocol's. There is no manifest to read and no segment list to
    /// schedule: one endpoint answers with however much it feels like sending,
    /// and the only way forward is to ask again from where the last answer
    /// stopped. So no `SegmentSchedule`, no parallelism, no resume journal —
    /// those exist to order and bound work that is known in advance, and here
    /// none of it is.
    ///
    /// What it does share is the end: two files, concatenated as they arrive, and
    /// the same muxer.
    func startSABR(
        captured: StreamTap.ABRRequest, formats: [StreamTap.Format],
        choosing: DownloadOption? = nil,
        pageURL: URL?, title: String, tab: Tab?
    ) async -> Result<Produced, StreamRefusal> {
        guard let body = captured.bytes else {
            debugLog("sabr: the captured body did not decode from base64 "
                + "(\(captured.body.count) characters)")
            return .failure(.unreadable)
        }
        // What was actually caught, before deciding it is unusable. "Did not
        // carry a config" covers a body that decoded to nothing, a body that is
        // a different request shape, and a parse that failed — three problems
        // with three different answers.
        let shape = Protobuf.fields(in: body)
            .map { "\($0.number)" }
            .joined(separator: ",")
        debugLog("sabr: captured \(body.count) bytes, fields [\(shape)]")

        guard let endpoint = URL(string: captured.url),
              var session = SABRClient.Session(capturedRequest: body, url: endpoint)
        else {
            debugLog("sabr: that request has no config (5) and context (19) to reuse")
            return .failure(.unreadable)
        }

        // Ask for something readable. Left to itself the server picked 144p VP9
        // in WebM, which downloaded perfectly and then could not be muxed,
        // because AVFoundation reads neither.
        var wantedVideo: Int?
        var wantedAudio: Int?
        // A row from the menu names an itag, and it is used as given. The whole
        // point of offering a choice is that it is not second-guessed.
        if let asked = choosing, let itag = Int(asked.id),
           let format = formats.first(where: { $0.itag == itag }),
           let revision = format.revision {
            let sound = asked.isAudioOnly
                ? format
                : SABRClient.Session.choose(from: formats)?.audio
            if !asked.isAudioOnly {
                session.videoFormats = [
                    SABR.FormatID(itag: itag, lastModified: revision).encodedID,
                ]
                wantedVideo = itag
            }
            if let sound, let soundRevision = sound.revision {
                session.audioFormats = [
                    SABR.FormatID(itag: sound.itag, lastModified: soundRevision).encodedID,
                ]
                wantedAudio = sound.itag
            }
            debugLog("sabr: asked for \(asked.title) — video \(wantedVideo.map(String.init) ?? "none")"
                + ", audio \(wantedAudio.map(String.init) ?? "none")")
        } else if let chosen = SABRClient.Session.choose(from: formats) {
            session.videoFormats = [SABR.FormatID(
                itag: chosen.video.itag, lastModified: chosen.video.revision ?? 0
            ).encodedID]
            session.audioFormats = [SABR.FormatID(
                itag: chosen.audio.itag, lastModified: chosen.audio.revision ?? 0
            ).encodedID]
            wantedVideo = chosen.video.itag
            wantedAudio = chosen.audio.itag
            debugLog("sabr: asking for \(chosen.video.itag) "
                + "(\(chosen.video.height)p \(chosen.video.mimeType)) "
                + "and \(chosen.audio.itag)")
        } else {
            debugLog("sabr: no mp4 pair on offer among \(formats.count); "
                + "letting the server choose")
        }

        let credentials = await SegmentFetcher.credentials(for: tab, page: pageURL)
        let fetcher = SegmentFetcher(credentials: credentials, parallelism: 1)

        do {
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true
            )
        } catch { return .failure(.unreadable) }

        // Which itag is picture and which is sound is learned from the answers
        // rather than decided here. A format id names a rendition and says
        // nothing about its kind; the initialisation metadata the server sends
        // carries a mime type, which is the only thing in the whole exchange that
        // does. So this fills in as the stream describes itself.
        var kinds: [Int: String] = [:]
        var initialised: Set<Int> = []
        var seenSegments: Set<Segment> = []
        var duplicates = 0
        var unwanted = 0

        let videoFile = workingDirectory.appendingPathComponent("video.mp4")
        let audioFile = workingDirectory.appendingPathComponent("audio.m4a")
        guard let videoHandle = try? StreamAssembler.open(videoFile),
              let audioHandle = try? StreamAssembler.open(audioFile)
        else { return .failure(.unreadable) }
        defer {
            try? videoHandle.close()
            try? audioHandle.close()
        }

        var endpointURL = endpoint
        var startMs = 0
        var written = 0
        var rounds = 0
        // How far each format has got, keyed by itag. One cursor per stream
        // rather than one for the pair, which is the whole of the fix described
        // where it is read below.
        var reached: [Int: Int] = [:]
        // Which segment numbers arrived, per format, so the end of the download
        // can say whether they are contiguous instead of inferring it from a
        // byte count that looked fine while a quarter of the video was missing.
        var numbers: [Int: Set<Int>] = [:]
        let began = ContinuousClock.now

        onDetail("Asking YouTube for the stream")

        while rounds < SABRClient.roundLimit, !isCancelled {
            rounds += 1
            var current = session
            current.url = endpointURL
            guard let round = await SABRClient.round(
                current, from: startMs, buffered: [], with: fetcher
            ) else {
                debugLog("sabr: round \(rounds) got no answer")
                return .failure(written > 0 ? .interrupted : .unreadable)
            }

            // A redirect is where to ask next, not a failure. The first answer to
            // a streaming request is very often one.
            if let redirect = round.redirect {
                debugLog("sabr: redirected to \(redirect.host ?? "?")")
                endpointURL = redirect
                rounds -= 1
                continue
            }
            if let protection = round.protection, protection.status != .ok {
                debugLog("sabr: protection status \(protection.raw) — a token is wanted")
                return .failure(.protected)
            }
            if round.hadError {
                debugLog("sabr: the server reported an error")
                return .failure(written > 0 ? .interrupted : .unreadable)
            }

            for (itag, mime) in round.mimeTypes where kinds[itag] == nil {
                kinds[itag] = mime
                debugLog("sabr: itag \(itag) is \(mime)")
            }

            var gained = 0
            // Which formats have had their header written. SABR marks an
            // initialisation segment rather than sending it only once, and it
            // arrives again after a redirect and at the head of later responses.
            // Writing it a second time puts a `moov` in the middle of the media,
            // which is why 569MB of download muxed into a 25-megabyte file: the
            // reader stopped at the first one it did not expect.
            // In header-id order, because a response interleaves two streams and
            // the dictionary's own order is arbitrary. Appending audio out of
            // order is a file that plays wrong rather than one that fails.
            for headerID in round.media.keys.sorted() {
                guard let bytes = round.media[headerID],
                      let header = round.headers[headerID], let itag = header.itag
                else { continue }
                if header.isInitializationSegment {
                    guard !initialised.contains(itag) else { continue }
                    initialised.insert(itag)
                    debugLog("sabr: header for itag \(itag), \(bytes.count) bytes")
                } else if let number = header.segmentNumber {
                    // Written once each, by segment number.
                    //
                    // Asking from where the last answer reached does not mean the
                    // next one starts there: the server resumes from a keyframe
                    // before it, so consecutive rounds overlap. Appending the
                    // overlap gives a file with segments repeated in the middle —
                    // which is why 538MB of video read back as 23, with a
                    // timeline longer than the video. The audio, whose segments
                    // happened not to overlap, came out exactly right, which made
                    // it look like a video problem rather than an ordering one.
                    guard seenSegments.insert(Segment(itag: itag, number: number)).inserted
                    else { duplicates += 1; continue }
                }
                // By itag, not by kind. Routing on the mime type alone put every
                // `audio/*` the server sent into one file, and it sends more
                // formats than were asked for — which produced an audio track of
                // exactly twice the video's length, two complete soundtracks
                // appended one after the other, and a video twenty seconds long
                // in the wrong direction. Asking for a format is not the same as
                // being sent only that format.
                let mime = kinds[itag] ?? ""
                if itag == wantedVideo || (wantedVideo == nil && mime.hasPrefix("video/")) {
                    try? videoHandle.write(contentsOf: bytes)
                } else if itag == wantedAudio || (wantedAudio == nil && mime.hasPrefix("audio/")) {
                    try? audioHandle.write(contentsOf: bytes)
                } else {
                    unwanted += bytes.count
                    continue
                }
                gained += bytes.count
                // How far this stream has got. Taken from the headers rather
                // than counted, because bytes do not say where in the video
                // they are.
                if let start = header.startMs, let duration = header.durationMs {
                    reached[itag] = max(reached[itag] ?? 0, start + duration)
                }
                if let number = header.segmentNumber {
                    numbers[itag, default: []].insert(number)
                }
            }

            written += gained
            if gained == 0 {
                // Nothing new. Either the video is finished or the server has
                // stopped advancing, and neither is worth asking about again.
                debugLog("sabr: round \(rounds) added nothing; stopping")
                break
            }
            // Where *both* streams have got to, which is the lesser of them.
            //
            // It was the greater, and that silently lost a quarter of every
            // video. Audio is 388 kbps against video's 9 Mbps, so a round
            // carrying sixty seconds of sound carries perhaps forty-five of
            // picture; asking from sixty next time means those fifteen seconds
            // of video are never requested again. Nothing complained, because a
            // gap between two fragments is not an error — each carries its own
            // timestamp, so the file still reported the right duration while
            // holding 28,870 of its 38,077 frames. The audio came out exact to
            // the kilobit, which is what made it look like a video problem
            // rather than a cursor one.
            //
            // Only formats that have actually sent something count, so a stream
            // the server never sends cannot hold the download at zero.
            let frontier = reached.values.min() ?? 0
            guard frontier > startMs else {
                debugLog("sabr: round \(rounds) did not advance past \(startMs)ms; stopping")
                break
            }
            startMs = frontier
            onProgress(0, written)
            onDetail("Asking YouTube for the stream")
        }

        let elapsed = (ContinuousClock.now - began).seconds
        // How much of the video both streams cover, which is what the file
        // actually holds and so what a truncation check should be told.
        let completeTo = reached.values.min() ?? 0
        let frontiers = reached.sorted { $0.key < $1.key }
            .map { "\($0.key)→\($0.value)ms" }.joined(separator: " ")
        debugLog("sabr: \(written) bytes over \(rounds) round(s) in "
            + "\(String(format: "%.1f", elapsed))s, reached \(frontiers)")

        guard !isCancelled else { return .failure(.unreadable) }
        guard written > 0 else { return .failure(.unreadable) }

        try? videoHandle.close()
        try? audioHandle.close()

        let sizes = [videoFile, audioFile].map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        debugLog("sabr: video \(sizes[0] ?? 0) bytes, audio \(sizes[1] ?? 0) bytes, "
            + "\(seenSegments.count) segments, \(duplicates) repeats, "
            + "\(unwanted) bytes of formats we did not ask for")

        // Whether what arrived is a run with no holes in it.
        //
        // The byte count cannot say. A download missing every fourth segment
        // has a plausible size, the right duration, a video track that opens
        // and plays, and a quarter of its frames gone — which is precisely the
        // state this went out in, and precisely why the count is not the test.
        for (itag, seen) in numbers.sorted(by: { $0.key < $1.key }) {
            guard let low = seen.min(), let high = seen.max() else { continue }
            let holes = (high - low + 1) - seen.count
            debugLog("sabr: itag \(itag) segments \(low)–\(high), "
                + (holes == 0 ? "contiguous" : "\(holes) MISSING"))
        }

        // Sound on its own needs no muxing, and the file is already what was
        // asked for. Named `.m4a` because that is what it is, and a `.mp4`
        // holding only audio confuses everything that opens it.
        if wantedVideo == nil {
            let audioOutput = workingDirectory
                .appendingPathComponent(Self.sanitised(title) + ".m4a")
            try? FileManager.default.moveItem(at: audioFile, to: audioOutput)
            let saved = FileManager.default.fileExists(atPath: audioOutput.path)
                ? audioOutput : audioFile
            return .success(Produced(
                url: saved,
                expectation: SavedMedia.Expectation(
                    wantsVideo: false, wantsAudio: true,
                    declaredDuration: completeTo > 0 ? Double(completeTo) / 1000 : nil
                )
            ))
        }

        let output = workingDirectory.appendingPathComponent(Self.sanitised(title) + ".mp4")
        onDetail("Combining audio and video")

        // ffmpeg rather than AVFoundation, which cannot read this. Measured on
        // the files above: `AVAssetReader` reports completion after yielding 25MB
        // of a 538MB video, while ffmpeg copies the whole thing in a second and
        // `ffprobe` agrees with the result. Everything else in this engine still
        // goes through AVFoundation; this is the one producer it mis-parses.
        guard let ffmpeg = MediaExtractor.shared.ffmpegURL else {
            debugLog("sabr: no ffmpeg, and AVFoundation cannot read this stream")
            return .failure(.unsupportedContainer(.fragmentedMP4))
        }
        switch await StreamAssembler.remux(
            video: videoFile, audio: audioFile, into: output, using: ffmpeg
        ) {
        case .success(let url):
            return .success(Produced(
                url: url,
                expectation: SavedMedia.Expectation(
                    wantsVideo: true, wantsAudio: true,
                    declaredDuration: completeTo > 0 ? Double(completeTo) / 1000 : nil
                )
            ))
        case .failure(let failure):
            debugLog("sabr: remux failed — \(failure)")
            return .failure(.unsupportedContainer(.fragmentedMP4))
        }
    }
}
