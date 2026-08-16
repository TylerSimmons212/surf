import AppKit
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
    /// The web view's size at pop-out time. Its frame is pinned to this so the
    /// page never reflows inside the panel and the measured rect stays valid.
    @ObservationIgnored private var pageSize: CGSize = .zero
    @ObservationIgnored private var lastVideoFrame: CGRect = .zero
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
        let contentSize = panelSize(for: videoFrame.size)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = tab.displayTitle
        // Stays above ordinary windows and follows you between Spaces, which is
        // the entire point of a pop-out.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = videoFrame.size
        panel.contentMinSize = NSSize(width: 240, height: 135)
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.clipsToBounds = true

        // The web view keeps the size it had in the main window — the page
        // must not reflow — and is never autoresized by the panel.
        tab.webView.autoresizingMask = []
        tab.webView.frame = NSRect(origin: .zero, size: pageSize)
        container.addSubview(tab.webView)

        panel.contentView = container
        lensContainer = container
        applyLens(videoFrame)

        positionInBottomTrailingCorner(panel, size: contentSize)
        panel.orderFront(nil)
        self.panel = panel
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
                }
            }
        }
    }

    /// Scales the video's own aspect ratio to a comfortable size, clamped so a
    /// tall or enormous video can't produce an unusable panel.
    private func panelSize(for videoSize: CGSize) -> NSSize {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return NSSize(width: 480, height: 270)
        }
        let targetWidth: CGFloat = 480
        let height = targetWidth * (videoSize.height / videoSize.width)
        return NSSize(width: targetWidth, height: min(max(height, 160), 540))
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
