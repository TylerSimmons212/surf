import Foundation
import Testing
@testable import SurfCore

@Suite("Block log")
struct BlockLogTests {

    private let classifier = BlockClassifier(
        listedDomains: ["doubleclick.net"],
        userBlockedDomains: ["tracker.example"]
    )

    private func attempt(
        _ url: String, _ kind: ResourceKind = .script, loaded: Bool = false
    ) -> RequestRecord {
        RequestRecord(url: url, kind: kind, didLoad: loaded)
    }

    private func record(
        _ log: inout BlockLog, _ record: RequestRecord, page: String = "example.com"
    ) {
        let host = DomainName.host(ofURL: record.url) ?? ""
        log.record(record, verdict: classifier.verdict(forHost: host, pageHost: page), host: host)
    }

    // MARK: - Verdicts

    @Test("A listed domain is blocked, and the rule's domain is named")
    func listed() {
        let verdict = classifier.verdict(forHost: "doubleclick.net", pageHost: "example.com")
        #expect(verdict == .blocked(.filterList(domain: "doubleclick.net")))
    }

    @Test("A subdomain of a listed domain is blocked, because the rule covers it")
    func listedCoversSubdomains() {
        // Only true because Surf converts the list itself: `||doubleclick.net^`
        // becomes a filter with the subdomain group, so `stats.g.doubleclick.net`
        // is genuinely refused and the panel can say so.
        #expect(classifier.verdict(forHost: "stats.g.doubleclick.net", pageHost: "example.com")
                == .blocked(.filterList(domain: "doubleclick.net")))
    }

    @Test("A user rule does cover subdomains, because its rule does")
    func userRulesCoverSubdomains() {
        #expect(classifier.verdict(forHost: "pixel.tracker.example", pageHost: "example.com")
                == .blocked(.userRule))
    }

    @Test("The user's own rule is credited to the user")
    func userRule() {
        #expect(classifier.verdict(forHost: "tracker.example", pageHost: "example.com")
                == .blocked(.userRule))
    }

    @Test("The site's own requests are not a party to anything")
    func firstParty() {
        // Even one that would otherwise match: a site loading from its own
        // host is the site working, and listing it would bury the rows that
        // matter under a CDN.
        #expect(classifier.verdict(forHost: "cdn.example.com", pageHost: "www.example.com")
                == .firstParty)
    }

    // MARK: - The page's evidence

    @Test("A request that completed is never reported as blocked")
    func loadedIsNotBlocked() {
        // This is what makes "pause on this site" honest without any special
        // case for it: with the rules off, listed domains load, and a domain
        // seen to load is reported as contacted.
        var log = BlockLog()
        record(&log, attempt("https://doubleclick.net/ad.js", loaded: true))
        #expect(log.blockedCount == 0)
        #expect(log.blocked.isEmpty)
        #expect(log.allowed.map(\.domain) == ["doubleclick.net"])
    }

    @Test("A request that failed against a listed domain is")
    func failedIsBlocked() {
        var log = BlockLog()
        record(&log, attempt("https://doubleclick.net/ad.js"))
        #expect(log.blockedCount == 1)
        #expect(log.blocked.map(\.domain) == ["doubleclick.net"])
    }

    @Test("One stray cached hit doesn't move a domain out of the blocked list")
    func blockedStaysBlocked() {
        var log = BlockLog()
        record(&log, attempt("https://doubleclick.net/a.js"))
        record(&log, attempt("https://doubleclick.net/b.js", loaded: true))
        #expect(log.blocked.map(\.domain) == ["doubleclick.net"])
        #expect(log.allowed.isEmpty)
    }

    // MARK: - Grouping

    @Test("Requests group under the site that made them, heaviest first")
    func grouping() {
        var log = BlockLog()
        record(&log, attempt("https://doubleclick.net/1.js"))
        record(&log, attempt("https://doubleclick.net/2.js"))
        record(&log, attempt("https://pixel.tracker.example/t.gif", .image))

        #expect(log.blockedCount == 3)
        #expect(log.blocked.map(\.domain) == ["doubleclick.net", "tracker.example"])
        #expect(log.blocked.first?.count == 2)
    }

    @Test("A row says what a domain was doing")
    func summaries() {
        var log = BlockLog()
        record(&log, attempt("https://tracker.example/t.gif", .image))
        #expect(log.blocked.first?.summary == "1 image")

        record(&log, attempt("https://tracker.example/u.gif", .image))
        #expect(log.blocked.first?.summary == "2 images")

        // Several kinds from one domain, so the neutral word is used rather
        // than picking one of them to stand for the rest.
        record(&log, attempt("https://tracker.example/s.js", .script))
        #expect(log.blocked.first?.summary == "3 requests")
    }

    @Test("A page can't fill the panel without bound")
    func domainLimit() {
        var log = BlockLog()
        for index in 0..<(BlockLog.domainLimit + 50) {
            record(&log, attempt("https://tracker\(index).example/a.js"))
        }
        #expect(log.allowed.count == BlockLog.domainLimit)
    }
}

@Suite("User rules")
struct UserBlockRulesTests {

    @Test("Blocking a host blocks the site it belongs to")
    func storedRegistrable() {
        var rules = UserBlockRules()
        rules.block("pagead2.googlesyndication.com")
        #expect(rules.blockedDomains == ["googlesyndication.com"])
        // Which is the point: the sibling host it rotates to next week is
        // covered by the rule made today.
        #expect(rules.isBlocked(host: "pagead47.googlesyndication.com"))
    }

    @Test("Pausing a page pauses the site")
    func pausing() {
        var rules = UserBlockRules()
        rules.setPaused(true, forSite: "shop.example.com")
        #expect(rules.isPaused(site: "www.example.com"))
        rules.setPaused(false, forSite: "example.com")
        #expect(!rules.isPaused(site: "www.example.com"))
    }

    // MARK: - Generated rules

    @Test("A user block is third-party only")
    func thirdPartyOnly() {
        let rules = ContentRuleJSON.blockRules(for: ["example.com"])
        // A rule that fired on the site itself would take the page down along
        // with the ad on it.
        #expect(rules.count == 1)
        #expect(rules[0].contains(#""load-type":["third-party"]"#))
        #expect(rules[0].contains(#""type":"block""#))
    }

    @Test("A generated block rule matches the domain and everything under it")
    func hostFilter() {
        let filter = ContentRuleJSON.hostFilter(for: "example.com")
        #expect(filter == #"^https?://([^:/?#]*\\.)?example\\.com"#)
    }

    @Test("Rules are generated in a stable order")
    func deterministic() {
        // The compiled list is cached under a hash of its own rules, so the
        // same rule set has to produce the same bytes or every launch would
        // recompile EasyList from scratch.
        let first = ContentRuleJSON.blockRules(for: ["b.com", "a.com", "c.com"])
        let second = ContentRuleJSON.blockRules(for: ["c.com", "a.com", "b.com"])
        #expect(first == second)
    }

    @Test("An empty rule set produces no list at all")
    func emptyList() {
        // WebKit rejects an empty array rather than compiling it to a no-op.
        #expect(ContentRuleJSON.list([]) == nil)
        #expect(ContentRuleJSON.list(["{}"]) == "[{}]")
    }
}

@Suite("Ad slots")
struct AdSlotTests {

    @Test("The names sites give ad containers are recognised")
    func names() {
        #expect(AdSlot.namesAnAdSlot("ad-slot-top"))
        #expect(AdSlot.namesAnAdSlot("header__advertisement"))
        #expect(AdSlot.namesAnAdSlot("adSlot"))
        #expect(AdSlot.namesAnAdSlot("div-gpt-ad-12345"))
        #expect(AdSlot.namesAnAdSlot("taboola-below-article"))
    }

    @Test("A word that merely contains one is not one")
    func notSubstrings() {
        // The whole reason for matching tokens: every one of these contains
        // "ad", and collapsing a page's headings or downloads would be a far
        // worse bug than leaving one banner's space reserved.
        #expect(!AdSlot.namesAnAdSlot("download-button"))
        #expect(!AdSlot.namesAnAdSlot("heading"))
        #expect(!AdSlot.namesAnAdSlot("shadow-root"))
        #expect(!AdSlot.namesAnAdSlot("readmore"))
        #expect(!AdSlot.namesAnAdSlot(""))
    }

    @Test("Camel case splits, but an acronym stays whole")
    func tokenizing() {
        #expect(AdSlot.tokens(in: "adSlot") == ["ad", "slot"])
        #expect(AdSlot.tokens(in: "GPT") == ["gpt"])
        #expect(AdSlot.tokens(in: "ad_slot-top ads") == ["ad", "slot", "top", "ads"])
    }

    @Test("The page-side list is generated from this one")
    func sharedList() {
        // Two lists that have to agree are two lists that eventually don't.
        let generated = AdSlot.slotNamesJSArray
        #expect(generated.hasPrefix("["))
        #expect(generated.contains("'advertisement'"))
        #expect(generated.split(separator: ",").count == AdSlot.slotNames.count)
    }
}

@Suite("Windows a page opens")
struct WindowRefusalTests {

    private let classifier = BlockClassifier(
        listedDomains: ["doubleclick.net"],
        userBlockedDomains: ["tracker.example"]
    )

    @Test("A window aimed at a listed domain is refused")
    func refusesAdWindows() {
        // The pop-under: the click is real, so WebKit is right to allow it, and
        // the destination is the only thing that gives it away.
        #expect(classifier.refusesWindow(to: "doubleclick.net", from: "news.example"))
        #expect(classifier.refusesWindow(to: "ads.doubleclick.net", from: "news.example"))
        #expect(classifier.refusesWindow(to: "tracker.example", from: "news.example"))
    }

    @Test("A window a site opens onto itself is never refused")
    func allowsFirstParty() {
        // Even for a site that is itself on a list — that is the site working,
        // and a reader who clicked a link and got nothing would rightly call it
        // a broken browser.
        #expect(!classifier.refusesWindow(to: "www.doubleclick.net", from: "doubleclick.net"))
    }

    @Test("An ordinary link to somewhere else still opens")
    func allowsOrdinaryWindows() {
        // The cost of being wrong here is a link the reader clicked and never
        // got, so nothing is refused on a guess.
        #expect(!classifier.refusesWindow(to: "example.org", from: "news.example"))
        #expect(!classifier.refusesWindow(to: "docs.example.net", from: "news.example"))
    }
}
