import Foundation
import SurfCore
import Observation

/// Visited pages, held in memory for address-bar autocomplete.
///
/// Memory-only by default: it exists so typing "git" can offer github, and it
/// dies with the process. It only ever touches disk when the user has
/// explicitly turned "Remember browsing history" on.
@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// Keyed by URL so revisits update one entry instead of piling up.
    private var entries: [String: HistoryEntry] = [:]

    /// Enough for autocomplete to feel complete without unbounded growth in a
    /// long-running session.
    private let capacity = 2_000

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        SessionFile.url.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    private init() {
        loadIfPersisting()
    }

    // MARK: - Recording

    func record(url: URL, title: String) {
        // about:blank and friends aren't places you can return to.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        let key = url.absoluteString

        if var existing = entries[key] {
            existing.visitCount += 1
            existing.lastVisit = Date()
            if !title.isEmpty { existing.title = title }
            entries[key] = existing
        } else {
            entries[key] = HistoryEntry(url: key, title: title, lastVisit: Date())
            evictIfNeeded()
        }
        scheduleSaveIfPersisting()
    }

    /// Titles land after the page finishes loading, so they're filled in later.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, var existing = entries[url.absoluteString] else { return }
        existing.title = title
        entries[url.absoluteString] = existing
        scheduleSaveIfPersisting()
    }

    /// Drops the least useful entries once over capacity — oldest first, and
    /// among equally old ones, the least visited.
    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let excess = entries.count - capacity
        let doomed = entries.values
            .sorted { lhs, rhs in
                if lhs.lastVisit != rhs.lastVisit { return lhs.lastVisit < rhs.lastVisit }
                return lhs.visitCount < rhs.visitCount
            }
            .prefix(excess)
        for entry in doomed { entries.removeValue(forKey: entry.url) }
    }

    // MARK: - Query

    func suggestions(for query: String, limit: Int = 6) -> [HistoryEntry] {
        HistorySearch.rank(Array(entries.values), query: query, now: Date(), limit: limit)
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Optional persistence

    private func loadIfPersisting() {
        guard PrivacySettings.current.rememberHistory else {
            // The setting may have just been turned off — erase what an earlier
            // run wrote rather than leaving it behind.
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.url, $0) })
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
            try JSONEncoder().encode(Array(entries.values)).write(to: fileURL, options: .atomic)
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
