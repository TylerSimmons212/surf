import Foundation

/// Turns whatever the user typed into something loadable.
///
/// The whole job is one ambiguous question: is this an address or a search? The
/// rules below are ordered most-certain to least, and anything that falls
/// through becomes a search — the safe default, since a failed search is a page
/// of results while a failed navigation is an error screen.
public enum URLResolver {

    public enum SearchEngine: String, CaseIterable, Sendable {
        case google, duckDuckGo

        public var queryTemplate: String {
            switch self {
            case .google: "https://www.google.com/search?q="
            case .duckDuckGo: "https://duckduckgo.com/?q="
            }
        }
    }

    public static func resolve(_ input: String, using engine: SearchEngine = .duckDuckGo) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. An explicit scheme means the user told us exactly what they want.
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if ["http", "https", "file", "about"].contains(scheme) {
                return url
            }
        }

        // 2. Whitespace anywhere is the strongest search signal there is —
        //    check before the host heuristics so "apple pie recipe" can't be
        //    mistaken for a hostname.
        if text.contains(where: \.isWhitespace) {
            return searchURL(for: text, using: engine)
        }

        // 3. localhost, with or without a port, is a host even though it has no dot.
        if text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/") {
            return URL(string: "http://\(text)")
        }

        // 4. A dotted, single-token string with a plausible TLD is an address.
        if looksLikeHost(text) {
            return URL(string: "https://\(text)")
        }

        return searchURL(for: text, using: engine)
    }

    /// A bare token like "example.com" or "docs.swift.org/guide".
    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)

        // Need at least name + TLD, and no empty labels ("foo..com", ".com", "foo.").
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }

        // A trailing all-alphabetic label of 2+ chars is the TLD test. This
        // deliberately rejects "3.14" and version strings like "swift.6.4".
        guard let tld = labels.last,
              tld.count >= 2,
              tld.allSatisfy(\.isLetter)
        else { return false }

        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_"))
        return host.unicodeScalars.allSatisfy(hostCharacters.contains)
    }

    private static func searchURL(for query: String, using engine: SearchEngine) -> URL? {
        // .urlQueryAllowed permits "&" and "+", which would corrupt the query
        // string, so those are removed from the allowed set.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: engine.queryTemplate + encoded)
    }
}
