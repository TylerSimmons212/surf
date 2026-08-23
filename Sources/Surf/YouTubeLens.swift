import Foundation
import SurfCore

/// The YouTube lens's state, and the navigation that drives it.
///
/// A site lens is the one kind of Focus that *expects* to navigate. Searching
/// is a page load and so is playing, because the data both need — the
/// results, the chapters, the caption list — is published on load and does
/// not refresh in place. So this owns the tab's address for as long as it is
/// up, and the tab's own reset knows to leave it alone (`focusSite`).
///
/// Three screens and nothing else: a field, a grid, a stage. The results are
/// held here rather than in `phase` so that leaving a video costs nothing —
/// the grid is still in memory, and going back to it is a state change rather
/// than another search.
@MainActor
@Observable
final class YouTubeLens {

    enum Phase: Equatable {
        /// The blank: one search field, centred, and nothing else. This is
        /// the front page too — a focused YouTube has no feed by design.
        case searching
        /// A search or a video is on its way.
        case loading
        case results
        case watching
        case failed(String)
    }

    private(set) var phase: Phase = .searching

    /// What is in the field. Bound by the view, and re-filled from the
    /// address when a results page loads, so the field says what the grid is
    /// showing rather than whatever was last typed.
    var query = ""

    private(set) var results: [YouTubeResult] = []
    private(set) var video: YouTubeVideo?
    private(set) var chapters: [YouTubeChapter] = []
    private(set) var captionTracks: [YouTubeCaptionTrack] = []
    private(set) var rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// The chosen subtitle language, or empty for off.
    private(set) var captionLanguage = ""
    private(set) var rate: Double = 1

    private weak var tab: Tab?
    private var readTask: Task<Void, Never>?
    private var stageWatchdog: Task<Void, Never>?

    init(tab: Tab) {
        self.tab = tab
    }

    /// The chapter playing now, for the name in the transport.
    var currentChapter: YouTubeChapter? {
        guard !chapters.isEmpty else { return nil }
        return YouTubeChapter.current(
            at: tab?.media?.currentTime ?? 0, in: chapters
        )
    }

    // MARK: - What the view asks for

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = YouTubePage.searchURL(for: trimmed), let tab else { return }
        query = trimmed
        leaveTheStage()
        phase = .loading
        tab.loadInSiteLens(url)
    }

    func play(_ result: YouTubeResult) {
        guard let url = result.watchURL, let tab else { return }
        leaveTheStage()
        // Cleared rather than kept: the chapters and captions on screen
        // belong to the video being left, and a stale chapter list under a
        // new video is worse than none.
        video = nil
        chapters = []
        captionTracks = []
        captionLanguage = ""
        rate = 1
        phase = .loading
        tab.loadInSiteLens(url)
    }

    /// Back to the grid — free, because the results never left memory. The
    /// page stays on the video's address; playing something else navigates
    /// again from there.
    func showResults() {
        leaveTheStage()
        phase = results.isEmpty ? .searching : .results
    }

    /// Back to the empty field, the way the lens opens.
    func startOver() {
        leaveTheStage()
        results = []
        query = ""
        phase = .searching
    }

    func setRate(_ value: Double) {
        rate = value
        tab?.youtubeSetRate(value)
    }

    /// An empty language turns subtitles off.
    func setCaptionLanguage(_ language: String) {
        captionLanguage = language
        tab?.youtubeSetCaptions(language)
    }

    func seek(to chapter: YouTubeChapter) {
        tab?.seekMedia(to: Double(chapter.start))
    }

    // MARK: - What the tab tells it

    /// A new document is on its way. Whatever was being read is stale.
    func documentWillChange() {
        readTask?.cancel()
        stageWatchdog?.cancel()
        stageWatchdog = nil
    }

    /// A document finished loading. What the lens shows next is decided by
    /// the address — the payloads only say what is *in* the page, never what
    /// kind of page it is.
    func documentDidLoad() {
        readTask?.cancel()
        readTask = Task { @MainActor in
            guard let tab else { return }
            switch YouTubePage.of(tab.currentSiteLensURL) {
            case .search(let text):
                query = text
                await readResults()
            case .watch:
                await readWatch()
            case .home, .other:
                // A channel, a playlist, the front page: no lens of its own,
                // so the field is what it gets. The grid survives if there
                // is one, because the user has not asked to lose it.
                if phase != .watching {
                    phase = results.isEmpty ? .searching : .results
                }
            }
        }
    }

    /// The lens is closing. The page must be handed back exactly as it was.
    func tearDown() {
        readTask?.cancel()
        readTask = nil
        leaveTheStage()
    }

    // MARK: - Reading the page

    private func read() async -> YouTubePageReply? {
        await tab?.youtubeRead()
    }

    /// Results, with a couple of retries.
    ///
    /// `ytInitialData` is inline in the document and is usually there the
    /// moment the load finishes — but "usually" across a redirect and a
    /// consent interstitial is not the same as always, and an empty grid is
    /// the one failure the user cannot tell from a broken feature.
    private func readResults() async {
        for delay in [0, 400, 1200] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            guard let reply = await read() else { continue }
            let found = reply.results
            guard !found.isEmpty else { continue }
            results = found
            phase = .results
            debugLog("youtube: \(found.count) results for \"\(query)\"")
            return
        }
        guard !Task.isCancelled else { return }
        phase = .failed("Nothing came back for \u{201C}\(query)\u{201D}.")
    }

    /// The watch page, which needs the player and not merely the document.
    ///
    /// `#movie_player` boots well after the load finishes, and staging before
    /// it exists pins a div that the player then fills from underneath. So
    /// the read waits for it, and gives up rather than showing a black
    /// rectangle with a transport on it.
    private func readWatch() async {
        for delay in [0, 250, 500, 1000, 1500, 2500] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, let tab else { return }
            guard let reply = await read() else { continue }

            // Taken as they arrive: the details land with the document and
            // the player follows, so the title can be on screen while the
            // stage is still being raised.
            if let found = reply.video { video = found }
            if !reply.chapters.isEmpty { chapters = reply.parsedChapters }
            if !reply.captionTracks.isEmpty {
                captionTracks = reply.parsedCaptionTracks
            }
            rates = reply.playbackRates

            guard reply.hasPlayer else { continue }
            guard await tab.youtubeStage() else { continue }
            tab.setPageScrollLocked(true, keepingInteraction: true)
            phase = .watching
            startStageWatchdog()
            debugLog("""
                youtube: staged \"\(video?.title ?? "?")\" — \
                \(chapters.count) chapters, \(captionTracks.count) caption tracks
                """)
            return
        }
        guard !Task.isCancelled else { return }
        phase = .failed("This video wouldn't start.")
    }

    /// Re-tags the player's current ancestor chain on a beat.
    ///
    /// Not paranoia: YouTube re-parents its player on layout changes, which
    /// walks it out from under the chain the stage tagged — the generic
    /// theater carries a watchdog for the same reason, and names YouTube in
    /// the comment. Staging is idempotent, so re-running it is the fix.
    private func startStageWatchdog() {
        stageWatchdog?.cancel()
        stageWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, phase == .watching else { return }
                guard let tab else { return }
                _ = await tab.youtubeStage()
            }
        }
    }

    /// Lowers the stage and stops the show. Safe to call when there is no
    /// stage up — the page's own attributes and sheet are swept regardless.
    private func leaveTheStage() {
        stageWatchdog?.cancel()
        stageWatchdog = nil
        guard let tab else { return }
        // Paused first: the overlay that replaces the stage is opaque, and a
        // video playing behind it is a voice in an empty room.
        if tab.media?.isPlaying == true { tab.toggleMediaPlayback() }
        tab.youtubeUnstage()
        tab.setPageScrollLocked(false)
    }
}
