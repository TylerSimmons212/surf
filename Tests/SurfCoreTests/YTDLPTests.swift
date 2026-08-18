import Foundation
import Testing
@testable import SurfCore

@Suite("yt-dlp arguments")
struct YTDLPArgumentTests {

    private func args(cookies: String? = nil, ffmpeg: String? = nil) -> [String] {
        YTDLP.arguments(
            pageURL: "https://example.com/watch?v=1",
            workingDirectory: "/tmp/work",
            cookieFile: cookies,
            ffmpegPath: ffmpeg
        )
    }

    @Test("The page URL is the last argument")
    func urlGoesLast() {
        // Anything after it would be read as another URL to download.
        #expect(args().last == "https://example.com/watch?v=1")
    }

    @Test("Playlists are never expanded")
    func noPlaylist() {
        // A one-video button that archives a whole channel is a different feature.
        #expect(args().contains("--no-playlist"))
    }

    @Test("Everything is written inside the given working directory")
    func confinedToWorkingDirectory() throws {
        let args = args()
        let index = try #require(args.firstIndex(of: "--paths"))
        #expect(args[index + 1] == "/tmp/work")
    }

    @Test("ffmpeg enables merged formats")
    func mergesWithFFmpeg() throws {
        let args = args(ffmpeg: "/opt/homebrew/bin")
        let index = try #require(args.firstIndex(of: "--format"))
        #expect(args[index + 1] == "bv*+ba/b")
        #expect(args.contains("--merge-output-format"))
    }

    @Test("Without ffmpeg only a pre-muxed stream is asked for")
    func singleStreamWithoutFFmpeg() throws {
        let args = args()
        let index = try #require(args.firstIndex(of: "--format"))
        // Asking for separate streams with nothing to join them fails at the
        // very end, after the whole download.
        #expect(args[index + 1] == "b")
        #expect(!args.contains("--merge-output-format"))
    }

    @Test("Cookies are only passed when there are some")
    func cookiesOptional() {
        #expect(!args().contains("--cookies"))
        #expect(args(cookies: "/tmp/work/cookies.txt").contains("--cookies"))
    }
}

@Suite("yt-dlp output parsing")
struct YTDLPParsingTests {

    @Test("Progress lines become byte counts")
    func parsesProgress() {
        let event = YTDLP.parse("surf-progress 512 1024 1024")
        #expect(event == .progress(YTDLP.Progress(bytesWritten: 512, totalBytes: 1024)))
        #expect(YTDLP.Progress(bytesWritten: 512, totalBytes: 1024).fraction == 0.5)
    }

    @Test("An unknown total falls back to the estimate")
    func fallsBackToEstimate() {
        // Fragmented streams often never report a real Content-Length.
        let event = YTDLP.parse("surf-progress 300 NA 1200")
        #expect(event == .progress(YTDLP.Progress(bytesWritten: 300, totalBytes: 1200)))
    }

    @Test("With neither total, progress is reported as unknown")
    func unknownTotal() {
        let event = YTDLP.parse("surf-progress 300 NA NA")
        #expect(event == .progress(YTDLP.Progress(bytesWritten: 300, totalBytes: 0)))
        #expect(YTDLP.Progress(bytesWritten: 300, totalBytes: 0).fraction == 0)
    }

    @Test("Byte counts that arrive as floats still parse")
    func floatBytes() {
        let event = YTDLP.parse("surf-progress 1048576.0 2097152.0 NA")
        #expect(event == .progress(YTDLP.Progress(bytesWritten: 1_048_576, totalBytes: 2_097_152)))
    }

    @Test("Progress can't exceed 1 when the estimate was low")
    func fractionIsClamped() {
        // An estimate that undershoots would otherwise drive the ring past full.
        #expect(YTDLP.Progress(bytesWritten: 2000, totalBytes: 1000).fraction == 1)
    }

    @Test("The final filename is picked up")
    func parsesDestination() {
        let event = YTDLP.parse("surf-file:/tmp/work/Some Video.mp4")
        #expect(event == .destination("/tmp/work/Some Video.mp4"))
    }

    @Test("Unrecognised output is ignored", arguments: [
        "[youtube] Extracting URL: https://example.com",
        "[download] 5.0% of ~ 12.00MiB at 1.00MiB/s",
        "",
        "surf-progress 300",
        "surf-file:",
    ])
    func ignoresNoise(_ line: String) {
        // Only our own templates are a contract; the rest of yt-dlp's output
        // changes between releases.
        #expect(YTDLP.parse(line) == nil)
    }
}

@Suite("yt-dlp failure messages")
struct YTDLPFailureTests {

    @Test("The last ERROR line wins")
    func picksErrorLine() {
        let stderr = """
        WARNING: unable to extract player version
        [debug] Loading archive file None
        ERROR: [youtube] abc123: Video unavailable
        """
        #expect(YTDLP.failureMessage(from: stderr) == "[youtube] abc123: Video unavailable")
    }

    @Test("Advice meant for a terminal is trimmed off")
    func trimsReportingAdvice() {
        let stderr = "ERROR: Unable to extract data; please report this issue on https://example.com"
        #expect(YTDLP.failureMessage(from: stderr) == "Unable to extract data")
    }

    @Test("Something is always said")
    func neverEmpty() {
        #expect(YTDLP.failureMessage(from: "") == "Download failed")
        #expect(YTDLP.failureMessage(from: "sudden death\n") == "sudden death")
    }
}

@Suite("Cookie export")
struct YTDLPCookieTests {

    private func cookie(
        domain: String,
        name: String = "session",
        value: String = "abc",
        path: String = "/",
        secure: Bool = true,
        expires: Double? = 1_800_000_000
    ) -> YTDLP.Cookie {
        YTDLP.Cookie(
            domain: domain, path: path, isSecure: secure,
            expiresAt: expires, name: name, value: value
        )
    }

    @Test("A domain cookie covers its subdomains", arguments: [
        (".example.com", "example.com"),
        (".example.com", "videos.example.com"),
        ("example.com", "example.com"),
        (".EXAMPLE.com", "Videos.Example.com"),
    ])
    func matchingHosts(_ domain: String, _ host: String) {
        #expect(YTDLP.cookieApplies(domain: domain, to: host))
    }

    @Test("Unrelated sites are never included", arguments: [
        (".example.com", "example.com.evil.test"),
        (".example.com", "notexample.com"),
        (".other.com", "example.com"),
        ("", "example.com"),
    ])
    func nonMatchingHosts(_ domain: String, _ host: String) {
        // This filter is the whole privacy story: yt-dlp gets one site's
        // cookies, not every session the user has.
        #expect(!YTDLP.cookieApplies(domain: domain, to: host))
    }

    @Test("Cookies serialise as seven tab-separated fields")
    func fieldLayout() throws {
        let file = YTDLP.netscapeCookieFile([cookie(domain: ".example.com")])
        let line = try #require(file.split(separator: "\n").first { !$0.hasPrefix("#") })
        let fields = line.components(separatedBy: "\t")
        #expect(fields.count == 7)
        #expect(fields[0] == ".example.com")
        #expect(fields[1] == "TRUE")   // covers subdomains
        #expect(fields[2] == "/")
        #expect(fields[3] == "TRUE")   // secure
        #expect(fields[4] == "1800000000")
        #expect(fields[5] == "session")
        #expect(fields[6] == "abc")
    }

    @Test("A host-only cookie is not marked as covering subdomains")
    func hostOnlyFlag() throws {
        let file = YTDLP.netscapeCookieFile([cookie(domain: "example.com")])
        let line = try #require(file.split(separator: "\n").first { !$0.hasPrefix("#") })
        #expect(line.components(separatedBy: "\t")[1] == "FALSE")
    }

    @Test("Session cookies get a zero expiry")
    func sessionCookies() throws {
        let file = YTDLP.netscapeCookieFile([cookie(domain: "example.com", expires: nil)])
        let line = try #require(file.split(separator: "\n").first { !$0.hasPrefix("#") })
        #expect(line.components(separatedBy: "\t")[4] == "0")
    }

    @Test("A value containing a tab is dropped, not written")
    func rejectsFieldInjection() {
        // The format has no escaping, so one stray tab would shift every field
        // after it and silently corrupt the cookies that follow.
        let file = YTDLP.netscapeCookieFile([
            cookie(domain: "example.com", name: "good"),
            cookie(domain: "example.com", name: "bad", value: "a\tb"),
            cookie(domain: "example.com", name: "alsobad", value: "a\nb"),
        ])
        #expect(file.contains("good"))
        #expect(!file.contains("bad"))
        #expect(!file.contains("alsobad"))
    }

    @Test("The file always carries its header")
    func header() {
        #expect(YTDLP.netscapeCookieFile([]).hasPrefix("# Netscape HTTP Cookie File"))
    }
}
