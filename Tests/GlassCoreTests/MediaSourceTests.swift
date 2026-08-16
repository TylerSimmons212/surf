import Foundation
import Testing
@testable import GlassCore

@Suite("Media source classification")
struct MediaSourceTests {

    @Test("Plain media files are fetchable", arguments: [
        "https://cdn.example.com/video.mp4",
        "http://example.com/audio.m4a",
        "https://example.com/no-extension-at-all",
        "https://example.com/clip.webm?token=abc",
    ])
    func plainFiles(_ input: String) {
        #expect(MediaSource.kind(of: input) == .file)
    }

    @Test("blob: is a page buffer, not a URL")
    func blobIsStreamed() {
        #expect(MediaSource.kind(of: "blob:https://example.com/9f2c-1a") == .streamed)
    }

    @Test("Manifests are recognised despite being http", arguments: [
        "https://example.com/hls/master.m3u8",
        "https://example.com/dash/manifest.mpd",
        "https://example.com/stream.M3U8",
    ])
    func manifests(_ input: String) {
        // The whole point: these look downloadable and aren't. Saving one gets
        // you a text index, not a video.
        #expect(MediaSource.kind(of: input) == .manifest)
    }

    @Test("A signing token in the query can't be mistaken for an extension")
    func queryDoesNotDecideExtension() {
        let url = "https://cdn.example.com/segment.mp4?policy=eyJ.abc.m3u8"
        #expect(MediaSource.kind(of: url) == .file)
    }

    @Test("Empty means no source yet, not an unsupported one", arguments: ["", "   ", "\n"])
    func emptyIsNone(_ input: String) {
        #expect(MediaSource.kind(of: input) == .none)
    }

    @Test("Other schemes are unsupported", arguments: [
        "data:video/mp4;base64,AAAA",
        "file:///Users/me/movie.mp4",
        "mediasource:1234",
    ])
    func unsupportedSchemes(_ input: String) {
        #expect(MediaSource.kind(of: input) == .unsupported)
    }
}
