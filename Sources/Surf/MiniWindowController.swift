import AppKit
import Observation
import SurfCore
import SwiftUI

/// A floating window holding one page you have not committed to yet.
///
/// A link arriving from somewhere else is a question, not a decision: most of
/// them are read once and thrown away, and the ones that aren't want to become
/// tabs. So the page opens in a panel that costs nothing to dismiss, with one
/// button that promotes it into the window proper.
///
/// The tab it holds is a real `Tab` in every respect except that its island
/// does not list it. That is what makes it ephemeral — not a flag anything has
/// to remember to check, but simple absence from the array the sidebar draws.
/// Promoting is `append`; dismissing is `teardown`.
@Observable
@MainActor
final class MiniWindowController: NSObject, NSWindowDelegate {
    static let shared = MiniWindowController()

    private(set) var tab: Tab?

    /// The island whose cookie jar the tab was built with. Promotion files it
    /// here rather than into whatever island happens to be current: the two
    /// drift apart the moment someone switches islands with the panel open,
    /// and a tab carrying one island's logins in another island's list is the
    /// same confusion `openSplit` refuses to create.
    private var origin: Island?

    private var panel: MiniWindowPanel?

    /// The window the link came from. Closing a mini window should put you back
    /// where you were rather than in whatever AppKit decides to raise next —
    /// dismissing is "never mind", and never mind means going back.
    private weak var opener: NSWindow?

    /// A browser window's proportions, at a size that suits the display it
    /// lands on — see `MiniWindowSizing`. It was a flat 1000×680, which is two
    /// thirds of a laptop screen and a quarter of a 6K one.
    private static func defaultSize(near mouse: NSPoint) -> NSSize {
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return MiniWindowSizing.minimum }
        return MiniWindowSizing.size(forVisible: visible)
    }

    private override init() { super.init() }

    var isOpen: Bool { tab != nil }

    // MARK: - Opening

    func open(_ url: URL, from session: BrowserSession) {
        // One at a time. A second link should replace the question on screen,
        // not stack another panel behind it.
        dismiss()

        // Before the panel takes key, so this is genuinely where we came from.
        opener = NSApp.keyWindow
        let island = session.currentIsland
        let fresh = session.makeUnlistedTab()
        tab = fresh
        origin = island
        fresh.submit(url.absoluteString)
        present(fresh, in: island, session: session)
        debugLog("mini: opened \(url.absoluteString) in \(island.name)")
    }

    private func present(_ tab: Tab, in island: Island, session: BrowserSession) {
        let mouse = NSEvent.mouseLocation
        let size = Self.defaultSize(near: mouse)
        let panel = MiniWindowPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // No `.nonactivatingPanel`. It stops a click in the panel making
            // Surf the active app, and an inactive app draws every control in
            // its inactive state — which is a row of buttons that do not
            // answer the pointer, because as far as AppKit is concerned nobody
            // is looking at them. The panel takes key on its own line below, so
            // it was never buying the restraint it looked like it was buying.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.contentMinSize = NSSize(width: 520, height: 380)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        let root = MiniWindowRootView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        // The page starts below the bar rather than running under it. That is
        // the whole reason the bar can be one full-width view: an AppKit view
        // takes every click inside its frame, and there is no page up here to
        // take them from.
        let barHeight = MiniWindowBar.height
        let web = tab.webView
        web.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - barHeight)
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)

        let bar = NSHostingView(
            rootView: MiniWindowBar(
                tab: tab,
                session: session,
                destination: island,
                onClose: { [weak self] in self?.dismiss() },
                onCopyLink: { [weak tab] in
                    guard let url = tab?.currentURL, !url.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                },
                onPromote: { [weak self] in self?.promote() },
                onPromoteInto: { [weak self] island in self?.promote(into: island) }
            )
        )
        bar.frame = NSRect(
            x: 0, y: size.height - barHeight, width: size.width, height: barHeight
        )
        // Glued to the top edge at a fixed height: the flexible margin is the
        // one below it, which is the page's to grow into.
        bar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(bar)

        panel.contentView = root
        positionNearPointer(panel, near: mouse, size: size)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Where the pointer is, nudged fully on screen. A window answering a click
    /// belongs near the click, not in a corner the eye has to go find.
    private func positionNearPointer(_ panel: NSPanel, near mouse: NSPoint, size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height)
        origin.x = min(max(visible.minX + 12, origin.x), visible.maxX - size.width - 12)
        origin.y = min(max(visible.minY + 12, origin.y), visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Leaving

    /// Keep the page.
    ///
    /// With no island named it joins the one it was made against, live and
    /// unreloaded. Naming a different island means something else entirely —
    /// see `BrowserSession.openTab(in:url:)`.
    func promote(into chosen: Island? = nil) {
        guard let tab, let origin, let session = tab.session else { return }
        let target = chosen ?? origin
        let url = tab.currentURL

        // Out of the panel before the panel goes away, or closing it would take
        // the live web view down with it and the tab would arrive blank — the
        // same order `PopOutController.restore` keeps, for the same reason.
        detachWebView(of: tab)
        teardownPanel()
        self.tab = nil
        self.origin = nil

        if target === origin {
            session.adopt(tab, into: origin)
        } else {
            // A different island is a different cookie jar. Carrying the live
            // view over would file a page that browsed as one identity into
            // another's list; fetching it again is what makes the promotion
            // mean what it says.
            tab.teardown()
            if let url, !url.isEmpty { session.openTab(in: target, url: url) }
        }

        // The tab is in the main window now, so that is where the user is.
        opener?.makeKeyAndOrderFront(nil)
        opener = nil
        debugLog("mini: promoted into \(target.name)")
    }

    /// Throw the page away. The tab was never in an island's list, so there is
    /// nothing to remove it from and nothing to remember it by.
    func dismiss() {
        guard let tab else { return }
        detachWebView(of: tab)
        teardownPanel()
        self.tab = nil
        origin = nil
        // Explicit, not just dropping the reference: a web view with audio
        // playing keeps its content process alive.
        tab.teardown()
        opener?.makeKeyAndOrderFront(nil)
        opener = nil
        debugLog("mini: dismissed")
    }

    private func detachWebView(of tab: Tab) {
        guard tab.isLive else { return }
        tab.webView.removeFromSuperview()
        tab.webView.autoresizingMask = [.width, .height]
    }

    private func teardownPanel() {
        panel?.delegate = nil
        panel?.onCancel = nil
        panel?.close()
        panel = nil
    }

    // MARK: - NSWindowDelegate

    /// The panel closing by any other route still has to release the tab.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { dismiss() }
    }
}
