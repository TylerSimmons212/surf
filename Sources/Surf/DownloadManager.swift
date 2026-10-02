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
    /// When progress was last published to the observable properties.
    /// `NSProgress` fires per received chunk — easily 50–200 Hz on a fast
    /// connection — and every publish redraws the sidebar. See `bind`.
    @ObservationIgnored var lastProgressPublish: TimeInterval = 0
    /// The yt-dlp run, for extracted downloads. Mutually exclusive with
    /// `download` — a given item is fetched one way or the other.
    @ObservationIgnored var extraction: Extraction?

    /// What the page said this was, recorded before the download started, so
    /// the finished file can be checked against something the downloader had no
    /// hand in. Nil for an adopted link download, which has no media to expect
    /// anything of and must never be probed as though it did.
    @ObservationIgnored var expectation: SavedMedia.Expectation?

    /// The tab this came from, weakly, because a download outliving its tab is
    /// ordinary and must not keep a web view alive.
    ///
    /// `itemsByTab` already maps the other direction. This one exists because
    /// starting a download and discovering what it actually is happen in
    /// different places: by the time a response says "this is a playlist", the
    /// only thing in hand is the `WKDownload`, and the right cookie store is
    /// the one belonging to the tab that asked.
    @ObservationIgnored weak var tab: Tab?

    /// What is happening right now, when a byte count would not say it.
    ///
    /// A stream download spends real time reading manifests and combining tracks,
    /// and "0 bytes of 0 bytes" describes neither. A sibling property rather than
    /// a fourth `State`: the three flat states are read at nine places across
    /// three files and none of them cares which phase this is in, so growing the
    /// enum would make every switch learn about stages it then ignores.
    var detail: String?

    /// The native stream download. Mutually exclusive with `download` and
    /// `extraction` for the same reason those two are with each other.
    @ObservationIgnored var stream: StreamDownload?

    /// The manifests a stream download was started from, kept so a retry can go
    /// back through the same engine.
    ///
    /// Without this a failed stream item fell through to the WebKit branch of
    /// `retry` with the manifest URL as its source, and saved the playlist as a
    /// video — the exact bug the content-type reroute exists to prevent, arriving
    /// by a route that bypasses it.
    @ObservationIgnored var manifests: [URL] = []

    /// A failed attempt's scratch directory, when it left partial output behind.
    /// A retry continues in it instead of starting the transfer again.
    @ObservationIgnored var resumeDirectory: URL?

    /// Sound was asked for and not picture. Kept on the item because a
    /// download can change engines after the choice was made — the stream
    /// engine refusing hands the job to yt-dlp — and the question "was this a
    /// request for audio" has to survive that. Without it, asking for a song
    /// and having the engine refuse gets you the film.
    @ObservationIgnored var wantsAudioOnly = false

    /// The rendition the user asked for, kept so a retry asks for the same one.
    ///
    /// Without it a resumed download would pick the engine's own answer, which
    /// both ignores the choice and invalidates the partial output: the sidecar
    /// records which rendition the segments on disk belong to, so a different
    /// pick means starting the transfer over.
    @ObservationIgnored var chosenRenditionID: String?

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

    /// What the menu last asked for, read by whichever path starts next.
    ///
    /// A property rather than an argument threaded through five call sites, and
    /// cleared as soon as it is read: a choice belongs to one download, and a
    /// stale one silently deciding the next download's quality would be worse
    /// than having no menu.
    @ObservationIgnored private var choice: DownloadOption?

    func takeChoice() -> DownloadOption? {
        defer { choice = nil }
        return choice
    }

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

        if let stream = item.stream {
            // Same arrangement, and the directory goes even though a retry could
            // otherwise have resumed from it: someone who cancelled a download
            // did not ask us to keep most of it.
            stream.cancel()
            stream.cleanUp()
            item.stream = nil
            item.detail = nil
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
        // A partial transfer the user has dismissed is garbage, and /var/folders
        // is only swept by the system eventually. `retry` clears this first,
        // precisely so the directory it is about to resume from survives being
        // removed from the list.
        if let resuming = item.resumeDirectory {
            try? FileManager.default.removeItem(at: resuming)
            item.resumeDirectory = nil
        }
        items.removeAll { $0 === item }
        itemsByTab = itemsByTab.filter { $0.value !== item }
    }

    func clearFinished() {
        let doomed = items.filter { !$0.isActive }
        for item in doomed { remove(item) }
    }

    func retry(_ item: DownloadItem, in tab: Tab?) {
        // A stream download goes back through the stream engine, and continues in
        // the directory the last attempt left if it left one. Checked before the
        // extraction branch because a stream item that fell through to the WebKit
        // branch below would be handed its manifest URL as a plain file and save
        // the playlist.
        if !item.manifests.isEmpty {
            let manifests = item.manifests
            let pageURL = item.pageURL
            let expectation = item.expectation
            let resuming = item.resumeDirectory
            let chosen = item.chosenRenditionID.map { DownloadOption(id: $0) }
            let title = (item.filename as NSString).deletingPathExtension
            // Cleared before `remove`, which deletes it otherwise — the whole
            // point of this branch is to keep the directory the next attempt
            // continues in. Written the other way round first, and the comment in
            // `remove` claiming it had been handled is what caught it.
            item.resumeDirectory = nil
            remove(item)
            startStreamDownload(
                from: manifests, page: pageURL, title: title, tab: tab,
                expecting: expectation, resuming: resuming, choosing: chosen
            )
            return
        }

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
                // Throttled to ~10 Hz: KVO fires per received chunk, and each
                // publish re-renders every view watching the download. The
                // final chunk always lands so the row finishes at 100%.
                let now = ProcessInfo.processInfo.systemUptime
                let fraction = progress.fractionCompleted
                guard now - item.lastProgressPublish >= 0.1 || fraction >= 1 else {
                    return
                }
                item.lastProgressPublish = now
                item.fraction = fraction
                item.bytesWritten = progress.completedUnitCount
                item.totalBytes = progress.totalUnitCount
            }
        }
    }

    // MARK: - What is on offer

    /// Everything this page could be downloaded as, and how long it runs.
    ///
    /// Two sources, because the two kinds of stream know different things.
    /// YouTube's formats are on the page and need no network at all. A manifest
    /// has to be fetched and parsed, which is a round trip — hence the menu
    /// saying it is looking rather than appearing to have finished.
    ///
    /// An empty list is an ordinary answer: a plain file has one quality, and
    /// there is nothing to choose.
    func options(for tab: Tab) async -> (options: [DownloadOption], duration: Double?) {
        let duration = tab.media.map { $0.duration > 0 ? $0.duration : nil } ?? nil

        if let seen = await tab.streamTap() {
            if !seen.formats.isEmpty {
                // Only what the downloader can actually deliver. It mixes down to
                // MP4, so offering the VP9-in-WebM renditions would be a menu
                // promising something another part of the program refuses — and
                // at 2160p that row read 2.1GB beside an AV1 of the same picture
                // at 543MB, which is a worse offer as well as an undeliverable
                // one.
                return (seen.formats.filter(\.isMP4).map { format in
                    DownloadOption(
                        id: String(format.itag),
                        height: format.isVideo ? format.height : nil,
                        bitrate: format.bitrate,
                        codecs: format.mimeType,
                        isAudioOnly: format.isAudio,
                        exactBytes: format.bytes
                    )
                }, duration)
            }
            if let manifest = seen.manifests.compactMap({ URL(string: $0) }).first {
                return (await renditions(at: manifest, in: tab), duration)
            }
        }

        if let media = tab.media, media.kind == .manifest,
           let url = URL(string: media.sourceURL) {
            return (await renditions(at: url, in: tab), duration)
        }
        return ([], duration)
    }

    /// What a manifest offers, which costs one fetch.
    private func renditions(at url: URL, in tab: Tab) async -> [DownloadOption] {
        let credentials = await SegmentFetcher.credentials(for: tab, page: tab.webView.url)
        let fetcher = SegmentFetcher(credentials: credentials, parallelism: 1)
        guard let text = await fetcher.text(at: url),
              let index = StreamManifest.parse(text, baseURL: url)
        else { return [] }
        var options = index.renditions.compactMap { rendition -> DownloadOption? in
            switch rendition.role {
            case .video, .muxed:
                return DownloadOption(
                    id: rendition.id, height: rendition.height,
                    bitrate: rendition.bandwidth, codecs: rendition.codecs ?? ""
                )
            // Soundtracks are added below, as one row, and subtitles are not
            // saved by anything here yet.
            case .audio, .other:
                return nil
            }
        }

        // One soundtrack row, and it describes the track that would actually be
        // fetched, because it is the same answer `pick` gives the download.
        //
        // Not one row per audio rendition. Apple's own manifest carries ten,
        // five of them called "English" — the id of an HLS soundtrack is its
        // NAME — and `EXT-X-MEDIA` declares no bandwidth, so there is nothing to
        // tell them apart with and nothing to rank them by. The manifest does
        // say which one belongs to the picture being taken, which is the only
        // soundtrack worth offering.
        if case .success(let chosen) = StreamPlan.pick(from: index),
           let audio = chosen.audio {
            options.append(DownloadOption(
                id: audio.id, bitrate: audio.bandwidth,
                codecs: audio.codecs ?? "", isAudioOnly: true
            ))
        }
        return options
    }

    // MARK: - Starting

    /// The one entry point for "save what's playing". Picks the engine.
    /// `choosing` is a row from the menu. Nil means the engine decides, which is
    /// what the button does on its own and what every path did before the menu
    /// existed.
    func downloadMedia(from tab: Tab, choosing: DownloadOption? = nil) {
        guard let media = tab.media else { return }
        self.choice = choosing

        switch media.kind {
        case .file:
            startDirectDownload(from: tab, media: media)
        case .manifest:
            // A manifest is the case the native engine exists for: the page
            // already fetched this URL to play the video, so it is a description
            // of the stream rather than a site to be reverse engineered.
            guard let manifestURL = URL(string: media.sourceURL) else { return }
            startStreamDownload(
                from: [manifestURL], page: tab.webView.url,
                title: media.title, tab: tab,
                expecting: SavedMedia.Expectation(
                    wantsVideo: media.hasVideo,
                    declaredDuration: media.duration > 0 ? media.duration : nil
                ),
                choosing: takeChoice()
            )

        case .streamed:
            // A `blob:` source is Media Source Extensions: the page assembled the
            // stream in its own buffer, so the element has no URL to give. What
            // the page *fetched* to fill that buffer is a different question, and
            // the tap has been recording the answer since document start.
            guard let pageURL = tab.webView.url else { return }
            let expectation = SavedMedia.Expectation(
                wantsVideo: media.hasVideo,
                declaredDuration: media.duration > 0 ? media.duration : nil
            )
            Task { @MainActor in
                let seen = await tab.streamTap()

                // Refused before anything is fetched, and refused here rather
                // than handed on: the subprocess will also fail, slower and with
                // a worse message, and the page has already told us why.
                if seen?.isProtected == true {
                    debugLog("download: a key system was requested; refusing")
                    let item = DownloadItem(filename: self.sanitize(media.title) + ".mp4")
                    item.host = pageURL.host
                    item.pageURL = pageURL
                    item.tab = tab
                    item.state = .failed(StreamRefusal.protected.message)
                    self.items.insert(item, at: 0)
                    self.itemsByTab[tab.id] = item
                    self.releaseTabBinding(for: item, after: .seconds(6))
                    return
                }

                // Read once, here, because all three engines below need it
                // and `takeChoice` clears on read.
                let chosen = self.takeChoice()

                // YouTube first, because on YouTube there is nothing else: no
                // manifest is fetched and no format carries a URL, so a captured
                // streaming request is the only route to its media.
                if let captured = seen?.abr {
                    debugLog("download: using a captured streaming request, "
                        + "\(seen?.formats.count ?? 0) formats on offer"
                        + (chosen.map { ", asked for \($0.title)" } ?? ""))
                    self.startSABRDownload(
                        captured: captured, formats: seen?.formats ?? [],
                        choosing: chosen,
                        page: pageURL, title: media.title, tab: tab,
                        expecting: expectation
                    )
                    return
                }

                let candidates = (seen?.manifests ?? []).compactMap { URL(string: $0) }
                if !candidates.isEmpty {
                    debugLog("download: tap found \(candidates.count) manifest(s)"
                        + (seen?.codecs.isEmpty == false
                            ? ", codecs \(seen?.codecs.joined(separator: " ") ?? "")" : ""))
                    self.startStreamDownload(
                        from: candidates, page: pageURL,
                        title: media.title, tab: tab, expecting: expectation,
                        choosing: chosen
                    )
                    return
                }

                // The page assembled this from something we never saw it fetch —
                // a custom protocol, a worker, or a request made before the tap
                // was armed. yt-dlp knows sites; we only know what we watched.
                debugLog("download: nothing in the tap; handing over")
                self.startExtraction(
                    from: pageURL, title: media.title, tab: tab,
                    expecting: expectation,
                    audioOnly: chosen?.isAudioOnly ?? false
                )
            }

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
        item.tab = tab
        item.expectation = SavedMedia.Expectation(
            wantsVideo: media.hasVideo,
            declaredDuration: media.duration > 0 ? media.duration : nil
        )
        items.insert(item, at: 0)
        itemsByTab[tab.id] = item

        // A large file that the server will serve in pieces is fetched in pieces,
        // because one connection is the slowest way to move one. Everything else
        // stays with WebKit, which is where this has always been and which
        // inherits the session rather than replaying it.
        Task { @MainActor in
            if await self.splitIfWorthwhile(item, url: url, tab: tab) { return }
            self.handToWebKit(item, url: url, tab: tab)
        }
    }

    /// Fetches a plain file in parallel, or answers false and leaves it alone.
    ///
    /// Every doubt resolves to false. The probe inside `startProgressive` runs
    /// through the same session and URL the parallel fetch would use, so it
    /// answering at all is the evidence that taking the download away from WebKit
    /// is safe — a file behind a session we cannot replay fails the probe and
    /// never leaves the path it works on.
    private func splitIfWorthwhile(
        _ item: DownloadItem, url: URL, tab: Tab
    ) async -> Bool {
        let download = StreamDownload(
            onDetail: { [weak item] detail in
                guard let item, item.isActive else { return }
                item.detail = detail
            },
            onProgress: { [weak item] fraction, bytes in
                guard let item, item.isActive else { return }
                item.fraction = max(item.fraction, min(fraction, 0.95))
                item.bytesWritten = Int64(bytes)
            }
        )
        item.stream = download

        let result = await download.startProgressive(
            url: url, pageURL: tab.webView.url,
            title: (item.filename as NSString).deletingPathExtension, tab: tab
        )
        item.stream = nil
        item.detail = nil

        guard item.isActive else {
            download.cleanUp()
            return true
        }

        switch result {
        case .success(let produced):
            await accept(item, produced: produced.url, expecting: produced.expectation)
            download.cleanUp()
            return true
        case .failure:
            // Not reported anywhere. This is not an error, it is the ordinary
            // answer for a small file or a server that will not serve ranges, and
            // the download is about to happen the way it always did.
            download.cleanUp()
            item.fraction = 0
            item.bytesWritten = 0
            return false
        }
    }

    private func handToWebKit(_ item: DownloadItem, url: URL, tab: Tab) {
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

    /// Downloads a stream ourselves, falling back to the subprocess if we can't.
    ///
    /// The invariant that keeps this safe to add: the native engine either
    /// refuses before its first segment byte, or it owns the download through to
    /// a finished file. There is no handing over halfway, because a transfer that
    /// was half one engine and half the other would have two progress models and
    /// no honest way to describe itself in a row ten points tall.
    func startStreamDownload(
        from manifests: [URL],
        page pageURL: URL?,
        title: String,
        tab: Tab?,
        expecting expectation: SavedMedia.Expectation?,
        resuming: URL? = nil,
        choosing: DownloadOption? = nil
    ) {
        guard let first = manifests.first else { return }
        let placeholder = sanitize(title.isEmpty ? (first.host ?? "video") : title)
        let item = DownloadItem(filename: placeholder + ".mp4")
        item.sourceURL = first
        item.host = pageURL?.host ?? first.host
        item.pageURL = pageURL
        item.tab = tab
        item.expectation = expectation
        item.manifests = manifests
        item.resumeDirectory = resuming
        item.chosenRenditionID = choosing.flatMap { $0.isAudioOnly ? nil : $0.id }
        item.wantsAudioOnly = choosing?.isAudioOnly ?? false
        items.insert(item, at: 0)
        if let tab { itemsByTab[tab.id] = item }

        let download = StreamDownload(
            resuming: resuming,
            onDetail: { [weak item] detail in
                guard let item, item.isActive else { return }
                item.detail = detail
            },
            onProgress: { [weak item] fraction, bytes in
                guard let item, item.isActive else { return }
                // Already monotone: the schedule weights by durations the manifest
                // stated, so it cannot revise downward the way a byte estimate
                // does. Clamped anyway, because two tracks report independently.
                item.fraction = max(item.fraction, min(fraction, 0.95))
                item.bytesWritten = Int64(bytes)
                item.detail = nil
            }
        )
        item.stream = download

        Task { @MainActor in
            let result = await download.start(
                manifests: manifests, pageURL: pageURL, title: title, tab: tab,
                choosing: choosing
            )
            item.stream = nil
            item.detail = nil

            guard item.isActive else {
                download.cleanUp()
                return
            }

            switch result {
            case .success(let produced):
                // After, not before. `accept` moves the file out of the working
                // directory, and cleaning up first deletes the thing being moved
                // — which then fails its move, fails its fallback copy, and sets
                // a state nothing logs. The download simply stopped, with the
                // plan in the log and no file and no error anywhere.
                await self.accept(item, produced: produced.url, expecting: produced.expectation)
                download.cleanUp()
                item.resumeDirectory = nil

            case .failure(let refusal):
                // Kept only when there is partial output to come back to.
                // Keeping every failure's directory would leave most of a
                // download on disk for every plan that was never going to work;
                // keeping none makes resuming unreachable.
                if download.hasPartialOutput, refusal == .interrupted {
                    item.resumeDirectory = download.workingDirectory
                    debugLog("stream: keeping \(download.workingDirectory.lastPathComponent)"
                        + " for a retry")
                } else {
                    download.cleanUp()
                    item.resumeDirectory = nil
                }
                debugLog("stream: refused — \(refusal) fallback=\(refusal.allowsFallback)")
                guard refusal.allowsFallback, let pageURL else {
                    item.state = .failed(refusal.message)
                    self.releaseTabBinding(for: item, after: .seconds(6))
                    return
                }
                // Quietly. A download that succeeds by another route is not an
                // error, and the row is removed so the retry button knows which
                // engine it is retrying.
                let audioOnly = item.wantsAudioOnly
                self.remove(item)
                self.startExtraction(
                    from: pageURL, title: title, tab: tab, expecting: expectation,
                    audioOnly: audioOnly
                )
            }
        }
    }

    /// Downloads a YouTube stream, falling back to the subprocess if we can't.
    ///
    /// Its own entry point rather than a branch inside `startStreamDownload`,
    /// because the two share nothing but their ending. That one reads a manifest
    /// and schedules the segments it names; this asks an endpoint repeatedly and
    /// is told how much it may have. A single function doing both would be a
    /// switch wearing a loop.
    func startSABRDownload(
        captured: StreamTap.ABRRequest,
        formats: [StreamTap.Format],
        choosing: DownloadOption? = nil,
        page pageURL: URL?,
        title: String,
        tab: Tab?,
        expecting expectation: SavedMedia.Expectation?
    ) {
        let placeholder = sanitize(title.isEmpty ? (pageURL?.host ?? "video") : title)
        let item = DownloadItem(filename: placeholder + ".mp4")
        item.host = pageURL?.host
        item.pageURL = pageURL
        item.tab = tab
        item.expectation = expectation
        items.insert(item, at: 0)
        if let tab { itemsByTab[tab.id] = item }

        let download = StreamDownload(
            onDetail: { [weak item] detail in
                guard let item, item.isActive else { return }
                item.detail = detail
            },
            onProgress: { [weak item] _, bytes in
                guard let item, item.isActive else { return }
                // No fraction: the protocol does not say how much is left, so a
                // bar would be inventing one. The byte count is the honest
                // number and the row already knows how to show it.
                item.bytesWritten = Int64(bytes)
            }
        )
        item.stream = download

        Task { @MainActor in
            let result = await download.startSABR(
                captured: captured, formats: formats, choosing: choosing,
                pageURL: pageURL, title: title, tab: tab
            )
            item.stream = nil
            item.detail = nil
            guard item.isActive else {
                download.cleanUp()
                return
            }

            switch result {
            case .success(let produced):
                await self.accept(item, produced: produced.url, expecting: produced.expectation)
                download.cleanUp()

            case .failure(let refusal):
                download.cleanUp()
                debugLog("sabr: refused — \(refusal) fallback=\(refusal.allowsFallback)")
                guard refusal.allowsFallback, let pageURL else {
                    item.state = .failed(refusal.message)
                    self.releaseTabBinding(for: item, after: .seconds(6))
                    return
                }
                let audioOnly = item.wantsAudioOnly
                self.remove(item)
                self.startExtraction(
                    from: pageURL, title: title, tab: tab, expecting: expectation,
                    audioOnly: audioOnly
                )
            }
        }
    }

    /// Hands a page to yt-dlp and wires its output into the same `DownloadItem`
    /// the direct path uses, so the UI needs no idea which engine is running.
    func startExtraction(
        from pageURL: URL, title: String, tab: Tab?,
        expecting expectation: SavedMedia.Expectation? = nil,
        audioOnly: Bool = false
    ) {
        guard MediaExtractor.shared.isAvailable else { return }

        // A placeholder name until yt-dlp reports the real one: a row reading
        // "Downloading…" for the thirty seconds it takes to resolve formats
        // looks stalled.
        let placeholder = sanitize(title.isEmpty ? (pageURL.host ?? "video") : title)
        let item = DownloadItem(filename: placeholder + (audioOnly ? ".m4a" : ".mp4"))
        item.host = pageURL.host
        item.pageURL = pageURL
        item.isExtracted = true
        // Restated rather than passed through, and this one matters. The
        // expectation handed down was built for a video — `wantsVideo: true` —
        // so a soundtrack arriving correctly would fail the track check and be
        // discarded as flawed. The guard would have thrown away exactly what was
        // asked for, which is the guard inventing a bug.
        item.expectation = audioOnly
            ? SavedMedia.Expectation(
                wantsVideo: false, wantsAudio: true,
                declaredDuration: expectation?.declaredDuration
            )
            : expectation
        item.wantsAudioOnly = audioOnly
        item.tab = tab
        items.insert(item, at: 0)
        if let tab { itemsByTab[tab.id] = item }

        Task { @MainActor in
            let extraction = await MediaExtractor.shared.start(
                pageURL: pageURL,
                // `tab.dataStore`, never `tab.webView` — the second would build
                // a web view just to read cookies, waking a sleeping tab.
                cookies: (tab?.dataStore ?? IslandStores.shared.store(forIdentifier: nil))
                    .httpCookieStore,
                audioOnly: audioOnly,
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
        switch result {
        case .failure(let failure):
            releaseExtraction(for: item)
            guard item.isActive else { return }
            item.state = .failed(failure.message)
            releaseTabBinding(for: item, after: .seconds(6))

        case .success(let produced):
            // Deliberately not a `defer`: checking the file is async, and the
            // scratch directory has to outlive the check. Cleaning up on the way
            // out of this function would delete the thing being inspected.
            Task { @MainActor in
                await self.accept(item, produced: produced)
                self.releaseExtraction(for: item)
            }
        }
    }

    /// Replaces a direct download that turned out to be a manifest with an
    /// extraction of the page it came from.
    ///
    /// The old row is removed rather than reused. Reusing it would mean a row
    /// that is half one engine and half the other, with a byte count from the
    /// playlist it was never going to save, and `isExtracted` is the flag the
    /// retry button reads to know what to retry — it has to be true from the
    /// start or a retry goes back to the direct path and fails the same way.
    private func reroute(_ item: DownloadItem) {
        guard let pageURL = item.pageURL else {
            item.state = .failed("That link is a playlist, not a video")
            releaseTabBinding(for: item, after: .seconds(6))
            return
        }
        let tab = item.tab
        let expectation = item.expectation
        let audioOnly = item.wantsAudioOnly
        let title = (item.filename as NSString).deletingPathExtension
        remove(item)
        startExtraction(
            from: pageURL, title: title, tab: tab, expecting: expectation,
            audioOnly: audioOnly
        )
    }

    private func releaseExtraction(for item: DownloadItem) {
        item.extraction?.cleanUp()
        item.extraction = nil
    }

    /// Checks the file against what the page said it was, then moves it.
    ///
    /// The order is the whole point. The file is still in a directory this code
    /// owns and is about to delete, so a file that failed the check is discarded
    /// rather than reported — there is nothing left in ~/Downloads for someone to
    /// double-click, be confused by, and have to delete by hand.
    private func accept(
        _ item: DownloadItem, produced: URL,
        expecting override: SavedMedia.Expectation? = nil
    ) async {
        // `override` nil falls through to the item's own, which is what a plain
        // file wants: nothing promised it tracks, but the page said whether it was
        // playing a video.
        guard item.isActive else { return }

        // The manifest's expectation beats the page's where there is one: only
        // the manifest knew there was a separate audio track to be missing.
        if let expectation = override ?? item.expectation,
           let inventory = await MediaInspector.inventory(of: produced),
           let flaw = SavedMedia.flaw(in: inventory, expecting: expectation) {
            // A cancel may have landed while AVFoundation was reading.
            guard item.isActive else { return }
            debugLog("extract: refused \(produced.lastPathComponent) — \(flaw)")
            item.state = .failed(flaw.message)
            releaseTabBinding(for: item, after: .seconds(6))
            return
        }

        guard item.isActive else { return }

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
                // Logged, because the silence here is what made an ordering bug
                // in the stream path take a sampled process to find: the plan was
                // in the log, no file appeared, and nothing said why.
                debugLog("download: couldn't move \(produced.path) to \(destination.path)")
                item.state = .failed("Couldn't save to Downloads")
                releaseTabBinding(for: item, after: .seconds(6))
                return
            }
        }

        debugLog("download: saved \(destination.lastPathComponent)")
        NSSound(named: "Surf")?.play()
        item.filename = destination.lastPathComponent
        item.destinationURL = destination
        item.fraction = 1
        item.state = .finished(destination)
        tagProvenance(of: destination, for: item)
        releaseTabBinding(for: item, after: .seconds(4))
        // Cosmetic and strictly after the file is whole and tagged.
        AIDownloadRenamer.renameIfEnabled(item)
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

        // The last chance to notice this is not a video.
        //
        // `MediaSource.kind(of:)` had only the URL to go on, and a signed
        // manifest URL carries no extension — so a playlist classified as a
        // plain file, and WebKit is now waiting to be told where to save a few
        // kilobytes of text under an `.mp4` name. The response says what the URL
        // couldn't, and returning nil cancels the download.
        //
        // Only for a media download: an adopted link download has no expectation
        // and no page to extract from, and a `.m3u8` someone deliberately
        // clicked is a file they asked for.
        if let item, item.expectation != nil, !item.isExtracted,
           MediaSource.isManifest(contentType: response.mimeType ?? "") {
            debugLog("download: \(response.mimeType ?? "?") is a manifest, extracting instead")
            reroute(item)
            return nil
        }

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
        // Cosmetic and strictly after the file is whole and tagged.
        AIDownloadRenamer.renameIfEnabled(item)
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
