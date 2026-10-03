import Foundation
import Testing
@testable import SurfCore

@Suite("Island layout")
struct IslandLayoutTests {

    private func island(
        _ name: String,
        store: UUID? = UUID(),
        id: UUID = UUID(),
        isHome: Bool? = false
    ) -> PersistedIsland {
        PersistedIsland(
            id: id, name: name, symbol: "🌊", tint: .surf,
            dataStoreID: store, isHomeIsland: isHome
        )
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

    /// Only one island came first, and only one is undeletable. A second
    /// claimant is demoted rather than dropped: it may well be a workspace the
    /// user made from home, and deleting somebody's islands to repair a field
    /// they never saw is the worse of the two failures by a distance.
    @Test("A second home island is demoted, not dropped")
    func duplicateHomeDemoted() {
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Work"), .home()], selected: 0
        )
        #expect(islands.filter(\.isHome).count == 1)
        #expect(islands.count == 3)
        // Demoted, not re-homed onto a fresh jar: it keeps browsing the default
        // store, which is where its logins actually are.
        #expect(islands.last?.dataStoreID == nil)
        #expect(islands.last?.isHome == false)
    }

    /// Two islands pointed at one store used to be dropped on sight. It is now
    /// how "keep my logins" is spelled, so it has to survive a decode intact —
    /// dropping one here would delete a workspace at launch.
    @Test("Islands sharing a data store are both kept")
    func sharedStoreSurvives() {
        let shared = UUID()
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Work", store: shared), island("Work Desk", store: shared)],
            selected: 0
        )
        #expect(islands.count == 3)
        #expect(islands.map(\.name) == ["Home", "Work", "Work Desk"])
    }

    /// The same shape one level up: an island sharing *home's* jar is an
    /// ordinary island that happens to browse the default store.
    @Test("An island sharing home's store is kept and is not home")
    func sharedDefaultStoreSurvives() {
        let (islands, _) = IslandLayout.normalize(
            [.home(), island("Second Desk", store: nil)], selected: 1
        )
        #expect(islands.count == 2)
        #expect(islands.filter(\.isHome).count == 1)
        #expect(islands.last?.isHome == false)
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
        let twin = UUID()
        let (islands, selected) = IslandLayout.normalize(
            [.home(), island("A", id: twin), island("B", id: twin), island("C")],
            selected: 3
        )
        #expect(islands[selected].name == "C")
    }

    /// If the selected island was itself dropped there is nothing to follow, so
    /// it falls back rather than pointing past the end.
    @Test("A dropped selection falls back to the first island")
    func droppedSelectionFallsBack() {
        let twin = UUID()
        let (islands, selected) = IslandLayout.normalize(
            [.home(), island("A", id: twin), island("B", id: twin)],
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

    // MARK: - Sharing a jar

    /// The guard that makes sharing safe to offer. Erasing a store somebody
    /// else is still browsing with signs them out in the direction nobody
    /// checks, with no undo.
    @Test("A store another island still claims is never erased")
    func sharedStoreIsNotErased() {
        let mine = UUID(), theirs = UUID()
        // Nothing else points at it: erasing is the whole point of deleting.
        #expect(IslandLayout.storeIsShared(mine, claimedBy: [theirs, nil]) == false)
        #expect(IslandLayout.storeIsShared(mine, claimedBy: []) == false)
        // Somebody else does.
        #expect(IslandLayout.storeIsShared(mine, claimedBy: [theirs, mine]))
    }

    /// The default store predates islands and holds every cookie from before
    /// the feature existed. It is never ours to erase, however few islands are
    /// left pointing at it — including none.
    @Test("The default store is never erasable")
    func defaultStoreIsNeverErased() {
        #expect(IslandLayout.storeIsShared(nil, claimedBy: []))
        #expect(IslandLayout.storeIsShared(nil, claimedBy: [UUID()]))
    }

    /// This sentence appears in a destructive dialog, telling someone their
    /// logins are safe. It has to read as English at every length.
    @Test("Shared islands are listed the way a sentence reads them")
    func namesReadAsProse() {
        #expect(IslandLayout.nameList([]).isEmpty)
        #expect(IslandLayout.nameList(["Home"]) == "Home")
        #expect(IslandLayout.nameList(["Home", "Work"]) == "Home and Work")
        #expect(IslandLayout.nameList(["Home", "Work", "Play"]) == "Home, Work and Play")
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
    /// Two islands, one store, and the store is claimed twice over — a sweep
    /// that counted claimants rather than sets would erase it on the second
    /// pass and sign both islands out.
    @Test("A store two islands share is not an orphan")
    func sharedStoresAreNotOrphans() {
        let shared = UUID()
        #expect(
            IslandLayout.orphanedDataStoreIDs(
                known: [island("Work", store: shared), island("Desk", store: shared)],
                onDisk: [shared]
            ).isEmpty
        )
    }

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

    // MARK: - What an island shares

    /// The sentence the island menu's header is for. It appears directly under
    /// the island's name every time the menu opens, so it has to be true and
    /// readable at none, one and several sharers.
    @Test("An island sharing nothing says so without naming anyone")
    func sharingLineAlone() {
        #expect(IslandLayout.sharingLine(with: []) == "Signed in on its own")
    }

    @Test("An island sharing a jar names who with")
    func sharingLineNamed() {
        #expect(IslandLayout.sharingLine(with: ["Personal"]) == "Shares logins with Personal")
        #expect(
            IslandLayout.sharingLine(with: ["Home", "Work", "Play"])
                == "Shares logins with Home, Work and Play"
        )
    }
}
