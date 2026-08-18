import Foundation

/// Reducing a hostname to the thing a person would call "the site".
///
/// Two questions run through the whole blocker and both are this one wearing
/// different clothes: is this request going somewhere other than the site I'm
/// looking at, and which rows of the list belong together. Both need the
/// registrable domain — `googlesyndication.com` for `pagead2.googlesyndication.com` —
/// rather than the host as sent.
public enum DomainName {

    /// Suffixes under which registrations happen, so the registrable domain is
    /// three labels rather than two.
    ///
    /// Not the public suffix list. That is ~9,000 entries updated continuously,
    /// and carrying a stale copy of it would be worse than carrying an
    /// approximation that is obviously an approximation. What this table has to
    /// get right is the common case, because the cost of being wrong is a
    /// blocked-list row grouped one label too coarsely — `bbc.co.uk` shown as
    /// `co.uk` — not a request wrongly blocked. Blocking itself never consults
    /// this: WebKit matches the rules on the full host.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk", "sch.uk", "me.uk", "ltd.uk",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "com.hk", "com.sg", "com.my", "com.ph", "com.vn",
        "co.kr", "or.kr", "ne.kr", "go.kr",
        "co.in", "net.in", "org.in", "gen.in", "firm.in",
        "co.za", "org.za", "net.za", "gov.za",
        "com.mx", "com.ar", "com.co", "com.pe", "com.ve", "com.ec", "com.uy",
        "com.tr", "gov.tr", "edu.tr",
        "co.il", "org.il", "ac.il", "gov.il",
        "co.th", "in.th", "ac.th", "go.th",
        "com.pl", "net.pl", "org.pl", "gov.pl",
        "com.ua", "com.ru", "org.ru", "net.ru",
        "com.eg", "com.sa", "com.ng", "com.pk", "com.bd",
        "co.id", "or.id", "web.id",
        "com.es", "com.pt", "com.gr", "com.cy", "com.mt",
    ]

    /// The registrable domain, lowercased. Returns the input unchanged when
    /// there is nothing to reduce — a bare hostname, or a literal IP address,
    /// which has no labels in the DNS sense and must not be truncated to its
    /// last two octets.
    public static func registrable(_ host: String) -> String {
        let cleaned = normalize(host)
        guard !cleaned.isEmpty, !isIPAddress(cleaned) else { return cleaned }

        let labels = cleaned.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count > 2 else { return cleaned }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        let depth = multiLabelSuffixes.contains(lastTwo) ? 3 : 2
        guard labels.count > depth else { return cleaned }
        return labels.suffix(depth).joined(separator: ".")
    }

    /// Whether a request leaves the site the page belongs to.
    ///
    /// Compared on registrable domains, not hosts: a page on `www.example.com`
    /// fetching from `static.example.com` is the site loading its own assets,
    /// and calling that third-party would fill the panel with a site's own
    /// CDN — noise that buries the rows that matter.
    public static func isThirdParty(_ host: String, from pageHost: String) -> Bool {
        let requested = registrable(host)
        let page = registrable(pageHost)
        guard !requested.isEmpty, !page.isEmpty else { return false }
        return requested != page
    }

    /// Whether a host is covered by a set of domains — the host itself, or any
    /// domain it sits under.
    ///
    /// Matched label-wise rather than with `hasSuffix`, which would let
    /// `notdoubleclick.net` match an entry for `doubleclick.net`.
    public static func matches(host: String, in domains: Set<String>) -> Bool {
        coveringDomain(host: host, in: domains) != nil
    }

    /// Which entry in the set covers this host, if any. The panel names the
    /// rule that caught a request, and "blocked by doubleclick.net" is a
    /// different statement from the host that was actually contacted.
    public static func coveringDomain(host: String, in domains: Set<String>) -> String? {
        let cleaned = normalize(host)
        guard !cleaned.isEmpty else { return nil }
        if domains.contains(cleaned) { return cleaned }

        var remainder = Substring(cleaned)
        while let dot = remainder.firstIndex(of: ".") {
            remainder = remainder[remainder.index(after: dot)...]
            guard remainder.contains(".") else { break }
            if domains.contains(String(remainder)) { return String(remainder) }
        }
        return nil
    }

    /// The host of a URL string, without building a `URL` — these arrive by the
    /// thousand from the page and most are discarded immediately.
    public static func host(ofURL url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Strip credentials and port, in that order: a password may contain a
        // colon, so cutting at the colon first can take half the host with it.
        let afterCredentials = authority.split(separator: "@").last ?? authority
        let host = afterCredentials.split(separator: ":").first.map(String.init) ?? ""
        let cleaned = normalize(host)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func normalize(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// IPv4 by shape, IPv6 by the brackets a URL carries it in.
    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }
}
