import Foundation

/// The two decisions the user can make about blocking, and the rules they
/// compile to.
///
/// Kept deliberately small. A blocker whose settings are a rule editor is a
/// blocker nobody tunes; the panel offers exactly two verbs — block this
/// domain, stop blocking on this site — and this is the file they write to.
public struct UserBlockRules: Codable, Equatable, Sendable {

    /// Domains the user added from the panel. Stored registrable, so blocking
    /// `googlesyndication.com` covers the `pagead2.` host it was seen on and
    /// every sibling it rotates to next week.
    public var blockedDomains: Set<String>

    /// Sites where blocking is off entirely. Registrable domains again: pausing
    /// on a page pauses on the site, because a site that breaks under blocking
    /// breaks on more than the one URL you noticed it on.
    public var pausedSites: Set<String>

    public init(blockedDomains: Set<String> = [], pausedSites: Set<String> = []) {
        self.blockedDomains = blockedDomains
        self.pausedSites = pausedSites
    }

    public var isEmpty: Bool { blockedDomains.isEmpty && pausedSites.isEmpty }

    public mutating func block(_ domain: String) {
        let registrable = DomainName.registrable(domain)
        guard !registrable.isEmpty else { return }
        blockedDomains.insert(registrable)
    }

    public mutating func unblock(_ domain: String) {
        blockedDomains.remove(DomainName.registrable(domain))
    }

    public func isBlocked(host: String) -> Bool {
        DomainName.matches(host: host, in: blockedDomains)
    }

    public mutating func setPaused(_ isPaused: Bool, forSite host: String) {
        let registrable = DomainName.registrable(host)
        guard !registrable.isEmpty else { return }
        if isPaused { pausedSites.insert(registrable) } else { pausedSites.remove(registrable) }
    }

    public func isPaused(site host: String) -> Bool {
        DomainName.matches(host: host, in: pausedSites)
    }
}

/// Turning those decisions into the JSON WebKit compiles.
public enum ContentRuleJSON {

    /// The user's own block rules.
    ///
    /// Third-party only. A rule that blocked `example.com` while you were *on*
    /// example.com would take the page down with the ad on it, and "block this"
    /// clicked in a panel is a statement about who the site is talking to, not
    /// about the site.
    public static func blockRules(for domains: Set<String>) -> [String] {
        domains.sorted().map { domain in
            """
            {"trigger":{"url-filter":"\(hostFilter(for: domain))",\
            "load-type":["third-party"]},"action":{"type":"block"}}
            """
        }
    }

    /// The allowlist — what "pause on this site" actually is.
    ///
    /// `ignore-previous-rules` only cancels rules that precede it *within the
    /// same compiled list*; it cannot reach across into another one. So these
    /// can't live in a list of their own and must be appended to every list they
    /// are meant to switch off, which is why they're generated separately from
    /// the blocks rather than alongside them.
    public static func allowlistRules(for sites: Set<String>) -> [String] {
        sites.sorted().map { site in
            """
            {"trigger":{"url-filter":".*","if-domain":["*\(escapeJSON(site))"]},\
            "action":{"type":"ignore-previous-rules"}}
            """
        }
    }

    /// Matches a domain and everything under it, at any path.
    ///
    /// `([^:/?#]*\.)?` is the converter's own spelling of Adblock Plus's `||`,
    /// used here so a hand-written rule and a list rule mean the same thing.
    static func hostFilter(for domain: String) -> String {
        let escaped = domain.map { character -> String in
            character == "." ? "\\\\." : String(character)
        }.joined()
        return "^https?://([^:/?#]*\\\\.)?\(escaped)"
    }

    static func escapeJSON(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A complete rule list from a set of rule objects, or nil when there are
    /// none — WebKit rejects an empty list rather than compiling to a no-op.
    public static func list(_ rules: [String]) -> String? {
        rules.isEmpty ? nil : "[\(rules.joined(separator: ","))]"
    }

    /// Appends rules to an already-encoded list.
    ///
    /// Done as text rather than by decoding nine megabytes of EasyList into
    /// model objects and re-encoding it: the payload is a JSON array, the rules
    /// go at the end, and every byte the publisher sent should reach WebKit's
    /// compiler exactly as sent.
    public static func appending(_ rules: [String], to list: Data) -> Data {
        guard !rules.isEmpty else { return list }
        guard let text = String(data: list, encoding: .utf8) else { return list }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return list }

        let body = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = body.isEmpty
            ? rules.joined(separator: ",")
            : body + "," + rules.joined(separator: ",")
        return Data("[\(joined)]".utf8)
    }
}
