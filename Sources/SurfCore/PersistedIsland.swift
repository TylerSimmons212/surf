import Foundation

/// One tab group as written to disk.
///
/// Only the things a group *is* — the tabs it holds are the tabs that name it,
/// so membership is never stored twice and the two copies can never disagree.
public struct PersistedTabGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

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
    /// Optional for the same reason `PersistedTab.groupID` is: files written
    /// before groups existed have no key here and must still decode.
    public var groups: [PersistedTabGroup]?
    /// Pinned sites, in shelf order. Optional so a `session.json` written
    /// before stickers existed decodes unchanged — the same additive-field rule
    /// `PersistedSession` follows.
    public var stickers: [Sticker]?

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        tint: IslandTint,
        dataStoreID: UUID?,
        tabs: [PersistedTab] = [],
        selectedIndex: Int = 0,
        groups: [PersistedTabGroup]? = nil,
        stickers: [Sticker]? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.groups = groups
        self.stickers = stickers
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
        // A group whose every tab was just dropped has nothing left to name.
        // Groups are defined by their members, so an empty one isn't an empty
        // folder waiting to be filled — it's a section header with no section,
        // and nothing in the sidebar could draw it or reach it.
        let surviving = Set(kept.compactMap(\.groupID))
        result.groups = groups?.filter { surviving.contains($0.id) }
        return result
    }
}

/// An island's colour.
///
/// Stored as components rather than a named case, because the editor offers the
/// system colour picker and that hands back whatever the user landed on — a
/// closed set of names cannot represent "the blue from my company's logo". The
/// presets below are still where new islands start, so nobody has to choose.
///
/// Components rather than a `Color`, so `SurfCore` stays free of SwiftUI.
public struct IslandTint: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped()
        self.green = green.clamped()
        self.blue = blue.clamped()
    }

    public static let surf = IslandTint(red: 0.10, green: 0.60, blue: 0.85)
    public static let lagoon = IslandTint(red: 0.28, green: 0.83, blue: 0.89)
    public static let kelp = IslandTint(red: 0.20, green: 0.68, blue: 0.48)
    public static let coral = IslandTint(red: 0.95, green: 0.44, blue: 0.42)
    public static let sand = IslandTint(red: 0.88, green: 0.72, blue: 0.42)
    public static let dusk = IslandTint(red: 0.55, green: 0.45, blue: 0.85)

    /// Ordered, because "the next colour" walks them in this order.
    public static let presets: [IslandTint] = [surf, lagoon, kelp, coral, sand, dusk]

    private static let presetNames: [(tint: IslandTint, name: String)] = [
        (surf, "surf"), (lagoon, "lagoon"), (kelp, "kelp"),
        (coral, "coral"), (sand, "sand"), (dusk, "dusk"),
    ]

    /// The preset's name, when this *is* a preset. Nil for a colour the user
    /// mixed themselves, which has no name worth inventing.
    public var presetName: String? {
        Self.presetNames.first { $0.tint == self }?.name
    }

    /// The tint a newly created island gets, walking the palette so the first
    /// few islands are told apart at a glance without anyone choosing.
    public static func next(after used: [IslandTint]) -> IslandTint {
        let counts = presets.map { tint in
            (tint: tint, count: used.filter { $0 == tint }.count)
        }
        // Least-used wins; ties break on palette order, so islands two and
        // three don't both land on the same colour.
        return counts.min { left, right in
            if left.count != right.count { return left.count < right.count }
            return presets.firstIndex(of: left.tint)! < presets.firstIndex(of: right.tint)!
        }?.tint ?? surf
    }

    // MARK: - Coding

    /// Reads both shapes: the named string this was first shipped as, and the
    /// components it is now.
    ///
    /// Not dead weight yet — a session file written this morning says
    /// `"tint": "surf"`, and failing to decode it would drop the island's
    /// colour on the floor at the first launch after updating.
    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let name = try? single.decode(String.self),
           let known = Self.presetNames.first(where: { $0.name == name })?.tint {
            self = known
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue)
        )
    }
}

extension Double {
    /// Colour components outside 0...1 aren't a colour, and a picker on a wide
    /// -gamut display can hand back values slightly past both ends.
    fileprivate func clamped() -> Double { Swift.min(1, Swift.max(0, self)) }
}
