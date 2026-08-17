import Foundation

/// The helper binaries Glass runs but doesn't build.
///
/// These are an implementation detail, deliberately: the user has a Glass
/// version and nothing else. When yt-dlp ships a fix for a site that changed its
/// player, that becomes a Glass improvement, delivered the same way every other
/// improvement is.
public enum Component: String, CaseIterable, Sendable {
    case ytdlp
    case ffmpeg

    /// The name on disk, and the name looked for on `PATH`.
    public var executableName: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        }
    }

    /// Whether a copy ships inside Glass.app.
    ///
    /// yt-dlp is public domain, so it can be bundled and the feature works with
    /// no network on first run. Every prebuilt static macOS ffmpeg is GPLv3, and
    /// bundling one would put Glass under GPLv3 with it — so ffmpeg is fetched
    /// from its publisher at runtime, which makes the user the recipient rather
    /// than Glass the redistributor. This is the same arrangement yt-dlp itself
    /// and HandBrake use.
    public var isBundled: Bool {
        switch self {
        case .ytdlp: true
        case .ffmpeg: false
        }
    }
}

/// A release that could be installed.
public struct ComponentRelease: Equatable, Sendable {
    public var version: String
    public var downloadURL: URL
    /// Lowercase hex. Nothing is installed without matching this.
    public var sha256: String
    /// ffmpeg ships zipped; yt-dlp is the bare executable.
    public var isZipped: Bool

    public init(version: String, downloadURL: URL, sha256: String, isZipped: Bool) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.isZipped = isZipped
    }
}

// MARK: - Versions

public enum ComponentVersion {

    /// Compares dotted numeric versions, newest-wins.
    ///
    /// Covers both schemes in play: yt-dlp's `2026.07.04` and ffmpeg's `9.0`.
    /// Compared component-wise as integers rather than as strings, because
    /// lexicographically "9.0" sorts after "10.0" and "2026.7.4" after
    /// "2026.07.04" — both wrong, and both silently.
    public static func isNewer(_ candidate: String, than installed: String?) -> Bool {
        guard let installed, !installed.isEmpty else { return true }

        let left = numbers(candidate)
        let right = numbers(installed)
        guard !left.isEmpty else { return false }

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}

// MARK: - Scheduling

public enum UpdateSchedule {
    /// Weekly. yt-dlp releases roughly monthly, so this catches a break within
    /// days without turning every launch into a network round trip.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        // A clock that jumped backwards would otherwise park the next check in
        // the far future and never check again.
        guard lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

// MARK: - yt-dlp discovery

/// yt-dlp publishes GitHub releases with a `SHA2-256SUMS` asset, so the version
/// and its checksum come from the same place the binary does.
public enum YTDLPRelease {
    public static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    )!

    /// The universal2 macOS build.
    public static let assetName = "yt-dlp_macos"

    private struct Release: Decodable {
        let tag_name: String
    }

    public static func version(fromReleaseJSON data: Data) -> String? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.tag_name.isEmpty
        else { return nil }
        return release.tag_name
    }

    public static func downloadURL(version: String) -> URL? {
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/\(assetName)")
    }

    public static func checksumsURL(version: String) -> URL? {
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/SHA2-256SUMS")
    }

    /// Pulls one asset's hash out of a `SHA2-256SUMS` file.
    ///
    /// Lines are `<hash>  <filename>`. The filename has to match exactly:
    /// `yt-dlp_macos` and `yt-dlp_macos_legacy` share a prefix, and the wrong
    /// one is a binary that won't run.
    public static func checksum(forAsset asset: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, String(fields[1]) == asset else { continue }
            return normalizedHash(String(fields[0]))
        }
        return nil
    }
}

// MARK: - ffmpeg discovery

/// ffmpeg comes from Martin Riedl's build server: the only source publishing
/// current, genuinely static macOS builds for both architectures, each with a
/// SHA-256 sidecar and a Developer ID signature.
///
/// Builds are identified by `<timestamp>_<version>` with no "latest" alias, so
/// the current one is read off the history page. That page is the fragile part,
/// which is why `fallback` exists below.
public enum FFmpegRelease {
    /// Their name for the architecture, which is not the one `uname` uses.
    public static func architecture(isAppleSilicon: Bool) -> String {
        isAppleSilicon ? "arm64" : "amd64"
    }

    public static func historyURL(architecture: String) -> URL? {
        URL(string: "https://ffmpeg.martin-riedl.de/info/history/macos/\(architecture)/release")
    }

    public static func downloadURL(architecture: String, build: String) -> URL? {
        URL(string: "https://ffmpeg.martin-riedl.de/download/macos/\(architecture)/\(build)/ffmpeg.zip")
    }

    public static func checksumURL(architecture: String, build: String) -> URL? {
        downloadURL(architecture: architecture, build: build)
            .map { $0.appendingPathExtension("sha256") }
    }

    /// The build ID is `<unix timestamp>_<version>`, newest first on the page.
    public static func latestBuild(inHistory html: String, architecture: String) -> String? {
        let pattern = "/info/detail/macos/\(architecture)/([0-9]+_[0-9.]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captured])
    }

    /// The version half of a build ID, for comparing against what's installed.
    public static func version(ofBuild build: String) -> String? {
        let parts = build.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// Sidecar files are `<hash>  ffmpeg.zip`.
    public static func checksum(inSidecar text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isNewline).first,
              let hash = first.split(separator: " ").first
        else { return nil }
        return normalizedHash(String(hash))
    }

    /// A known-good build, verified by hand, used when the history page can't be
    /// read. A site redesign should cost a slightly older ffmpeg, not the
    /// feature — and never an unverified download.
    public static func fallback(architecture: String) -> ComponentRelease? {
        let known: [String: (build: String, sha256: String)] = [
            "arm64": (
                "1785863997_9.0",
                "5267ef149ee0d208057a1b316aac079b661b0476574dee5da7d225769773c603"
            ),
            "amd64": (
                "1785871427_9.0",
                "79d14663d8b078dbbc38de18d63a30f8a5bfc860af5dfee7f8cf3e387cf1c02c"
            ),
        ]
        guard let entry = known[architecture],
              let url = downloadURL(architecture: architecture, build: entry.build),
              let version = version(ofBuild: entry.build)
        else { return nil }
        return ComponentRelease(
            version: version, downloadURL: url, sha256: entry.sha256, isZipped: true
        )
    }

    /// The publisher's Apple team ID.
    ///
    /// Checked in addition to the hash: the hash proves the file matches what
    /// the site advertised, and this proves the site was advertising something
    /// Martin Riedl signed. A compromised site can restate a hash; it can't
    /// restate a Developer ID signature.
    public static let signingTeamID = "KU3N25YGLU"
}

/// Hashes are compared as lowercase hex, from whatever case the source used.
private func normalizedHash(_ hash: String) -> String? {
    let cleaned = hash.trimmingCharacters(in: .whitespaces).lowercased()
    guard cleaned.count == 64,
          cleaned.allSatisfy({ $0.isHexDigit })
    else { return nil }
    return cleaned
}
