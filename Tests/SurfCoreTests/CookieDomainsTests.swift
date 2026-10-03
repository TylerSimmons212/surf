import Foundation
import Testing
@testable import SurfCore

@Suite("Cookie domains")
struct CookieDomainsTests {

    /// Only the fields the grouping reads.
    private func cookie(_ name: String, _ domain: String, path: String = "/") -> StorageCookie {
        StorageCookie(name: name, value: "v", domain: domain, path: path)
    }

    // MARK: - What counts as a site

    @Test("A leading-dot domain is the same site as its undotted twin")
    func leadingDotFolds() {
        let summary = CookieDomains.summary(of: [
            cookie("session", ".github.com"),
            cookie("logged_in", "github.com"),
        ])

        #expect(summary.domains.count == 1)
        #expect(summary.domains.first?.domain == "github.com")
        #expect(summary.domains.first?.count == 2)
    }

    /// The one mistake `DomainName.registrable` does not make for you: it
    /// strips trailing dots, and `.github.com` has two labels so it falls out
    /// of the reduction unchanged.
    @Test("The leading dot is stripped before the domain is reduced")
    func leadingDotStripped() {
        #expect(CookieDomains.site(of: ".github.com") == "github.com")
        #expect(CookieDomains.site(of: "github.com") == "github.com")
    }

    @Test("Subdomains fold into the registrable domain")
    func subdomainsFold() {
        let summary = CookieDomains.summary(of: [
            cookie("a", "api.github.com"),
            cookie("b", "gist.github.com"),
            cookie("c", ".github.com"),
        ])

        #expect(summary.domains.count == 1)
        #expect(summary.domains.first?.domain == "github.com")
        #expect(summary.domains.first?.count == 3)
    }

    @Test("A multi-label suffix is respected, never truncated to it")
    func multiLabelSuffix() {
        #expect(CookieDomains.site(of: "www.bbc.co.uk") == "bbc.co.uk")
        #expect(CookieDomains.site(of: ".bbc.co.uk") == "bbc.co.uk")
    }

    /// An IP literal has no labels in the DNS sense. Truncating it would put a
    /// domain in a destructive row's title that is not the one being erased.
    @Test("An IP literal is left whole")
    func ipLiteral() {
        #expect(CookieDomains.site(of: "192.168.1.10") == "192.168.1.10")
    }

    @Test("A domain that names nothing is dropped rather than rendered blank")
    func namelessDropped() {
        let summary = CookieDomains.summary(of: [
            cookie("orphan", ""),
            cookie("real", "github.com"),
        ])

        #expect(summary.domains.count == 1)
        #expect(summary.domains.first?.domain == "github.com")
        // Excluded from the totals too, so the rows and the totals are
        // answering the same question.
        #expect(summary.totalCookies == 1)
    }

    // MARK: - The invariant that makes an unconfirmed delete safe

    /// A row is handed exactly the cookies it counted, so clicking it cannot
    /// remove more than its title said — even if the grouping were wrong.
    @Test("Every row carries exactly the cookies it counted, and nothing is lost")
    func rowsCarryWhatTheyCount() {
        let input = [
            cookie("a", ".github.com"),
            cookie("b", "api.github.com"),
            cookie("c", "google.com"),
            cookie("d", "bbc.co.uk"),
        ]
        let summary = CookieDomains.summary(of: input)

        for row in summary.domains {
            #expect(row.cookies.count == row.count)
        }
        let union = summary.domains.flatMap(\.cookies)
        #expect(union.count == input.count)
        #expect(Set(union.map(\.id)) == Set(input.map(\.id)))
    }

    @Test("Two cookies differing only in path are two cookies")
    func pathDistinguishes() {
        let summary = CookieDomains.summary(of: [
            cookie("session", "github.com", path: "/"),
            cookie("session", "github.com", path: "/gist"),
        ])

        #expect(summary.domains.first?.count == 2)
        #expect(summary.totalCookies == 2)
    }

    // MARK: - Order

    @Test("The sites holding most come first, ties alphabetical")
    func orderedByCount() {
        let summary = CookieDomains.summary(of: [
            cookie("a", "small.com"),
            cookie("b", "big.com"), cookie("c", "big.com"), cookie("d", "big.com"),
            cookie("e", "mid.com"), cookie("f", "mid.com"),
            cookie("g", "alpha.com"),
        ])

        #expect(summary.domains.map(\.domain) == ["big.com", "mid.com", "alpha.com", "small.com"])
    }

    @Test("Ties ignore case")
    func tiesIgnoreCase() {
        let summary = CookieDomains.summary(of: [
            cookie("a", "Zebra.com"),
            cookie("b", "apple.com"),
        ])

        #expect(summary.domains.map(\.domain) == ["apple.com", "zebra.com"])
    }

    // MARK: - The cap

    @Test("The cap keeps the largest sites and still reports the whole jar")
    func capReportsTheWhole() {
        // Twenty sites, each with a distinct count so the order is unambiguous.
        let cookies = (1...20).flatMap { site in
            (1...site).map { cookie("c\($0)", "site\(String(format: "%02d", site)).com") }
        }
        let summary = CookieDomains.summary(of: cookies, limit: 12)

        #expect(summary.domains.count == 12)
        #expect(summary.totalDomains == 20)
        #expect(summary.hiddenDomainCount == 8)
        // 1 + 2 + … + 20
        #expect(summary.totalCookies == 210)
        // The twelve largest, biggest first.
        #expect(summary.domains.first?.domain == "site20.com")
        #expect(summary.domains.last?.domain == "site09.com")
    }

    @Test("Under the cap, nothing is hidden")
    func underTheCap() {
        let summary = CookieDomains.summary(of: [cookie("a", "github.com")], limit: 12)

        #expect(summary.domains.count == 1)
        #expect(summary.hiddenDomainCount == 0)
        #expect(summary.totalDomains == 1)
    }

    // MARK: - Edges

    @Test("An empty jar summarises as empty")
    func emptyJar() {
        let summary = CookieDomains.summary(of: [])

        #expect(summary.isEmpty)
        #expect(summary.domains.isEmpty)
        #expect(summary.totalDomains == 0)
        #expect(summary.totalCookies == 0)
        #expect(summary.hiddenDomainCount == 0)
    }

    /// Deliberate, and pinned so it stays a decision rather than drifting: an
    /// expired-but-unreaped cookie is in the jar, so it is part of what the
    /// count means and deleting it is still the right outcome.
    @Test("Expired cookies are counted")
    func expiredCounted() {
        let expired = StorageCookie(
            name: "old", value: "v", domain: "github.com",
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        let summary = CookieDomains.summary(of: [expired])

        #expect(summary.totalCookies == 1)
        #expect(summary.domains.first?.count == 1)
    }

    @Test("A row states the site and the size of what clicking it takes")
    func rowTitle() {
        let row = CookieDomain(
            domain: "github.com",
            cookies: [cookie("a", "github.com"), cookie("b", "github.com")]
        )

        #expect(row.rowTitle == "github.com (2)")
    }

    // MARK: - What the parent row says

    @Test("The headline counts the whole jar, not the visible rows")
    func headlineCountsTheWhole() {
        let cookies = (1...20).flatMap { site in
            (1...site).map { cookie("c\($0)", "site\(site).com") }
        }
        let summary = CookieDomains.summary(of: cookies, limit: 12)
        #expect(summary.headline == "210 cookies in 20 sites")
    }

    /// "1 cookies in 1 sites" on the row that opens a destructive submenu reads
    /// as a bug, which is not what anyone should be thinking about there.
    @Test("The headline is singular where it has to be")
    func headlineSingular() {
        #expect(CookieDomains.summary(of: [cookie("a", "github.com")]).headline
            == "1 cookie in 1 site")
    }
}
