import Foundation

/// A site Focus has a lens built specifically for.
///
/// The article, recipe and video lenses read whatever page they are given.
/// A site lens is the other kind: it knows one site's own data and its own
/// player, and in exchange it can offer what a general reader cannot — a
/// chapter list, the site's search, its results as our grid.
///
/// One case today. The enum exists rather than a `isYouTube` bool because
/// the matching, the display name and the navigation rules are already three
/// things that belong together, and the second site should have somewhere to
/// go that isn't an `if` in a view.
public enum SiteFocusSite: String, CaseIterable, Sendable {
    case youtube
    case amazon

    /// The site this address belongs to, or nil when Focus has no lens for it.
    public static func matching(_ url: URL?) -> SiteFocusSite? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return allCases.first { $0.claims(host: host) }
    }

    /// Whether an address is still the same site — what keeps a site lens up
    /// across the navigations it makes itself, and drops it when a link
    /// leaves for somewhere else.
    public func claims(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return claims(host: host)
    }

    private func claims(host: String) -> Bool {
        switch self {
        case .youtube:
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            // m. is the same site in a smaller coat. music.youtube.com is a
            // different application wearing the same domain, and its lens
            // would be a different lens.
            return bare == "youtube.com" || bare == "m.youtube.com"
                || bare == "youtu.be"
        case .amazon:
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            // amazon.com and nothing else. The twenty-odd international
            // marketplaces run different markup, different currency and
            // localised availability text, none of which this lens has ever
            // been pointed at — and reading a price wrong is worse than
            // declining to offer. smile. and the media subdomains are not
            // storefronts at all.
            return bare == "amazon.com"
        }
    }

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .amazon: return "Amazon"
        }
    }
}

/// Which YouTube page an address is, and how to build the ones the lens
/// navigates to.
///
/// URL knowledge rather than DOM knowledge, so the lens can decide what it
/// is looking at before the page has finished loading — and so this is
/// testable without a web view.
public enum YouTubePage: Equatable, Sendable {
    /// The front page. The lens draws its search field over it and never the
    /// feed, which is the whole point of focusing YouTube.
    case home
    case search(query: String)
    case watch(id: String)
    /// A YouTube page with no lens of its own — a channel, a playlist, a
    /// short. The lens falls back to its search field rather than guessing.
    case other

    public static func of(_ url: URL?) -> YouTubePage {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .other }

        let host = (url.host()?.lowercased()).map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        } ?? ""
        let path = components.path
        let items = components.percentEncodedQueryItems ?? []
        func query(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value
            else { return nil }
            // YouTube form-encodes its queries: a space arrives as "+", and
            // percent-decoding alone leaves it there — a search for
            // "swift+concurrency" showing in our own field is the site's
            // encoding leaking into the interface. A real plus sign is
            // already "%2B" by the time it gets here, so it survives.
            return raw.replacingOccurrences(of: "+", with: "%20")
                .removingPercentEncoding ?? raw
        }

        // A youtu.be link is a video id wearing a path.
        if host == "youtu.be" {
            let id = String(path.dropFirst())
            return isValidVideoID(id) ? .watch(id: id) : .other
        }

        switch path {
        case "", "/":
            return .home
        case "/results":
            // A results page with no query is the search box, not a search.
            guard let text = query("search_query"), !text.isEmpty else { return .home }
            return .search(query: text)
        case "/watch":
            guard let id = query("v"), isValidVideoID(id) else { return .other }
            return .watch(id: id)
        default:
            return .other
        }
    }

    /// The address a search in the lens navigates to.
    ///
    /// A full navigation rather than driving the site's own search box: the
    /// results data the grid reads is published on load, so a fresh load is
    /// what makes it fresh. Playing a *second* video costs no navigation —
    /// the player swaps in place — so this is the only place the lens pays
    /// for a page load, once per search.
    public static func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Encoded by hand rather than through `queryItems`, which leaves a
        // literal "+" in the query — the one character whose meaning is
        // ambiguous here. Spaces go out as %20 and a real plus as %2B, so
        // the address this builds reads back as the query it was built from.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.percentEncodedQuery = "search_query=\(encoded)"
        return components.url
    }

    public static func watchURL(id: String) -> URL? {
        guard isValidVideoID(id) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// YouTube video ids are eleven characters of an unpadded base64 URL
    /// alphabet. Checked rather than trusted because an id goes straight
    /// into a URL and into `loadVideoById`, and a payload that hands us
    /// something else should lose its card, not build a broken address.
    public static func isValidVideoID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "_" || character == "-")
        }
    }

    /// The query behind a results page, for the lens's search field to show
    /// what it is currently showing results for.
    public var searchQuery: String? {
        if case .search(let query) = self { return query }
        return nil
    }

    public var videoID: String? {
        if case .watch(let id) = self { return id }
        return nil
    }
}
