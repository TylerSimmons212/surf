import AppKit
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

    /// Empty means "no name of our own" — take whatever the server suggests.
    init(filename: String) {
        self.filename = filename
    }
}

/// Saves media files to disk using WebKit's own download machinery.
///
/// `startDownload(using:)` rather than `URLSession` on purpose: it inherits the
/// web view's cookies, referrer, and session, so media that's only served to an
/// authenticated session still downloads. A separate URLSession would be logged
/// out and get a 403.
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
        if item.isActive { item.download?.cancel() }
        items.removeAll { $0 === item }
        itemsByTab = itemsByTab.filter { $0.value !== item }
    }

    func clearFinished() {
        let doomed = items.filter { !$0.isActive }
        for item in doomed { remove(item) }
    }

    func retry(_ item: DownloadItem, in tab: Tab?) {
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

    func downloadMedia(from tab: Tab) {
        guard let media = tab.media, media.isDownloadable,
              let url = URL(string: media.sourceURL)
        else { return }

        let item = DownloadItem(filename: suggestedName(for: media, url: url))
        item.sourceURL = url
        item.host = tab.webView.url?.host ?? url.host
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
        NSSound(named: "Glass")?.play()
        let saved = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent(item.filename)

        item.fraction = 1
        item.state = .finished(saved ?? URL(fileURLWithPath: item.filename))
        item.progressObservation = nil
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

    func reveal(_ item: DownloadItem) {
        guard case let .finished(url) = item.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
