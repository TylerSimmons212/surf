import AppKit
import SwiftUI

/// Links handed to Surf by other applications.
///
/// macOS delivers these to the app delegate, which is the one place in Surf
/// with no owner to hand it a `BrowserSession` — every other AppKit entry point
/// is reached from a view or a tab that already has one. Hence the static
/// current session, and hence the queue: a link can arrive *before* there is a
/// session at all, because opening a link is one of the ways the app gets
/// launched in the first place.
@MainActor
enum ExternalLinks {
    /// Links that arrived before there was anywhere to put them.
    private static var pending: [URL] = []

    /// Called by the app delegate. Safe at any point in the launch sequence.
    static func receive(_ urls: [URL]) {
        let usable = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !usable.isEmpty else { return }
        guard let session = BrowserSession.current else {
            debugLog("external: \(usable.count) link(s) queued — no session yet")
            pending.append(contentsOf: usable)
            return
        }
        usable.forEach { open($0, in: session) }
    }

    /// Called once the session exists, for anything that arrived before it.
    static func flushPending() {
        guard let session = BrowserSession.current, !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        debugLog("external: releasing \(queued.count) queued link(s)")
        queued.forEach { open($0, in: session) }
    }

    private static func open(_ url: URL, in session: BrowserSession) {
        if LinkPreferences.externalUseMiniWindow {
            debugLog("external: \(url.absoluteString) → mini window")
            MiniWindowController.shared.open(url, from: session)
        } else {
            debugLog("external: \(url.absoluteString) → tab")
            session.openTab(in: session.currentIsland, url: url.absoluteString)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Asking macOS to make Surf the default browser.
///
/// The system puts up its own confirmation, so this is a request rather than a
/// change — which is the only reason an app is allowed to ask at all.
@MainActor
enum DefaultBrowser {
    static var isSurf: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!
        ) else { return false }
        // By identity, not by path. The same app answers to several URLs —
        // symlinked, relocated, standardised differently — and comparing the
        // strings would report "no" for a copy of Surf that plainly is the
        // handler.
        guard let id = Bundle(url: handler)?.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier
    }

    /// Whether asking could possibly work. A `swift run` binary is not a bundle
    /// and has no identifier, so Launch Services has nothing to register — the
    /// request would fail silently and read as a broken button.
    static var canAsk: Bool { Bundle.main.bundleIdentifier != nil }

    static func request() {
        let me = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(
                at: me,
                toOpenURLsWithScheme: scheme
            ) { error in
                if let error {
                    debugLog("default browser: \(scheme) refused — \(error.localizedDescription)")
                }
            }
        }
    }
}
