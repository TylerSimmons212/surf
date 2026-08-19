import Foundation

/// One island as written to disk: an identity, a cookie jar, and the tabs
/// filed under it.
///
/// `dataStoreID` carries the whole isolation model in one optional. `nil` means
/// WebKit's default store — the jar the browser has been filling since before
/// islands existed. Making that a property of the *data* rather than an
/// `if index == 0` somewhere is what keeps it true after the user renames,
/// reorders, or deletes islands around it: the home island is the one without
/// an identifier, wherever it happens to sit.
///
/// `id` is deliberately not `dataStoreID`. An island's identity outlives its
/// storage — you can wipe an island's data without the island ceasing to
/// exist, and `WKWebsiteDataStore.remove(forIdentifier:)` is asynchronous and
/// fallible, so there is a window where the store is going away and the sidebar
/// still needs something stable to draw.
public struct PersistedIsland: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// One emoji. Stored as a string because that's what an emoji is — a
    /// grapheme cluster, not a character.
    public var symbol: String
    public var tint: IslandTint
    /// nil == the shared default store.
    public var dataStoreID: UUID?
    public var tabs: [PersistedTab]
    public var selectedIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        tint: IslandTint,
        dataStoreID: UUID?,
        tabs: [PersistedTab] = [],
        selectedIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    /// The island the browser starts life as, and the only one that may use the
    /// default store.
    public static func home(
        id: UUID = UUID(),
        tabs: [PersistedTab] = [],
        selectedIndex: Int = 0
    ) -> PersistedIsland {
        PersistedIsland(
            id: id,
            name: "Home",
            symbol: "🏝️",
            tint: .surf,
            dataStoreID: nil,
            tabs: tabs,
            selectedIndex: selectedIndex
        )
    }

    public var isHome: Bool { dataStoreID == nil }

    /// Drops tabs with nothing worth restoring, following the selection the way
    /// `PersistedSession.sanitized()` does.
    ///
    /// Unlike a session, an island that empties out is **kept**. Dropping it
    /// would mean closing your last work tab deletes the work island — and
    /// orphans its data store, silently losing those logins with no undo.
    /// Islands go away when someone deletes them, and at no other time.
    public func sanitized() -> PersistedIsland {
        var kept: [PersistedTab] = []
        var newSelection: Int?

        for (index, tab) in tabs.enumerated() where tab.isRestorable {
            if index == selectedIndex { newSelection = kept.count }
            kept.append(tab)
        }

        var result = self
        result.tabs = kept
        result.selectedIndex = newSelection ?? 0
        return result
    }
}

/// An island's colour, named rather than stored as a colour so that `SurfCore`
/// stays free of SwiftUI. `Sources/Surf` maps these onto the ocean palette.
public enum IslandTint: String, Codable, CaseIterable, Sendable {
    case surf
    case lagoon
    case kelp
    case coral
    case sand
    case dusk

    /// The tint a newly created island gets, walking the palette so that the
    /// first few islands are told apart at a glance without anyone choosing.
    public static func next(after used: [IslandTint]) -> IslandTint {
        let counts = allCases.map { tint in
            (tint: tint, count: used.filter { $0 == tint }.count)
        }
        // Least-used wins; ties break on palette order, so islands two and
        // three don't both land on the same colour.
        return counts.min { left, right in
            if left.count != right.count { return left.count < right.count }
            return allCases.firstIndex(of: left.tint)! < allCases.firstIndex(of: right.tint)!
        }?.tint ?? .surf
    }
}
