import Foundation
import Testing
@testable import GlassCore

@Suite("History autocomplete")
struct HistorySearchTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        _ url: String,
        title: String = "",
        visits: Int = 1,
        daysAgo: Double = 0
    ) -> HistoryEntry {
        HistoryEntry(
            url: url,
            title: title,
            visitCount: visits,
            lastVisit: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    private func urls(_ results: [HistoryEntry]) -> [String] {
        results.map(\.url)
    }

    // MARK: - Display normalisation

    @Test("Display URL strips scheme, www, and trailing slash")
    func displayURL() {
        #expect(entry("https://www.github.com/").displayURL == "github.com")
        #expect(entry("http://example.com/path").displayURL == "example.com/path")
        #expect(entry("https://docs.swift.org").displayURL == "docs.swift.org")
    }

    // MARK: - Matching

    @Test("Empty query returns nothing")
    func emptyQuery() {
        #expect(HistorySearch.rank([entry("https://a.com")], query: "", now: now).isEmpty)
        #expect(HistorySearch.rank([entry("https://a.com")], query: "   ", now: now).isEmpty)
    }

    @Test("Typing a prefix finds the site despite the scheme and www")
    func prefixIgnoresSchemeAndWWW() {
        let results = HistorySearch.rank([entry("https://www.github.com")], query: "git", now: now)
        #expect(urls(results) == ["https://www.github.com"])
    }

    @Test("An address prefix outranks a title match on a more popular page")
    func addressPrefixWins() {
        let entries = [
            entry("https://example.com/blog", title: "All about git", visits: 20, daysAgo: 0),
            entry("https://github.com", title: "GitHub", visits: 1, daysAgo: 20),
        ]
        let results = HistorySearch.rank(entries, query: "git", now: now)
        #expect(results.first?.url == "https://github.com")
    }

    @Test("A path or domain segment prefix matches")
    func componentPrefix() {
        let entries = [entry("https://swift.org/documentation")]
        #expect(!HistorySearch.rank(entries, query: "doc", now: now).isEmpty)

        let subdomain = [entry("https://docs.swift.org")]
        #expect(!HistorySearch.rank(subdomain, query: "swift", now: now).isEmpty)
    }

    @Test("Titles are searchable too")
    func titleMatch() {
        let entries = [entry("https://a.com/x1y2", title: "Swift Concurrency Guide")]
        #expect(!HistorySearch.rank(entries, query: "concurrency", now: now).isEmpty)
    }

    @Test("Matching is case-insensitive both ways")
    func caseInsensitive() {
        let entries = [entry("https://GitHub.com", title: "GitHub")]
        #expect(!HistorySearch.rank(entries, query: "github", now: now).isEmpty)
        #expect(!HistorySearch.rank(entries, query: "GITHUB", now: now).isEmpty)
    }

    @Test("Non-matches are excluded entirely")
    func noMatch() {
        let entries = [entry("https://apple.com", title: "Apple")]
        #expect(HistorySearch.rank(entries, query: "zzzz", now: now).isEmpty)
    }

    // MARK: - Ranking

    @Test("With equal match strength, more visits wins")
    func frequencyBreaksTies() {
        let entries = [
            entry("https://a.com", visits: 1, daysAgo: 0),
            entry("https://a.co", visits: 15, daysAgo: 0),
        ]
        let results = HistorySearch.rank(entries, query: "a.c", now: now)
        #expect(results.first?.url == "https://a.co")
    }

    @Test("With equal visits, more recent wins")
    func recencyBreaksTies() {
        let entries = [
            entry("https://a.com/old", visits: 3, daysAgo: 60),
            entry("https://a.com/new", visits: 3, daysAgo: 0),
        ]
        let results = HistorySearch.rank(entries, query: "a.com", now: now)
        #expect(results.first?.url == "https://a.com/new")
    }

    @Test("A hugely popular page can't outrank a much stronger match")
    func frecencyIsCapped() {
        let entries = [
            entry("https://news.com", title: "docs everywhere", visits: 10_000, daysAgo: 0),
            entry("https://docs.com", visits: 1, daysAgo: 90),
        ]
        let results = HistorySearch.rank(entries, query: "docs", now: now)
        #expect(results.first?.url == "https://docs.com")
    }

    @Test("Results are capped at the limit")
    func respectsLimit() {
        let entries = (0..<20).map { entry("https://site\($0).com") }
        #expect(HistorySearch.rank(entries, query: "site", now: now, limit: 4).count == 4)
    }

    @Test("Identical queries return a stable order")
    func stableOrdering() {
        let entries = [
            entry("https://b.com", visits: 2, daysAgo: 1),
            entry("https://a.com", visits: 2, daysAgo: 1),
        ]
        let first = urls(HistorySearch.rank(entries, query: ".com", now: now))
        let second = urls(HistorySearch.rank(entries.reversed(), query: ".com", now: now))
        #expect(first == second)
    }
}
