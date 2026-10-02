import AppKit

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
