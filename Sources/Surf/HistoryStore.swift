import Foundation
import SurfCore
import Observation

/// Visited pages, held in memory for address-bar autocomplete.
///
/// Memory-only by default: it exists so typing "git" can offer github, and it
/// dies with the process. It only ever touches disk when the user has
/// explicitly turned "Remember browsing history" on.
///
/// One bucket per island, because the trail you leave in Work has no business
/// surfacing in Personal's address bar. Islands sharing a cookie jar still get
/// separate buckets: the jar is the one thing two islands may deliberately
/// share, and what you *did* in an island is the island's own. That is why the
/// key is `Island.id` and not `dataStoreID`, which is not unique.
///
/// Still a singleton, and still one file. The alternative — a store per island
/// — would mean N files, N debounce timers and a lifecycle to match the island
/// list, in exchange for nothing: the partition is a dictionary key.
@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// Island id, then url. Keyed by url within a bucket so revisits update one
    /// entry instead of piling up.
    private var buckets: [UUID: [String: HistoryEntry]] = [:]

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        SessionFile.url.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    /// Deliberately not loaded here.
    ///
    /// The file is keyed by island, and migrating the old flat shape needs to
    /// know which island is home — neither of which this type can discover on
    /// its own, and both of which `BrowserSession` knows the moment it has
    /// decoded its own file. So loading is a call rather than a side effect of
    /// first use, which also means it happens exactly once at a known moment
    /// instead of whenever something first touched the singleton.
    private init() {}

    // MARK: - Recording

    func record(url: URL, title: String, in island: UUID) {
        // about:blank and friends aren't places you can return to.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        let key = url.absoluteString
        var bucket = buckets[island] ?? [:]

        if var existing = bucket[key] {
            existing.visitCount += 1
            existing.lastVisit = Date()
            if !title.isEmpty { existing.title = title }
            bucket[key] = existing
        } else {
            bucket[key] = HistoryEntry(url: key, title: title, lastVisit: Date())
            for doomed in HistoryBudget.evictions(from: Array(bucket.values)) {
                bucket.removeValue(forKey: doomed)
            }
        }

        buckets[island] = bucket
        scheduleSaveIfPersisting()
    }

    /// Titles land after the page finishes loading, so they're filled in later.
    func updateTitle(_ title: String, for url: URL, in island: UUID) {
        guard !title.isEmpty,
              var existing = buckets[island]?[url.absoluteString]
        else { return }
        existing.title = title
        buckets[island]?[url.absoluteString] = existing
        scheduleSaveIfPersisting()
    }

    // MARK: - Query

    func suggestions(for query: String, in island: UUID, limit: Int = 6) -> [HistoryEntry] {
        HistorySearch.rank(
            Array((buckets[island] ?? [:]).values), query: query, now: Date(), limit: limit
        )
    }

    /// Everything, every island. The Settings button that calls this says
    /// "Clear Browsing Data Now" without qualification, and
    /// `BrowsingDataCleaner` already walks every island's store for the reason
    /// it documents: a promise kept only for the island you happened to be
    /// standing in is not a promise.
    func clear() {
        buckets.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drops one island's trail, when the island itself is deleted.
    ///
    /// Not scheduled — saved now. The island is going away in the same turn,
    /// and a debounce that lost the race would leave a deleted island's
    /// browsing in the file for the next launch to read back.
    func forget(island: UUID) {
        guard buckets.removeValue(forKey: island) != nil else { return }
        saveNow()
    }

    // MARK: - Optional persistence

    /// Reads the file, migrating the pre-island shape into `home`.
    ///
    /// `live` is the islands that actually exist, so a bucket belonging to one
    /// deleted while the app wasn't running is dropped rather than restored.
    func load(home: UUID, live: Set<UUID>) {
        guard PrivacySettings.current.rememberHistory else {
            // The setting may have just been turned off — erase what an earlier
            // run wrote rather than leaving it behind.
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedHistory.self, from: data)
        else { return }
        buckets = decoded.resolved(home: home, live: live)
    }

    private func scheduleSaveIfPersisting() {
        guard PrivacySettings.current.rememberHistory else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, PrivacySettings.current.rememberHistory else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard PrivacySettings.current.rememberHistory else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try JSONEncoder().encode(PersistedHistory(buckets: buckets))
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            fputs("[surf] history save failed: \(error)\n", stderr)
        }
    }

    /// Called when the preference is switched off, so turning it off erases the
    /// trail instead of merely freezing it.
    func handlePersistenceDisabled() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
