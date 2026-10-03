import Foundation
import Testing
@testable import SurfCore

@Suite("Per-island history on disk")
struct PersistedHistoryTests {

    private let home = UUID()
    private let work = UUID()

    private func entry(
        _ url: String, visits: Int = 1, at seconds: TimeInterval = 0
    ) -> HistoryEntry {
        HistoryEntry(
            url: url, title: "", visitCount: visits,
            lastVisit: Date(timeIntervalSince1970: seconds)
        )
    }

    private func decode(_ json: String) throws -> PersistedHistory {
        try JSONDecoder().decode(PersistedHistory.self, from: Data(json.utf8))
    }

    // MARK: - Migration

    /// The shape shipped before history was per-island: a bare array, with
    /// nothing in the file saying where its entries belong. They belong to
    /// home, because home is the only island that existed when it was written.
    @Test("A file written before islands lands in the home island")
    func legacyFlatArrayMigrates() throws {
        let decoded = try decode("""
        [{"url":"https://a.com","title":"A","visitCount":3,"lastVisit":0}]
        """)

        #expect(decoded.islands.isEmpty)
        #expect(decoded.unfiled.count == 1)

        let buckets = decoded.resolved(home: home, live: [home, work])
        #expect(buckets[home]?.count == 1)
        #expect(buckets[home]?["https://a.com"]?.visitCount == 3)
        #expect(buckets[work] == nil)
    }

    @Test("The keyed shape round-trips")
    func keyedRoundTrips() throws {
        let original = PersistedHistory(islands: [
            home: [entry("https://a.com")],
            work: [entry("https://b.com"), entry("https://c.com")],
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedHistory.self, from: data)

        #expect(decoded.islands[home]?.count == 1)
        #expect(decoded.islands[work]?.count == 2)
        #expect(decoded.unfiled.isEmpty)
    }

    /// Keyed by `uuidString`, not by `UUID` — which Swift would encode as a
    /// flat array of alternating keys and values: valid JSON that nobody
    /// reading the file could make sense of.
    @Test("Islands are written under readable keys")
    func keysAreReadable() throws {
        let data = try JSONEncoder().encode(
            PersistedHistory(islands: [home: [entry("https://a.com")]])
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains(home.uuidString))
    }

    // MARK: - The crash this replaces

    /// The loader this replaces built its dictionary with
    /// `Dictionary(uniqueKeysWithValues:)`, which **traps** on a duplicate key.
    /// So a `history.json` carrying one repeated url — however it came to be
    /// written — took Surf down at launch, before a window appeared.
    @Test("A duplicate url does not trap, and the later visit wins")
    func duplicateUrlsSurvive() throws {
        let decoded = try decode("""
        {"islands":{"\(home.uuidString)":[
          {"url":"https://a.com","title":"old","visitCount":1,"lastVisit":0},
          {"url":"https://a.com","title":"new","visitCount":9,"lastVisit":500}
        ]}}
        """)

        let buckets = decoded.resolved(home: home, live: [home])
        #expect(buckets[home]?.count == 1)
        #expect(buckets[home]?["https://a.com"]?.title == "new")
        #expect(buckets[home]?["https://a.com"]?.visitCount == 9)
    }

    @Test("Order does not decide which duplicate wins — recency does")
    func duplicateOrderIrrelevant() throws {
        let decoded = try decode("""
        {"islands":{"\(home.uuidString)":[
          {"url":"https://a.com","title":"new","visitCount":9,"lastVisit":500},
          {"url":"https://a.com","title":"old","visitCount":1,"lastVisit":0}
        ]}}
        """)

        #expect(decoded.resolved(home: home, live: [home])[home]?["https://a.com"]?.title == "new")
    }

    // MARK: - Islands that are gone

    /// `deleteIsland` forgets its trail as it goes, so this is the file written
    /// before that — or by a run that died mid-delete.
    @Test("A bucket for an island that no longer exists is dropped")
    func deadIslandsDropped() throws {
        let ghost = UUID()
        let decoded = try decode("""
        {"islands":{
          "\(home.uuidString)":[{"url":"https://a.com","title":"","visitCount":1,"lastVisit":0}],
          "\(ghost.uuidString)":[{"url":"https://x.com","title":"","visitCount":1,"lastVisit":0}]
        }}
        """)

        let buckets = decoded.resolved(home: home, live: [home])
        #expect(buckets.keys.count == 1)
        #expect(buckets[ghost] == nil)
    }

    @Test("An unparseable island key is ignored rather than fatal")
    func badKeyIgnored() throws {
        let decoded = try decode("""
        {"islands":{"not-a-uuid":[{"url":"https://a.com","title":"","visitCount":1,"lastVisit":0}]}}
        """)

        #expect(decoded.islands.isEmpty)
    }

    // MARK: - Edges

    @Test("An empty or absent islands key decodes to nothing")
    func emptyDecodes() throws {
        #expect(try decode("{}").islands.isEmpty)
        #expect(try decode("{\"islands\":{}}").islands.isEmpty)
        #expect(try decode("[]").unfiled.isEmpty)
    }

    @Test("Buckets convert back for saving")
    func fromBuckets() {
        let persisted = PersistedHistory(buckets: [
            home: ["https://a.com": entry("https://a.com")],
        ])

        #expect(persisted.islands[home]?.count == 1)
        #expect(persisted.unfiled.isEmpty)
    }
}

@Suite("History budget")
struct HistoryBudgetTests {

    private func entry(_ url: String, visits: Int, at seconds: TimeInterval) -> HistoryEntry {
        HistoryEntry(
            url: url, title: "", visitCount: visits,
            lastVisit: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Under capacity, nothing is evicted")
    func underCapacity() {
        let entries = (0..<5).map { entry("https://\($0).com", visits: 1, at: TimeInterval($0)) }
        #expect(HistoryBudget.evictions(from: entries, capacity: 10).isEmpty)
        #expect(HistoryBudget.evictions(from: entries, capacity: 5).isEmpty)
    }

    @Test("Over capacity, the oldest go first and only the excess goes")
    func oldestFirst() {
        let entries = [
            entry("https://new.com", visits: 1, at: 300),
            entry("https://old.com", visits: 1, at: 100),
            entry("https://mid.com", visits: 1, at: 200),
        ]
        let doomed = HistoryBudget.evictions(from: entries, capacity: 2)

        #expect(doomed == ["https://old.com"])
    }

    /// Among equally old entries, the one you went to least.
    @Test("Ties on age break on visit count")
    func tiesBreakOnVisits() {
        let entries = [
            entry("https://often.com", visits: 10, at: 100),
            entry("https://rarely.com", visits: 1, at: 100),
            entry("https://new.com", visits: 1, at: 900),
        ]

        #expect(HistoryBudget.evictions(from: entries, capacity: 2) == ["https://rarely.com"])
    }

    @Test("A capacity of zero evicts everything")
    func zeroCapacity() {
        let entries = [entry("https://a.com", visits: 1, at: 0)]
        #expect(HistoryBudget.evictions(from: entries, capacity: 0).count == 1)
    }

    /// Per island rather than shared, so one island's browsing can never evict
    /// another's — which would make an island's address bar depend on browsing
    /// done somewhere it cannot see.
    @Test("The shipped capacity is per island")
    func shippedCapacity() {
        #expect(HistoryBudget.capacity == 2_000)
    }
}
