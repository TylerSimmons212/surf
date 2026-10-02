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

    /// Four at once, probed from the research rather than picked: CDNs read many
    /// parallel connections from one address as something to throttle, and the
    /// measured gain flattens well before the point where they start.
    static let parallelism = 4

    private let workingDirectory: URL
    private var isCancelled = false

    /// What the user is told while this runs, in place of a byte count that means
    /// nothing during the parts that are not fetching.
    private let onDetail: @MainActor (String?) -> Void
    private let onProgress: @MainActor (Double, Int) -> Void

    init(
        onDetail: @escaping @MainActor (String?) -> Void,
        onProgress: @escaping @MainActor (Double, Int) -> Void
    ) {
        self.workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-stream-\(UUID().uuidString)", isDirectory: true)
        self.onDetail = onDetail
        self.onProgress = onProgress
    }

    func cancel() { isCancelled = true }

    /// Left behind on failure so a retry can resume, and only removed on success
    /// or cancel. The segments on disk are the resume journal.
    func cleanUp() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - The sequence

    func start(
        manifestURL: URL, pageURL: URL?, title: String, tab: Tab?
    ) async -> Result<Produced, StreamRefusal> {
        debugLog("stream: begin \(manifestURL.absoluteString)")
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
        guard let masterText = await fetcher.text(at: manifestURL),
              let master = HLSPlaylist.parse(masterText, baseURL: manifestURL)
        else { return .failure(.unreadable) }

        // Two passes, because a master playlist names its variants and only the
        // chosen one's own playlist lists segments. Which is why the pick happens
        // against a manifest with no segments in it at all.
        let pick: StreamPick
        switch StreamPlan.pick(from: master) {
        case .success(let chosen): pick = chosen
        case .failure(let refusal): return .failure(refusal)
        }

        let videoIndex: StreamIndex
        if let next = pick.video.manifestURL, master.needsSecondPass {
            guard let text = await fetcher.text(at: next),
                  let parsed = HLSPlaylist.parse(text, baseURL: next)
            else { return .failure(.unreadable) }
            videoIndex = parsed
        } else {
            videoIndex = master
        }

        var audioIndex: StreamIndex?
        if let next = pick.audio?.manifestURL {
            guard let text = await fetcher.text(at: next),
                  let parsed = HLSPlaylist.parse(text, baseURL: next)
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

    struct Produced {
        var url: URL
        /// Carried out so `SavedMedia` can check the file against what the
        /// manifest promised, which is the whole reason the plan built one.
        var expectation: SavedMedia.Expectation
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
        guard let handle = try? StreamAssembler.open(output) else {
            debugLog("stream: \(label) couldn't open \(output.path)")
            return .failure(.unreadable)
        }
        defer { try? handle.close() }

        // The header first, and on its own: without it the segments are not a
        // file, and there is nothing to parallelise about one request.
        if let initSegment = rendition.initSegment {
            guard case .success(let data) = await fetcher.fetch(initSegment) else {
                debugLog("stream: \(label) init segment refused")
                return .failure(.unreadable)
            }
            try? handle.write(contentsOf: data)
        }

        let segments = rendition.segments
        var schedule = SegmentSchedule(
            durations: segments.map(\.duration), window: Self.parallelism
        )
        var pending: [Int: Data] = [:]

        await withTaskGroup(of: (Int, Result<Data, SegmentFetcher.Failure>).self) { group in
            fetching: while !schedule.isDrained, !isCancelled {
                while let index = schedule.next() {
                    let segment = segments[index]
                    group.addTask { (index, await fetcher.fetch(segment)) }
                }
                guard let (index, result) = await group.next() else { break }

                switch result {
                case .success(let data):
                    pending[index] = data
                    schedule.complete(index, bytes: data.count)
                case .failure(let failure):
                    debugLog("stream: \(label) segment \(index) — \(failure)")
                    // Labelled, because a bare `break` here leaves the `switch`
                    // and not the loop. It would still have stopped, by way of
                    // the stall check below, but only by accident.
                    if schedule.fail(index) == .giveUp { break fetching }
                }

                for writable in schedule.takeWritable() {
                    if let data = pending.removeValue(forKey: writable) {
                        try? handle.write(contentsOf: data)
                    }
                }
                onStep(schedule.fraction, schedule.bytesWritten)
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
            + "\(segments.count) segments \(Self.parallelism) at a time, "
            + "drained=\(schedule.isDrained)")
        guard schedule.isDrained else {
            debugLog("stream: \(label) stalled at segment \(schedule.failedSegment ?? -1)")
            return .failure(.unreadable)
        }
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
