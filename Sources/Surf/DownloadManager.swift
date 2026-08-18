import AppKit
import SurfCore
import Observation
import WebKit

/// A download in flight or recently finished.
@Observable
@MainActor
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case downloading
        case finished(URL)
        case failed(String)
    }

    let id = UUID()
    var filename: String
    var fraction: Double = 0
    var state: State = .downloading
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    /// Kept so a failed download can be retried without the page's help.
    var sourceURL: URL?
    /// Where the bytes are being written, so a cancelled transfer can clean up
    /// after itself.
    var destinationURL: URL?
    /// Where it came from, for the list's subtitle.
    var host: String?
    /// The page the download was started from, recorded on the saved file.
    var pageURL: URL?
    /// Set when yt-dlp is doing the work, in which case the page URL is the
    /// input and there is no direct media URL to retry against.
    var isExtracted = false

    var isActive: Bool { state == .downloading }

    var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard totalBytes > 0 else {
            return bytesWritten > 0 ? formatter.string(fromByteCount: bytesWritten) : ""
        }
        if isActive {
            return "\(formatter.string(fromByteCount: bytesWritten)) of \(formatter.string(fromByteCount: totalBytes))"
        }
        return formatter.string(fromByteCount: totalBytes)
    }

    /// Holds the download alive; WebKit doesn't retain it for us.
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var progressObservation: NSKeyValueObservation?
    /// The yt-dlp run, for extracted downloads. Mutually exclusive with
    /// `download` — a given item is fetched one way or the other.
    @ObservationIgnored var extraction: Extraction?

    /// Empty means "no name of our own" — take whatever the server suggests.
    init(filename: String) {
        self.filename = filename
    }
}

/// Saves media files to disk.
///
/// Two engines, chosen by what the source turns out to be:
///
/// - A plain media file goes through `WKWebView.startDownload(using:)` rather
///   than `URLSession`, because it inherits the web view's cookies, referrer and
///   session — media served only to an authenticated session still downloads.
///   A separate URLSession would be logged out and get a 403.
/// - Segmented media (`blob:` from Media Source Extensions, or an HLS/DASH
///   manifest) has no single URL to fetch, so `MediaExtractor` runs yt-dlp
///   against the *page*.
///
/// Everything downstream — the item's state machine, the progress ring, the
/// list, provenance tagging — is shared, and doesn't know which engine ran.
@Observable
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    /// Newest first. This is the history list; entries persist until cleared
    /// rather than disappearing when the transfer ends.
    private(set) var items: [DownloadItem] = []

    /// The download for a given tab, so the media player can show its progress
    /// inline. Released shortly after finishing so the row returns to normal —
    /// the entry itself stays in `items`.
    private(set) var itemsByTab: [Tab.ID: DownloadItem] = [:]

    private override init() { super.init() }

    func activeItem(for tab: Tab) -> DownloadItem? { itemsByTab[tab.id] }

    var activeCount: Int { items.filter(\.isActive).count }

    /// Aggregate progress across everything still running, for the toolbar ring.
    var activeProgress: Double {
        let running = items.filter(\.isActive)
        guard !running.isEmpty else { return 0 }
        return running.reduce(0) { $0 + $1.fraction } / Double(running.count)
    }

    // MARK: - List management

    func cancel(_ item: DownloadItem) {
        item.state = .failed("Cancelled")
        item.progressObservation = nil

        if let extraction = item.extraction {
            // Everything a yt-dlp run produced lives in its own scratch
            // directory, so there's nothing to pick through.
            extraction.cancel()
            extraction.cleanUp()
            item.extraction = nil
            return
        }

        item.download?.cancel { _ in
            MainActor.assumeIsolated {
                // WebKit leaves the partial file on disk. Half a download in
                // the Downloads folder looks like a real file and isn't one.
                if let url = item.destinationURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func remove(_ item: DownloadItem) {
        if item.isActive { cancel(item) }
        items.removeAll { $0 === item }
        itemsByTab = itemsByTab.filter { $0.value !== item }
    }

    func clearFinished() {
        let doomed = items.filter { !$0.isActive }
        for item in doomed { remove(item) }
    }

    func retry(_ item: DownloadItem, in tab: Tab?) {
        // An extracted download's input was the page, and re-running yt-dlp
        // against it needs none of the web view's help.
        if item.isExtracted, let pageURL = item.pageURL {
            remove(item)
            startExtraction(
                from: pageURL,
                title: (item.filename as NSString).deletingPathExtension,
                tab: tab
            )
            return
        }

        guard let url = item.sourceURL else { return }
        remove(item)
        let fresh = DownloadItem(filename: item.filename)
        fresh.sourceURL = url
        fresh.host = url.host
        items.insert(fresh, at: 0)
        let webView = tab?.webView ?? PopOutController.shared.poppedOutTab?.webView
        guard let webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated { self?.bind(fresh, to: download) }
        }
    }

    // MARK: - Receiving

    /// Adopts a download WebKit created for us.
    ///
    /// Link-initiated downloads arrive this way: WebKit turns a navigation into
    /// a `WKDownload` and hands it over. Without a delegate it has nowhere to
    /// put the file, so the navigation is simply cancelled — which is what
    /// "Frame load interrupted" means.
    func adopt(_ download: WKDownload, from tab: Tab?) {
        // No filename of our own: the server's Content-Disposition knows best
        // for a file the user asked for by name.
        let item = DownloadItem(filename: "")
        item.sourceURL = download.originalRequest?.url
        item.host = download.originalRequest?.url?.host
        item.pageURL = tab?.webView.url
        items.insert(item, at: 0)
        if let tab { itemsByTab[tab.id] = item }
        bind(item, to: download)
    }

    private func bind(_ item: DownloadItem, to download: WKDownload) {
        download.delegate = self
        item.download = download
        item.progressObservation = download.progress.observe(
            \.fractionCompleted, options: [.new]
        ) { progress, _ in
            MainActor.assumeIsolated {
                item.fraction = progress.fractionCompleted
                item.bytesWritten = progress.completedUnitCount
                item.totalBytes = progress.totalUnitCount
            }
        }
    }

    // MARK: - Starting

    /// The one entry point for "save what's playing". Picks the engine.
    func downloadMedia(from tab: Tab) {
        guard let media = tab.media else { return }

        switch media.kind {
        case .file:
            startDirectDownload(from: tab, media: media)
        case .manifest, .streamed:
            guard let pageURL = tab.webView.url else { return }
            startExtraction(from: pageURL, title: media.title, tab: tab)
        case .none, .unsupported:
            return
        }
    }

    private func startDirectDownload(from tab: Tab, media: MediaState) {
        guard let url = URL(string: media.sourceURL) else { return }

        let item = DownloadItem(filename: suggestedName(for: media, url: url))
        item.sourceURL = url
        item.host = tab.webView.url?.host ?? url.host
        item.pageURL = tab.webView.url
        items.insert(item, at: 0)
        itemsByTab[tab.id] = item

        var request = URLRequest(url: url)
        // Some CDNs reject media requests that arrive without the page referrer.
        if let pageURL = tab.webView.url {
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        tab.webView.startDownload(using: request) { [weak self] download in
            MainActor.assumeIsolated { self?.bind(item, to: download) }
        }
    }

    // MARK: - Extraction

    /// Hands a page to yt-dlp and wires its output into the same `DownloadItem`
    /// the direct path uses, so the UI needs no idea which engine is running.
    func startExtraction(from pageURL: URL, title: String, tab: Tab?) {
        guard MediaExtractor.shared.isAvailable else { return }

        // A placeholder name until yt-dlp reports the real one: a row reading
        // "Downloading…" for the thirty seconds it takes to resolve formats
        // looks stalled.
        let placeholder = sanitize(title.isEmpty ? (pageURL.host ?? "video") : title)
        let item = DownloadItem(filename: placeholder + ".mp4")
        item.host = pageURL.host
        item.pageURL = pageURL
        item.isExtracted = true
        items.insert(item, at: 0)
        if let tab { itemsByTab[tab.id] = item }

        Task { @MainActor in
            let extraction = await MediaExtractor.shared.start(
                pageURL: pageURL,
                // Held strongly on purpose: the manager is a singleton and the
                // item is in `items` until the user clears it, so there is no
                // cycle to break and nothing to outlive.
                onProgress: { progress in
                    guard item.isActive else { return }
                    item.bytesWritten = progress.bytesWritten
                    item.totalBytes = progress.totalBytes
                    // Never backwards. Two things push it that way: each
                    // progress line reaches the main actor as its own task with
                    // no ordering guarantee, and a fragmented stream's total is
                    // an estimate that revises itself downward as it goes. A
                    // ring that retreats reads as a stalled download.
                    item.fraction = max(item.fraction, progress.fraction)
                },
                onFinish: { result in
                    self.finishExtraction(item, result: result)
                }
            )

            guard let extraction else {
                item.state = .failed("Couldn't start yt-dlp")
                self.releaseTabBinding(for: item, after: .seconds(6))
                return
            }

            // A cancel that landed while we were exporting cookies would
            // otherwise be forgotten the moment the process handle arrives.
            guard item.isActive else {
                extraction.cancel()
                extraction.cleanUp()
                return
            }
            item.extraction = extraction
        }
    }

    /// Moves the finished file out of the run's scratch directory and into
    /// ~/Downloads, where the direct path would have put it.
    private func finishExtraction(_ item: DownloadItem, result: Result<URL, ExtractionFailure>) {
        defer {
            item.extraction?.cleanUp()
            item.extraction = nil
        }

        guard item.isActive else { return }

        switch result {
        case .failure(let failure):
            item.state = .failed(failure.message)
            releaseTabBinding(for: item, after: .seconds(6))

        case .success(let produced):
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            let destination = uniqueURL(in: downloads, named: produced.lastPathComponent)

            do {
                try FileManager.default.moveItem(at: produced, to: destination)
            } catch {
                // Across filesystems a move can fail where a copy won't — the
                // scratch directory is in /tmp, which need not be the same
                // volume as the home directory.
                guard (try? FileManager.default.copyItem(at: produced, to: destination)) != nil
                else {
                    item.state = .failed("Couldn't save to Downloads")
                    releaseTabBinding(for: item, after: .seconds(6))
                    return
                }
            }

            NSSound(named: "Surf")?.play()
            item.filename = destination.lastPathComponent
            item.destinationURL = destination
            item.fraction = 1
            item.state = .finished(destination)
            tagProvenance(of: destination, for: item)
            releaseTabBinding(for: item, after: .seconds(4))
        }
    }

    // MARK: - Naming

    /// Prefers the page's own title over the URL's filename, which is usually
    /// an opaque CDN hash. The extension still comes from the URL.
    private func suggestedName(for media: MediaState, url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let base = media.title.isEmpty ? url.deletingPathExtension().lastPathComponent : media.title
        return sanitize(base) + "." + ext
    }

    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave room for the extension and a dedupe suffix within HFS's limit.
        return String(cleaned.prefix(180)).isEmpty ? "video" : String(cleaned.prefix(180))
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let item = item(for: download)
        // A media download names itself from the page title; an adopted one has
        // no name of its own and defers to Content-Disposition entirely.
        var name = (item?.filename).flatMap { $0.isEmpty ? nil : $0 } ?? suggestedFilename
        let serverExt = (suggestedFilename as NSString).pathExtension
        if !serverExt.isEmpty, (name as NSString).pathExtension.lowercased() != serverExt.lowercased() {
            name = (name as NSString).deletingPathExtension + "." + serverExt
        }

        let destination = uniqueURL(in: downloads, named: name)
        item?.filename = destination.lastPathComponent
        item?.destinationURL = destination
        return destination
    }

    /// WebKit refuses to overwrite, so resolve collisions before handing it a path.
    private func uniqueURL(in directory: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        NSSound(named: "Surf")?.play()
        let saved = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent(item.filename)

        item.fraction = 1
        let location = item.destinationURL ?? saved ?? URL(fileURLWithPath: item.filename)
        item.state = .finished(location)
        item.progressObservation = nil
        tagProvenance(of: location, for: item)
        releaseTabBinding(for: item, after: .seconds(4))
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        guard let item = item(for: download) else { return }
        // A cancel arrives here too; don't overwrite the nicer message.
        if item.state == .downloading {
            item.state = .failed(error.localizedDescription)
        }
        item.progressObservation = nil
        releaseTabBinding(for: item, after: .seconds(6))
    }

    /// Frees the media player's inline slot once the outcome has been on screen
    /// long enough to read. The entry stays in `items` — that's the history.
    private func releaseTabBinding(for item: DownloadItem, after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            itemsByTab = itemsByTab.filter { $0.value !== item }
        }
    }

    // MARK: - Provenance

    /// Records where the file came from, on the file.
    ///
    /// This is the durable answer to "where did this come from" — it lives with
    /// the file forever, survives moving it, and shows up in Finder's Get Info.
    /// A browser-side list would only duplicate it, and worse.
    private func tagProvenance(of url: URL, for item: DownloadItem) {
        let sources = [item.sourceURL?.absoluteString, item.pageURL?.absoluteString]
            .compactMap { $0 }
        guard !sources.isEmpty else { return }

        // Finder reads this as a binary plist array: [file URL, page URL].
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: sources, format: .binary, options: 0
        ) {
            _ = data.withUnsafeBytes { buffer in
                setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms",
                         buffer.baseAddress, data.count, 0, 0)
            }
        }

        stampQuarantineAgent(on: url)
    }

    /// WebKit sets the quarantine flag but leaves the agent name blank, so
    /// Gatekeeper's warning can't say which app did the downloading.
    private func stampQuarantineAgent(on url: URL) {
        let key = "com.apple.quarantine"
        let length = getxattr(url.path, key, nil, 0, 0, 0)
        guard length > 0 else { return }

        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, key, &buffer, length, 0, 0) == length,
              let existing = String(bytes: buffer, encoding: .utf8)
        else { return }

        // Format is flags;timestamp;agent;uuid — fill in the agent only.
        var fields = existing.components(separatedBy: ";")
        while fields.count < 4 { fields.append("") }
        guard fields[2].isEmpty else { return }
        fields[2] = "Surf"

        let updated = Array(fields.joined(separator: ";").utf8)
        _ = setxattr(url.path, key, updated, updated.count, 0, 0)
    }

    func reveal(_ item: DownloadItem) {
        guard case let .finished(url) = item.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
