import AppKit
import GlassCore
import Observation
import SwiftUI

/// Owns the dev tools windows: one panel per inspected tab.
///
/// A separate window rather than a dock inside the browser window, for a
/// concrete reason: AppKit asks real views before SwiftUI-drawn content, so the
/// `WKWebView` wins every hit test against anything merely painted over it (see
/// `WebViewContainer`). A docked panel with a text field in it would lose
/// clicks. A real window sidesteps that entirely — and on a second display it's
/// what people want anyway.
@Observable
@MainActor
final class DevToolsController: NSObject, NSWindowDelegate {
    static let shared = DevToolsController()

    /// Tabs with an open panel, so the sidebar can badge them.
    private(set) var inspectedTabIDs: Set<Tab.ID> = []

    @ObservationIgnored private var panels: [Tab.ID: NSPanel] = [:]
    @ObservationIgnored private var sessions: [Tab.ID: DevToolsSession] = [:]

    private override init() { super.init() }

    func isOpen(for tab: Tab) -> Bool { inspectedTabIDs.contains(tab.id) }
    func session(for tab: Tab) -> DevToolsSession? { sessions[tab.id] }

    func toggle(_ tab: Tab) {
        isOpen(for: tab) ? close(for: tab) : open(tab)
    }

    // MARK: - Open

    func open(_ tab: Tab, pane: DevToolsSession.Pane? = nil) {
        if let existing = panels[tab.id] {
            if let pane { sessions[tab.id]?.pane = pane }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let session = DevToolsSession(tab: tab)
        if let pane { session.pane = pane }
        sessions[tab.id] = session

        let size = DevToolsLayout.defaultSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Titled, unlike the media pop-out: that one is borderless because
            // it's a piece of floating video, whereas this is a workspace you
            // resize, move and read a title in.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // A workspace, not an accessory. Floating would keep it over every other
        // app, which is wrong for a window you tab between — and ⌘` should reach
        // it like any other window of ours.
        panel.isFloatingPanel = false
        // The console's input has to be able to take key and type into.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = DevToolsLayout.minimumSize
        panel.delegate = self
        panel.tabbingMode = .disallowed
        // One remembered frame for all panels, so the first one each launch
        // lands where it was left.
        panel.setFrameAutosaveName("glass.devtools")

        panel.contentView = NSHostingView(rootView: DevToolsView(session: session))

        // Only place a fresh panel; a restored autosave frame is the user's.
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            panel.setFrameOrigin(
                DevToolsLayout.cascadedOrigin(
                    index: panels.count,
                    size: size,
                    on: screen.visibleFrame
                )
            )
        }

        panels[tab.id] = panel
        inspectedTabIDs.insert(tab.id)
        trackTitle(of: tab, in: panel)

        session.start()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Close

    /// Called both from the panel's own close button and from
    /// `BrowserSession.close(_:)` before a tab is torn down. Idempotent, since
    /// closing a panel programmatically also fires `windowWillClose`.
    func close(for tab: Tab) {
        close(tabID: tab.id)
    }

    private func close(tabID: Tab.ID) {
        sessions.removeValue(forKey: tabID)?.stop()
        inspectedTabIDs.remove(tabID)

        if let panel = panels.removeValue(forKey: tabID) {
            panel.delegate = nil
            panel.contentView = nil
            panel.close()
        }
    }

    // MARK: - Navigation

    /// `Tab` calls this from `didCommit` — the authoritative "this is a new
    /// document" signal. Note that the `\.url` KVO is *not* the right hook: it
    /// also fires for SPA route changes, where the document survives and none
    /// of the agent's ids have gone stale.
    func documentDidCommit(for tab: Tab) {
        sessions[tab.id]?.documentDidChange()
    }

    // MARK: - Safari hand-off

    /// The one thing that genuinely cannot be built.
    ///
    /// Page JavaScript runs in the WebContent process, and the WebKit Inspector
    /// protocol is reachable only over a private XPC service — so breakpoints,
    /// stepping and heap snapshots are not a matter of effort. `isInspectable`
    /// (set on every tab) advertises our web views to Safari's Develop menu,
    /// which is where that work has to happen.
    func handOffToSafari(_ tab: Tab) {
        let alert = NSAlert()
        alert.messageText = "Debug in Safari's Web Inspector"
        alert.informativeText = """
        Glass can't host a JavaScript debugger: page scripts run in a separate \
        process that only Safari's inspector can attach to.

        Glass's pages are already exposed to it. In Safari, enable \
        Settings → Advanced → "Show features for web developers", then choose \
        Develop → \(Host.current().localizedName ?? "This Mac") → Glass.
        """
        alert.addButton(withTitle: "Open Safari")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: safari,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Title tracking

    /// Keeps the panel's title honest as the page navigates.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself.
    /// The re-read is deferred a tick because the callback runs *before* the
    /// new value is stored — reading immediately would just see the old title
    /// and register for a change that had already happened.
    private func trackTitle(of tab: Tab, in panel: NSPanel) {
        withObservationTracking {
            panel.title = "Developer Tools — \(tab.displayTitle)"
        } onChange: { [weak self, weak tab, weak panel] in
            Task { @MainActor in
                guard let self, let tab, let panel,
                      self.panels[tab.id] === panel
                else { return }
                self.trackTitle(of: tab, in: panel)
            }
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // The window is resolved to a plain identity out here: `Notification`
        // isn't `Sendable`, so it can't cross into the main-actor closure, and
        // an `ObjectIdentifier` carries everything the lookup needs.
        guard let window = notification.object as? NSWindow else { return }
        let identity = ObjectIdentifier(window)
        MainActor.assumeIsolated {
            guard let id = panels.first(where: { ObjectIdentifier($0.value) == identity })?.key
            else { return }
            close(tabID: id)
        }
    }
}
