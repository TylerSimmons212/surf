import AVFoundation
import Foundation

/// Turns fetched segments into a file.
///
/// Two operations, and the first one is the surprise: for fragmented MP4,
/// assembly is concatenation. An initialisation segment followed by its media
/// segments, appended in order, is a file AVFoundation opens and reads. Checked
/// before any of this was built, against real DASH segments: `cat` of an init and
/// seven segments gives an asset reporting 28.00s of H.264. No remux, no parsing,
/// no library.
///
/// The second is muxing a separate picture and soundtrack into one file, which
/// `AVAssetReader` and `AVAssetWriter` do with no re-encoding at all. Two
/// separate DASH streams merged in 27 milliseconds; Apple's own 4K HEVC with
/// Dolby Digital Plus in 52. That is the `ffmpeg -c copy` step, done by the
/// system.
///
/// What it will not do is anything outside the MP4 and QuickTime family.
/// `AVAssetWriter` enumerates its output types in the error it throws for a bad
/// one, and there is no WebM, no Matroska and no MPEG-TS in the list.
/// `AVURLAsset` will not read those either. Those streams are refused by
/// `StreamPlan` before a byte is fetched.
enum StreamAssembler {

    enum Failure: Error, Equatable {
        case cannotWrite(String)
        /// AVFoundation read the file and found no track of a kind it was
        /// promised. Distinct from a bad write, because this one means the bytes
        /// arrived and were not what the manifest said.
        case missingTrack
        case muxFailed(String)
    }

    /// Opens the output once and hands back a handle to append to.
    ///
    /// A handle rather than a buffer because the schedule guarantees in-order
    /// writes, so there is never a reason to hold a segment in memory after it
    /// has been written, and never a reassembly pass at the end.
    static func open(_ url: URL) throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Picture and sound into one MP4, with nothing decoded on the way.
    ///
    /// `outputSettings: nil` on both sides is what makes it passthrough. With
    /// settings, it re-encodes. `sourceFormatHint` is then required: there is
    /// nothing else to describe a track the writer will never be told about by an
    /// encoder, and without it `canAdd` simply answers false, which reads as "this
    /// file is unsupported" rather than "you left out an argument". That one cost
    /// an attempt to find.
    ///
    /// Written against macOS 27's async API — `inputReceiver`, `outputProvider`,
    /// `start`, `await append` — rather than the callback one it replaced. The old
    /// shape needed `requestMediaDataWhenReady` on a queue, a checked continuation
    /// to await it, and `nonisolated(unsafe)` to get the non-Sendable reader and
    /// writer across the boundary. It also had a deadlock in it: draining one
    /// track to completion before starting the other stops the writer accepting
    /// samples for a track that has run ahead, so the second pump waits on a ready
    /// signal that never comes. A task group over two `await` loops has neither
    /// problem, and is most of the reason this is short.
    static func mux(video: URL, audio: URL, into output: URL) async -> Result<URL, Failure> {
        try? FileManager.default.removeItem(at: output)

        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first
        else { return .failure(.missingTrack) }

        do {
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil,
                sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
            )
            let audioInput = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil,
                sourceFormatHint: try await audioTrack.load(.formatDescriptions).first
            )
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                return .failure(.muxFailed("this combination of formats can't be written to MP4"))
            }
            let videoReader = try AVAssetReader(asset: videoAsset)
            let audioReader = try AVAssetReader(asset: audioAsset)

            // Bound through `nonisolated(unsafe)` because each of these four is
            // touched by exactly one task and never shared between them, which is
            // the invariant that annotation exists to assert. AVFoundation's
            // readers and writers are not `Sendable` and cannot be made so, and
            // the alternative — copying the two tracks one after the other —
            // deadlocks: the writer stops accepting samples for a track that has
            // run ahead of the other, so the second loop waits on a readiness
            // that cannot arrive.
            nonisolated(unsafe) let videoReceiver = writer.inputReceiver(for: videoInput)
            nonisolated(unsafe) let audioReceiver = writer.inputReceiver(for: audioInput)
            nonisolated(unsafe) let videoProvider = videoReader.outputProvider(
                for: AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            )
            nonisolated(unsafe) let audioProvider = audioReader.outputProvider(
                for: AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            )

            try writer.start()
            // `start()` replaces `startWriting()` and nothing more: the session
            // is still a separate call, and without it the first append throws
            // "Must start a session" from inside a task, where it surfaces as a
            // crash rather than an error. Dropped this when moving to the async
            // API and found it by running the thing.
            writer.startSession(atSourceTime: .zero)
            try videoReader.start()
            try audioReader.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await copy(from: videoProvider, to: videoReceiver) }
                group.addTask { try await copy(from: audioProvider, to: audioReceiver) }
                try await group.waitForAll()
            }

            await writer.finishWriting()
            return .success(output)
        } catch {
            return .failure(.muxFailed(error.localizedDescription))
        }
    }

    /// Every sample from one track into one writer input, untouched.
    private static func copy(
        from provider: AVAssetReaderOutput.Provider<
            CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
        >,
        to receiver: AVAssetWriterInput.SampleBufferReceiver
    ) async throws {
        while let sample = try await provider.next() {
            try await receiver.append(sample)
        }
        receiver.finish()
    }
}
