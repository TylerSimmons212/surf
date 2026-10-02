import Foundation

/// Whether the file we just saved is the file we meant to save.
///
/// Someone downloaded a video and got a file with only audio in it. Surf
/// reported success. The cause was never reproduced — the extraction 403s on
/// the video stream and ought to have failed outright — and that is the point
/// of this type: a download that silently returns less than it was asked for is
/// a whole class of bug, and the class can be closed without identifying any
/// one member of it.
///
/// The check is worth having specifically because the failures it catches
/// produce *playable* files. A truncated video opens, plays, and ends early.
/// Nothing about it looks wrong until the moment you needed the rest of it.
///
/// Pure, so the judgement can be tested without AVFoundation. Reading the
/// tracks out of a real file is `MediaInspector`'s job and is four lines.
public enum SavedMedia {

    /// What the page said we were about to save, recorded before the download
    /// starts.
    ///
    /// This is the half that makes the guard work: it comes from the page, which
    /// already told us `hasVideo` and `duration` for the element being saved. So
    /// it is independent of whatever the downloader reports about its own
    /// success, and a downloader that lies or gives up quietly cannot affect it.
    public struct Expectation: Equatable, Sendable {

        /// The element being saved is a `<video>` with a frame in it. False for
        /// a podcast or an `<audio>` element, which must not be failed for
        /// lacking a video track.
        public var wantsVideo: Bool

        /// Set only when something authoritative said an audio track exists —
        /// a manifest listing an audio rendition. Left false on the yt-dlp path,
        /// where nothing does: a silent screen recording is a real video, and
        /// failing one for having no audio would be this guard causing the kind
        /// of bug it exists to prevent.
        public var wantsAudio: Bool

        /// Seconds, as the page reported them. Nil when there is no duration to
        /// be short of, which is a live stream.
        public var declaredDuration: Double?

        public init(
            wantsVideo: Bool,
            wantsAudio: Bool = false,
            declaredDuration: Double? = nil
        ) {
            self.wantsVideo = wantsVideo
            self.wantsAudio = wantsAudio
            self.declaredDuration = declaredDuration
        }
    }

    /// What the finished file turned out to contain.
    public struct Inventory: Equatable, Sendable {
        public var hasVideo: Bool
        public var hasAudio: Bool
        /// Seconds. Zero for a file with no readable timing, which is itself a
        /// finding rather than a missing measurement.
        public var duration: Double

        public init(hasVideo: Bool, hasAudio: Bool, duration: Double) {
            self.hasVideo = hasVideo
            self.hasAudio = hasAudio
            self.duration = duration
        }
    }

    /// What is wrong with it, in the words the user is going to read.
    public enum Flaw: Equatable, Sendable {
        /// No tracks, or no duration. A file that is not media at all, which is
        /// what saving a manifest instead of a video produces.
        case empty
        /// The reported bug.
        case audioOnly
        /// The same failure mirrored: the merge dropped the other half.
        case videoOnly
        /// Playable and short. The dangerous one.
        case truncated(found: Double, expected: Double)

        /// A sentence for the downloads list. No error codes, and the machinery
        /// is not named — the rest of the download UI deliberately never says
        /// "yt-dlp" either.
        public var message: String {
            switch self {
            case .empty:
                "That didn't come through as a video — try again"
            case .audioOnly:
                "Only the audio came through — try again"
            case .videoOnly:
                "Only the video came through, with no sound — try again"
            case .truncated(let found, let expected):
                "Only \(MediaTime.display(found)) of \(MediaTime.display(expected)) came through — try again"
            }
        }
    }

    /// Anything less than half of what was expected is missing the download
    /// rather than ending it.
    ///
    /// Deliberately generous. The failure being caught is a file assembled from
    /// three segments out of seven, not a container whose duration rounds a
    /// frame differently from the page's. A guard that discards files earns its
    /// false negatives and cannot afford its false positives.
    static let truncationFloor = 0.5

    /// Nil when the file is what was asked for, so the call site reads
    /// `guard let flaw = SavedMedia.flaw(...) else { succeed() }`.
    public static func flaw(
        in inventory: Inventory,
        expecting expectation: Expectation
    ) -> Flaw? {
        guard inventory.hasVideo || inventory.hasAudio,
              inventory.duration.isFinite, inventory.duration > 0
        else { return .empty }

        if expectation.wantsVideo, !inventory.hasVideo { return .audioOnly }
        if expectation.wantsAudio, !inventory.hasAudio { return .videoOnly }

        // A longer file than expected is not a flaw. It is the ordinary case
        // where the page was reporting an advert's duration when the download
        // started, and the feature it resolved to is twenty times longer.
        if let expected = expectation.declaredDuration,
           expected.isFinite, expected > 0,
           inventory.duration < expected * truncationFloor {
            return .truncated(found: inventory.duration, expected: expected)
        }

        return nil
    }
}
