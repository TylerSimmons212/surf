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
}
