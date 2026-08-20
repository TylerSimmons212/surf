import Foundation

/// The pure rules islands obey, kept away from WebKit so they can be tested.
///
/// Sibling of `TabSelection`: index arithmetic and validity checks live here,
/// the objects that act on them live in the app target. Small functions, but
/// the ones where being wrong means browsing as the wrong person.
public enum IslandLayout {

    /// Whether WebKit will accept this as a data store identifier.
    ///
    /// The all-zeros UUID is rejected because `WKWebsiteDataStore(forIdentifier:)`
    /// raises an Objective-C exception on it rather than returning nil — so an
    /// island created from a zeroed UUID wouldn't fail to isolate, it would
    /// terminate the app. `UUID()` never produces one, but a decoded session
    /// file is not something we generated, and neither is a value that survived
    /// a partial write.
    public static func isValidDataStoreIdentifier(_ identifier: UUID) -> Bool {
        identifier != zeroIdentifier
    }

    static let zeroIdentifier = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    /// Repairs a decoded island list so the rest of the app can assume it is
    /// well-formed: at least one island, exactly one home island, and a
    /// selection that names a real one.
    ///
    /// Note what is *not* repaired: two islands naming one data store. That
    /// used to be dropped on sight — a jar wearing two names — and is now how
    /// "bring over my logins" is spelled, so a shared store is left exactly as
    /// written. What still can't be shared is home-ness: two islands may browse
    /// the default jar, but only one of them is the island the browser started
    /// life as, and a second claimant is demoted rather than dropped. Dropping
    /// it would delete a workspace the user made, for a field they never saw.
    ///
    /// The selection is *followed* rather than clamped, the same choice
    /// `PersistedSession.sanitized()` makes: if islands before the selected one
    /// are dropped, the index shifts to keep pointing at the same island.
    /// Clamping would silently open the browser in somebody else's identity.
    public static func normalize(
        _ islands: [PersistedIsland],
        selected: Int
    ) -> (islands: [PersistedIsland], selected: Int) {
        var kept: [PersistedIsland] = []
        var newSelection: Int?
        var seenHome = false
        var seenIDs: Set<UUID> = []

        for (index, island) in islands.enumerated() {
            // A duplicate id would make the sidebar and the tab list disagree
            // about which island a tab is in.
            guard seenIDs.insert(island.id).inserted else { continue }

            var island = island
            if island.isHome {
                // The first claimant keeps the title; a later one becomes an
                // ordinary island that happens to share the default jar, which
                // is a shape the app now supports and draws correctly. It is
                // *not* handed a fresh store instead: a store invented here has
                // no data in it, so its tabs would look logged out for reasons
                // nobody could trace back to a decode.
                if seenHome { island.isHomeIsland = false }
                seenHome = true
            } else if let store = island.dataStoreID {
                guard isValidDataStoreIdentifier(store) else { continue }
            }

            if index == selected { newSelection = kept.count }
            kept.append(island)
        }

        // Never empty: every caller downstream is allowed to assume a current
        // island exists.
        if kept.isEmpty { return ([.home()], 0) }
        if !seenHome { kept.insert(.home(), at: 0); newSelection = newSelection.map { $0 + 1 } }

        let selection = newSelection ?? 0
        return (kept, selection < kept.count ? selection : 0)
    }

    /// Whether erasing `store` would take data some other island is still
    /// browsing with.
    ///
    /// The guard on deletion, and the reason sharing a jar is safe to offer:
    /// deleting an island erases its store, and an island created with "bring
    /// over logins" points at a store it does not own. Erasing it would sign
    /// the user out of the island they copied *from* — the direction nobody
    /// checks, with no undo.
    ///
    /// `nil` — the default store — always answers true. That jar predates
    /// islands and is never ours to erase, whoever is left pointing at it.
    public static func storeIsShared(_ store: UUID?, claimedBy others: [UUID?]) -> Bool {
        guard let store else { return true }
        return others.contains(store)
    }

    /// A list of island names as a sentence reads it: "Home", "Home and Work",
    /// "Home, Work and Play".
    ///
    /// Lives here rather than at the one alert that needs it because the rule
    /// is prose, not layout, and prose that appears in a destructive dialog is
    /// worth a test: this is the sentence that tells someone their logins are
    /// safe, and it has to be true and readable at one, two and five islands.
    public static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The index to select after deleting the island at `deletedIndex`.
    /// Returns nil when nothing is left — which callers must refuse, since
    /// there is always at least one island.
    ///
    /// Same rule as closing a tab: whatever slides into the vacated slot wins.
    public static func indexAfterDeleting(islandAt deletedIndex: Int, count: Int) -> Int? {
        TabSelection.indexAfterClosing(closedIndex: deletedIndex, originalCount: count)
    }

    /// Places on a coastline, walked in order, skipping any already taken.
    ///
    /// "Island 2" is a correct name and a joyless one. These cost nothing, and
    /// a browser whose whole idea is islands may as well have somewhere to put
    /// you rather than a number.
    static let placeNames = [
        "Driftwood", "Sandbar", "Coral Cove", "Low Tide", "Reef Break",
        "Palm Grove", "Tide Pool", "Lagoon", "Shell Bay", "Salt Flat",
        "High Water", "Long Shore",
    ]

    /// A name for a new island that isn't already taken.
    public static func defaultName(existing: [String]) -> String {
        let taken = Set(existing)
        if let free = placeNames.first(where: { !taken.contains($0) }) { return free }
        // Past the end of the coastline, fall back to counting. Bounded by
        // construction: at most one name per existing island can collide.
        var number = existing.count + 1
        while taken.contains("Island \(number)") { number += 1 }
        return "Island \(number)"
    }

    /// Data stores on disk that no island claims any more.
    ///
    /// Deleting an island is several steps, any of which can be interrupted by
    /// a quit or a crash, and a store left behind is hundreds of megabytes of
    /// somebody's browsing that nothing will ever show them again. Computing
    /// the difference here rather than inline keeps the launch-time sweep
    /// testable without WebKit.
    public static func orphanedDataStoreIDs(
        known islands: [PersistedIsland],
        onDisk: [UUID]
    ) -> [UUID] {
        let claimed = Set(islands.compactMap(\.dataStoreID))
        // Order preserved from `onDisk` so a sweep is deterministic, and
        // de-duplicated in case WebKit ever reports one twice.
        var seen: Set<UUID> = []
        return onDisk.filter { !claimed.contains($0) && seen.insert($0).inserted }
    }
}
