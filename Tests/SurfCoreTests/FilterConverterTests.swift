import Foundation
import Testing
@testable import SurfCore

@Suite("Filter converter")
struct FilterConverterTests {

    private func rule(_ filter: String) -> String? {
        switch FilterConverter.parse(filter) {
        case .block(let rule, _, _): rule
        case .exception(let rule, _): rule
        case .ignored, .unsupported: nil
        }
    }

    private func domain(_ filter: String) -> String? {
        guard case let .block(_, _, domain) = FilterConverter.parse(filter) else { return nil }
        return domain
    }

    private func isUnsupported(_ filter: String) -> Bool {
        if case .unsupported = FilterConverter.parse(filter) { return true }
        return false
    }

    private func isIgnored(_ filter: String) -> Bool {
        if case .ignored = FilterConverter.parse(filter) { return true }
        return false
    }

    // MARK: - The rule that matters

    @Test("A host-anchored rule covers the host and its subdomains")
    func hostAnchored() throws {
        // The whole reason this converter exists. `||adnxs.com^` has to reach
        // `ib.adnxs.com`, which is the host the ads actually come from — the
        // borrowed conversion matched the bare host only, and let them through.
        let translated = try #require(FilterConverter.hostAnchored("adnxs.com^"))
        #expect(translated.regex == #"^https?://([^:/?#]*\.)?adnxs\.com([^a-z0-9_.%-].*)?$"#)
        #expect(translated.host == "adnxs.com")
        #expect(translated.isWholeDomain)
    }

    @Test("The boundary stops a domain matching a longer one")
    func boundaryIsRealPunctuation() throws {
        // `||example.com^` must not match `example.community`. Without the
        // trailing boundary it would, and the converter would be quietly
        // blocking sites nobody wrote a rule about.
        let translated = try #require(FilterConverter.hostAnchored("example.com^"))
        let regex = try NSRegularExpression(pattern: translated.regex)

        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }

        #expect(matches("https://example.com/ad.js"))
        #expect(matches("https://ads.example.com/x"))
        #expect(matches("https://example.com"))
        #expect(!matches("https://example.community/page"))
        #expect(!matches("https://notexample.com/x"))
    }

    @Test("A path on a host narrows the rule and names no domain")
    func pathQualified() throws {
        let translated = try #require(FilterConverter.hostAnchored("example.com/ads/"))
        #expect(translated.regex == #"^https?://([^:/?#]*\.)?example\.com\/ads\/"#)
        #expect(!translated.isWholeDomain)
        // Which is what keeps the panel from claiming the whole host is blocked.
        #expect(domain("||example.com/ads/") == nil)
        #expect(domain("||example.com^") == "example.com")
    }

    @Test("A wildcard is a run of anything")
    func wildcards() throws {
        let translated = try #require(FilterConverter.hostAnchored("example.com/*/ads"))
        #expect(translated.regex.contains(".*"))
        #expect(!translated.isWholeDomain)
    }

    // MARK: - Options

    @Test("Third-party is carried across")
    func thirdParty() throws {
        #expect(try #require(rule("||ads.example^$third-party"))
            .contains(#""load-type":["third-party"]"#))
        #expect(try #require(rule("||ads.example^$~third-party"))
            .contains(#""load-type":["first-party"]"#))
        // A rule limited to third-party requests doesn't block the domain
        // outright, so it doesn't get to name one.
        #expect(domain("||ads.example^$third-party") == nil)
    }

    @Test("Type options become resource types")
    func resourceTypes() throws {
        let scripted = try #require(rule("||ads.example^$script,image"))
        #expect(scripted.contains(#""resource-type":["image","script"]"#))
    }

    @Test("A rule with no type option never applies to a page the user typed")
    func defaultTypesExcludeDocuments() throws {
        // Adblock Plus's own default, and the consequence of getting it wrong is
        // that an ad list becomes able to block a site outright.
        let plain = try #require(rule("||ads.example^"))
        // Quoted, because `svg-document` is in the default set and is a
        // different thing entirely.
        #expect(!plain.contains(#""document""#))
        #expect(!plain.contains(#""popup""#))
        // Unless it says so.
        #expect(try #require(rule("||ads.example^$document")).contains(#""document""#))
    }

    /// These rules used to be dropped outright, because `document` is the only
    /// near-neighbour WebKit has for an iframe and it also covers the page the
    /// user typed the address of — so converting them handed an ad list the
    /// power to refuse a top-level navigation. `load-context` is what makes it
    /// safe, and it is verifiable against a real web view: with the context
    /// pinned to a child frame, the iframe is blocked and a top-level load of
    /// the very same URL still goes through.
    @Test("A rule that blocks nested documents becomes a child-frame rule")
    func nestedDocumentBlocksBecomeFrameRules() throws {
        let result = FilterConverter.convert("||ads.example^$subdocument")
        #expect(result.rules.count == 1)
        #expect(result.frameRules == 1)

        let rule = try #require(result.rules.first)
        #expect(rule.contains(#""load-context":["child-frame"]"#))
        #expect(rule.contains(#""resource-type":["document"]"#))
        #expect(rule.contains(#""type":"block""#))
    }

    /// The filter named frames and nothing else, so it must not quietly start
    /// blocking scripts and images as well — which is what falling through to
    /// the default resource types would do.
    @Test("A frames-only filter produces only the frame rule")
    func framesOnlyStaysFramesOnly() {
        let result = FilterConverter.convert("||ads.example^$subdocument")
        #expect(result.rules.allSatisfy { $0.contains(#""load-context""#) })
        #expect(!result.rules.contains { $0.contains(#""script""#) })
    }

    /// Adblock Plus's default is every type, nested documents included. This is
    /// the case that matters most in practice: it is most of a list, and it is
    /// why an ad iframe used to load even when its host was blocked outright.
    @Test("A plain rule blocks the host's frames as well as its subresources")
    func plainRulesReachFrames() throws {
        let result = FilterConverter.convert("||ads.example^")
        #expect(result.rules.count == 2)
        #expect(result.frameRules == 1)

        let subresource = try #require(result.rules.first)
        #expect(subresource.contains(#""script""#))
        #expect(!subresource.contains(#""load-context""#))

        let frame = try #require(result.rules.last)
        #expect(frame.contains(#""load-context":["child-frame"]"#))
        #expect(!frame.contains(#""script""#))
    }

    /// `load-context` narrows the whole trigger, so the frame rule has to be a
    /// rule of its own. Folding `document` into the subresource trigger and
    /// pinning that to child frames would stop it blocking scripts in the top
    /// frame — verified against a real web view, where exactly that happened.
    @Test("The frame rule is separate, so subresource blocking keeps its reach")
    func frameRuleIsSeparate() {
        let result = FilterConverter.convert("||ads.example^")
        let contexts = result.rules.filter { $0.contains(#""load-context""#) }
        #expect(contexts.count == 1)
        #expect(result.rules.count == 2)
    }

    /// A rule that named its types said what it meant. Adding frames to it
    /// would block something the filter never asked to block.
    @Test("A rule that names its types is not widened to frames")
    func namedTypesAreNotWidened() {
        let result = FilterConverter.convert("||ads.example^$script")
        #expect(result.frameRules == 0)
        #expect(result.rules.count == 1)
    }

    @Test("A negated subdocument option keeps frames out of it")
    func negatedSubdocument() {
        let result = FilterConverter.convert("||ads.example^$~subdocument")
        #expect(result.frameRules == 0)
    }

    @Test("An exception for nested documents is kept, and widened")
    func nestedDocumentExceptionsAreKept() throws {
        // The asymmetry runs the other way for an exception: widening it
        // un-blocks more than the list asked for, where dropping it would leave
        // a request refused that the list said to allow.
        let rule = try #require(rule("@@||good.example^$subdocument"))
        #expect(rule.contains(#""type":"ignore-previous-rules""#))
        #expect(rule.contains(#""document""#))
    }

    @Test("A negated type is removed from the default set")
    func negatedTypes() throws {
        let rule = try #require(rule("||ads.example^$~script"))
        #expect(!rule.contains(#""script""#))
        #expect(rule.contains(#""image""#))
    }

    @Test("Domain scoping becomes if-domain, with subdomains")
    func domainScoping() throws {
        let scoped = try #require(rule("||ads.example^$domain=news.test"))
        #expect(scoped.contains(#""if-domain":["*news.test"]"#))

        let excluded = try #require(rule("||ads.example^$domain=~news.test"))
        #expect(excluded.contains(#""unless-domain":["*news.test"]"#))
    }

    @Test("A rule needing both if-domain and unless-domain is refused")
    func mixedDomains() {
        // WebKit takes one or the other. Emitting either half alone would be a
        // different rule than the one the list wrote.
        #expect(isUnsupported("||ads.example^$domain=a.test|~b.a.test"))
    }

    // MARK: - Exceptions

    @Test("An exception becomes ignore-previous-rules")
    func exceptions() throws {
        let rule = try #require(rule("@@||example.com^$document"))
        #expect(rule.contains(#""type":"ignore-previous-rules""#))
    }

    @Test("Exceptions are emitted after the blocks they override")
    func exceptionOrdering() {
        // WebKit applies rules in order and ignore-previous-rules cancels only
        // what came before it. An exception written above its block does nothing.
        let result = FilterConverter.convert("""
        @@||example.com^$document
        ||ads.example^
        """)
        // Three now, not two: the plain block rule brings a child-frame
        // companion with it. What matters is unchanged — every block, however
        // many, comes before the exception that cancels it.
        #expect(result.rules.count == 3)
        let blocks = result.rules.prefix(2)
        #expect(blocks.allSatisfy { $0.contains(#""type":"block""#) })
        #expect(result.rules[2].contains(#""type":"ignore-previous-rules""#))
    }

    /// A plain allowlist entry has to keep protecting a site's frames now that
    /// blocks reach them, or turning frame blocking on would quietly punch a
    /// hole in every exception in the list.
    @Test("A plain exception gets a frame companion too")
    func plainExceptionsReachFrames() {
        let result = FilterConverter.convert("@@||good.example^")
        #expect(result.rules.count == 2)
        #expect(result.frameRules == 1)
        #expect(result.rules.allSatisfy { $0.contains(#""ignore-previous-rules""#) })
        #expect(result.rules.contains { $0.contains(#""load-context":["child-frame"]"#) })
    }

    /// The budget exists because WebKit refuses an over-sized list outright:
    /// the failure mode is not "fewer rules", it is "no blocking at all". An
    /// over-budget list has to degrade to what it blocked before frame rules
    /// existed, not to something arbitrary.
    @Test("Frame rules are what gets dropped when the list runs out of room")
    func budgetDropsFrameRulesFirst() {
        let list = """
        ||one.example^
        ||two.example^
        ||three.example^
        """
        let full = FilterConverter.convert(list)
        #expect(full.rules.count == 6)
        #expect(full.frameRules == 3)
        #expect(full.droppedFrameRules == 0)

        // Room for the three block rules and one companion.
        let squeezed = FilterConverter.convert(list, limit: 4)
        #expect(squeezed.rules.count == 4)
        #expect(squeezed.frameRules == 1)
        #expect(squeezed.droppedFrameRules == 2)
        // The subresource blocking is intact — it is the companions that went.
        #expect(squeezed.rules.filter { !$0.contains(#""load-context""#) }.count == 3)
    }

    @Test("With no room at all the list is exactly what it was before")
    func budgetOfZeroFrameRules() {
        let result = FilterConverter.convert("||ads.example^", limit: 1)
        #expect(result.rules.count == 1)
        #expect(result.frameRules == 0)
        #expect(result.droppedFrameRules == 1)
        #expect(!result.rules[0].contains(#""load-context""#))
    }

    // MARK: - What is refused, and in which direction

    @Test("An option WebKit has no answer for refuses the rule")
    func unsupportedOptions() {
        #expect(isUnsupported("||ads.example^$csp=script-src 'none'"))
        #expect(isUnsupported("||ads.example^$redirect=noop.js"))
        #expect(isUnsupported("||ads.example^$removeparam=utm_source"))
    }

    @Test("A regex literal is refused rather than passed to a different engine")
    func regexLiterals() {
        // WebKit's regex is a subset of the one these were written for, and a
        // rule it rejects fails the entire list's compile — every other rule
        // with it.
        #expect(isUnsupported("/banner[0-9]+\\.gif/"))
    }

    @Test("A cosmetic exception is dropped, and only ever costs a hidden element")
    func cosmeticExceptions() {
        // The asymmetry the whole converter is built on: WebKit can't cancel
        // element hiding without also cancelling blocking, so this is dropped.
        // The cost is something staying hidden — never something staying blocked.
        #expect(isIgnored("example.com#@#.ad-banner"))
        #expect(isIgnored("@@||example.com^$generichide"))
    }

    @Test("Procedural filters are counted, not guessed at")
    func procedural() {
        #expect(isUnsupported("example.com#?#div:-abp-has(> .ad)"))
        #expect(isUnsupported("example.com##div:has(> .sponsored)"))
    }

    // MARK: - Cosmetic rules

    @Test("An element-hiding rule becomes css-display-none")
    func cosmetic() throws {
        let rule = try #require(rule("##.ad-banner"))
        #expect(rule.contains(#""type":"css-display-none""#))
        #expect(rule.contains(#""selector":".ad-banner""#))
        #expect(rule.contains(#""url-filter":".*""#))
    }

    @Test("A scoped element-hiding rule only applies on its sites")
    func scopedCosmetic() throws {
        let rule = try #require(rule("news.test,other.test##.ad"))
        #expect(rule.contains(#""if-domain":["*news.test","*other.test"]"#))
    }

    @Test("A selector is encoded, not concatenated")
    func selectorEncoding() throws {
        // Twenty thousand selectors written by strangers, one of which contains
        // a quote, and the whole list fails to compile.
        let rule = try #require(rule(##"##a[href="/ads"]"##))
        #expect(rule.contains(#"\"/ads\""#))
        #expect((try? JSONSerialization.jsonObject(with: Data(rule.utf8))) != nil)
    }

    // MARK: - Whole lists

    @Test("A list converts to rules in WebKit's order, and counts what it dropped")
    func wholeList() {
        let result = FilterConverter.convert("""
        [Adblock Plus 2.0]
        ! Title: Test list
        ||ads.example^
        ||tracker.example^$third-party
        ##.advert
        @@||good.example^$document
        ||broken.example^$csp=none

        """)
        // Six, not four: `||ads.example^` and `||tracker.example^$third-party`
        // each bring a child-frame companion. The cosmetic rule and the
        // `$document` exception do not — one hides an element, the other
        // already covers nested documents.
        #expect(result.converted == 6)
        #expect(result.frameRules == 2)
        #expect(result.skipped == 1)
        #expect(result.blockedDomains == ["ads.example"])
    }

    @Test("Every rule a list produces is valid JSON")
    func everythingIsEncodable() {
        let result = FilterConverter.convert("""
        ||ads.example^
        news.test##.ad[data-x="1"]
        @@||good.example^
        """)
        for rule in result.rules {
            #expect((try? JSONSerialization.jsonObject(with: Data(rule.utf8))) != nil)
        }
    }

    @Test("The same list always converts to the same bytes")
    func deterministic() {
        // The compiled list is cached under a hash of these, so an unstable
        // encoding would mean recompiling a hundred thousand rules every launch.
        let list = "||ads.example^$script,image,third-party\nnews.test,other.test##.ad"
        #expect(FilterConverter.convert(list) == FilterConverter.convert(list))
    }
}
