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
