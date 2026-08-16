import Foundation

/// One tab as written to disk.
///
/// `interactionState` is WebKit's opaque blob covering back/forward history and
/// scroll position. `url` is kept alongside it as a fallback: the blob is
/// version-specific and can be rejected by a future WebKit, and it's also what
/// the sidebar shows before a restored tab has loaded.
public struct PersistedTab: Codable, Equatable, Sendable {
    public var url: String?
    public var title: String
    public var interactionState: Data?

    public init(url: String?, title: String, interactionState: Data? = nil) {
        self.url = url
        self.title = title
        self.interactionState = interactionState
    }

    /// A tab sitting on the home screen has nothing worth restoring.
    public var isRestorable: Bool {
        guard let url, !url.isEmpty else { return false }
        return true
    }
}

public struct PersistedSession: Codable, Equatable, Sendable {
    public var tabs: [PersistedTab]
    public var selectedIndex: Int

    public init(tabs: [PersistedTab], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    /// Drops unrestorable tabs and repairs the selection, returning nil when
    /// there's nothing worth restoring at all.
    ///
    /// The selection is *followed* rather than clamped: if tabs before the
    /// selected one are dropped, the index shifts to keep pointing at the same
    /// tab. Clamping would silently reopen on the wrong page.
    public func sanitized() -> PersistedSession? {
        var kept: [PersistedTab] = []
        var newSelection: Int?

        for (index, tab) in tabs.enumerated() where tab.isRestorable {
            if index == selectedIndex { newSelection = kept.count }
            kept.append(tab)
        }

        guard !kept.isEmpty else { return nil }
        // If the selected tab was itself dropped, fall back to the first tab.
        return PersistedSession(tabs: kept, selectedIndex: newSelection ?? 0)
    }
}

/// Where the session file lives, and how it's read and written.
public enum SessionFile {

    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Glass", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public static func load(from url: URL = SessionFile.url) -> PersistedSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A corrupt or outdated file must never block launch — losing the
        // session is annoying, failing to start is not acceptable.
        return (try? JSONDecoder().decode(PersistedSession.self, from: data))?.sanitized()
    }

    public static func save(_ session: PersistedSession, to url: URL = SessionFile.url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(session)
        // Atomic: a crash mid-write leaves the previous session intact rather
        // than a truncated file.
        try data.write(to: url, options: .atomic)
    }
}
