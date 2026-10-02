import Foundation
import Testing
@testable import SurfCore

@Suite("Saved media verification")
struct SavedMediaTests {

    // MARK: - The reported bug

    @Test("A video that saved only its audio is a failure")
    func audioOnly() {
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: false, hasAudio: true, duration: 596),
            expecting: .init(wantsVideo: true, declaredDuration: 596)
        )
        #expect(flaw == .audioOnly)
    }

    @Test("A video that saved both tracks is fine")
    func complete() {
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 596),
            expecting: .init(wantsVideo: true, declaredDuration: 596)
        )
        #expect(flaw == nil)
    }

    // MARK: - Not overreaching

    @Test("A podcast is not failed for having no video")
    func audioDownloadIsLegitimate() {
        // `wantsVideo` comes from the page's own `hasVideo`, so an <audio>
        // element expects no video track and must pass. Getting this wrong would
        // make the guard break the downloads it was added to protect.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: false, hasAudio: true, duration: 2400),
            expecting: .init(wantsVideo: false, declaredDuration: 2400)
        )
        #expect(flaw == nil)
    }

    @Test("A silent video is not failed for having no audio")
    func silentVideoIsLegitimate() {
        // A screen recording or a looping clip often has no audio track at all.
        // Nothing on the extraction path can tell us one was expected, so
        // `wantsAudio` stays false and this has to pass.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: false, duration: 12),
            expecting: .init(wantsVideo: true, declaredDuration: 12)
        )
        #expect(flaw == nil)
    }

    @Test("A missing audio track is a failure once something says there was one")
    func videoOnlyWhenAudioWasPromised() {
        // This is what a manifest listing an audio rendition buys: the mirrored
        // half of the reported bug becomes detectable.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: false, duration: 596),
            expecting: .init(wantsVideo: true, wantsAudio: true, declaredDuration: 596)
        )
        #expect(flaw == .videoOnly)
    }

    // MARK: - Nothing useful at all

    @Test("A file with no tracks is empty, whatever its duration claims")
    func noTracks() {
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: false, hasAudio: false, duration: 596),
            expecting: .init(wantsVideo: true)
        )
        #expect(flaw == .empty)
    }

    @Test("A file with tracks but no duration is empty", arguments: [
        0.0, -1.0, Double.infinity, Double.nan,
    ])
    func noDuration(_ duration: Double) {
        // Saving a manifest instead of a video lands here: a few kilobytes of
        // text that AVFoundation reports nothing useful about.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: duration),
            expecting: .init(wantsVideo: true)
        )
        #expect(flaw == .empty)
    }

    // MARK: - Playable and short, the dangerous one

    @Test("Three segments out of seven is truncated")
    func truncated() {
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 12),
            expecting: .init(wantsVideo: true, declaredDuration: 28)
        )
        #expect(flaw == .truncated(found: 12, expected: 28))
    }

    @Test("A file a little short of its declared length is not truncated")
    func minorShortfallPasses() {
        // Containers disagree with each other about duration by a frame or two,
        // and the floor is generous on purpose. The failure being caught is a
        // download that stopped, not arithmetic.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 27.96),
            expecting: .init(wantsVideo: true, declaredDuration: 28)
        )
        #expect(flaw == nil)
    }

    @Test("A file longer than expected is not a flaw")
    func longerThanExpectedPasses() {
        // The ordinary case: an advert was playing when the download started, so
        // the page reported fifteen seconds and the feature is ten minutes.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 596),
            expecting: .init(wantsVideo: true, declaredDuration: 15)
        )
        #expect(flaw == nil)
    }

    @Test("With no declared duration, length is not judged")
    func noExpectationMeansNoTruncation() {
        // A live stream has no end to fall short of.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 3),
            expecting: .init(wantsVideo: true, declaredDuration: nil)
        )
        #expect(flaw == nil)
    }

    @Test("A declared duration that is nonsense is not judged", arguments: [
        0.0, -30.0, Double.infinity,
    ])
    func unusableExpectation(_ declared: Double) {
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: true, hasAudio: true, duration: 3),
            expecting: .init(wantsVideo: true, declaredDuration: declared)
        )
        #expect(flaw == nil)
    }

    // MARK: - Precedence

    @Test("A missing video track is reported ahead of a short duration")
    func audioOnlyBeatsTruncated() {
        // Both are true of the reported file. "Only the audio came through" is
        // the more useful sentence, and the one that tells the user retrying is
        // worth it.
        let flaw = SavedMedia.flaw(
            in: .init(hasVideo: false, hasAudio: true, duration: 10),
            expecting: .init(wantsVideo: true, declaredDuration: 596)
        )
        #expect(flaw == .audioOnly)
    }

    // MARK: - What the user reads

    @Test("Every flaw says something a person could act on")
    func messages() {
        #expect(SavedMedia.Flaw.audioOnly.message == "Only the audio came through — try again")
        #expect(SavedMedia.Flaw.truncated(found: 74, expected: 596).message
            == "Only 1:14 of 9:56 came through — try again")
        // No flaw names the tool, matching the rest of the download UI.
        for flaw in [
            SavedMedia.Flaw.empty, .audioOnly, .videoOnly,
            .truncated(found: 1, expected: 2),
        ] {
            #expect(!flaw.message.isEmpty)
            #expect(!flaw.message.lowercased().contains("yt-dlp"))
            #expect(!flaw.message.lowercased().contains("ffmpeg"))
        }
    }
}
