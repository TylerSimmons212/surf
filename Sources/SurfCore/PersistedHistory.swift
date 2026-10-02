import Foundation

/// Browsing history as written to disk: one bucket per island.
///
/// History is per-island for the same reason tabs and stickers are. The jar is
/// the one thing two islands may deliberately share; what you *did* in an
/// island is the island's own, so the trail you leave in Work must not surface
/// in Personal's address bar. Keyed on `Island.id` rather than on
/// `dataStoreID`, which is not unique — two islands sharing one jar are still
/// two islands, and would otherwise be indistinguishable here.
///
/// Written only when "Remember browsing history" is on. With it off, nothing
/// reaches this type at all and the file is deleted.
public struct PersistedHistory: Equatable, Sendable {

    public var islands: [UUID: [HistoryEntry]]

    /// Entries from a file written before history was per-island.
    ///
    /// That file is a bare JSON array with no islands in it, so there is
    /// nothing in the file itself that says where its entries belong. Only the
    /// caller knows which island is home — and home is the answer, because it
    /// is the only island that existed when the file was written. Carried
    /// separately rather than guessed at here, and read-time only: `resolved`
    /// files it, and `encode` never writes it.
    public var unfiled: [HistoryEntry]

    public init(islands: [UUID: [HistoryEntry]] = [:], unfiled: [HistoryEntry] = []) {
        self.islands = islands
        self.unfiled = unfiled
    }

    /// The buckets the store wants, keyed by url within each island.
    ///
    /// Three things happen here, each of which would otherwise be a quiet bug:
    ///
    /// * Legacy entries are filed under `home`. `home` is assumed to be in
    ///   `live`, which `IslandLayout.normalize` guarantees.
    /// * An island in the file that no longer exists is dropped. Its trail
    ///   went when it was deleted; this catches a file written before that.
    /// * Duplicate urls within one bucket keep the more recent visit. The
    ///   loader this replaces used `Dictionary(uniqueKeysWithValues:)`, which
    ///   **traps** on a duplicate — so a `history.json` with one repeated url,
    ///   however it came to be written, crashed Surf at launch.
    public func resolved(home: UUID, live: Set<UUID>) -> [UUID: [String: HistoryEntry]] {
        var result: [UUID: [String: HistoryEntry]] = [:]

        func file(_ entries: [HistoryEntry], under island: UUID) {
            var bucket = result[island] ?? [:]
            for entry in entries {
                if let existing = bucket[entry.url], existing.lastVisit >= entry.lastVisit {
                    continue
                }
                bucket[entry.url] = entry
            }
            result[island] = bucket
        }

        for (island, entries) in islands where live.contains(island) {
            file(entries, under: island)
        }
        if !unfiled.isEmpty { file(unfiled, under: home) }
        return result
    }

    /// Back from the store's buckets, for saving.
    public init(buckets: [UUID: [String: HistoryEntry]]) {
        self.islands = buckets.mapValues { Array($0.values) }
        self.unfiled = []
    }
}

// MARK: - Coding

extension PersistedHistory: Codable {

    private enum CodingKeys: String, CodingKey { case islands }

    /// Reads both shapes: the flat array this shipped as, and the keyed object
    /// it is now.
    ///
    /// Not dead weight — a `history.json` written before this change is a flat
    /// array, and failing to decode it would silently throw away whatever
    /// autocomplete had learned. Same approach `IslandTint.init(from:)` already
    /// takes for a field that changed shape, and the same job
    /// `PersistedSession.resolvedIslands` does for a pre-islands session.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let flat = try? container.decode([HistoryEntry].self) {
            self.init(islands: [:], unfiled: flat)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyed = try container.decodeIfPresent(
            [String: [HistoryEntry]].self, forKey: .islands
        ) ?? [:]
        // Keyed by `uuidString` rather than by `UUID`, which Swift would encode
        // as a flat array of alternating keys and values — valid JSON, and
        // unreadable by anybody looking at the file.
        self.init(
            islands: Dictionary(
                keyed.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                uniquingKeysWith: { $1 }
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var keyed: [String: [HistoryEntry]] = [:]
        for (island, entries) in islands { keyed[island.uuidString] = entries }
        try container.encode(keyed, forKey: .islands)
    }
}
