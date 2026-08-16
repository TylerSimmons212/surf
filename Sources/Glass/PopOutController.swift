import AppKit
import Observation
import SwiftUI

/// Floats a playing tab in a small always-on-top panel.
///
/// The live `WKWebView` is *moved* into the panel rather than a second one
/// being created. Loading the page again would restart the video, lose the
/// position, and outright fail for streamed sources whose URLs are `blob:`
/// handles valid only inside their original document.
@Observable
@MainActor
final class PopOutController: NSObject, NSWindowDelegate {
    static let shared = PopOutController()

    /// The main window renders a placeholder for this tab while it's popped out.
    private(set) var poppedOutTab: Tab?

    @ObservationIgnored private var panel: NSPanel?

    private override init() { super.init() }

    func isPoppedOut(_ tab: Tab) -> Bool { poppedOutTab?.id == tab.id }

    func toggle(_ tab: Tab) {
        isPoppedOut(tab) ? restore() : popOut(tab)
    }

    // MARK: - Pop out

    func popOut(_ tab: Tab) {
        if poppedOutTab != nil { restore() }

        tab.setPopOutStyling(true)
        // Publishing first makes the main window swap in its placeholder, which
        // releases the web view from SwiftUI's hierarchy. Taking the view while
        // SwiftUI still owns it invites it to be pulled back out again.
        poppedOutTab = tab

        Task { @MainActor in
            // One turn for SwiftUI to apply the placeholder before we adopt the view.
            try? await Task.sleep(for: .milliseconds(60))
            let size = await tab.videoDimensions()
            presentPanel(for: tab, videoSize: size)
        }
    }

    private func presentPanel(for tab: Tab, videoSize: CGSize?) {
        let contentSize = panelSize(for: videoSize)
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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        if let ratio = videoSize, ratio.height > 0 {
            panel.contentAspectRatio = ratio
        }

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]
        tab.webView.frame = container.bounds
        tab.webView.autoresizingMask = [.width, .height]
        // addSubview moves the view out of whatever hierarchy it was in.
        container.addSubview(tab.webView)
        panel.contentView = container

        positionInBottomTrailingCorner(panel, size: contentSize)
        panel.orderFront(nil)
        self.panel = panel
    }

    /// Scales the video's own aspect ratio to a comfortable size, clamped so a
    /// tall or enormous video can't produce an unusable panel.
    private func panelSize(for videoSize: CGSize?) -> NSSize {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
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

        // Detach before the panel goes away, or closing it would take the web
        // view down with it and the tab would come back blank.
        tab.webView.removeFromSuperview()
        tab.webView.autoresizingMask = []
        tab.setPopOutStyling(false)

        panel?.delegate = nil
        panel?.close()
        panel = nil

        // Published last: this is what tells the main window to remount it.
        poppedOutTab = nil
    }

    /// The panel's own close button routes here.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { restore() }
    }
}
