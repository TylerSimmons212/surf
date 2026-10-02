import Foundation
import Testing
@testable import SurfCore

@Suite("DASH manifests")
struct DASHManifestTests {

    private static let base = URL(string: "https://cdn.example.com/dash/manifest.mpd")!

    private func parse(_ text: String, _ url: URL = base) -> StreamIndex? {
        DASHManifest.parse(text, baseURL: url)
    }

    private func video(_ index: StreamIndex) throws -> StreamRendition {
        try #require(index.renditions.first { $0.role == .video || $0.role == .muxed })
    }

    // MARK: - Is this even a manifest

    @Test("Anything that isn't an MPD is refused", arguments: [
        StreamFixtures.notAnMPD,
        StreamFixtures.notAPlaylist,
        "",
        "<MPD",
    ])
    func rejectsNonManifests(_ text: String) {
        #expect(DASHManifest.parse(text, baseURL: Self.base) == nil)
    }

    @Test("An m3u8 is not an MPD and the other way round")
    func formatsDoNotCrossOver() {
        // Each parser has to decline what the other one handles, or a mis-routed
        // manifest parses to nonsense rather than to nothing.
        #expect(DASHManifest.parse(StreamFixtures.fmp4Master, baseURL: Self.base) == nil)
        #expect(HLSPlaylist.parse(StreamFixtures.numberTemplateMPD, baseURL: Self.base) == nil)
    }

    // MARK: - The whole document at once

    @Test("Everything is described in one pass, unlike HLS")
    func noSecondPass() throws {
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        // An MPD lists its segments outright, so the choice is made against a
        // manifest that already has them.
        #expect(!index.needsSecondPass)
        #expect(index.renditions.count == 3)
        #expect(index.renditions.filter { $0.role == .video }.count == 2)
        #expect(index.renditions.filter { $0.role == .audio }.count == 1)
    }

    @Test("The manifest's own duration is believed over a sum of segments")
    func duration() throws {
        // A template states a nominal length for every segment and the last one is
        // short, so summing them overshoots. PT10M34.6S is 634.6.
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        #expect(index.declaredDuration == 634.6)
    }

    // MARK: - Segment counts, which come from arithmetic

    @Test("Segment count is the period divided by the nominal segment length")
    func segmentCount() throws {
        // 634.6 seconds at 120/30 = 4 seconds each, rounded up: 159. Verified
        // against the real manifest, where segment 159 exists and returns 206.
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        #expect(try video(index).segments.count == 159)
    }

    @Test("The first and last segment URLs are the ones that exist")
    func segmentURLs() throws {
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        let high = try #require(index.renditions.first { $0.id == "high" })
        #expect(high.segments.first?.url.absoluteString
            == "https://cdn.example.com/dash/high/high_1.m4v")
        #expect(high.segments.last?.url.absoluteString
            == "https://cdn.example.com/dash/high/high_159.m4v")
        #expect(high.initSegment?.url.absoluteString
            == "https://cdn.example.com/dash/high/high_0.m4v")
    }

    @Test("Audio counts its own segments, on its own timescale")
    func audioHasItsOwnCount() throws {
        // 192512/48000 is ~4.01 seconds, not 4, so the audio count differs from
        // the video's. Anything assuming one count for both breaks here.
        let index = try #require(parse(StreamFixtures.paddedNumberMPD))
        let video = try video(index)
        let audio = try #require(index.renditions.first { $0.role == .audio })
        #expect(video.segments.count != audio.segments.count)
    }

    // MARK: - Template substitution, where a parser silently builds 404s

    @Test("A width specifier inside the variable is honoured")
    func paddedNumber() throws {
        // `$Number%04d$` is real and common. Building `1.m4s` where the server has
        // `0001.m4s` is a 404 per segment and a download that fails completely
        // while looking like a network problem.
        let index = try #require(parse(StreamFixtures.paddedNumberMPD))
        let video = try video(index)
        #expect(video.segments.first?.url.lastPathComponent == "0001.m4s")
        #expect(video.segments.last?.url.lastPathComponent == "0184.m4s")
    }

    @Test("Each variable is substituted", arguments: [
        ("$Number$", "7"),
        ("$Number%04d$", "0007"),
        ("$Number%01d$", "7"),
        ("$Time$", "1234"),
        ("$RepresentationID$", "v1"),
        ("$Bandwidth$", "800000"),
    ])
    func variables(_ template: String, _ expected: String) {
        let result = DASHManifest.expand(
            template,
            with: .init(representationID: "v1", bandwidth: "800000"),
            number: 7, time: 1234
        )
        #expect(result == expected)
    }

    @Test("Several variables in one template")
    func combinedVariables() {
        let result = DASHManifest.expand(
            "$RepresentationID$/seg-$Number%05d$-$Time$.m4s",
            with: .init(representationID: "video_1", bandwidth: "500"),
            number: 42, time: 96000
        )
        #expect(result == "video_1/seg-00042-96000.m4s")
    }

    @Test("A doubled dollar is a literal one and cannot open a variable")
    func escapedDollar() {
        let result = DASHManifest.expand(
            "odd$$Number$$path/$Number$.m4s",
            with: .init(representationID: "v", bandwidth: "1"),
            number: 3, time: nil
        )
        // The escaped pair becomes one dollar, and only the genuine variable is
        // replaced. Substituting `$$` first would let a literal dollar in a path
        // open a variable that was never there.
        #expect(result == "odd$Number$path/3.m4s")
    }

    @Test("An absurd width is left alone rather than allocating for it")
    func absurdWidth() {
        let result = DASHManifest.expand(
            "$Number%0999d$.m4s",
            with: .init(representationID: "v", bandwidth: "1"),
            number: 1, time: nil
        )
        #expect(result == "$Number%0999d$.m4s")
    }

    // MARK: - Explicit timelines

    @Test("An S element's repeat count is additional, not total")
    func timelineRepeats() throws {
        // r="2" is three segments, not two. Reading it as a total loses the last
        // of every run, which produces a file that plays and ends early.
        // 3 + 1 + 2 = 6.
        let index = try #require(parse(StreamFixtures.timelineMPD))
        #expect(try video(index).segments.count == 6)
    }

    @Test("A timeline's own durations are used, not a nominal one")
    func timelineDurations() throws {
        let segments = try video(try #require(parse(StreamFixtures.timelineMPD))).segments
        #expect(segments.map(\.duration) == [4, 4, 4, 2, 4, 4])
    }

    @Test("The clock continues across runs without a restated start")
    func timelineClock() throws {
        // Only the first S states @t. The rest continue from it, and $Time$ has to
        // follow — each segment's URL names the moment it starts.
        let segments = try video(try #require(parse(StreamFixtures.timelineMPD))).segments
        let times = segments.map { $0.url.lastPathComponent }
        #expect(times == [
            "1-0.m4s", "2-4000.m4s", "3-8000.m4s",
            "4-12000.m4s", "5-14000.m4s", "6-18000.m4s",
        ])
    }

    @Test("A timeline beats arithmetic when both are stated")
    func timelineWinsOverDuration() throws {
        // An explicit timeline is exact. A nominal duration beside it is a
        // fallback, and preferring the arithmetic would invent a count.
        let text = StreamFixtures.timelineMPD.replacingOccurrences(
            of: #"startNumber="1""#, with: #"startNumber="1" duration="1000""#
        )
        #expect(try video(try #require(parse(text))).segments.count == 6)
    }

    // MARK: - Enumerated lists and single files

    @Test("A segment list is read in order")
    func segmentList() throws {
        let index = try #require(parse(StreamFixtures.segmentListMPD))
        let video = try video(index)
        #expect(video.segments.count == 3)
        #expect(video.segments.map { $0.url.lastPathComponent } == ["1.m4s", "2.m4s", "3.m4s"])
        #expect(video.initSegment?.url.lastPathComponent == "init.mp4")
    }

    @Test("A representation with no addressing is one file")
    func singleFile() throws {
        // The on-demand profile, and every SegmentBase representation once you
        // decline to read its index box. One segment, which downloads correctly.
        let index = try #require(parse(StreamFixtures.singleFileMPD))
        let video = try video(index)
        #expect(video.segments.count == 1)
        #expect(video.segments.first?.url.lastPathComponent == "DASH_vodvideo_Track1.m4v")
        #expect(video.initSegment == nil)
        #expect(video.segments.first?.duration == 597)
    }

    // MARK: - Attributes inherit downwards

    @Test("Codecs and type on the adaptation set reach the representation")
    func inheritance() throws {
        // Sony's test vector puts codecs, mimeType and contentType on the set and
        // nothing on the representation. Reading only the representation leaves a
        // stream with no codec, no role, and no way to be chosen — which is a
        // manifest that parses to renditions nothing will pick.
        let index = try #require(parse(StreamFixtures.singleFileMPD))
        let video = try video(index)
        #expect(video.codecs == "avc1.4D401E")
        #expect(video.role == .video)
        #expect(video.width == 854)
        #expect(video.height == 480)
        let audio = try #require(index.renditions.first { $0.role == .audio })
        #expect(audio.codecs == "mp4a.40.5")
    }

    @Test("A representation's own attribute wins over the set's")
    func representationOverridesSet() throws {
        let text = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4" contentType="video" codecs="avc1.111111"
              width="100" height="50">
              <SegmentTemplate duration="4" timescale="1" startNumber="1"
                media="$Number$.m4s" initialization="i.mp4"/>
              <Representation id="v" codecs="hvc1.222222" width="1920" height="1080"
                bandwidth="1"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let video = try video(try #require(parse(text)))
        #expect(video.codecs == "hvc1.222222")
        #expect(video.width == 1920)
        #expect(video.height == 1080)
    }

    @Test("A template on the representation wins over one on the set")
    func representationTemplateWins() throws {
        let text = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4" contentType="video" codecs="avc1.1">
              <SegmentTemplate duration="4" timescale="1" startNumber="1"
                media="set/$Number$.m4s" initialization="set/i.mp4"/>
              <Representation id="v" bandwidth="1">
                <SegmentTemplate duration="4" timescale="1" startNumber="1"
                  media="rep/$Number$.m4s" initialization="rep/i.mp4"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let video = try video(try #require(parse(text)))
        #expect(video.segments.first?.url.lastPathComponent == "1.m4s")
        #expect(video.segments.first?.url.path.contains("/rep/") == true)
    }

    // MARK: - Where the bytes come from

    @Test("BaseURL elements chain, each relative to the last")
    func baseURLChain() throws {
        // Root, then period, then adaptation set. Resolving any of them against
        // the page rather than the chain is how a download ends up somewhere the
        // manifest never named.
        let index = try #require(parse(StreamFixtures.baseURLChainMPD))
        let video = try video(index)
        #expect(video.segments.first?.url.absoluteString
            == "https://seg.example.net/root/period1/video/1.m4s")
        #expect(video.initSegment?.url.absoluteString
            == "https://seg.example.net/root/period1/video/init.mp4")
    }

    @Test("A plan records the host a BaseURL sent it to")
    func hostsFollowTheChain() throws {
        let index = try #require(parse(StreamFixtures.baseURLChainMPD))
        let pick = try StreamPlan.pick(from: index).get()
        // Both tracks come from the one document, which is the DASH shape.
        let plan = try StreamPlan.make(video: index, audio: index, labelledBy: pick).get()
        // The manifest is on cdn.example.com and names seg.example.net. That is an
        // ordinary CDN arrangement and also the shape a hostile manifest takes, so
        // what matters is that the plan says where it is going.
        #expect(plan.hosts == ["seg.example.net"])
        #expect(plan.audio?.segments.first?.url.absoluteString
            == "https://seg.example.net/root/period1/audio/1.m4s")
    }

    // MARK: - Refusals

    @Test("Content protection anywhere in the document is DRM")
    func protected() throws {
        let index = try #require(parse(StreamFixtures.protectedMPD))
        #expect(index.protection == .protected)
        guard case .failure(let refusal) = StreamPlan.pick(from: index) else {
            Issue.record("protected content produced a plan")
            return
        }
        #expect(refusal == .protected)
        #expect(!refusal.allowsFallback)
    }

    @Test("Protection nested deeper than the adaptation set still counts")
    func protectionNestsDeeply() throws {
        // A `ContentProtection` on the representation protects the content exactly
        // as much as one on the set, and a check that only looks one level down
        // produces a download of encrypted segments.
        let text = StreamFixtures.numberTemplateMPD.replacingOccurrences(
            of: #"height="2160"/>"#,
            with: #"height="2160"><ContentProtection schemeIdUri="urn:x"/></Representation>"#
        )
        #expect(try #require(parse(text)).protection == .protected)
    }

    @Test("A dynamic manifest is live")
    func live() throws {
        // And it parses rather than failing. A live manifest states no total, so no
        // segment count can be worked out and every rendition comes back empty —
        // returning nil then reports "not a manifest", which sends the reader
        // looking for a parse bug instead of telling them the stream has not
        // finished.
        let index = try #require(parse(StreamFixtures.liveMPD))
        #expect(index.isLive)
        #expect(index.declaredDuration == nil)
        guard case .failure(let refusal) = StreamPlan.pick(from: index) else {
            Issue.record("a live manifest produced a plan")
            return
        }
        #expect(refusal == .live)
        #expect(refusal.allowsFallback)
    }

    // MARK: - Pairing, which DASH does not state

    @Test("A video stream is paired with a soundtrack the manifest never linked")
    func pairingWithoutALink() throws {
        // HLS says `AUDIO="group"` on the variant. DASH says nothing: the
        // adaptation sets are independent and a player combines them. So the
        // reconciliation happens in the parser, because which soundtracks belong
        // to a picture is a fact about the format rather than a decision about the
        // download — and a planner that had to know which format it was handed
        // would be the wrong shape.
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        let pick = try StreamPlan.pick(from: index).get()
        #expect(pick.video.role == .video)
        #expect(pick.video.height == 2160)
        #expect(pick.audio != nil)
        #expect(try #require(pick.audio).codecs == "mp4a.40.5")
    }

    @Test("A manifest with no audio at all is refused rather than silently halved")
    func videoWithNoAudio() throws {
        let text = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4" contentType="video" codecs="avc1.1">
              <SegmentTemplate duration="4" timescale="1" startNumber="1"
                media="$Number$.m4s" initialization="i.mp4"/>
              <Representation id="v" bandwidth="1" width="640" height="360"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        guard case .failure(let refusal) = StreamPlan.pick(from: try #require(parse(text))) else {
            Issue.record("a video-only manifest produced a plan")
            return
        }
        #expect(refusal == .separateTracks)
        #expect(refusal.allowsFallback)
    }

    // MARK: - The whole way through

    @Test("A plan built from an MPD fetches the rendition that was chosen")
    func planUsesTheChosenRendition() throws {
        // The bug this exists for: `make` used to take the first rendition with
        // segments, which for HLS is the only one in a media playlist and for DASH
        // is whichever the publisher listed first. On a real manifest that meant
        // choosing 3840x2160 and then fetching a 1024x576 stream's segments,
        // labelled as 4K. On another it meant the video track's segments being the
        // audio file.
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        let pick = try StreamPlan.pick(from: index).get()
        let plan = try StreamPlan.make(video: index, audio: index, labelledBy: pick).get()

        #expect(plan.video.height == 2160)
        // The proof is the URL, not the label.
        #expect(plan.video.segments.first?.url.absoluteString
            == "https://cdn.example.com/dash/high/high_1.m4v")
        let audio = try #require(plan.audio)
        #expect(audio.segments.first?.url.absoluteString
            == "https://cdn.example.com/dash/aud/aud_1.m4a")
        #expect(plan.expectation.wantsVideo)
        #expect(plan.expectation.wantsAudio)
        #expect(plan.segmentCount == plan.video.segments.count + audio.segments.count)
    }

    @Test("A height cap applies the same way it does to a playlist")
    func heightCap() throws {
        let index = try #require(parse(StreamFixtures.numberTemplateMPD))
        let pick = try StreamPlan.pick(from: index, preferring: .init(maxHeight: 720)).get()
        #expect(pick.video.height == 180)
    }

    // MARK: - ISO 8601 durations

    @Test("Durations are read", arguments: [
        ("PT10M34.6S", 634.6),
        ("PT9M57S", 597.0),
        ("PT1H2M3S", 3723.0),
        ("PT0H0M4.000S", 4.0),
        ("PT12M14S", 734.0),
        ("PT4S", 4.0),
        ("PT1H", 3600.0),
    ])
    func durations(_ text: String, _ expected: Double) {
        let parsed = DASHManifest.duration(text)
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - expected) < 0.0001)
    }

    @Test("Anything unreadable is nil rather than zero", arguments: [
        "", "PT", "10M", "P10M", "PT10", "PTXS", "nonsense", "PT0S",
    ])
    func unreadableDurations(_ text: String) {
        // Nil, not zero. A duration of zero would be divided by when working out a
        // segment count.
        #expect(DASHManifest.duration(text) == nil)
    }
}

@Suite("Manifest dispatch")
struct StreamManifestTests {

    private static let base = URL(string: "https://cdn.example.com/m/manifest")!

    @Test("A playlist is recognised without being named", arguments: [
        StreamFixtures.fmp4Master, StreamFixtures.fmp4Media, StreamFixtures.separateAudioMaster,
    ])
    func hls(_ text: String) {
        #expect(StreamManifest.parse(text, baseURL: Self.base) != nil)
    }

    @Test("An MPD is recognised without being named", arguments: [
        StreamFixtures.numberTemplateMPD, StreamFixtures.singleFileMPD,
        StreamFixtures.timelineMPD, StreamFixtures.segmentListMPD,
    ])
    func dash(_ text: String) {
        #expect(StreamManifest.parse(text, baseURL: Self.base) != nil)
    }

    @Test("Neither format is neither", arguments: [
        StreamFixtures.notAPlaylist, StreamFixtures.notAnMPD, "", "   ",
    ])
    func neither(_ text: String) {
        #expect(StreamManifest.parse(text, baseURL: Self.base) == nil)
    }

    @Test("Dispatch produces what the named parser would have")
    func agreesWithTheParsers() {
        // The point of the dispatcher is that the caller stops naming a format.
        // It earns that only if it is otherwise invisible.
        #expect(StreamManifest.parse(StreamFixtures.fmp4Master, baseURL: Self.base)
            == HLSPlaylist.parse(StreamFixtures.fmp4Master, baseURL: Self.base))
        #expect(StreamManifest.parse(StreamFixtures.numberTemplateMPD, baseURL: Self.base)
            == DASHManifest.parse(StreamFixtures.numberTemplateMPD, baseURL: Self.base))
    }

    @Test("A DASH plan needs no second index for its soundtrack")
    func dashNeedsNoAudioIndex() throws {
        // The runner fetches a second manifest only when the pick points at one,
        // which DASH never does. So `make` has to accept a pick whose soundtrack
        // already carries its segments, or every DASH download refuses with
        // `noSegments` while the parser is perfectly correct.
        let index = try #require(
            StreamManifest.parse(StreamFixtures.numberTemplateMPD, baseURL: Self.base)
        )
        let pick = try StreamPlan.pick(from: index).get()
        #expect(pick.audio != nil)
        let plan = try StreamPlan.make(video: index, audio: nil, labelledBy: pick).get()
        let audio = try #require(plan.audio)
        #expect(audio.role == .audio)
        #expect(!audio.segments.isEmpty)
        // And it is the soundtrack, not the picture handed over under its name.
        #expect(audio.segments.first?.url.lastPathComponent == "aud_1.m4a")
    }

    @Test("An HLS plan still refuses when its soundtrack was never fetched")
    func hlsStillNeedsItsAudioIndex() throws {
        // The dangerous half of the same change. An HLS pick's soundtrack is a
        // pointer with no segments, and a loose fallback to the video index would
        // find the video rendition and hand back its segments as the audio track.
        let master = try #require(
            HLSPlaylist.parse(StreamFixtures.separateAudioMaster, baseURL: Self.base)
        )
        let pick = try StreamPlan.pick(from: master).get()
        // Not nested inside the outer `#require`: the macro expands recursively.
        let videoURL = try #require(pick.video.manifestURL)
        let videoIndex = try #require(
            HLSPlaylist.parse(StreamFixtures.fmp4Media, baseURL: videoURL)
        )
        guard case .failure(let refusal) = StreamPlan.make(
            video: videoIndex, audio: nil, labelledBy: pick
        ) else {
            Issue.record("an unfetched HLS soundtrack produced a plan")
            return
        }
        #expect(refusal == .noSegments)
    }
}
