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
    /// The pre-Islands shape: one flat tab list and one selection.
    ///
    /// Still written, and still holding the *home* island's tabs, for one
    /// release. The duplication costs a second copy of one tab array in a JSON
    /// file; what it buys is that downgrading the app — or a crash-loop that
    /// rolls back to the previous build — shows the user their real tabs with
    /// their real logins instead of an empty browser.
    public var tabs: [PersistedTab]
    public var selectedIndex: Int

    /// nil means this file was written before islands existed. Optional so the
    /// synthesized decoder uses `decodeIfPresent` and an old `session.json`
    /// decodes without a custom initializer.
    public var islands: [PersistedIsland]?
    public var selectedIslandIndex: Int?
    public var schemaVersion: Int?

    /// Bumped when the *meaning* of a field changes, not when one is added —
    /// additions are handled by optionality.
    public static let currentSchemaVersion = 2

    public init(
        tabs: [PersistedTab],
        selectedIndex: Int,
        islands: [PersistedIsland]? = nil,
        selectedIslandIndex: Int? = nil,
        schemaVersion: Int? = nil
    ) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.islands = islands
        self.selectedIslandIndex = selectedIslandIndex
        self.schemaVersion = schemaVersion
    }

    /// Builds a session from islands, filling in the legacy mirror from the
    /// home island so an older build can still read it.
    public init(islands: [PersistedIsland], selectedIslandIndex: Int) {
        let home = islands.first(where: \.isHome)
        self.tabs = home?.tabs ?? []
        self.selectedIndex = home?.selectedIndex ?? 0
        self.islands = islands
        self.selectedIslandIndex = selectedIslandIndex
        self.schemaVersion = Self.currentSchemaVersion
    }

    /// The islands to actually open, whatever shape the file was in.
    ///
    /// A file with no `islands` key becomes one home island carrying the legacy
    /// tabs. Nobody is signed out by that migration, because the home island is
    /// *defined* as the one using the default store — the same jar those
    /// cookies were already in.
    public var resolvedIslands: (islands: [PersistedIsland], selected: Int) {
        guard let islands else {
            return ([.home(tabs: tabs, selectedIndex: selectedIndex)], 0)
        }
        return IslandLayout.normalize(islands, selected: selectedIslandIndex ?? 0)
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

        guard let islands else {
            guard !kept.isEmpty else { return nil }
            // If the selected tab was itself dropped, fall back to the first.
            return PersistedSession(tabs: kept, selectedIndex: newSelection ?? 0)
        }

        let (normalized, selectedIsland) = IslandLayout.normalize(
            islands, selected: selectedIslandIndex ?? 0
        )
        let cleaned = normalized.map { $0.sanitized() }

        // The one case that still sanitizes away to nothing is the one that
        // existed before islands did: a lone home island with nothing open. Any
        // island the user actually made is kept even when empty, because the
        // island *is* the cookie jar — throwing it away here would orphan a
        // store full of logins on the first quit with everything closed.
        //
        // Stickers count as something open: they're the user's pins, and a
        // shelf of them with every tab closed is a perfectly normal way to
        // quit. Sanitizing that to nil would peel every sticker off at launch.
        if cleaned.count == 1, cleaned[0].isHome, cleaned[0].tabs.isEmpty,
           cleaned[0].stickers?.isEmpty ?? true {
            return nil
        }

        return PersistedSession(islands: cleaned, selectedIslandIndex: selectedIsland)
    }
}

/// Where the session file lives, and how it's read and written.
public enum SessionFile {

    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Surf", isDirectory: true)
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

/// Serializes session writes so they can happen off the main thread.
///
/// An actor rather than a bare `Task`: saves are triggered by whatever the
/// browser happens to be doing, so two can easily be in flight at once, and two
/// atomic writes racing to the same path would leave whichever finished last —
/// not necessarily the newer one. Serializing them keeps last-scheduled and
/// last-written the same thing.
public actor SessionWriter {
    public static let shared = SessionWriter()

    private init() {}

    public func write(_ session: PersistedSession, to url: URL = SessionFile.url) {
        Self.writeSynchronously(session, to: url)
    }

    /// The same write, on the caller's thread — for quitting, where there is no
    /// later turn of the run loop to finish on.
    public static func writeSynchronously(
        _ session: PersistedSession,
        to url: URL = SessionFile.url
    ) {
        do {
            try SessionFile.save(session, to: url)
        } catch {
            fputs("[surf] session save failed: \(error)\n", stderr)
        }
    }
}
