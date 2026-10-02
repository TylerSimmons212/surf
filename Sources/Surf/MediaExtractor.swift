import Foundation
import SurfCore
import WebKit

/// Why an extraction ended without a file. Carries a message meant for the
/// downloads list, not a diagnostic code — there is nothing to recover from
/// programmatically, only something to tell the user.
struct ExtractionFailure: Error {
    let message: String
}

/// Runs yt-dlp for media the web view can't fetch itself.
///
/// WebKit downloads a URL. That covers a plain `<video src="movie.mp4">` and
/// nothing else: HLS and DASH players hand the element a `blob:` handle to a
/// buffer they're filling from thousands of segments, and an `.m3u8` URL is an
/// index, not the video. Both are dead ends for `startDownload(using:)`, which
/// is why the download button used to be disabled with an apology.
///
/// yt-dlp knows how to go from a *page* to its media. The cost is a subprocess
/// with no access to the web view's session — see `writeCookieFile` for how
/// that gap is closed, and how narrowly.
@MainActor
final class MediaExtractor {
    static let shared = MediaExtractor()

    private init() {}

    /// Resolution is cached because `isAvailable` is read from a view body, and
    /// invalidated when `UpdateManager` installs something.
    private var resolved: [Component: URL?] = [:]

    var executableURL: URL? { url(of: .ytdlp) }
    var ffmpegURL: URL? { url(of: .ffmpeg) }

    var isAvailable: Bool { executableURL != nil }
    var hasFFmpeg: Bool { ffmpegURL != nil }

    func invalidateResolution() { resolved.removeAll() }

    private func url(of component: Component) -> URL? {
        if let cached = resolved[component] { return cached }
        let found = Self.locate(component)
        resolved[component] = found
        return found
    }

    /// Newest first:
    ///
    /// 1. an explicit override, for debugging — no UI, `defaults write` only
    /// 2. the managed copy `UpdateManager` keeps current
    /// 3. a copy bundled into Surf.app, if a build ever ships one (none do
    ///    today — it was dropped to keep the app small)
    /// 4. anything on the usual `PATH` locations, which is what makes
    ///    `swift run` builds work without a bundle
    private static func locate(_ component: Component) -> URL? {
        let name = component.executableName
        var candidates: [URL] = []

        let override = SurfDefaults.store.string(forKey: "\(name)Path")
        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let managed = UpdateManager.installedURL(component) {
            candidates.append(managed)
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) {
            candidates.append(bundled)
        }
        // A GUI app inherits launchd's PATH, not the user's shell PATH, so the
        // usual locations have to be named outright.
        candidates += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
        ].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Starting

    /// Launches an extraction for `pageURL`.
    ///
    /// Returns nil if yt-dlp couldn't be started at all; every other failure
    /// arrives through `onFinish`.
    func start(
        pageURL: URL,
        cookies: WKHTTPCookieStore,
        onProgress: @escaping @MainActor (YTDLP.Progress) -> Void,
        onFinish: @escaping @MainActor (Result<URL, ExtractionFailure>) -> Void
    ) async -> Extraction? {
        guard let executableURL else { return nil }

        // One scratch directory per run. Fragments, partial files and the
        // pre-merge streams all live here, so nothing half-finished is ever
        // visible in ~/Downloads and cancelling is a single directory removal.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-media-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true
        )) != nil else { return nil }

        let cookieFile = await writeCookieFile(for: pageURL, in: workingDirectory, from: cookies)

        let extraction = Extraction(
            executableURL: executableURL,
            arguments: YTDLP.arguments(
                pageURL: pageURL.absoluteString,
                workingDirectory: workingDirectory.path,
                cookieFile: cookieFile?.path,
                ffmpegPath: ffmpegURL?.deletingLastPathComponent().path
            ),
            workingDirectory: workingDirectory,
            cookieFile: cookieFile
        )

        guard extraction.run(onProgress: onProgress, onFinish: onFinish) else {
            extraction.cleanUp()
            return nil
        }
        return extraction
    }

    // MARK: - Cookies

    /// Hands yt-dlp the cookies for one site, and only that site.
    ///
    /// A subprocess can't share `WKWebsiteDataStore`, so authenticated media
    /// would 403 without this. The obvious implementation — export everything —
    /// would write every session the user has to a file on disk; instead the set
    /// is filtered to the host being downloaded from, the file lives inside the
    /// run's own temp directory at mode 0600, and it is deleted when the run
    /// ends whatever the outcome.
    private func writeCookieFile(
        for pageURL: URL, in directory: URL, from store: WKHTTPCookieStore
    ) async -> URL? {
        guard let host = pageURL.host else { return nil }

        // The downloading tab's own jar, not the default one. A download
        // started from an island would otherwise be authenticated as whoever
        // the *home* island is signed in as — a 403 if you're lucky, and
        // somebody else's video if you're not.
        let all = await store.allCookies()
        let relevant = all
            .filter { YTDLP.cookieApplies(domain: $0.domain, to: host) }
            .map {
                YTDLP.Cookie(
                    domain: $0.domain,
                    path: $0.path,
                    isSecure: $0.isSecure,
                    expiresAt: $0.expiresDate?.timeIntervalSince1970,
                    name: $0.name,
                    value: $0.value
                )
            }
        guard !relevant.isEmpty else { return nil }

        let url = directory.appendingPathComponent("cookies.txt")
        guard let data = YTDLP.netscapeCookieFile(relevant).data(using: .utf8) else { return nil }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        return url
    }
}

// MARK: - One run

/// A single yt-dlp process, from launch to exit.
///
/// Not `@MainActor`: `Process` termination and pipe reads happen on threads
/// Foundation picks. Everything mutable is behind the lock, and every callback
/// is handed back on the main actor.
final class Extraction: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()

    /// The scratch directory. The caller moves the finished file out of it, then
    /// calls `cleanUp`.
    let workingDirectory: URL
    private let cookieFile: URL?

    private let lock = NSLock()
    private var destination: URL?
    private var errorOutput = ""
    private var isCancelled = false

    init(executableURL: URL, arguments: [String], workingDirectory: URL, cookieFile: URL?) {
        self.workingDirectory = workingDirectory
        self.cookieFile = cookieFile
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        // No stdin: yt-dlp must never be able to sit waiting on a prompt that
        // nothing can answer.
        process.standardInput = FileHandle.nullDevice
    }

    /// - Returns: false if the process couldn't be launched.
    func run(
        onProgress: @escaping @MainActor (YTDLP.Progress) -> Void,
        onFinish: @escaping @MainActor (Result<URL, ExtractionFailure>) -> Void
    ) -> Bool {
        let outReader = LineReader(handle: stdout.fileHandleForReading) { [weak self] line in
            guard let self, let event = YTDLP.parse(line) else { return }
            switch event {
            case .progress(let progress):
                Task { @MainActor in onProgress(progress) }
            case .destination(let path):
                lock.withLock { self.destination = URL(fileURLWithPath: path) }
            }
        }

        let errReader = LineReader(handle: stderr.fileHandleForReading) { [weak self] line in
            guard let self else { return }
            lock.withLock {
                // Bounded: a failing extractor can produce a great deal of this,
                // and only the tail is ever read.
                self.errorOutput = String((self.errorOutput + "\n" + line).suffix(4_000))
            }
        }

        do {
            try process.run()
        } catch {
            return false
        }

        // waitUntilExit blocks, so it gets its own queue rather than a slot in
        // the cooperative pool.
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit()
            let status = process.terminationStatus

            // The process is gone but its pipes may still hold the last lines,
            // including the one naming the file.
            outReader.waitForEnd()
            errReader.waitForEnd()

            // The cookie file has done its job; it should not outlive the run
            // even by the length of a move.
            if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) }

            let (destination, message, cancelled) = lock.withLock {
                (self.destination, self.errorOutput, self.isCancelled)
            }

            Task { @MainActor in
                if cancelled { return }
                if status == 0, let destination,
                   FileManager.default.fileExists(atPath: destination.path) {
                    onFinish(.success(destination))
                } else if status == 0 {
                    onFinish(.failure(ExtractionFailure(
                        message: "Nothing to download on this page"
                    )))
                } else {
                    onFinish(.failure(ExtractionFailure(
                        message: YTDLP.failureMessage(from: message)
                    )))
                }
            }
        }

        return true
    }

    /// SIGTERM rather than SIGKILL: yt-dlp closes its files on the way out.
    func cancel() {
        lock.withLock { isCancelled = true }
        if process.isRunning { process.terminate() }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }
}

// MARK: - Pipe reading

/// Turns a pipe into whole lines.
///
/// `availableData` arrives in arbitrary chunks that split lines wherever the
/// buffer happened to end, so partial input is held until a terminator shows up.
private final class LineReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.surf.media-extractor.reader")
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var hasEnded = false

    init(handle: FileHandle, onLine: @escaping @Sendable (String) -> Void) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            queue.async {
                guard !chunk.isEmpty else {
                    self.flush(onLine)
                    handle.readabilityHandler = nil
                    if !self.hasEnded {
                        self.hasEnded = true
                        self.finished.signal()
                    }
                    return
                }
                self.buffer.append(chunk)
                self.consume(onLine)
            }
        }
    }

    /// Progress lines are newline-terminated by `--newline`, but yt-dlp still
    /// uses carriage returns in places, so both count as line ends.
    private func consume(_ onLine: @Sendable (String) -> Void) {
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                onLine(text)
            }
        }
    }

    private func flush(_ onLine: @Sendable (String) -> Void) {
        consume(onLine)
        if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
            onLine(text)
            buffer.removeAll()
        }
    }

    /// Blocks until EOF has been seen and drained. Called from the wait queue,
    /// never the main thread.
    func waitForEnd() {
        _ = finished.wait(timeout: .now() + 5)
    }
}
