import Foundation
import Testing
@testable import SurfCore

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

@Suite("Manifest content types")
struct ManifestContentTypeTests {

    @Test("Every type a playlist is actually served as", arguments: [
        "application/vnd.apple.mpegurl",
        "application/x-mpegURL",
        "APPLICATION/X-MPEGURL",
        "application/mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
        "video/vnd.apple.mpegurl",
        "application/dash+xml",
    ])
    func manifests(_ input: String) {
        #expect(MediaSource.isManifest(contentType: input))
    }

    @Test("Parameters don't hide the type", arguments: [
        "application/x-mpegurl; charset=utf-8",
        "application/x-mpegurl;charset=UTF-8",
        "  application/dash+xml ; charset=utf-8",
    ])
    func parameters(_ input: String) {
        #expect(MediaSource.isManifest(contentType: input))
    }

    @Test("Real media is not a manifest", arguments: [
        "video/mp4",
        "audio/mp4",
        "video/webm",
        "application/octet-stream",
        "video/mp2t",
        "",
        "   ",
    ])
    func notManifests(_ input: String) {
        #expect(!MediaSource.isManifest(contentType: input))
    }

    @Test("text/plain is left alone")
    func plainTextIsNotClaimed() {
        // Misconfigured servers do send playlists as text/plain. Claiming it
        // would misroute every genuinely plain file, and the cost of that is
        // worse than the cost of missing those servers: a download that works
        // would start going to a subprocess that cannot find anything.
        #expect(!MediaSource.isManifest(contentType: "text/plain"))
        #expect(!MediaSource.isManifest(contentType: "text/plain; charset=utf-8"))
    }

    @Test("The URL and the response can disagree, and the response wins")
    func theCaseThisExistsFor() {
        // A signed HLS master with no extension to read. `kind(of:)` has nothing
        // to go on and says `.file`, which is how playlist text ends up saved as
        // a video.
        let signed = "https://cdn.example.com/m/9f2c1a?Policy=eyJTdGF0ZW1lbnQ&Signature=abc"
        #expect(MediaSource.kind(of: signed) == .file)
        #expect(MediaSource.isManifest(contentType: "application/x-mpegURL"))
    }
}
