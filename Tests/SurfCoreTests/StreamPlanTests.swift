import Foundation
import Testing
@testable import SurfCore

@Suite("Stream plans")
struct StreamPlanTests {

    private func index(_ text: String, _ base: URL = StreamFixtures.base) throws -> StreamIndex {
        try #require(HLSPlaylist.parse(text, baseURL: base))
    }

    private func pick(
        _ text: String, _ preference: StreamPreference = .init()
    ) throws -> Result<StreamPick, StreamRefusal> {
        StreamPlan.pick(from: try index(text), preferring: preference)
    }

    /// The runner's whole sequence, as a test helper: read the master, choose,
    /// read what was chosen, build the plan.
    private func plan(
        master: String,
        media: String,
        audio: String? = nil,
        preference: StreamPreference = .init()
    ) throws -> Result<StreamPlan, StreamRefusal> {
        let chosen = try pick(master, preference).get()
        let videoIndex = try index(media, try #require(chosen.video.manifestURL))
        let audioIndex = try audio.map { text in
            try index(text, try #require(chosen.audio?.manifestURL))
        }
        return StreamPlan.make(
            video: videoIndex, audio: audioIndex,
            labelledBy: chosen, preferring: preference
        )
    }

    // MARK: - Choosing a rendition

    @Test("The best rendition is the tallest")
    func picksTallest() throws {
        #expect(try pick(StreamFixtures.fmp4Master).get().video.height == 1080)
    }

    @Test("A muxed stream needs no second track")
    func muxedHasNoAudioTrack() throws {
        #expect(try pick(StreamFixtures.fmp4Master).get().audio == nil)
    }

    @Test("A height cap is a ceiling, not a target")
    func heightCap() throws {
        #expect(try pick(StreamFixtures.fmp4Master, .init(maxHeight: 720)).get().video.height == 720)
    }

    @Test("A cap between renditions takes the one below it")
    func capBetweenRenditions() throws {
        // 360, 720 and 1080 on offer. Asking for 900 must not round up.
        #expect(try pick(StreamFixtures.fmp4Master, .init(maxHeight: 900)).get().video.height == 720)
    }

    @Test("A cap below everything takes the smallest rather than refusing")
    func capBelowEverything() throws {
        // "No bigger than 100" on a stream whose smallest is 360. Refusing would
        // obey the letter of a preference at the cost of the download, and
        // returning the tallest — which is what this did at first — makes the cap
        // worse than having no cap at all.
        #expect(try pick(StreamFixtures.fmp4Master, .init(maxHeight: 100)).get().video.height == 360)
    }

    // MARK: - An asked-for rendition

    @Test("A chosen rendition is taken exactly, not treated as a ceiling")
    func chosenRendition() throws {
        // The difference from `maxHeight`, which is the reason this is its own
        // field. A cap rounds down on purpose; a menu row does not, because the
        // menu listed that rendition and the user read its size.
        let chosen = try pick(
            StreamFixtures.fmp4Master, .init(renditionID: "720/stream.m3u8")
        ).get()
        #expect(chosen.video.id == "720/stream.m3u8")
        #expect(chosen.video.height == 720)
    }

    @Test("Choosing beats the tallest-wins rule")
    func chosenOverridesBest() throws {
        // 1080 is on offer and is what the engine takes unasked. Asking for 360
        // has to get 360 rather than the best available.
        #expect(try pick(StreamFixtures.fmp4Master).get().video.height == 1080)
        #expect(try pick(
            StreamFixtures.fmp4Master, .init(renditionID: "360/stream.m3u8")
        ).get().video.height == 360)
    }

    @Test("Choosing and a cap together: the choice wins")
    func chosenBeatsCap() throws {
        // Nothing sets both today, and if anything ever does, the explicit
        // request is the one a person made.
        let chosen = try pick(
            StreamFixtures.fmp4Master,
            .init(maxHeight: 360, renditionID: "1080/stream.m3u8")
        ).get()
        #expect(chosen.video.height == 1080)
    }

    @Test("An id that is no longer there falls back instead of failing")
    func staleChoice() throws {
        // The menu's list and this parse are two separate fetches, so a
        // live-edited master or a different advert in front of the film can
        // change the ids in between. Refusing the download because a row went
        // stale would be worse than giving the best on offer.
        let chosen = try pick(
            StreamFixtures.fmp4Master, .init(renditionID: "2160/stream.m3u8")
        ).get()
        #expect(chosen.video.height == 1080)
    }

    @Test("An audio rendition cannot be chosen as the picture")
    func audioIDIgnored() throws {
        // `pick` only ever considers video and muxed renditions, so an audio id
        // matches nothing and the ordinary rule answers. The menu does not offer
        // one on this path for exactly that reason; this is the guard under it.
        let chosen = try pick(
            StreamFixtures.separateAudioMaster,
            .init(renditionID: "audio/en/128k.m3u8")
        ).get()
        #expect(chosen.video.role == .video)
        #expect(chosen.audio != nil)
    }

    @Test("Bandwidth breaks a tie between equal heights")
    func bandwidthBreaksTies() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        high.m3u8
        """
        #expect(try pick(text).get().video.id == "high.m3u8")
    }

    @Test("A rendition that declares no height is still a candidate")
    func undeclaredHeightIsStillPlayable() throws {
        // Single-variant playlists frequently declare nothing. Dropping them
        // would refuse the only stream on offer.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        only.m3u8
        """
        #expect(try pick(text).get().video.id == "only.m3u8")
    }

    @Test("A declared rendition beats an undeclared one")
    func declaredBeatsUndeclared() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        mystery.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2"
        known.m3u8
        """
        #expect(try pick(text).get().video.id == "known.m3u8")
    }

    @Test("The order renditions appear in does not decide")
    func orderIndependent() throws {
        let index = try index(StreamFixtures.fmp4Master)
        var reversed = index
        reversed.renditions.reverse()
        let a = try StreamPlan.pick(from: index).get()
        let b = try StreamPlan.pick(from: reversed).get()
        #expect(a.video.id == b.video.id)
    }

    // MARK: - Separate tracks, which is how modern streams are packaged

    @Test("A video-only rendition is paired with its soundtrack")
    func pairsSeparateTracks() throws {
        let chosen = try pick(StreamFixtures.separateAudioMaster).get()
        #expect(chosen.video.role == .video)
        #expect(chosen.video.height == 1080)
        let audio = try #require(chosen.audio)
        #expect(audio.role == .audio)
        // The group the video variant named, not just any audio in the manifest.
        #expect(audio.audioGroup == "aac-128k")
    }

    @Test("The default soundtrack is the one taken")
    func prefersDefaultAudio() throws {
        // A group routinely holds several languages and a described-video track.
        // DEFAULT is the only thing in the format expressing which the publisher
        // meant, and here the French track is listed with DEFAULT=NO.
        let chosen = try pick(StreamFixtures.separateAudioMaster).get()
        #expect(try #require(chosen.audio).id == "English")
    }

    @Test("Manifest order decides when nothing is marked default")
    func fallsBackToManifestOrder() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="First",DEFAULT=NO,URI="a/1.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Second",DEFAULT=NO,URI="a/2.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="a"
        v.m3u8
        """
        #expect(try #require(try pick(text).get().audio).id == "First")
    }

    @Test("A soundtrack from another group is not used")
    func wrongGroupIsNotUsed() throws {
        // Apple's stream carries five groups at different bitrates and codecs.
        // Taking one the variant did not name would pair Dolby Atmos audio with a
        // video stream expecting stereo AAC.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Stereo",DEFAULT=YES,URI="a/s.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="atmos"
        v.m3u8
        """
        guard case .failure(let refusal) = try pick(text) else {
            Issue.record("a variant naming a group that does not exist produced a plan")
            return
        }
        #expect(refusal == .separateTracks)
        #expect(refusal.allowsFallback)
    }

    @Test("A video-only rendition with no group at all is refused")
    func videoWithoutAnyAudioGroup() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1280x720,CODECS="avc1.64001f"
        v.m3u8
        """
        guard case .failure(let refusal) = try pick(text) else {
            Issue.record("a silent video-only variant produced a plan")
            return
        }
        #expect(refusal == .separateTracks)
    }

    @Test("Muxed and video-only compete on equal terms")
    func tallestWinsWhateverThePackaging() throws {
        // Preferring muxed packaging would hand back 720p while a 1080p video
        // stream sat beside it, for no reason a user would recognise.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",DEFAULT=YES,URI="a/1.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
        muxed720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028",AUDIO="a"
        video1080.m3u8
        """
        let chosen = try pick(text).get()
        #expect(chosen.video.id == "video1080.m3u8")
        #expect(chosen.audio != nil)
    }

    @Test("A muxed stream is taken whole when it is the tallest")
    func muxedWinsWhenTallest() throws {
        // Unified Streaming is shaped this way: muxed variants alongside separate
        // audio renditions. Taking the muxed one means no muxing at all.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",DEFAULT=YES,URI="a/1.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        muxed1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="a"
        video720.m3u8
        """
        let chosen = try pick(text).get()
        #expect(chosen.video.id == "muxed1080.m3u8")
        #expect(chosen.audio == nil)
    }

    // MARK: - Refusals, every one of them before a byte is fetched

    @Test("DRM is refused and is the one thing not handed on")
    func drmIsRefusedOutright() throws {
        guard case .failure(let refusal) = try pick(StreamFixtures.sampleAESMedia) else {
            Issue.record("protected content produced a plan")
            return
        }
        #expect(refusal == .protected)
        // The whole point: yt-dlp will also fail, slower and with a worse
        // message. Refusing now, in a sentence someone wrote, is better.
        #expect(!refusal.allowsFallback)
        #expect(refusal.message == "This video is protected and can't be saved")
    }

    @Test("A fetchable key is refused but handed on")
    func aes128FallsBack() throws {
        guard case .failure(let refusal) = try pick(StreamFixtures.aes128Media) else {
            Issue.record("AES-128 produced a plan")
            return
        }
        #expect(refusal == .encryptedWithFetchableKey)
        // Not DRM. We just do not do it yet, and the subprocess does.
        #expect(refusal.allowsFallback)
    }

    @Test("A live stream is refused")
    func liveIsRefused() throws {
        guard case .failure(let refusal) = try pick(StreamFixtures.liveMedia) else {
            Issue.record("a live stream produced a plan")
            return
        }
        #expect(refusal == .live)
        #expect(refusal.allowsFallback)
    }

    @Test("Nothing playable is a refusal, not an empty plan")
    func subtitlesOnly() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",URI="s/en.m3u8"
        """
        guard case .failure(let refusal) = try pick(text) else {
            Issue.record("a subtitle-only playlist produced a plan")
            return
        }
        #expect(refusal == .noRenditions)
    }

    @Test("Protection is checked before renditions are compared")
    func protectionBeatsEverything() {
        // A protected stream with no renditions at all must still say protected.
        // The order these are checked in is what makes the refusal honest.
        let index = StreamIndex(renditions: [], protection: .protected)
        guard case .failure(let refusal) = StreamPlan.pick(from: index) else {
            Issue.record("produced a plan")
            return
        }
        #expect(refusal == .protected)
    }

    // MARK: - Building the plan

    @Test("A plan carries the segments from one playlist and the description from the other")
    func planMergesBothPlaylists() throws {
        let plan = try plan(master: StreamFixtures.fmp4Master, media: StreamFixtures.fmp4Media).get()
        // A media playlist does not restate resolution or codecs, and the master
        // does not list segments. Neither alone is a plan.
        #expect(plan.video.height == 1080)
        #expect(plan.video.codecs == "avc1.640028,mp4a.40.2")
        #expect(plan.video.segments.count == 7)
        #expect(plan.segmentCount == 7)
        #expect(plan.duration == 28)
        #expect(plan.container == .fragmentedMP4)
        #expect(plan.audio == nil)
    }

    @Test("A two-track plan carries both segment lists")
    func twoTrackPlan() throws {
        let plan = try plan(
            master: StreamFixtures.separateAudioMaster,
            media: StreamFixtures.fmp4Media,
            audio: StreamFixtures.audioMedia
        ).get()
        #expect(plan.video.segments.count == 7)
        let audio = try #require(plan.audio)
        // Audio and video segment on their own boundaries, so the counts differ
        // and only the durations match. Anything assuming a shared count breaks
        // here.
        #expect(audio.segments.count == 4)
        #expect(audio.role == .audio)
        #expect(plan.segmentCount == 11)
        // Duration is the video's. The audio's is incidental.
        #expect(plan.duration == 28)
    }

    @Test("A separate soundtrack means the file must have sound in it")
    func separateAudioImpliesExpectation() throws {
        let plan = try plan(
            master: StreamFixtures.separateAudioMaster,
            media: StreamFixtures.fmp4Media,
            audio: StreamFixtures.audioMedia
        ).get()
        // The manifest stated outright that this has audio by giving it its own
        // playlist, so a file arriving without an audio track is a failure.
        #expect(plan.expectation.wantsVideo)
        #expect(plan.expectation.wantsAudio)
    }

    @Test("The expectation comes from the manifest, not from hope")
    func expectationFromManifest() throws {
        let plan = try plan(master: StreamFixtures.fmp4Master, media: StreamFixtures.fmp4Media).get()
        #expect(plan.expectation.wantsVideo)
        // CODECS named mp4a, so a file arriving with no audio track is a failure.
        #expect(plan.expectation.wantsAudio)
        #expect(plan.expectation.declaredDuration == 28)
    }

    @Test("A variant with no CODECS at all promises nothing about sound")
    func noCodecsNoPromise() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
        v.m3u8
        """
        let plan = try plan(master: master, media: StreamFixtures.fmp4Media).get()
        #expect(plan.expectation.wantsVideo)
        #expect(!plan.expectation.wantsAudio)
    }

    @Test("A container AVFoundation cannot read is refused")
    func unsupportedContainer() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
        v.m3u8
        """
        guard case .failure(let refusal) = try plan(
            master: master, media: StreamFixtures.mpegTSMedia
        ) else {
            Issue.record("a transport stream produced a plan")
            return
        }
        #expect(refusal == .unsupportedContainer(.mpegTS))
        #expect(refusal.allowsFallback)
    }

    @Test("A transport-stream soundtrack is refused too")
    func unsupportedAudioContainer() throws {
        guard case .failure(let refusal) = try plan(
            master: StreamFixtures.separateAudioMaster,
            media: StreamFixtures.fmp4Media,
            audio: StreamFixtures.mpegTSMedia
        ) else {
            Issue.record("a transport-stream soundtrack produced a plan")
            return
        }
        #expect(refusal == .unsupportedContainer(.mpegTS))
    }

    @Test("A playlist with no segments is a refusal")
    func noSegments() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
        v.m3u8
        """
        let empty = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-ENDLIST
        """
        guard case .failure(let refusal) = try plan(master: master, media: empty) else {
            Issue.record("an empty playlist produced a plan")
            return
        }
        #expect(refusal == .noSegments)
    }

    @Test("A missing soundtrack playlist is a refusal, not a silent file")
    func missingAudioIndex() throws {
        let chosen = try pick(StreamFixtures.separateAudioMaster).get()
        let videoIndex = try index(StreamFixtures.fmp4Media, try #require(chosen.video.manifestURL))
        // The pick says there is a soundtrack and nothing was fetched for it.
        // Producing a video-only file here is exactly the bug this whole branch
        // exists to prevent.
        guard case .failure(let refusal) = StreamPlan.make(
            video: videoIndex, audio: nil, labelledBy: chosen
        ) else {
            Issue.record("a pick with audio produced a plan with no audio index")
            return
        }
        #expect(refusal == .noSegments)
    }

    // MARK: - Where the bytes come from, which is a privacy question

    @Test("Every host a plan will touch is recorded")
    func hostsAreCollected() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
        v.m3u8
        """
        let plan = try plan(master: master, media: StreamFixtures.absoluteURLMedia).get()
        // The manifest named a different host from its own, which is ordinary.
        // Recording it is what lets the count be refused and the log say where a
        // download went.
        #expect(plan.hosts == ["seg.example.net"])
    }

    @Test("A manifest fanning out across many hosts is refused")
    func tooManyHosts() throws {
        // The manifest names the hosts we are about to send the tab's cookies to.
        // A hostile BaseURL is the reason this limit exists, and a real CDN never
        // needs more than one or two.
        var media = "#EXTM3U\n#EXT-X-MAP:URI=\"https://a.example.com/i.mp4\"\n"
        for host in ["b", "c", "d", "e", "f"] {
            media += "#EXTINF:4.0,\nhttps://\(host).example.com/s.m4s\n"
        }
        media += "#EXT-X-ENDLIST"

        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
        v.m3u8
        """
        guard case .failure(let refusal) = try plan(master: master, media: media) else {
            Issue.record("six hosts produced a plan")
            return
        }
        #expect(refusal == .tooManyHosts(6))
    }

    @Test("A soundtrack's hosts count towards the limit")
    func audioHostsCount() throws {
        // Otherwise the limit is trivially escaped by putting the extra hosts in
        // the audio playlist.
        let plan = try plan(
            master: StreamFixtures.separateAudioMaster,
            media: StreamFixtures.fmp4Media,
            audio: StreamFixtures.absoluteURLMedia,
            preference: .init(hostLimit: 1)
        )
        guard case .failure(let refusal) = plan else {
            Issue.record("two hosts passed a limit of one")
            return
        }
        #expect(refusal == .tooManyHosts(2))
    }

    @Test("The host limit is configurable, and four by default")
    func hostLimitDefault() {
        #expect(StreamPreference().hostLimit == 4)
        #expect(StreamPreference(hostLimit: 1).hostLimit == 1)
    }

    @Test("Protection is still checked when the plan is built, not only when it is chosen")
    func protectionRecheckedOnMake() throws {
        // The master said nothing and the media playlist is where the key tag
        // lives. Checking only at pick time would miss every stream that declares
        // its protection in the second playlist, which is most of them.
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"
        v.m3u8
        """
        guard case .failure(let refusal) = try plan(
            master: master, media: StreamFixtures.sampleAESMedia
        ) else {
            Issue.record("protected media produced a plan")
            return
        }
        #expect(refusal == .protected)
        #expect(!refusal.allowsFallback)
    }

    @Test("Protection in the soundtrack is caught as well")
    func protectionInAudioIndex() throws {
        // A stream with a clear picture and an encrypted soundtrack is not
        // something to download half of.
        guard case .failure(let refusal) = try plan(
            master: StreamFixtures.separateAudioMaster,
            media: StreamFixtures.fmp4Media,
            audio: StreamFixtures.sampleAESMedia
        ) else {
            Issue.record("an encrypted soundtrack produced a plan")
            return
        }
        #expect(refusal == .protected)
    }
}
