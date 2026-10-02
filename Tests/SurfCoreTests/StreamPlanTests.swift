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
    ) throws -> Result<StreamRendition, StreamRefusal> {
        StreamPlan.pick(from: try index(text), preferring: preference)
    }

    // MARK: - Choosing a rendition

    @Test("The best rendition is the tallest")
    func picksTallest() throws {
        let chosen = try pick(StreamFixtures.fmp4Master).get()
        #expect(chosen.height == 1080)
    }

    @Test("A height cap is a ceiling, not a target")
    func heightCap() throws {
        let chosen = try pick(StreamFixtures.fmp4Master, .init(maxHeight: 720)).get()
        #expect(chosen.height == 720)
    }

    @Test("A cap between renditions takes the one below it")
    func capBetweenRenditions() throws {
        // 360, 720 and 1080 on offer. Asking for 900 must not round up.
        let chosen = try pick(StreamFixtures.fmp4Master, .init(maxHeight: 900)).get()
        #expect(chosen.height == 720)
    }

    @Test("A cap below everything takes the smallest rather than refusing")
    func capBelowEverything() throws {
        // "No bigger than 100" on a stream whose smallest is 360. Refusing would
        // be obeying the letter of a preference at the cost of the download.
        let chosen = try pick(StreamFixtures.fmp4Master, .init(maxHeight: 100)).get()
        #expect(chosen.height == 360)
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
        #expect(try pick(text).get().id == "high.m3u8")
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
        #expect(try pick(text).get().id == "only.m3u8")
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
        #expect(try pick(text).get().id == "known.m3u8")
    }

    @Test("The order renditions appear in does not decide")
    func orderIndependent() throws {
        let index = try index(StreamFixtures.fmp4Master)
        var reversed = index
        reversed.renditions.reverse()
        let a = try StreamPlan.pick(from: index).get()
        let b = try StreamPlan.pick(from: reversed).get()
        #expect(a.height == b.height)
        #expect(a.id == b.id)
    }

    // MARK: - Refusals, every one of them before a byte is fetched

    @Test("DRM is refused and is the one thing not handed on")
    func drmIsRefusedOutright() throws {
        let result = try pick(StreamFixtures.sampleAESMedia)
        guard case .failure(let refusal) = result else {
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
        let result = try pick(StreamFixtures.aes128Media)
        guard case .failure(let refusal) = result else {
            Issue.record("AES-128 produced a plan")
            return
        }
        #expect(refusal == .encryptedWithFetchableKey)
        // Not DRM. We just do not do it yet, and the subprocess does.
        #expect(refusal.allowsFallback)
    }

    @Test("A live stream is refused")
    func liveIsRefused() throws {
        let result = try pick(StreamFixtures.liveMedia)
        guard case .failure(let refusal) = result else {
            Issue.record("a live stream produced a plan")
            return
        }
        #expect(refusal == .live)
        #expect(refusal.allowsFallback)
    }

    @Test("Separate video and audio are refused for now, and handed on")
    func separateTracksFallBack() throws {
        // Apple's reference stream is shaped this way and so is most premium
        // packaging. Until there is a muxer, saying so beats a silent file.
        let result = try pick(StreamFixtures.separateAudioMaster)
        guard case .failure(let refusal) = result else {
            Issue.record("video-only renditions produced a plan")
            return
        }
        #expect(refusal == .separateTracks)
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

    private func plan(
        master: String, media: String, preference: StreamPreference = .init()
    ) throws -> Result<StreamPlan, StreamRefusal> {
        let chosen = try pick(master, preference).get()
        let expanded = try index(media, try #require(chosen.manifestURL))
        return StreamPlan.make(from: expanded, labelledBy: chosen, preferring: preference)
    }

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

    @Test("The expectation comes from the manifest, not from hope")
    func expectationFromManifest() throws {
        let plan = try plan(master: StreamFixtures.fmp4Master, media: StreamFixtures.fmp4Media).get()
        #expect(plan.expectation.wantsVideo)
        // CODECS named mp4a, so a file arriving with no audio track is a failure.
        #expect(plan.expectation.wantsAudio)
        #expect(plan.expectation.declaredDuration == 28)
    }

    @Test("A stream that never claimed sound is not required to have it")
    func noAudioClaimedNoAudioRequired() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f"
        v.m3u8
        """
        // Video-only CODECS with no AUDIO group: a silent stream, which is a real
        // thing. Requiring audio here would be the guard inventing a bug.
        let chosen = try #require(HLSPlaylist.parse(master, baseURL: StreamFixtures.base)?
            .renditions.first)
        #expect(chosen.role == .video)
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
}
