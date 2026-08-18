import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisit: Date

    public var id: String { url }

    public init(url: String, title: String = "", visitCount: Int = 1, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }

    /// What the user actually typed to reach this before: no scheme, no "www.",
    /// no trailing slash. Both matching and display use it.
    public var displayURL: String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Ranks history entries against what the user is typing.
///
/// The ordering rule that matters: a prefix match on the address always beats a
/// match buried in the middle of a title, because typing "git" means "take me
/// to github", not "find pages about git".
public enum HistorySearch {

    /// Strength of the match itself, before recency and frequency adjust it.
    /// The gaps are wide so a strong match can't be overtaken by a weak match
    /// on a heavily-visited page.
    private enum MatchKind: Int {
        case addressPrefix = 1000
        case addressComponentPrefix = 700
        case addressContains = 400
        case titlePrefix = 300
        case titleContains = 150
    }

    public static func rank(
        _ entries: [HistoryEntry],
        query: String,
        now: Date,
        limit: Int = 6
    ) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let scored = entries.compactMap { entry -> (HistoryEntry, Int)? in
            guard let kind = matchKind(for: entry, needle: needle) else { return nil }
            return (entry, kind.rawValue + frecencyBonus(entry, now: now))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                // Stable, predictable tie-breaks: newer first, then alphabetical
                // so results don't shuffle between identical queries.
                if lhs.0.lastVisit != rhs.0.lastVisit { return lhs.0.lastVisit > rhs.0.lastVisit }
                return lhs.0.url < rhs.0.url
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func matchKind(for entry: HistoryEntry, needle: String) -> MatchKind? {
        let address = entry.displayURL.lowercased()
        let title = entry.title.lowercased()

        if address.hasPrefix(needle) { return .addressPrefix }

        // "docs" should match "swift.org/docs" — a prefix of any path or domain
        // segment counts, since that's how people recall URLs.
        if address.split(whereSeparator: { $0 == "/" || $0 == "." })
            .contains(where: { $0.hasPrefix(needle) }) {
            return .addressComponentPrefix
        }

        if address.contains(needle) { return .addressContains }
        if title.hasPrefix(needle) { return .titlePrefix }
        if title.contains(needle) { return .titleContains }
        return nil
    }

    /// Frequency plus recency. Capped so a single very popular page can't
    /// permanently outrank a better textual match.
    private static func frecencyBonus(_ entry: HistoryEntry, now: Date) -> Int {
        let frequency = min(entry.visitCount, 20) * 5

        let days = now.timeIntervalSince(entry.lastVisit) / 86_400
        let recency: Int
        switch days {
        case ..<1: recency = 50
        case ..<7: recency = 30
        case ..<30: recency = 15
        default: recency = 0
        }
        return frequency + recency
    }
}
