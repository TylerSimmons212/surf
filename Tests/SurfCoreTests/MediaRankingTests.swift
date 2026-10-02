import Testing

@testable import SurfCore

@Suite("Media ranking")
struct MediaRankingTests {

    /// A typical embedded feature player: large, long, and making noise.
    private let feature = MediaSignals(
        isPlaying: true, isMuted: false, loops: false,
        width: 900, height: 400, duration: 2700, hasMetadata: true, startedAt: 100
    )

    /// A typical video advert: small, short, muted, on a loop, and — the whole
    /// problem — started *after* the thing it interrupted.
    private let advert = MediaSignals(
        isPlaying: true, isMuted: true, loops: true,
        width: 300, height: 250, duration: 15, hasMetadata: false, startedAt: 9000
    )

    @Test("Nothing to choose from picks nothing")
    func empty() {
        #expect(MediaRanking.primaryIndex(among: []) == nil)
    }

    /// The case this exists for. Under last-one-wins the advert took the
    /// sidebar, the play button and Pop Out, because it started later.
    @Test("A feature beats the adverts that started after it")
    func featureBeatsAdverts() {
        let candidates = [feature, advert, advert, advert]
        #expect(MediaRanking.primaryIndex(among: candidates) == 0)
    }

    /// Order must not matter. If it did, this would be last-one-wins again
    /// wearing a scoring function.
    @Test("The answer doesn't depend on the order they arrived in")
    func orderIndependent() {
        #expect(MediaRanking.primaryIndex(among: [advert, advert, feature]) == 2)
        #expect(MediaRanking.primaryIndex(among: [feature, advert]) == 0)
    }

    /// Muting the thing you're watching is a normal thing to do, and it must
    /// not hand the player to an advert. Size, length and metadata have to
    /// carry it without help from the audio signal.
    @Test("Muting the feature doesn't surrender the player to an advert")
    func mutedFeatureStillWins() {
        var muted = feature
        muted.isMuted = true
        #expect(MediaRanking.primaryIndex(among: [muted, advert]) == 0)
    }

    /// The opposite failure: an advert that got permission to make noise still
    /// shouldn't beat a muted feature, because everything else about it is
    /// small, short and looping.
    @Test("An audible advert doesn't beat a muted feature")
    func audibleAdvertLoses() {
        var muted = feature
        muted.isMuted = true
        var loud = advert
        loud.isMuted = false
        #expect(MediaRanking.primaryIndex(among: [muted, loud]) == 0)
    }

    /// A hero video behind a headline is the failure mode size alone would
    /// cause: it's the biggest thing on the page and nobody is watching it.
    @Test("A full-bleed background loop doesn't win on size alone")
    func backgroundLoopLoses() {
        let backdrop = MediaSignals(
            isPlaying: true, isMuted: true, loops: true,
            width: 1600, height: 900, duration: 12, hasMetadata: false, startedAt: 50
        )
        #expect(MediaRanking.primaryIndex(among: [backdrop, feature]) == 1)
    }

    /// Playing outranks stopped by a margin wider than every other term put
    /// together — a paused feature shouldn't hold the player against something
    /// actually running, or pausing would strand you.
    @Test("Anything playing beats anything stopped")
    func playingBeatsStopped() {
        var stopped = feature
        stopped.isPlaying = false
        #expect(MediaRanking.primaryIndex(among: [stopped, advert]) == 1)
    }

    /// With nothing playing at all there's still a row to show, and it should
    /// be the most substantial thing on the page rather than the last to stop.
    @Test("With everything stopped the better candidate still wins")
    func allStopped() {
        var stoppedFeature = feature
        stoppedFeature.isPlaying = false
        var stoppedAdvert = advert
        stoppedAdvert.isPlaying = false
        #expect(MediaRanking.primaryIndex(among: [stoppedAdvert, stoppedFeature]) == 1)
    }

    /// Live streams and un-loaded metadata both report zero duration. Treating
    /// that as "very short" would file every livestream as an advert.
    @Test("Unknown duration is not held against a stream")
    func unknownDurationIsNeutral() {
        var live = feature
        live.duration = 0
        #expect(MediaRanking.score(live) > MediaRanking.score(advert))

        var shortKnown = feature
        shortKnown.duration = 15
        #expect(MediaRanking.score(live) > MediaRanking.score(shortKnown))
    }

    /// Two identical candidates have to resolve somehow, and the old
    /// most-recent rule is the right tie-break — it's only wrong as a
    /// *primary* rule.
    @Test("Identical candidates fall back to the most recent")
    func tieBreak() {
        var older = feature
        older.startedAt = 10
        var newer = feature
        newer.startedAt = 20
        #expect(MediaRanking.primaryIndex(among: [older, newer]) == 1)
        #expect(MediaRanking.primaryIndex(among: [newer, older]) == 0)
    }

    /// Built from signals captured out of a real browser running the real
    /// injected script: one 900×400 ten-minute feature and two 300×250 twelve-
    /// second adverts on a loop, the adverts starting 1.4 and 2.4 seconds after
    /// it. These are the numbers the page actually produced, not invented ones.
    @Test("Signals captured from a real page pick the feature, not the adverts")
    func capturedFromARealPage() {
        let captured = [
            MediaSignals(
                isPlaying: true, isMuted: true, loops: false,
                width: 900, height: 400, duration: 600,
                hasMetadata: true, startedAt: 20
            ),
            MediaSignals(
                isPlaying: true, isMuted: true, loops: true,
                width: 300, height: 250, duration: 12,
                hasMetadata: true, startedAt: 1400
            ),
            MediaSignals(
                isPlaying: true, isMuted: true, loops: true,
                width: 300, height: 250, duration: 12,
                hasMetadata: true, startedAt: 2400
            ),
        ]
        #expect(MediaRanking.primaryIndex(among: captured) == 0)
    }

    /// An element that hasn't been laid out reports zero size; that shouldn't
    /// read as a negative, just as an absence of evidence.
    @Test("An unlaid-out element scores no worse than a tiny one")
    func zeroSizeIsNotNegative() {
        var unlaid = feature
        unlaid.width = 0
        unlaid.height = 0
        #expect(MediaRanking.score(unlaid) > MediaRanking.score(advert))
    }
}

@Suite("Media audibility")
struct MediaAudibilityTests {

    private func signals(
        playing: Bool = true, muted: Bool = false, bytes: Double? = nil
    ) -> MediaSignals {
        MediaSignals(isPlaying: playing, isMuted: muted, audioBytes: bytes)
    }

    @Test("A muted autoplay video is not audible — the case this exists for")
    func mutedIsSilent() {
        #expect(signals(muted: true).isAudible == false)
        // Even once it has decoded audio: muted is muted.
        #expect(signals(muted: true, bytes: 9_000).isAudible == false)
    }

    @Test("Playing, unmuted, with sound decoded")
    func audible() {
        #expect(signals(bytes: 9_000).isAudible)
    }

    @Test("Unmuted but silent — a video with no audio track at all")
    func noAudioTrack() {
        #expect(signals(bytes: 0).isAudible == false)
    }

    @Test("Paused is never audible, whatever it has decoded")
    func paused() {
        #expect(signals(playing: false, bytes: 9_000).isAudible == false)
    }

    @Test("Unreported bytes fall back to the muted test, not to silence")
    func unknownBytes() {
        // A WebKit release that stops reporting this should cost a few odd
        // videos, not every video.
        #expect(signals(bytes: nil).isAudible)
        #expect(signals(muted: true, bytes: nil).isAudible == false)
    }
}

@Suite("Media staging")
struct MediaStagingTests {

    /// The main video, unmuted, and — the case that matters — paused or not
    /// started yet, while the advert beside it plays on.
    private let feature = MediaSignals(
        isPlaying: false, isMuted: false,
        width: 640, height: 360, duration: 1800, startedAt: 100
    )

    private let advert = MediaSignals(
        isPlaying: true, isMuted: true, loops: true,
        width: 300, height: 170, duration: 15, startedAt: 9000
    )

    @Test("Nothing to stage on a page with nothing")
    func empty() {
        #expect(MediaRanking.stageIndex(among: []) == nil)
    }

    /// The bug this exists for. The ranking hands a playing advert the win
    /// over a paused feature — rightly, for a now-playing strip — and the
    /// theater used to stage whatever the ranking chose.
    @Test("A paused feature is staged over a playing muted advert")
    func pausedFeatureBeatsPlayingAdvert() {
        let candidates = [(advert, true), (feature, true)]
        #expect(MediaRanking.primaryIndex(among: candidates.map(\.0)) == 0)
        #expect(MediaRanking.stageIndex(among: candidates) == 1)
    }

    /// No theater for an article whose only video is an ad.
    @Test("A page whose only video is a muted advert has nothing to stage")
    func advertAloneIsNotStaged() {
        #expect(MediaRanking.stageIndex(among: [(advert, true)]) == nil)
    }

    @Test("Audio without a picture has nothing to stage")
    func audioOnly() {
        #expect(MediaRanking.stageIndex(among: [(feature, false)]) == nil)
    }

    @Test("Among videos with sound the ranking still decides")
    func rankingDecidesAmongTheEligible() {
        var playing = feature
        playing.isPlaying = true
        #expect(MediaRanking.stageIndex(among: [(feature, true), (playing, true)]) == 1)
    }
}

@Suite("Media sound")
struct MediaSoundTests {

    @Test("Sound doesn't depend on playing; audible does")
    func soundOutlivesPause() {
        let paused = MediaSignals(isPlaying: false, isMuted: false, audioBytes: 9_000)
        #expect(paused.hasSound)
        #expect(paused.isAudible == false)
    }

    @Test("Muted, or decoded and silent, has no sound")
    func silence() {
        #expect(MediaSignals(isMuted: true).hasSound == false)
        #expect(MediaSignals(isMuted: false, audioBytes: 0).hasSound == false)
        #expect(MediaSignals(isMuted: false, audioBytes: nil).hasSound)
    }
}
