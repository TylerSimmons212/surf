import Foundation

/// The pure half of the yt-dlp integration: what to ask it for, and how to read
/// what it says back.
///
/// Everything here is string-in / string-out so it can be tested without
/// spawning anything. `MediaExtractor` in the app target owns the `Process`.
public enum YTDLP {

    // MARK: - Talking to it

    /// Progress is asked for in a fixed, machine-readable shape rather than
    /// scraped from the human progress bar, which carries ANSI escapes, rewrites
    /// itself with carriage returns, and changes between releases.
    ///
    /// `%(...)s` and not `%(...)d`: missing values render as the literal "NA",
    /// which a numeric conversion refuses outright and takes the whole run with it.
    public static let progressTemplate = """
    download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s \
    %(progress.total_bytes_estimate)s
    """

    /// Printed once, after the file has reached its final name — post-merge,
    /// post-remux. Anything read earlier names a fragment.
    public static let filenameTemplate = "after_move:\(filenamePrefix)%(filepath)s"

    static let progressPrefix = "surf-progress"
    static let filenamePrefix = "surf-file:"

    /// Where the download lands, relative to the working directory it's given.
    ///
    /// `.180B` truncates by *bytes*, not characters — a 200-emoji video title is
    /// well inside any character limit and well past the filesystem's.
    public static let outputTemplate = "%(title).180B.%(ext)s"

    /// Builds the command line.
    ///
    /// - Parameters:
    ///   - pageURL: the page, not the media URL. Resolving one to the other is
    ///     the entire reason yt-dlp is here.
    ///   - workingDirectory: a private scratch directory. Partial files,
    ///     fragments and intermediate formats all land here, so a cancelled run
    ///     is cleaned up by deleting one directory, and a half-finished video
    ///     never appears in ~/Downloads looking real.
    ///   - cookieFile: a Netscape cookie file scoped to this site, or nil.
    ///   - ffmpegPath: enables separate video+audio streams to be merged. Without
    ///     it, the best *single* pre-muxed stream is the ceiling — usually 720p.
    public static func arguments(
        pageURL: String,
        workingDirectory: String,
        cookieFile: String? = nil,
        ffmpegPath: String? = nil
    ) -> [String] {
        var args = [
            // Progress as discrete lines instead of one line rewritten in place.
            "--newline",
            // --print implies --quiet; --progress opts progress back in. The
            // result is a stdout carrying only our two templates.
            "--progress",
            "--progress-template", progressTemplate,
            "--print", filenameTemplate,
            // A "download this video" button that quietly starts a 400-video
            // channel archive is not the same feature.
            "--no-playlist",
            "--no-mtime",
            // The default is 1, which fetches a segmented stream one segment at
            // a time. Measured end to end through yt-dlp itself, on a 303MB
            // 720p DASH stream from Akamai: 59.07s at 1, 10.28s at 4. That is
            // 5.75x, 5.13 MB/s to 29.50 MB/s, and the two outputs hash
            // identically — parallelism costs nothing in correctness here
            // because each fragment is a separate ranged request either way.
            //
            // Four and not higher because this number cannot adapt to the server
            // the way a fetcher of our own would, and a lot of parallel
            // connections from one address is what a CDN throttles.
            "--concurrent-fragments", "4",
            // The default is to skip a fragment that won't download and carry
            // on. That turns a stream whose video fragments are being refused
            // into a successful exit with only the audio in the file, which is
            // exactly the bug this guards. A download that cannot have all of
            // the video should fail and say so.
            "--abort-on-unavailable-fragments",
            "--output", outputTemplate,
            "--paths", workingDirectory,
        ]

        if let ffmpegPath {
            args += [
                "--ffmpeg-location", ffmpegPath,
                "--format", "bv*+ba/b",
                // Ask for a container that QuickTime and Finder preview both
                // understand; fall back rather than fail if it can't be had.
                "--merge-output-format", "mp4",
            ]
        } else {
            args += ["--format", "b"]
        }

        if let cookieFile {
            args += ["--cookies", cookieFile]
        }

        args.append(pageURL)
        return args
    }

    // MARK: - Reading it back

    public struct Progress: Equatable, Sendable {
        public var bytesWritten: Int64
        public var totalBytes: Int64

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesWritten) / Double(totalBytes))
        }

        public init(bytesWritten: Int64, totalBytes: Int64) {
            self.bytesWritten = bytesWritten
            self.totalBytes = totalBytes
        }
    }

    public enum Event: Equatable, Sendable {
        case progress(Progress)
        case destination(String)
    }

    /// Interprets one line of stdout. Returns nil for anything unrecognised —
    /// yt-dlp's output surface is large and changes; only our own templates are
    /// a contract.
    public static func parse(_ line: String) -> Event? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix(filenamePrefix) {
            let path = String(text.dropFirst(filenamePrefix.count))
            return path.isEmpty ? nil : .destination(path)
        }

        guard text.hasPrefix(progressPrefix) else { return nil }
        let fields = text.split(separator: " ").dropFirst().map(String.init)
        guard fields.count >= 3 else { return nil }

        // Fields are downloaded / total / estimate. The exact total is unknown
        // until the server sends a Content-Length, which for a fragmented stream
        // may be never — hence the estimate as a second chance.
        let written = number(fields[0]) ?? 0
        let total = number(fields[1]) ?? number(fields[2]) ?? 0
        return .progress(Progress(bytesWritten: written, totalBytes: total))
    }

    /// "NA" for absent, and byte counts that arrive as floats ("1.048576e+06")
    /// often enough to matter.
    private static func number(_ field: String) -> Int64? {
        guard field != "NA", let value = Double(field), value.isFinite, value >= 0 else {
            return nil
        }
        return Int64(value)
    }

    /// Turns yt-dlp's stderr into something worth putting in a UI.
    ///
    /// Its errors are one useful line buried in tracebacks and update nags, and
    /// the useful line is the last `ERROR:` one.
    public static func failureMessage(from stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            var message = String(error.dropFirst("ERROR:".count))
                .trimmingCharacters(in: .whitespaces)
            // The suffix is advice for someone reading a terminal.
            for noise in ["; please report this issue on", "Please report this issue on"] {
                if let range = message.range(of: noise) {
                    message = String(message[..<range.lowerBound])
                }
            }
            return String(message.prefix(200))
        }

        return lines.last.map { String($0.prefix(200)) } ?? "Download failed"
    }

    // MARK: - Cookies

    /// One cookie, flattened out of whatever the platform's cookie type is.
    public struct Cookie: Sendable, Equatable {
        public var domain: String
        public var path: String
        public var isSecure: Bool
        /// Seconds since 1970. Nil means a session cookie.
        public var expiresAt: Double?
        public var name: String
        public var value: String

        public init(
            domain: String,
            path: String,
            isSecure: Bool,
            expiresAt: Double?,
            name: String,
            value: String
        ) {
            self.domain = domain
            self.path = path
            self.isSecure = isSecure
            self.expiresAt = expiresAt
            self.name = name
            self.value = value
        }
    }

    /// Whether a cookie's domain covers the given host.
    ///
    /// This is the filter that keeps the exported file honest: yt-dlp gets the
    /// cookies for the site being downloaded from, and not the user's entire
    /// logged-in life written to a temp file.
    public static func cookieApplies(domain: String, to host: String) -> Bool {
        let host = host.lowercased()
        // A leading dot is the classic "and all subdomains" marker.
        let scope = domain.lowercased().hasPrefix(".")
            ? String(domain.lowercased().dropFirst())
            : domain.lowercased()
        guard !scope.isEmpty, !host.isEmpty else { return false }
        return host == scope || host.hasSuffix("." + scope)
    }

    /// Serialises cookies in the Netscape format `--cookies` expects.
    ///
    /// Tab-separated, one per line: domain, subdomain flag, path, secure flag,
    /// expiry, name, value. Values containing tabs or newlines are dropped
    /// rather than escaped — the format has no escaping, and a mangled line
    /// would silently shift every field after it.
    public static func netscapeCookieFile(_ cookies: [Cookie]) -> String {
        var lines = [
            "# Netscape HTTP Cookie File",
            "# Written by Surf. Ephemeral — delete after use.",
        ]

        for cookie in cookies {
            let fields = [cookie.domain, cookie.path, cookie.name, cookie.value]
            guard !fields.contains(where: { $0.contains("\t") || $0.contains("\n") }) else {
                continue
            }
            // Session cookies get 0, which yt-dlp reads as "no expiry".
            let expiry = cookie.expiresAt.map { String(Int64(max(0, $0))) } ?? "0"
            lines.append([
                cookie.domain,
                cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                cookie.path.isEmpty ? "/" : cookie.path,
                cookie.isSecure ? "TRUE" : "FALSE",
                expiry,
                cookie.name,
                cookie.value,
            ].joined(separator: "\t"))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
