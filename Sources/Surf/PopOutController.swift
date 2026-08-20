import AppKit
import SurfCore
import Observation
import SwiftUI

/// Floats a playing tab's video in a small always-on-top panel.
///
/// The video is *staged* — the same attribute-and-stylesheet promotion the
/// theater lens uses: the page's own element pinned to fill its viewport,
/// every ancestor's containing-block and stacking-context traps dissolved,
/// everything off the path to the video hidden. The panel then simply shows
/// the web view, and the web view's whole viewport *is* the video.
///
/// This replaced a geometry lens — a clipped container whose bounds tracked
/// the measured video rect on a 700ms beat. An earlier comment here argued
/// CSS promotion was an unwinnable war against players that nest the video
/// under transforms and stacking contexts; the theater lens won that war
/// (attributes survive style rewrites, ancestors are neutralised, lights-out
/// ends the z-order fight — proven against YouTube's player), and staging
/// carries what the lens could not: no frozen page size, no rect to chase
/// when the site relayouts, and no site overlay bleeding into the frame.
///
/// It is still the original document in the original web view, so DRM
/// playback and `blob:` media keep working — nothing is scraped or re-loaded.
@Observable
@MainActor
final class PopOutController: NSObject, NSWindowDelegate {
    static let shared = PopOutController()

    /// The main window renders a placeholder for this tab while it's popped out.
    private(set) var poppedOutTab: Tab?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var chromeView: NSHostingView<PopOutChrome>?
    @ObservationIgnored private let chromeModel = PopOutChromeModel()
    /// The size the panel was presented at. Used to tell an untouched panel
    /// from one the user has sized themselves.
    @ObservationIgnored private var presentedSize: CGSize?
    @ObservationIgnored private var trackingTask: Task<Void, Never>?

    private override init() { super.init() }

    func isPoppedOut(_ tab: Tab) -> Bool { poppedOutTab?.id == tab.id }

    func toggle(_ tab: Tab) {
        isPoppedOut(tab) ? restore() : popOut(tab)
    }

    // MARK: - Pop out

    func popOut(_ tab: Tab) {
        if poppedOutTab != nil { restore() }

        // The element's shape, read before staging inflates it to viewport
        // size — after that, its measured rect is the panel's own aspect and
        // says nothing about the video.
        guard let media = tab.media, media.hasVideo else { return }
        let signals = media.signals
        let videoSize = signals.width > 1 && signals.height > 1
            ? CGSize(width: signals.width, height: signals.height)
            : CGSize(width: 16, height: 9)

        guard tab.stageVideoForPopOut() else { return }

        Task { @MainActor in
            // Publishing first makes the main window swap in its placeholder,
            // which releases the web view from SwiftUI's hierarchy before we
            // adopt it into the panel.
            poppedOutTab = tab
            try? await Task.sleep(for: .milliseconds(60))
            presentPanel(for: tab, videoSize: videoSize)
            startTracking(tab)
        }
    }

    private func presentPanel(for tab: Tab, videoSize: CGSize) {
        let contentSize = PopOutSizing.panelSize(forVideo: videoSize)
        presentedSize = contentSize

        // Borderless: a titled panel reads as a mini window, and the whole point
        // is that this should read as a piece of floating video.
        let panel = PopOutPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Stays above ordinary windows and follows you between Spaces, which is
        // the entire point of a pop-out.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = videoSize
        panel.contentMinSize = PopOutSizing.minimumSize(forVideo: videoSize)
        panel.delegate = self
        // Transparent so the rounded corners aren't filled in by the window's
        // own background, and shadowed so it lifts off whatever is behind it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let root = PopOutRootView(frame: NSRect(origin: .zero, size: contentSize))
        root.autoresizingMask = [.width, .height]

        // The staged video fills whatever viewport it is given, so the web
        // view just fills the panel and resizes with it. The page reflowing
        // underneath is invisible — lights-out hides it — and harmless.
        tab.webView.autoresizingMask = [.width, .height]
        tab.webView.frame = root.bounds
        root.addSubview(tab.webView)

        chromeModel.title = tab.displayTitle
        chromeModel.isPlaying = tab.stagedMedia?.isPlaying ?? false
        chromeModel.onClose = { [weak self] in self?.closeFromChrome() }
        chromeModel.onRestore = { [weak self] in self?.restore() }
        // The staged element, not the ranking's pick: an advert starting
        // mid-float must not capture the pop-out's buttons.
        chromeModel.onTogglePlay = { [weak tab] in tab?.stagedToggle() }
        chromeModel.onSeek = { [weak tab] time in tab?.stagedSeek(to: time) }
        chromeModel.onSkip = { [weak tab] delta in tab?.stagedSkip(by: delta) }
        chromeModel.currentTime = tab.stagedMedia?.currentTime ?? 0
        chromeModel.duration = tab.stagedMedia?.duration ?? 0

        let chrome = NSHostingView(rootView: PopOutChrome(model: chromeModel))
        chrome.frame = root.bounds
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)
        chromeView = chrome

        root.onHoverChange = { [weak self] hovering in
            MainActor.assumeIsolated { self?.chromeModel.isHovering = hovering }
        }

        panel.contentView = root

        positionInBottomTrailingCorner(panel, size: contentSize)
        panel.orderFront(nil)
        self.panel = panel
    }

    /// The chrome's close button dismisses the pop-out entirely, folding the
    /// tab back into the main window rather than leaving it orphaned.
    private func closeFromChrome() {
        restore()
    }

    /// No geometry left to track — the stage holds its own. What remains is
    /// the watch for a video the page tore out, and keeping the chrome's
    /// numbers honest when playback changes from anywhere else.
    private func startTracking(_ tab: Tab) {
        trackingTask?.cancel()
        trackingTask = Task { @MainActor in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, poppedOutTab?.id == tab.id else { return }
                guard let media = tab.stagedMedia else {
                    // A beat of grace: reports arrive on a heartbeat, and one
                    // silent read mustn't fold a healthy pop-out.
                    misses += 1
                    if misses >= 3 { restore() ; return }
                    continue
                }
                misses = 0
                chromeModel.isPlaying = media.isPlaying
                chromeModel.currentTime = media.currentTime
                chromeModel.duration = media.duration
                // Same re-assertion the theater's watchdog makes: a player
                // that re-parents its video walks it out from under the
                // tagged chain, and the panel goes white with the audio
                // still running. Staging is idempotent; re-run it.
                await tab.reassertStagedVideo()
            }
        }
    }

    private func positionInBottomTrailingCorner(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let frame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        )
    }

    // MARK: - Restore

    func restore() {
        guard let tab = poppedOutTab else { return }

        trackingTask?.cancel()
        trackingTask = nil

        // Detach before the panel goes away, or closing it would take the web
        // view down with it and the tab would come back blank.
        tab.webView.removeFromSuperview()
        tab.webView.autoresizingMask = [.width, .height]
        tab.unstageVideoAfterPopOut()

        chromeView = nil
        presentedSize = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil

        // Published last: this is what tells the main window to remount it.
        poppedOutTab = nil
    }

    // MARK: - NSWindowDelegate

    /// The panel's own close button routes here.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { restore() }
    }
}
