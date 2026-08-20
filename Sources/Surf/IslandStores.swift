import Foundation
import SurfCore
import WebKit

/// The one place a `WKWebsiteDataStore` is ever constructed.
///
/// Each island keeps its own cookies, local storage, IndexedDB and service
/// workers, which WebKit models as a data store keyed by a UUID. The rule that
/// makes the whole feature work is that **an identifier maps to exactly one
/// live object**: `WKWebsiteDataStore(forIdentifier:)` hands back a *new*
/// instance on every call, and two instances over one directory are two
/// independent network sessions — stale cookie reads, a doubled networking
/// process, and writes landing in whichever one flushed last. That failure is
/// invisible until someone notices a login that works in one tab and not the
/// tab beside it, so construction is funnelled through here and memoised, and
/// this file is the only place in the app that names the initialiser.
///
/// Stores are also retained for the life of the process on purpose. Releasing
/// one while a web view still references it is not safe, and a tab can be
/// asleep — holding no web view at all — while its store still owes WebKit a
/// flush.
@MainActor
final class IslandStores {

    static let shared = IslandStores()

    private init() {}

    private var stores: [UUID: WKWebsiteDataStore] = [:]

    /// Identifiers that failed to produce a persistent store this run, so the
    /// UI can say so rather than quietly forgetting the user every launch.
    private(set) var degraded: Set<UUID> = []

    /// The store for an island.
    ///
    /// `nil` means the shared default store — the island the browser started
    /// life as, whose cookies predate this feature. Keeping it as `.default()`
    /// rather than migrating it to an identifier is what lets Islands ship
    /// without signing the user out of everything: there is no supported way to
    /// move cookies between stores.
    func store(forIdentifier identifier: UUID?) -> WKWebsiteDataStore {
        guard let identifier else { return .default() }
        if let existing = stores[identifier] { return existing }

        // An all-zeros identifier raises an Objective-C exception rather than
        // returning nil, which would take the app down rather than the island.
        guard IslandLayout.isValidDataStoreIdentifier(identifier) else {
            return degradedStore(for: identifier)
        }

        let store = WKWebsiteDataStore(forIdentifier: identifier)
        stores[identifier] = store
        return store
    }

    /// The fallback is deliberately *not* `.default()`.
    ///
    /// Falling back to the shared store would silently merge two identities —
    /// precisely the thing islands exist to prevent, and the user would have no
    /// way to tell it had happened. A non-persistent store degrades to "this
    /// island forgets you when you quit", which is wrong but visible.
    private func degradedStore(for identifier: UUID) -> WKWebsiteDataStore {
        degraded.insert(identifier)
        let store = WKWebsiteDataStore.nonPersistent()
        stores[identifier] = store
        return store
    }

    func isDegraded(_ identifier: UUID?) -> Bool {
        guard let identifier else { return false }
        return degraded.contains(identifier)
    }

    /// Drops the memoised instance without touching what's on disk.
    ///
    /// Deletion needs this: `WKWebsiteDataStore.remove(forIdentifier:)` fails
    /// while anything still references the store, and a forgotten memo here is
    /// a reference.
    func discard(_ identifier: UUID) {
        stores.removeValue(forKey: identifier)
        degraded.remove(identifier)
    }

    /// Identifiers the user has deleted but WebKit hasn't let go of yet.
    ///
    /// `remove(forIdentifier:)` fails while *anything* still references the
    /// store, and tearing down a tab is asynchronous — `releaseWebView` pauses
    /// media, closes presentations and loads `about:blank` before the view goes
    /// — so the first attempt after a delete routinely lands while the web
    /// views are still dying. Measured, not assumed: deleting an island and
    /// asking WebKit ten seconds later still listed the identifier.
    ///
    /// Hence a tombstone that outlives the process. The retry loop below
    /// usually wins; when it doesn't, the next launch does, before anything has
    /// had a chance to reference the store at all.
    ///
    /// Deliberately a list of *intended deletions* rather than a sweep of
    /// unclaimed stores. A sweep needs a trustworthy island list, and there is
    /// one case where we don't have one: with "reopen tabs on launch" off the
    /// session file isn't even read, so every island would look unclaimed and a
    /// sweep would erase all of them. A tombstone can only ever delete
    /// something the user asked to delete.
    private static let tombstoneKey = "islandStoresPendingDeletion"

    private var tombstones: [UUID] {
        get {
            (UserDefaults.standard.array(forKey: Self.tombstoneKey) as? [String] ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(
                newValue.map(\.uuidString), forKey: Self.tombstoneKey
            )
        }
    }

    /// Marks a store as unwanted unless something claims it before the next
    /// launch — the disk half of a provisional island.
    ///
    /// An island being created has a store from its first blank tab onward, so
    /// abandoning it by crashing leaves a directory behind that nothing will
    /// ever name again. Written down *before* it can be abandoned, because the
    /// whole problem with a crash is that it doesn't stop to tidy up.
    func tombstone(_ identifier: UUID) {
        if !tombstones.contains(identifier) { tombstones.append(identifier) }
    }

    /// Takes a store back off the list: something owns it now.
    ///
    /// Ordered deliberately at the call site — a store is claimed *before* the
    /// island naming it is written, never after. The two orderings fail in
    /// opposite directions and only one of them is survivable: claim-then-crash
    /// leaves an unclaimed store, which is a few empty kilobytes, while
    /// write-then-crash leaves an island whose logins get erased at the next
    /// launch.
    func claim(_ identifier: UUID) {
        tombstones.removeAll { $0 == identifier }
    }

    /// Erases an island's storage from disk, and keeps trying until it does.
    func removeData(for identifier: UUID) async {
        if !tombstones.contains(identifier) { tombstones.append(identifier) }
        discard(identifier)

        // Backing off rather than hammering: what we're waiting for is other
        // references being released, which takes as long as it takes.
        for delay in [0.0, 0.4, 1.0, 2.0, 4.0] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                tombstones.removeAll { $0 == identifier }
                return
            } catch {
                debugLog("island store removal deferred: \(error)")
            }
        }
        debugLog("island store \(identifier) left tombstoned for next launch")
    }

    /// Finishes deletions a previous run couldn't.
    ///
    /// Called at launch, before any island has built a web view — which is
    /// exactly why it succeeds where the live attempt failed: nothing is
    /// holding the store yet.
    /// `claimed` is the stores the restored islands actually name, and nothing
    /// in it is ever erased however it came to be listed here. A tombstone is a
    /// record of intent, and intent can be stale: the launch that wrote one may
    /// have died before it could record that the store had been claimed after
    /// all. Erasing on the strength of a list alone would sign somebody out of
    /// an island sitting right there in their sidebar.
    func collectTombstones(sparing claimed: Set<UUID> = []) async {
        let pending = tombstones.filter { !claimed.contains($0) }
        tombstones = pending
        guard !pending.isEmpty else { return }
        let onDisk = Set(await Self.identifiersOnDisk())
        var remaining: [UUID] = []
        for identifier in pending {
            // Already gone: the deletion did land, we just never got to record
            // it before the process ended.
            guard onDisk.contains(identifier) else { continue }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            } catch {
                debugLog("tombstoned store \(identifier) still refusing: \(error)")
                remaining.append(identifier)
            }
        }
        tombstones = remaining
    }

    /// Every store the user has data in, whether or not an island has opened
    /// one this run.
    ///
    /// Enumerated from disk rather than from the session's islands, and that
    /// distinction is the whole point: a background island you haven't visited
    /// since launch has never built a web view, so its store was never
    /// instantiated — and a "clear everything on quit" that only walked live
    /// stores would quietly spare exactly the islands you use least.
    ///
    /// Instantiating a store in order to erase it is not wasteful here. It's
    /// the only way to ask WebKit to remove data from one.
    func allStores() async -> [WKWebsiteDataStore] {
        var stores: [WKWebsiteDataStore] = [.default()]
        for identifier in await Self.identifiersOnDisk() {
            stores.append(store(forIdentifier: identifier))
        }
        return stores
    }

    /// Every identifier WebKit is holding storage for.
    ///
    /// Completion-handler only — there is no async spelling of this one, so the
    /// bridge lives here rather than at each call site.
    static func identifiersOnDisk() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
    }
}
