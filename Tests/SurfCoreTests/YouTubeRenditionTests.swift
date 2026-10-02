import Foundation
import Testing
@testable import SurfCore

@Suite("YouTube renditions")
struct YouTubeRenditionTests {

    // The audio of a real watch page (u2rYp8AMuSg, October 2026): itag 140
    // three times over. Itags, xtags and sizes are the page's own; the
    // lastModified values are stand-ins, distinct as the real ones are.
    // Asking for one of the variants by itag and revision alone named a format
    // that does not exist, and the server answered with a request to reload the
    // player and no media at all.
    private let stableVolume = "CggKA2RyYxIBMQ"   // drc=1
    private let voiceBoost = "CgcKAnZiEgEx"       // vb=1

    private var page: [YouTubeRendition] {
        [
            .init(itag: 137, lastModified: "1700000000000137",
                  mimeType: #"video/mp4; codecs="avc1.640028""#, height: 1080,
                  bitrate: 400_000, contentLength: "45729762"),
            .init(itag: 134, lastModified: "1700000000000134",
                  mimeType: #"video/mp4; codecs="avc1.4d401e""#, height: 360,
                  bitrate: 90_000, contentLength: "10216021"),
            .init(itag: 140, lastModified: "1700000000000140",
                  mimeType: #"audio/mp4; codecs="mp4a.40.2""#,
                  bitrate: 130_000, contentLength: "27202697"),
            .init(itag: 140, lastModified: "1700000000000141",
                  mimeType: #"audio/mp4; codecs="mp4a.40.2""#,
                  bitrate: 130_000, contentLength: "27202697", xtags: stableVolume),
            .init(itag: 140, lastModified: "1700000000000142",
                  mimeType: #"audio/mp4; codecs="mp4a.40.2""#,
                  bitrate: 130_010, contentLength: "27203007", xtags: voiceBoost),
        ]
    }

    @Test("A variant is named with its xtags, so the id is one the server has")
    func variantCarriesXtags() throws {
        let variant = try #require(page.first { $0.xtags == voiceBoost })
        let id = try #require(variant.formatID)
        #expect(id.xtags == voiceBoost)
        // On the wire, not just in the struct: field 3 of the FormatId.
        let decoded = try #require(SABR.FormatID.decoded(id.encodedID))
        #expect(decoded == SABR.FormatID(
            itag: 140, lastModified: 1_700_000_000_000_142, xtags: voiceBoost))
    }

    @Test("The plain rendition is named without xtags")
    func plainHasNone() throws {
        let plain = try #require(page.first { $0.itag == 140 && $0.xtags == nil })
        #expect(plain.formatID?.xtags == nil)
    }

    @Test("The engine's pick takes the plain soundtrack over Stable Volume and voice boost")
    func choosesPlainAudio() throws {
        // The voice-boost rendition has the higher bitrate, which is what a
        // pick by bitrate alone landed on. It is processed audio the player
        // uses only when someone opts into it.
        let chosen = try #require(YouTubeRendition.choose(from: page))
        #expect(chosen.audio.xtags == nil)
        #expect(chosen.audio.formatID?.xtags == nil)
        #expect(chosen.video.itag == 137)
    }

    @Test("A menu row's itag resolves to the plain rendition wherever it is listed")
    func namedPrefersPlain() throws {
        let variantsFirst = page.filter { $0.xtags != nil } + page.filter { $0.xtags == nil }
        let named = try #require(YouTubeRendition.named(140, in: variantsFirst))
        #expect(named.xtags == nil)
    }

    @Test("With only variants on offer, the one chosen is still named exactly")
    func onlyVariants() throws {
        // A dubbed video lists every soundtrack with xtags. Whichever is taken,
        // the request has to name it as it is.
        let dubbed = page.filter { $0.isVideo || $0.xtags != nil }
        let chosen = try #require(YouTubeRendition.choose(from: dubbed))
        #expect(chosen.audio.xtags != nil)
        #expect(chosen.audio.formatID?.xtags == chosen.audio.xtags)
    }

    @Test("The bridge's JSON decodes with or without xtags")
    func decodes() throws {
        let json = #"""
        [{"itag":140,"lastModified":"1700000000000140","mimeType":"audio/mp4","height":0,"bitrate":1,"contentLength":"1"},
         {"itag":140,"lastModified":"1700000000000141","mimeType":"audio/mp4","height":0,"bitrate":1,"contentLength":"1","xtags":"CggKA2RyYxIBMQ"}]
        """#
        let renditions = try JSONDecoder().decode([YouTubeRendition].self, from: Data(json.utf8))
        #expect(renditions.map(\.xtags) == [nil, stableVolume])
    }
}
