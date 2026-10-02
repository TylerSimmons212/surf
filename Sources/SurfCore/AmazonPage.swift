import Foundation

/// Which Amazon page an address is, and how to build the ones the lens
/// navigates to.
///
/// URL knowledge rather than DOM knowledge, the same bet `YouTubePage` makes —
/// with one correction that Amazon forces. YouTube's comment says the lens can
/// "decide what it is looking at before the page has finished loading," and for
/// YouTube that holds. It does not hold here: Amazon serves its bot check at
/// the URL you asked for, with a 200-shaped body, so a `/s?k=…` address can be
/// a search page or a wall of distorted characters and this type cannot tell
/// the difference.
///
/// So what this produces is an *expectation*, not a verdict. The lens records
/// it, reads the page, and hands both to `AmazonReconcile`, which is where the
/// question actually gets answered.
public enum AmazonPage: Equatable, Sendable {
    /// The front page. The lens draws its search field over it and never the
    /// feed — Amazon's own home is four thousand pixels of carousels.
    case home
    case search(query: String)
    case product(asin: String)
    case cart
    /// Sign-in and order history: real pages behind a password that the lens
    /// hands back rather than reimplementing.
    case signIn
    case orders
    /// An Amazon page with no lens of its own — a storefront, a department, a
    /// deals page. The lens falls back to its search field rather than
    /// guessing.
    case other

    public static func of(_ url: URL?) -> AmazonPage {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .other }

        let path = components.path
        let lower = path.lowercased()
        let items = components.percentEncodedQueryItems ?? []

        func query(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value
            else { return nil }
            // Amazon form-encodes its queries exactly as YouTube does: a space
            // arrives as "+", and percent-decoding alone leaves it there — a
            // search for "usb+c+cable" showing in our own field is the site's
            // encoding leaking into the interface. A real plus is already
            // "%2B" by the time it gets here, so it survives.
            return raw.replacingOccurrences(of: "+", with: "%20")
                .removingPercentEncoding ?? raw
        }

        // Order matters below: sign-in and the cart are checked before the
        // product match, because Amazon interposes them on paths that still
        // carry a /dp/ segment.
        if lower.hasPrefix("/ap/signin") || lower.hasPrefix("/ap/") {
            return .signIn
        }
        if lower.contains("/order-history") || lower.hasPrefix("/gp/css/order")
            || lower.hasPrefix("/gp/your-account/order") {
            return .orders
        }
        // The readable cart only.
        //
        // `/cart/smart-wagon` is not it: Amazon sends you there straight after
        // an add, and it is a confirmation screen carrying recommendations
        // rather than a cart. It holds none of the `.sc-list-item` rows the
        // sidebar reads, so treating it as the cart meant opening the sidebar
        // right after adding something and being told the cart was empty —
        // while the badge beside it said three.
        //
        // So the prefix match is gone and the paths are named. Anything else
        // under `/cart/` is some interstitial we have not met, and `.other`
        // sends the lens to the real cart rather than reading a stranger.
        if lower.hasPrefix("/gp/cart") || lower == "/cart" || lower == "/cart/"
            || lower == "/cart/view" || lower == "/cart/view.html" {
            return .cart
        }

        // A product id can sit anywhere in the path, because Amazon prefixes
        // it with a slug: /Anker-USB-C-Cable/dp/B088NRLMPV/ref=sr_1_6.
        if let asin = productID(inPath: path) {
            return .product(asin: asin)
        }

        switch lower {
        case "", "/":
            return .home
        case "/s", "/s/":
            // A results page with no query is the search box, not a search.
            // Amazon spells the parameter "k" today and "field-keywords" in
            // its older links, and both still resolve.
            let text = query("k") ?? query("field-keywords") ?? ""
            return text.isEmpty ? .home : .search(query: text)
        default:
            return .other
        }
    }

    /// The product id in a path, if there is one.
    ///
    /// Looks for the segment *after* one of Amazon's product markers rather
    /// than scanning for anything ASIN-shaped, because a slug can contain a
    /// ten-character uppercase word and picking that up would build an
    /// address to nothing.
    static func productID(inPath path: String) -> String? {
        let segments = path.split(separator: "/").map(String.init)
        let markers: Set<String> = ["dp", "gp/product", "product", "gp/aw/d", "d"]
        for (index, segment) in segments.enumerated() {
            guard markers.contains(segment.lowercased()) else { continue }
            // "/gp/product/B0…" reads as two segments here, so the id is
            // simply whatever follows the marker.
            guard index + 1 < segments.count else { continue }
            let candidate = segments[index + 1].uppercased()
            if isValidASIN(candidate) { return candidate }
        }
        return nil
    }

    /// The address a search in the lens navigates to.
    ///
    /// A full navigation rather than driving the site's own search box, for
    /// the same reason the YouTube lens does it: the results are published
    /// with the document, so a fresh load is what makes them fresh.
    public static func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Encoded by hand rather than through `queryItems`, which leaves a
        // literal "+" in the query — the one character whose meaning is
        // ambiguous here. Spaces go out as %20 and a real plus as %2B, so the
        // address this builds reads back as the query it was built from.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.amazon.com"
        components.path = "/s"
        components.percentEncodedQuery = "k=\(encoded)"
        return components.url
    }

    public static func productURL(asin: String) -> URL? {
        let id = asin.uppercased()
        guard isValidASIN(id) else { return nil }
        return URL(string: "https://www.amazon.com/dp/\(id)")
    }

    /// Whether this address is the cart. The one question a cart write has to
    /// answer before it presses anything.
    public var isCart: Bool { self == .cart }

    public static var cartURL: URL? {
        URL(string: "https://www.amazon.com/gp/cart/view.html")
    }

    /// Amazon product ids are ten characters of uppercase alphanumerics.
    ///
    /// Checked rather than trusted for the same reason `isValidVideoID` is: an
    /// id read out of a page goes straight into a URL, and a payload that
    /// hands us something else should lose its card rather than build an
    /// address to nowhere.
    ///
    /// Deliberately not "starts with B0" — books keep their ISBN as an ASIN,
    /// so `0439708184` is as real an id as `B088NRLMPV`.
    public static func isValidASIN(_ id: String) -> Bool {
        guard id.count == 10 else { return false }
        return id.allSatisfy { character in
            character.isASCII
                && (character.isNumber
                    || (character.isLetter && character.isUppercase))
        }
    }

    /// The query behind a results page, for the lens's field to show what the
    /// grid is currently showing results for.
    public var searchQuery: String? {
        if case .search(let query) = self { return query }
        return nil
    }

    public var productASIN: String? {
        if case .product(let asin) = self { return asin }
        return nil
    }

    /// Whether this page is one the lens should get out of the way for.
    /// Sign-in and order history are password-shaped, and framing them in our
    /// own chrome is the one thing this feature must never do.
    public var demandsTheRealSite: Bool {
        switch self {
        case .signIn, .orders: return true
        case .home, .search, .product, .cart, .other: return false
        }
    }
}
