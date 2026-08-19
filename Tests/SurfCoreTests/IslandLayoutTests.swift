import Foundation
import Testing
@testable import SurfCore

@Suite("Island layout")
struct IslandLayoutTests {

    private func island(
        _ name: String,
        store: UUID? = UUID(),
        id: UUID = UUID()
    ) -> PersistedIsland {
        PersistedIsland(id: id, name: name, symbol: "🌊", tint: .surf, dataStoreID: store)
    }

    // MARK: - Identifiers

    /// The all-zeros UUID doesn't make `WKWebsiteDataStore(forIdentifier:)`
    /// return nil, it makes it raise — so this check is the difference between
    /// an island that fails to isolate and an app that terminates.
    @Test("The all-zeros identifier is rejected")
    func zeroIdentifierRejected() {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(IslandLayout.isValidDataStoreIdentifier(zero) == false)
    }

    /// The check has to be narrow. Rejecting anything else would send a
    /// perfectly good island down the degraded, non-persistent path and lose
    /// the user's logins on every quit.
    @Test("Freshly minted identifiers are accepted")
    func freshIdentifiersAccepted() {
        for _ in 0..<100 {
            #expect(IslandLayout.isValidDataStoreIdentifier(UUID()))
        }
    }

    // MARK: - Normalizing

    /// Everything downstream reads `currentIsland` without a nil branch.
    @Test("An empty list normalizes to a single home island")
    func emptyGainsHome() {
        let (islands, selected) = IslandLayout.normalize([], selected: 0)
        #expect(islands.count == 1)
        #expect(islands[0].isHome)
        #expect(selected == 0)
    }

    /// A file listing only isolated islands would otherwise leave the default
    /// store — where all the user's existing cookies live — unreachable.
    @Test("A list with no home island gains one at the front")
    func homeIsRestored() {
        let (islands, selected) = IslandLayout.normalize(
            [island("Work"), island("Personal")], selected: 1
        )
        #expect(islands.count == 3)
        #expect(islands[0].isHome)
        // The selection followed its island rather than staying on index 1,
        // which is now a different island entirely.
        #expect(islands[selected].name == "Personal")
    }

    /// Two islands sharing the default store aren't isolation with a cosmetic
    /// flaw — they're two islands that are secretly one.
    @Test("Only the first home island survives")
    func duplicateHomeDropped() {
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Work"), .home()], selected: 0
        )
        #expect(islands.filter(\.isHome).count == 1)
        #expect(islands.count == 2)
    }

    /// Same reasoning one level down: two islands pointed at one store are one
    /// cookie jar wearing two names.
    @Test("Islands sharing a data store are collapsed to the first")
    func duplicateStoreDropped() {
        let shared = UUID()
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Work", store: shared), island("Copy", store: shared)],
            selected: 0
        )
        #expect(islands.count == 2)
        #expect(islands.last?.name == "Work")
    }

    /// A dropped island must not silently be replaced by a fresh store: the
    /// tabs filed under it would look logged out for reasons nobody could
    /// trace back to a decode.
    @Test("An island with a zeroed store identifier is dropped, not repaired")
    func zeroedStoreDropped() {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Broken", store: zero)], selected: 0
        )
        #expect(islands.count == 1)
        #expect(islands[0].isHome)
    }

    /// Followed, not clamped. Clamping would open the browser in whichever
    /// identity happened to slide into the index — which is the one mistake
    /// this feature cannot afford to make.
    @Test("The selection follows its island when earlier ones are dropped")
    func selectionFollows() {
        let shared = UUID()
        let (islands, selected) = IslandLayout.normalize(
            [.home(), island("A", store: shared), island("B", store: shared), island("C")],
            selected: 3
        )
        #expect(islands[selected].name == "C")
    }

    /// If the selected island was itself dropped there is nothing to follow, so
    /// it falls back rather than pointing past the end.
    @Test("A dropped selection falls back to the first island")
    func droppedSelectionFallsBack() {
        let shared = UUID()
        let (islands, selected) = IslandLayout.normalize(
            [.home(), island("A", store: shared), island("B", store: shared)],
            selected: 2
        )
        #expect(selected == 0)
        #expect(islands[selected].isHome)
    }

    /// A duplicate id would make the sidebar and the tab list disagree about
    /// which island a tab is in.
    @Test("Islands sharing an id are collapsed to the first")
    func duplicateIDDropped() {
        let id = UUID()
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("First", id: id), island("Second", id: id)], selected: 0
        )
        #expect(islands.count == 2)
        #expect(islands.last?.name == "First")
    }

    // MARK: - Deletion and naming

    /// Deliberately the same rule as closing a tab: whatever slides into the
    /// vacated slot wins, so the two don't feel like different apps.
    @Test("Deleting an island selects whatever slides into its place")
    func deletionSelection() {
        #expect(IslandLayout.indexAfterDeleting(islandAt: 0, count: 3) == 0)
        #expect(IslandLayout.indexAfterDeleting(islandAt: 2, count: 3) == 1)
        #expect(IslandLayout.indexAfterDeleting(islandAt: 0, count: 1) == nil)
    }

    @Test("A new island is named after somewhere, and skips names in use")
    func defaultNameSkips() {
        #expect(IslandLayout.defaultName(existing: ["Home"]) == "Driftwood")
        #expect(IslandLayout.defaultName(existing: ["Home", "Driftwood"]) == "Sandbar")
        // Renaming one back into the pool frees it again, rather than the list
        // marching on regardless of what is actually taken.
        #expect(IslandLayout.defaultName(existing: ["Home", "Sandbar"]) == "Driftwood")
    }

    /// Past the end of the coastline it has to keep working rather than start
    /// handing out a name someone already has.
    @Test("Running out of places falls back to counting, still without collisions")
    func defaultNameExhausted() {
        let all = ["Home"] + IslandLayout.placeNames
        #expect(IslandLayout.defaultName(existing: all) == "Island \(all.count + 1)")
        let awkward = all + ["Island \(all.count + 1)"]
        #expect(IslandLayout.defaultName(existing: awkward) == "Island \(awkward.count + 1)")
    }

    // MARK: - Orphans

    /// The net under an interrupted deletion. A store nothing claims is
    /// hundreds of megabytes of browsing that nothing will ever show again.
    @Test("Stores no island claims are reported as orphans")
    func orphansFound() {
        let kept = UUID(), dropped = UUID()
        let orphans = IslandLayout.orphanedDataStoreIDs(
            known: [.home(), island("Work", store: kept)],
            onDisk: [kept, dropped]
        )
        #expect(orphans == [dropped])
    }

    /// The dangerous direction: a store that *is* claimed must never be swept,
    /// and the home island claims none, so its absence from `onDisk` proves
    /// nothing.
    @Test("A claimed store is never swept, and duplicates report once")
    func claimedStoresSurvive() {
        let claimed = UUID()
        #expect(
            IslandLayout.orphanedDataStoreIDs(
                known: [island("Work", store: claimed)], onDisk: [claimed, claimed]
            ).isEmpty
        )
        let loose = UUID()
        #expect(
            IslandLayout.orphanedDataStoreIDs(known: [.home()], onDisk: [loose, loose])
                == [loose]
        )
    }
}
