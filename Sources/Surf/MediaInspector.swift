import AVFoundation
import Foundation
import SurfCore

/// What is actually in a media file on disk.
///
/// The whole of Surf's side of `SavedMedia`: four properties read out of
/// AVFoundation so a pure function can judge them. It is separate from
/// `SavedMedia` rather than a method on it because `SurfCore` has no AVFoundation
/// and the judgement is the part worth testing.
enum MediaInspector {

    /// Nil means *cannot judge*, which the caller must treat as passing.
    ///
    /// AVFoundation reads the MP4 and QuickTime family and nothing else: no
    /// WebM, no Matroska, no MPEG-TS. Without ffmpeg installed, an extraction
    /// can legitimately produce a WebM, and failing every one of those because
    /// we could not open it would be this check breaking downloads that work.
    ///
    /// So an unreadable file is not evidence of anything. The one case that
    /// leaves open — a few kilobytes of playlist text saved under an `.mp4`
    /// name — is closed where it is actually caused, by classifying the response
    /// rather than by inspecting the wreckage afterwards.
    static func inventory(of url: URL) async -> SavedMedia.Inventory? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let duration = try? await asset.load(.duration)
        else { return nil }

        return SavedMedia.Inventory(
            hasVideo: tracks.contains { $0.mediaType == .video },
            hasAudio: tracks.contains { $0.mediaType == .audio },
            // Seconds, or NaN for an asset with no readable timing. `SavedMedia`
            // treats that as empty rather than as a measurement it is missing,
            // which is why this does not guard it here.
            duration: CMTimeGetSeconds(duration)
        )
    }
}
