import Foundation
import Testing
@testable import SurfCore

@Suite("HLS playlists")
struct HLSPlaylistTests {

    private func parse(_ text: String, _ base: URL = StreamFixtures.base) -> StreamIndex? {
        HLSPlaylist.parse(text, baseURL: base)
    }

    // MARK: - Is this even a playlist

    @Test("Anything without the header is not a playlist", arguments: [
        StreamFixtures.notAPlaylist,
        "",
        "   \n  \n",
        "#EXT-X-VERSION:7\n#EXT-X-ENDLIST",
    ])
    func rejectsNonPlaylists(_ text: String) {
        // A server that answers 200 with an error page would otherwise parse to
        // an empty index, which reads as "this video has no segments" rather than
        // "this is not a playlist".
        #expect(parse(text) == nil)
    }

    // MARK: - Masters

    @Test("Every variant is found, and the trick-play stream is not one")
    func masterVariants() throws {
        let index = try #require(parse(StreamFixtures.fmp4Master))
        // Three variants. The EXT-X-I-FRAME-STREAM-INF is all keyframes and no
        // sound, and would otherwise look like an excellent 1080p rendition.
        #expect(index.renditions.count == 3)
        #expect(index.needsSecondPass)
        #expect(!index.renditions.contains { $0.id.contains("iframe") })
    }

    @Test("A comma inside CODECS is not an attribute separator")
    func codecsCommaIsNotASeparator() throws {
        // The classic misparse: split the line on commas and CODECS becomes
        // `avc1.64001f` with a junk attribute called `mp4a.40.2`. The variant then
        // reads as video-only and every decision after it changes.
        let index = try #require(parse(StreamFixtures.fmp4Master))
        let v720 = try #require(index.renditions.first { $0.height == 720 })
        #expect(v720.codecs == "avc1.64001f,mp4a.40.2")
        #expect(v720.role == .muxed)
    }

    @Test("Resolution and bandwidth come through")
    func masterAttributes() throws {
        let index = try #require(parse(StreamFixtures.fmp4Master))
        let v1080 = try #require(index.renditions.first { $0.id == "1080/stream.m3u8" })
        #expect(v1080.width == 1920)
        #expect(v1080.height == 1080)
        // Peak, not the 5942000 average sitting next to it.
        #expect(v1080.bandwidth == 6221600)
    }

    @Test("Variant URLs resolve against the playlist")
    func masterURLResolution() throws {
        let index = try #require(parse(StreamFixtures.fmp4Master))
        let urls = index.renditions.compactMap(\.manifestURL).map(\.absoluteString)
        #expect(urls.contains("https://cdn.example.com/hls/720/stream.m3u8"))
        #expect(urls.contains("https://cdn.example.com/hls/1080/stream.m3u8"))
    }

    @Test("Video-only variants and their audio group are both found")
    func separateAudio() throws {
        let index = try #require(parse(StreamFixtures.separateAudioMaster))
        let video = index.renditions.filter { $0.role == .video }
        let audio = index.renditions.filter { $0.role == .audio }
        #expect(video.count == 2)
        #expect(audio.count == 2)
        // The linkage that says where a video-only stream's sound is.
        #expect(video.allSatisfy { $0.audioGroup == "aac-128k" })
        #expect(audio.allSatisfy { $0.audioGroup == "aac-128k" })
    }

    @Test("An AUDIO group overrules CODECS about what the variant contains")
    func audioGroupOverrulesCodecs() {
        // Apple's own reference stream is shaped like this: CODECS names both an
        // video and an audio format while AUDIO points at a separate group. The
        // specification says CODECS lists formats present in the variant *and*
        // its associated renditions, so the video playlist itself is silent.
        //
        // Reading CODECS alone would download it and produce a video with no
        // sound. Taken verbatim from devstreaming-cdn.apple.com.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ec3-48-768",NAME="English",URI="a/prog_index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=18352480,RESOLUTION=1920x1080,CODECS="avc1.640028,ec-3",AUDIO="ec3-48-768"
        v/prog_index.m3u8
        """
        let index = HLSPlaylist.parse(text, baseURL: StreamFixtures.base)
        let variant = index?.renditions.first { $0.id == "v/prog_index.m3u8" }
        #expect(variant?.role == .video)
        // The string is still kept verbatim, because it is what tells a muxer
        // what it is being handed.
        #expect(variant?.codecs == "avc1.640028,ec-3")
    }

    @Test("Dolby codecs are audio", arguments: [
        "avc1.640028,ec-3", "avc1.640028,ac-3", "avc1.64001f,mp4a.40.5",
    ])
    func dolbyAndHEAAC(_ codecs: String) {
        // ec-3 and ac-3 are Dolby Digital Plus and Dolby Digital; mp4a.40.5 is
        // HE-AAC. All three appear in Apple's stream, and missing any one of them
        // would read a muxed variant as video-only.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=2x1,CODECS="\(codecs)"
        v.m3u8
        """
        #expect(HLSPlaylist.parse(text, baseURL: StreamFixtures.base)?
            .renditions.first?.role == .muxed)
    }

    @Test("The old dotted-decimal codec form is still a codec")
    func legacyCodecStrings() {
        // Unified Streaming serves `avc1.66.30` rather than the hex form.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=493000,RESOLUTION=224x100,CODECS="mp4a.40.2,avc1.66.30"
        v.m3u8
        """
        #expect(HLSPlaylist.parse(text, baseURL: StreamFixtures.base)?
            .renditions.first?.role == .muxed)
    }

    @Test("Codec order does not decide the role")
    func codecOrderIndependent() {
        // mux.dev lists audio first. Plenty of packagers do.
        let audioFirst = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="mp4a.40.2,avc1.64001f"
        v.m3u8
        """
        let videoFirst = audioFirst.replacingOccurrences(
            of: "mp4a.40.2,avc1.64001f", with: "avc1.64001f,mp4a.40.2")
        #expect(HLSPlaylist.parse(audioFirst, baseURL: StreamFixtures.base)?
            .renditions.first?.role == .muxed)
        #expect(HLSPlaylist.parse(videoFirst, baseURL: StreamFixtures.base)?
            .renditions.first?.role == .muxed)
    }

    @Test("Subtitles are kept but not mistaken for media")
    func subtitlesAreNotAudio() throws {
        let index = try #require(parse(StreamFixtures.separateAudioMaster))
        let subs = index.renditions.filter { $0.role == .other }
        #expect(subs.count == 1)
        #expect(subs.first?.id == "English")
    }

    // MARK: - Media playlists, where the counting happens

    @Test("Segments are counted, ordered and resolved")
    func mediaSegments() throws {
        let index = try #require(parse(
            StreamFixtures.fmp4Media,
            URL(string: "https://cdn.example.com/hls/720/stream.m3u8")!
        ))
        let rendition = try #require(index.renditions.first)
        // Count, first and last. The middle never breaks on its own: count is
        // where sequence numbers go wrong and the ends are where URL resolution
        // does.
        #expect(rendition.segments.count == 7)
        #expect(rendition.segments.first?.url.absoluteString
            == "https://cdn.example.com/hls/720/seg-1.m4s")
        #expect(rendition.segments.last?.url.absoluteString
            == "https://cdn.example.com/hls/720/seg-7.m4s")
    }

    @Test("Duration is summed from the segments")
    func mediaDuration() throws {
        let index = try #require(parse(StreamFixtures.fmp4Media))
        #expect(index.declaredDuration == 28)
        #expect(index.renditions.first?.duration == 28)
    }

    @Test("A fractional duration survives being read")
    func fractionalDuration() throws {
        let index = try #require(parse(StreamFixtures.mpegTSMedia))
        // 9.009 + 9.009 + 3.003
        let total = try #require(index.declaredDuration)
        #expect(abs(total - 21.021) < 0.0001)
    }

    @Test("The init segment is found and is not counted as content")
    func initSegment() throws {
        let index = try #require(parse(StreamFixtures.fmp4Media))
        let rendition = try #require(index.renditions.first)
        let initSegment = try #require(rendition.initSegment)
        #expect(initSegment.url.absoluteString == "https://cdn.example.com/hls/init.mp4")
        // It has no playable length, so weighting progress by duration must not
        // be thrown off by it.
        #expect(initSegment.duration == 0)
        #expect(!rendition.segments.contains { $0.url == initSegment.url })
    }

    @Test("A title after the duration is not read as part of it")
    func extinfWithTitle() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.5,Chapter One
        a.ts
        #EXT-X-ENDLIST
        """
        let index = try #require(parse(text))
        #expect(index.renditions.first?.segments.first?.duration == 4.5)
    }

    // MARK: - Byte ranges, where an omitted offset breaks everything after it

    @Test("A byte range with no offset continues from the last one")
    func byteRangeContinuation() throws {
        let index = try #require(parse(
            StreamFixtures.byteRangeMedia,
            URL(string: "https://cdn.example.com/hls/stream.m3u8")!
        ))
        let segments = try #require(index.renditions.first?.segments)
        #expect(segments.count == 3)
        // 75232@1012 is stated.
        #expect(segments[0].byteRange == 1012..<76244)
        // 82112 with no offset picks up at 76244.
        #expect(segments[1].byteRange == 76244..<158356)
        #expect(segments[2].byteRange == 158356..<228220)
        // All three are the same file, which is the whole point of the tag.
        #expect(Set(segments.map(\.url.absoluteString)).count == 1)
    }

    @Test("An init segment can carry its own range")
    func initSegmentByteRange() throws {
        let index = try #require(parse(StreamFixtures.byteRangeMedia))
        #expect(index.renditions.first?.initSegment?.byteRange == 0..<1012)
    }

    // MARK: - Protection

    @Test("A fetchable key is not DRM")
    func aes128IsNotDRM() throws {
        // METHOD=AES-128 with a plain URI is a key served over the same
        // connection as everything else. Plenty of ordinary sites use it, and
        // calling it DRM would refuse downloads that are perfectly possible.
        let index = try #require(parse(StreamFixtures.aes128Media))
        #expect(index.protection == .fetchableKey)
    }

    @Test("SAMPLE-AES is DRM")
    func sampleAESIsDRM() throws {
        let index = try #require(parse(StreamFixtures.sampleAESMedia))
        #expect(index.protection == .protected)
    }

    @Test("Any unrecognised method is treated as DRM", arguments: [
        "SAMPLE-AES", "SAMPLE-AES-CTR", "SAMPLE-AES-CENC", "ISO-23001-7", "SOMETHING-NEW",
    ])
    func unknownMethodsAreProtected(_ method: String) {
        // Failing closed. A method we do not recognise producing a corrupt file
        // is worse than refusing something that might have worked.
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=\(method),URI="skd://x"
        #EXTINF:4.0,
        a.m4s
        #EXT-X-ENDLIST
        """
        #expect(HLSPlaylist.parse(text, baseURL: StreamFixtures.base)?.protection == .protected)
    }

    @Test("METHOD=NONE is not protection")
    func methodNone() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        a.m4s
        #EXT-X-ENDLIST
        """
        #expect(try #require(parse(text)).protection == .none)
    }

    @Test("The worst protection in a playlist is the one that counts")
    func worstProtectionWins() throws {
        // A playlist that starts clear and switches to FairPlay partway is
        // protected, and reading the last tag alone would say otherwise.
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"
        #EXTINF:4.0,
        a.m4s
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        b.m4s
        #EXT-X-ENDLIST
        """
        #expect(try #require(parse(text)).protection == .protected)
    }

    // MARK: - Liveness

    @Test("No ENDLIST means there is no whole file to produce")
    func liveHasNoEnd() throws {
        let index = try #require(parse(StreamFixtures.liveMedia))
        #expect(index.isLive)
    }

    @Test("ENDLIST means it has an end", arguments: [
        StreamFixtures.fmp4Media, StreamFixtures.mpegTSMedia, StreamFixtures.aes128Media,
    ])
    func endedIsNotLive(_ text: String) {
        #expect(HLSPlaylist.parse(text, baseURL: StreamFixtures.base)?.isLive == false)
    }

    // MARK: - Containers

    @Test("An EXT-X-MAP means fragmented MP4")
    func fmp4Container() throws {
        #expect(try #require(parse(StreamFixtures.fmp4Media))
            .renditions.first?.container == .fragmentedMP4)
    }

    @Test("Transport streams are recognised so they are not attempted")
    func tsContainer() throws {
        // AVFoundation reads neither MPEG-TS nor WebM, so this has to be known
        // before anything is fetched.
        #expect(try #require(parse(StreamFixtures.mpegTSMedia))
            .renditions.first?.container == .mpegTS)
    }

    // MARK: - Where the segments actually live

    @Test("Absolute segment URLs are kept as they are")
    func absoluteSegments() throws {
        let index = try #require(parse(StreamFixtures.absoluteURLMedia))
        let rendition = try #require(index.renditions.first)
        #expect(rendition.segments.first?.url.host == "seg.example.net")
        #expect(rendition.initSegment?.url.host == "seg.example.net")
        // Not refused here. A manifest naming another host is an ordinary CDN
        // arrangement; whether to send cookies there is the planner's decision,
        // and a parser that quietly dropped them would hide it.
        #expect(rendition.segments.count == 2)
    }

    @Test("Segments resolve against the playlist, never the page")
    func resolvesAgainstPlaylistNotPage() throws {
        let index = try #require(parse(
            StreamFixtures.fmp4Media,
            URL(string: "https://media.example.com/a/b/c/stream.m3u8")!
        ))
        #expect(index.renditions.first?.segments.first?.url.absoluteString
            == "https://media.example.com/a/b/c/seg-1.m4s")
    }

    // MARK: - Attribute reading

    @Test("Quoted values keep their contents and lose their quotes")
    func attributeQuoting() {
        let attrs = HLSPlaylist.attributes(
            after: "#EXT-X-MEDIA:",
            in: #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a,b",NAME="Pass, One",DEFAULT=YES"#
        )
        #expect(attrs["TYPE"] == "AUDIO")
        #expect(attrs["GROUP-ID"] == "a,b")
        #expect(attrs["NAME"] == "Pass, One")
        #expect(attrs["DEFAULT"] == "YES")
    }

    @Test("Attribute names are matched regardless of case")
    func attributeCase() {
        let attrs = HLSPlaylist.attributes(
            after: "#X:", in: #"#X:bandwidth=100,Resolution=2x1"#
        )
        #expect(attrs["BANDWIDTH"] == "100")
        #expect(attrs["RESOLUTION"] == "2x1")
    }

    // MARK: - Shapes that should not crash

    @Test("A playlist with tags and no segments parses to no segments")
    func emptyMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-ENDLIST
        """
        let index = try #require(parse(text))
        #expect(index.renditions.first?.segments.isEmpty == true)
        #expect(index.declaredDuration == nil)
    }

    @Test("An EXTINF with nothing after it is dropped, not guessed at")
    func danglingExtinf() throws {
        let text = """
        #EXTM3U
        #EXTINF:4.0,
        #EXT-X-ENDLIST
        """
        #expect(try #require(parse(text)).renditions.first?.segments.isEmpty == true)
    }

    @Test("A variant line with no URI after it is dropped")
    func danglingStreamInf() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=2x1,CODECS="avc1.42e01e"
        """
        #expect(try #require(parse(text)).renditions.isEmpty)
    }

    @Test("Windows line endings parse the same as Unix ones")
    func crlf() throws {
        let unix = try #require(parse(StreamFixtures.fmp4Media))
        let windows = try #require(parse(
            StreamFixtures.fmp4Media.replacingOccurrences(of: "\n", with: "\r\n")
        ))
        #expect(unix == windows)
    }
}
