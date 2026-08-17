import Foundation
import Testing
@testable import GlassCore

@Suite("Component versions")
struct ComponentVersionTests {

    @Test("Newer versions are recognised", arguments: [
        ("2026.08.16", "2026.07.04"),
        ("2026.01.01", "2025.12.31"),
        ("9.0", "8.1.2"),
        ("8.1.2", "8.1.1"),
        ("10.0", "9.0"),
    ])
    func newer(_ candidate: String, _ installed: String) {
        #expect(ComponentVersion.isNewer(candidate, than: installed))
    }

    @Test("Same or older versions are not", arguments: [
        ("2026.07.04", "2026.07.04"),
        ("2026.07.04", "2026.08.16"),
        ("8.1.2", "9.0"),
        ("9.0", "10.0"),
    ])
    func notNewer(_ candidate: String, _ installed: String) {
        #expect(!ComponentVersion.isNewer(candidate, than: installed))
    }

    @Test("Numeric comparison, not lexicographic")
    func numericNotLexicographic() {
        // "9.0" > "10.0" as strings, and "2026.7.4" > "2026.07.04" too. Both
        // would silently refuse a real update.
        #expect(ComponentVersion.isNewer("10.0", than: "9.0"))
        #expect(!ComponentVersion.isNewer("2026.7.4", than: "2026.07.04"))
    }

    @Test("Nothing installed means anything is newer", arguments: [nil, ""])
    func nothingInstalled(_ installed: String?) {
        #expect(ComponentVersion.isNewer("9.0", than: installed))
    }

    @Test("Trailing zeros don't count as a new version")
    func equalWithDifferentDepth() {
        #expect(!ComponentVersion.isNewer("9.0.0", than: "9.0"))
        #expect(!ComponentVersion.isNewer("9.0", than: "9.0.0"))
        #expect(ComponentVersion.isNewer("9.0.1", than: "9.0"))
    }

    @Test("An unparseable candidate never wins")
    func garbageCandidate() {
        #expect(!ComponentVersion.isNewer("latest", than: "9.0"))
    }
}

@Suite("Update scheduling")
struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A first run always checks")
    func firstRun() {
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
    }

    @Test("A check inside the interval is skipped")
    func tooSoon() {
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    }

    @Test("A check older than the interval is due")
    func overdue() {
        let old = now.addingTimeInterval(-UpdateSchedule.interval - 1)
        #expect(UpdateSchedule.isDue(lastCheck: old, now: now))
    }

    @Test("A future timestamp doesn't park the next check forever")
    func clockWentBackwards() {
        // A restored backup or a corrected clock would otherwise leave a
        // last-check date the present never catches up to.
        let future = now.addingTimeInterval(60 * 60 * 24 * 365)
        #expect(UpdateSchedule.isDue(lastCheck: future, now: now))
    }
}

@Suite("yt-dlp release discovery")
struct YTDLPReleaseTests {

    @Test("The tag is read from the release JSON")
    func parsesTag() throws {
        let json = Data(#"{"tag_name":"2026.07.04","name":"yt-dlp 2026.07.04"}"#.utf8)
        #expect(YTDLPRelease.version(fromReleaseJSON: json) == "2026.07.04")
    }

    @Test("Unusable JSON yields nothing rather than a guess", arguments: [
        #"{"nope":1}"#, "not json at all", "", #"{"tag_name":""}"#,
    ])
    func rejectsBadJSON(_ text: String) {
        #expect(YTDLPRelease.version(fromReleaseJSON: Data(text.utf8)) == nil)
    }

    /// The real format, taken verbatim from the 2026.07.04 release.
    private let sums = """
    495be29ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd  yt-dlp
    498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b  yt-dlp_macos
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  yt-dlp_macos_legacy
    """

    @Test("The right asset's checksum is picked")
    func picksAsset() {
        #expect(
            YTDLPRelease.checksum(forAsset: "yt-dlp_macos", in: sums)
                == "498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b"
        )
    }

    @Test("Assets sharing a prefix are not confused")
    func exactNameMatch() {
        // "yt-dlp", "yt-dlp_macos" and "yt-dlp_macos_legacy" all prefix-match
        // each other, and the wrong one is a binary that won't run here.
        #expect(YTDLPRelease.checksum(forAsset: "yt-dlp", in: sums)?.hasPrefix("495be2") == true)
        #expect(
            YTDLPRelease.checksum(forAsset: "yt-dlp_macos_legacy", in: sums)?.hasPrefix("aaaa")
                == true
        )
    }

    @Test("A missing asset yields nothing")
    func missingAsset() {
        #expect(YTDLPRelease.checksum(forAsset: "yt-dlp_linux", in: sums) == nil)
    }

    @Test("Malformed hashes are refused, not passed through", arguments: [
        "short  yt-dlp_macos",
        "zzzz9ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd00  yt-dlp_macos",
        "  yt-dlp_macos",
    ])
    func rejectsBadHashes(_ line: String) {
        #expect(YTDLPRelease.checksum(forAsset: "yt-dlp_macos", in: line) == nil)
    }

    @Test("Download and checksum URLs point at the same release")
    func urls() throws {
        let download = try #require(YTDLPRelease.downloadURL(version: "2026.07.04"))
        let sums = try #require(YTDLPRelease.checksumsURL(version: "2026.07.04"))
        #expect(download.absoluteString.hasSuffix("/2026.07.04/yt-dlp_macos"))
        #expect(sums.absoluteString.hasSuffix("/2026.07.04/SHA2-256SUMS"))
    }
}

@Suite("ffmpeg release discovery")
struct FFmpegReleaseTests {

    /// The shape of the real history page.
    private let history = """
    <table><tbody>
    <tr><td><a href="/info/detail/macos/arm64/1785863997_9.0">9.0</a></td></tr>
    <tr><td><a href="/info/detail/macos/arm64/1783000000_8.1.2">8.1.2</a></td></tr>
    </tbody></table>
    """

    @Test("The newest build ID is taken from the history page")
    func parsesBuild() {
        #expect(FFmpegRelease.latestBuild(inHistory: history, architecture: "arm64")
            == "1785863997_9.0")
    }

    @Test("Another architecture's rows are ignored")
    func architectureScoped() {
        // Both arches are linked from the same site; picking the wrong one
        // installs a binary that can't run on this machine.
        #expect(FFmpegRelease.latestBuild(inHistory: history, architecture: "amd64") == nil)
    }

    @Test("An unreadable page yields nothing, so the fallback takes over")
    func unparseablePage() {
        #expect(FFmpegRelease.latestBuild(inHistory: "<html>redesigned</html>",
                                          architecture: "arm64") == nil)
    }

    @Test("The version is split out of the build ID")
    func versionFromBuild() {
        #expect(FFmpegRelease.version(ofBuild: "1785863997_9.0") == "9.0")
        #expect(FFmpegRelease.version(ofBuild: "nonsense") == nil)
    }

    @Test("The checksum sidecar is read")
    func sidecar() {
        let text = "5267ef149ee0d208057a1b316aac079b661b0476574dee5da7d225769773c603  ffmpeg.zip\n"
        #expect(FFmpegRelease.checksum(inSidecar: text)
            == "5267ef149ee0d208057a1b316aac079b661b0476574dee5da7d225769773c603")
    }

    @Test("A truncated sidecar is refused")
    func badSidecar() {
        #expect(FFmpegRelease.checksum(inSidecar: "notahash  ffmpeg.zip") == nil)
        #expect(FFmpegRelease.checksum(inSidecar: "") == nil)
    }

    @Test("Architecture names are theirs, not uname's")
    func architectureNames() {
        #expect(FFmpegRelease.architecture(isAppleSilicon: true) == "arm64")
        #expect(FFmpegRelease.architecture(isAppleSilicon: false) == "amd64")
    }

    @Test("Both architectures have a verified fallback", arguments: ["arm64", "amd64"])
    func fallbackExists(_ arch: String) throws {
        // Without this a redesign of their history page takes the feature with
        // it. Each hash was checked by hand against the published sidecar.
        let release = try #require(FFmpegRelease.fallback(architecture: arch))
        #expect(release.sha256.count == 64)
        #expect(release.isZipped)
        #expect(release.downloadURL.absoluteString.contains("/macos/\(arch)/"))
    }

    @Test("An unknown architecture has no fallback to offer")
    func noFallbackForUnknownArch() {
        #expect(FFmpegRelease.fallback(architecture: "riscv") == nil)
    }
}

@Suite("Components")
struct ComponentTests {

    @Test("Only yt-dlp is bundled")
    func bundling() {
        // ffmpeg's every prebuilt static macOS build is GPLv3, and bundling one
        // would put Glass under GPLv3 too. Fetching it at runtime makes the
        // user the recipient rather than Glass the redistributor.
        #expect(Component.ytdlp.isBundled)
        #expect(!Component.ffmpeg.isBundled)
    }

    @Test("Executable names match what's looked for on disk")
    func names() {
        #expect(Component.ytdlp.executableName == "yt-dlp")
        #expect(Component.ffmpeg.executableName == "ffmpeg")
    }
}
