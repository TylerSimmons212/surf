import AppKit
import GlassCore
import Observation
import SwiftUI

/// Floats a playing tab's video in a small always-on-top panel — by cropping,
/// not by restyling.
///
/// The live `WKWebView` keeps its full main-window size inside a clipping
/// container whose `bounds` are set to the video's rectangle. AppKit's
/// frame/bounds decoupling then does everything at once: translation, scaling,
/// clipping, *and* correct hit-testing, so the site's own player controls keep
/// working inside the lens.
///
/// Why not inject CSS to blow the video up to fill the page? Because that's a
/// war: any ancestor with a transform, filter, containment, or z-index forms a
/// containing block or stacking context that re-scopes `position: fixed`, and
/// real players (YouTube) nest the video many such layers deep. The lens never
/// touches the page's layout, so there is nothing to fight.
///
/// The same reasoning covers streaming sites: this is the original document in
/// the original web view, so DRM playback and `blob:` media keep working —
/// nothing is scraped or re-loaded.
@Observable
@MainActor
final class PopOutController: NSObject, NSWindowDelegate {
    static let shared = PopOutController()

    /// The main window renders a placeholder for this tab while it's popped out.
    private(set) var poppedOutTab: Tab?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var lensContainer: NSView?
    @ObservationIgnored private var chromeView: NSHostingView<PopOutChrome>?
    @ObservationIgnored private let chromeModel = PopOutChromeModel()
    /// The web view's size at pop-out time. Its frame is pinned to this so the
    /// page never reflows inside the panel and the measured rect stays valid.
    @ObservationIgnored private var pageSize: CGSize = .zero
    @ObservationIgnored private var lastVideoFrame: CGRect = .zero
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

        // Read the size synchronously: on an automatic pop-out the selection
        // changes immediately after this call, and the web view is unmounted
        // before an awaited read would run.
        let capturedSize = tab.webView.bounds.size
        guard capturedSize.width > 0, capturedSize.height > 0 else { return }

        Task { @MainActor in
            // Measure while the page is still laid out at that size. If there's
            // no measurable video, do nothing at all — a lens onto nothing is
            // worse than no lens.
            guard let rect = await tab.measureVideoFrame() else { return }
            pageSize = capturedSize
            lastVideoFrame = rect

            tab.setPageScrollLocked(true)
            // Publishing first makes the main window swap in its placeholder,
            // which releases the web view from SwiftUI's hierarchy before we
            // adopt it into the panel.
            poppedOutTab = tab
            try? await Task.sleep(for: .milliseconds(60))
            presentPanel(for: tab, videoFrame: rect)
            startTracking(tab)
        }
    }

    private func presentPanel(for tab: Tab, videoFrame: CGRect) {
        let contentSize = PopOutSizing.panelSize(forVideo: videoFrame.size)
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
        panel.contentAspectRatio = videoFrame.size
        panel.contentMinSize = PopOutSizing.minimumSize(forVideo: videoFrame.size)
        panel.delegate = self
        // Transparent so the rounded corners aren't filled in by the window's
        // own background, and shadowed so it lifts off whatever is behind it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let root = PopOutRootView(frame: NSRect(origin: .zero, size: contentSize))
        root.autoresizingMask = [.width, .height]

        let container = NSView(frame: root.bounds)
        container.autoresizingMask = [.width, .height]
        container.clipsToBounds = true

        // The web view keeps the size it had in the main window — the page
        // must not reflow — and is never autoresized by the panel.
        tab.webView.autoresizingMask = []
        tab.webView.frame = NSRect(origin: .zero, size: pageSize)
        container.addSubview(tab.webView)
        root.addSubview(container)

        chromeModel.title = tab.displayTitle
        chromeModel.isPlaying = tab.media?.isPlaying ?? false
        chromeModel.onClose = { [weak self] in self?.closeFromChrome() }
        chromeModel.onRestore = { [weak self] in self?.restore() }
        chromeModel.onTogglePlay = { [weak tab] in tab?.toggleMediaPlayback() }
        chromeModel.onSeek = { [weak tab] time in tab?.seekMedia(to: time) }
        chromeModel.onSkip = { [weak tab] delta in tab?.skipMedia(by: delta) }
        chromeModel.currentTime = tab.media?.currentTime ?? 0
        chromeModel.duration = tab.media?.duration ?? 0

        let chrome = NSHostingView(rootView: PopOutChrome(model: chromeModel))
        chrome.frame = root.bounds
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)
        chromeView = chrome

        root.onHoverChange = { [weak self] hovering in
            MainActor.assumeIsolated { self?.chromeModel.isHovering = hovering }
        }

        panel.contentView = root
        lensContainer = container
        applyLens(videoFrame)

        positionInBottomTrailingCorner(panel, size: contentSize)
        panel.orderFront(nil)
        self.panel = panel
    }

    /// The chrome's close button dismisses the pop-out entirely, folding the
    /// tab back into the main window rather than leaving it orphaned.
    private func closeFromChrome() {
        restore()
    }

    /// The heart of the lens: point the container's bounds at the video.
    ///
    /// With `frame` at panel size and `bounds` set to the video's rect in the
    /// web view's coordinate space, AppKit renders exactly that rect scaled to
    /// fill the panel — and routes events with the same mapping. The rect
    /// arrives in CSS coordinates (top-left origin), so flip into AppKit's
    /// bottom-left space.
    private func applyLens(_ videoFrame: CGRect) {
        lensContainer?.bounds = NSRect(
            x: videoFrame.minX,
            y: pageSize.height - videoFrame.maxY,
            width: videoFrame.width,
            height: videoFrame.height
        )
    }

    /// Sites move their players — layout settles late, ads collapse, theater
    /// mode toggles. Re-measure on a slow beat and follow.
    private func startTracking(_ tab: Tab) {
        trackingTask?.cancel()
        trackingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, poppedOutTab?.id == tab.id else { return }
                guard let rect = await tab.measureVideoFrame() else {
                    // The video left the DOM — nothing to show anymore.
                    restore()
                    return
                }
                if rect != lastVideoFrame {
                    lastVideoFrame = rect
                    applyLens(rect)
                    reshapeIfVideoChangedShape(to: rect.size)
                }
                // Keeps the chrome's play/pause glyph honest when playback is
                // changed from anywhere else — the sidebar, or the page itself.
                chromeModel.isPlaying = tab.media?.isPlaying ?? false
                chromeModel.currentTime = tab.media?.currentTime ?? 0
                chromeModel.duration = tab.media?.duration ?? 0
            }
        }
    }

    /// Adopts a new shape when the video turns out not to be the shape it first
    /// measured — dimensions often aren't known until metadata loads, and a
    /// player can swap clips without the panel closing.
    ///
    /// Only re-sizes a panel the user hasn't touched. Once it's been dragged to
    /// a size, that size is theirs; the aspect ratio still updates so the next
    /// drag snaps to the right shape.
    private func reshapeIfVideoChangedShape(to videoSize: CGSize) {
        guard let panel, videoSize.width > 0, videoSize.height > 0 else { return }
        guard !PopOutSizing.aspectMatches(panel.contentAspectRatio, videoSize) else { return }

        panel.contentAspectRatio = videoSize
        panel.contentMinSize = PopOutSizing.minimumSize(forVideo: videoSize)

        guard let presentedSize, panel.frame.size == presentedSize else { return }
        let fitted = PopOutSizing.panelSize(forVideo: videoSize)
        panel.setContentSize(fitted)
        self.presentedSize = panel.frame.size
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
        tab.setPageScrollLocked(false)

        lensContainer = nil
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

    /// Resizing a view's frame resets its bounds scale, which would break the
    /// lens mapping — so re-point it after every live resize.
    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { applyLens(lastVideoFrame) }
    }
}
