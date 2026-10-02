import Foundation

/// One row of the cookie menu: a site, and every cookie the jar holds for it.
///
/// A jar is a flat list of a few hundred cookies, and nobody opening a profile
/// menu wants that. What they want is the handful of sites they have an account
/// with, and the ability to sign out of one. So the unit here is the site rather
/// than the cookie.
public struct CookieDomain: Sendable, Equatable, Identifiable {

    /// The registrable domain — what a person would call the site.
    public let domain: String

    /// The cookies counted under it, carried rather than re-derived.
    ///
    /// This is what makes an unconfirmed delete safe. The row displays a count,
    /// and the delete is handed exactly the set that produced that count, so a
    /// row cannot remove more than it said it would — even if the grouping
    /// below got the site wrong.
    public let cookies: [StorageCookie]

    public var id: String { domain }

    public var count: Int { cookies.count }

    /// `github.com (14)` — the site and the size of what clicking it takes.
    public var rowTitle: String { "\(domain) (\(count))" }

    public init(domain: String, cookies: [StorageCookie]) {
        self.domain = domain
        self.cookies = cookies
    }
}

/// What one island's jar is holding, as a menu can state it.
///
/// The visible rows are capped, but the totals are not: they count the whole
/// jar. A confirmation that says "142 cookies across 36 sites" has to be
/// telling the truth about what it is about to erase, not about what happened
/// to fit on screen.
public struct CookieJarSummary: Sendable, Equatable {
    public let domains: [CookieDomain]
    public let hiddenDomainCount: Int
    public let totalDomains: Int
    public let totalCookies: Int

    public var isEmpty: Bool { totalCookies == 0 }

    /// `142 cookies in 36 sites` — what the parent row says it is holding.
    ///
    /// Counted over the whole jar rather than the visible rows, and singular
    /// where it has to be: "1 cookies in 1 sites" on the row that opens a
    /// destructive submenu reads as a bug, which is not what you want somebody
    /// thinking about at that moment.
    public var headline: String {
        let cookies = "\(totalCookies) \(totalCookies == 1 ? "cookie" : "cookies")"
        let sites = "\(totalDomains) \(totalDomains == 1 ? "site" : "sites")"
        return "\(cookies) in \(sites)"
    }

    public init(
        domains: [CookieDomain],
        hiddenDomainCount: Int,
        totalDomains: Int,
        totalCookies: Int
    ) {
        self.domains = domains
        self.hiddenDomainCount = hiddenDomainCount
        self.totalDomains = totalDomains
        self.totalCookies = totalCookies
    }
}

public enum CookieDomains {

    /// A dozen rows. Past that a menu is a list somebody is scrolling, and the
    /// complete, searchable one already exists in the dev tools storage pane —
    /// so this is the fast path to the sites you actually have an account with,
    /// which is why the order below puts the largest first.
    public static let menuLimit = 12

    /// Collapses a jar into one row per site.
    public static func summary(
        of cookies: [StorageCookie], limit: Int = menuLimit
    ) -> CookieJarSummary {
        var buckets: [String: [StorageCookie]] = [:]
        for cookie in cookies {
            // A cookie whose domain reduces to nothing has no row that could
            // account for it, and a blank menu row cannot be read or aimed at.
            // Dropped from the counts too, so the number a row states and the
            // number the totals state are answering the same question.
            guard let site = site(of: cookie.domain) else { continue }
            buckets[site, default: []].append(cookie)
        }

        let all = buckets
            .map { CookieDomain(domain: $0.key, cookies: $0.value) }
            // Most cookies first, because the count is the best proxy available
            // for how much of you a site is holding. Ties alphabetically, so
            // the order is stable rather than whatever the dictionary says.
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.domain.localizedCaseInsensitiveCompare(right.domain)
                    == .orderedAscending
            }

        let kept = Array(all.prefix(max(0, limit)))
        return CookieJarSummary(
            domains: kept,
            hiddenDomainCount: all.count - kept.count,
            totalDomains: all.count,
            totalCookies: buckets.values.reduce(0) { $0 + $1.count }
        )
    }

    /// The site a cookie belongs to, or nil when it does not name one.
    ///
    /// Two steps, and the first one is the whole reason this function exists.
    ///
    /// A cookie scoped to a domain is written with a leading dot and one scoped
    /// to a host without it, so a real jar holds both `.github.com` and
    /// `github.com`. `DomainName.normalize` strips *trailing* dots only, and
    /// `.github.com` splits into two labels, which falls out of `registrable`'s
    /// `labels.count > 2` guard and comes back unchanged. Without the strip, the
    /// commonest shape in any jar is two rows for one site, each of which signs
    /// you half out.
    ///
    /// Then `registrable`, which folds `api.github.com` and `gist.github.com`
    /// in with it. That is what the row promises: a session is routinely spread
    /// across all three, and three rows that each half-work is a menu that
    /// does not work. It also means the menu and the blocking shield agree
    /// about what counts as a site, since both go through `DomainName`.
    ///
    /// Deliberately not `CookieMatching.domainMatches`. That answers "would
    /// this cookie travel to this host", and the relation runs the wrong way
    /// for grouping — a cookie scoped to `api.example.com` does not match host
    /// `example.com`, so a row keyed on the registrable domain and built by
    /// matching would miss exactly the subdomain-scoped cookies that carry the
    /// login.
    public static func site(of domain: String) -> String? {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let site = DomainName.registrable(bare)
        return site.isEmpty ? nil : site
    }
}
