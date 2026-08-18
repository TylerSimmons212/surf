import Testing

@testable import GlassCore

@Suite("Tag decoding")
struct TagDecoderTests {

    private func request(_ url: String, at: Double = 0, id: String = "1") -> NetworkRequest {
        NetworkRequest(id: id, url: url, startedAt: at)
    }

    /// A plain substring test would attribute `evil-facebook.com.attacker.test`
    /// to Meta. A tag debugger that misattributes traffic is worse than one
    /// that misses it.
    @Test("Host matching needs a label boundary, not a substring")
    func hostBoundary() {
        #expect(TagDecoder.signature(for: "https://www.facebook.com/tr/?id=1")?.id == "meta")
        #expect(TagDecoder.signature(for: "https://facebook.com/tr/?id=1")?.id == "meta")
        #expect(TagDecoder.signature(for: "https://evil-facebook.com/tr/?id=1") == nil)
        #expect(TagDecoder.signature(for: "https://facebook.com.attacker.test/tr/") == nil)
    }

    @Test("The path narrows a host that serves more than tags")
    func pathNarrowing() {
        // facebook.com serves the whole site; only /tr is the pixel.
        #expect(TagDecoder.signature(for: "https://www.facebook.com/some/page") == nil)
        #expect(TagDecoder.signature(for: "https://www.facebook.com/tr/?id=1") != nil)
    }

    @Test("A Meta pixel fire decodes to its event and custom data")
    func metaPixel() {
        let event = TagDecoder.decode(request(
            "https://www.facebook.com/tr/?id=1234567890&ev=Purchase"
            + "&cd%5Bvalue%5D=49.99&cd%5Bcurrency%5D=USD"
        ))
        #expect(event?.vendorId == "meta")
        #expect(event?.accountId == "1234567890")
        #expect(event?.name == "Purchase")
        // `cd[value]` and GA4's `ep.value` are the same fact; the validation
        // rules shouldn't need a spelling per vendor.
        #expect(event?.parameters["value"] == "49.99")
        #expect(event?.parameters["currency"] == "USD")
        #expect(event?.category == .advertising)
    }

    @Test("A GA4 hit decodes its measurement id and event parameters")
    func ga4() {
        let event = TagDecoder.decode(request(
            "https://www.google-analytics.com/g/collect?v=2&tid=G-ABC123&en=purchase"
            + "&ep.transaction_id=T-1&epn.value=25&ep.currency=GBP"
        ))
        #expect(event?.vendorId == "ga4")
        #expect(event?.accountId == "G-ABC123")
        #expect(event?.name == "purchase")
        #expect(event?.parameters["transaction_id"] == "T-1")
        #expect(event?.parameters["value"] == "25")
    }

    /// Google Ads puts the conversion id in the path, not a query parameter.
    @Test("An account id in the path is found")
    func accountInPath() {
        let event = TagDecoder.decode(request(
            "https://googleads.g.doubleclick.net/pagead/viewthroughconversion/987654321/?value=10"
        ))
        #expect(event?.vendorId == "google-ads")
        #expect(event?.accountId == "987654321")
    }

    @Test("A missing event name falls back to the vendor's default")
    func defaultEvent() {
        #expect(TagDecoder.decode(request("https://www.facebook.com/tr/?id=1"))?.name == "PageView")
        #expect(
            TagDecoder.decode(request("https://www.google-analytics.com/g/collect?tid=G-1"))?.name
                == "page_view"
        )
    }

    /// TikTok and GA4 batch their payloads into a POST body rather than a query
    /// string, so the body has to be folded in or those events read as empty.
    @Test("A JSON body is folded in, including nested objects")
    func jsonBody() {
        let event = TagDecoder.decode(
            request("https://analytics.tiktok.com/api/v2/pixel?sdkid=ABC"),
            body: #"{"event":"CompletePayment","properties":{"value":30,"currency":"EUR"}}"#
        )
        #expect(event?.name == "CompletePayment")
        #expect(event?.parameters["value"] == "30")
        #expect(event?.parameters["currency"] == "EUR")
    }

    @Test("A form-encoded body is folded in too")
    func formBody() {
        let event = TagDecoder.decode(
            request("https://ct.pinterest.com/v3/?tid=2612"),
            body: "event=checkout&ed%5Bvalue%5D=12.50"
        )
        #expect(event?.name == "checkout")
        #expect(event?.parameters["value"] == "12.50")
    }

    @Test("Ordinary traffic isn't mistaken for a tag")
    func notATag() {
        #expect(TagDecoder.decode(request("https://example.com/api/users")) == nil)
        #expect(TagDecoder.decode(request("https://cdn.example.com/app.js")) == nil)
    }

    /// The ad-library links are the honest half of the ad idea: no scraping,
    /// no API that needs a token, just the search already filled in.
    @Test("Ad library links fill in the identifier")
    func adLibraryLinks() {
        let meta = TagDecoder.signatures.first { $0.id == "meta" }?.adLibrary
        let url = meta?.url(id: "123", domain: "shop.example.com")
        #expect(url?.contains("shop.example.com") == true)
        #expect(meta?.note.contains("app token") == true)
    }
}

@Suite("Tag validation")
struct TagValidationTests {

    private func event(
        _ name: String, vendor: String = "meta", account: String = "1",
        at: Double = 0, id: String = "e", parameters: [String: String] = [:],
        category: TagCategory = .advertising
    ) -> TagEvent {
        TagEvent(
            id: id, vendorId: vendor, vendorName: "Meta Pixel", category: category,
            accountId: account, name: name, parameters: parameters, at: at, url: ""
        )
    }

    /// The bug this pane exists for. Nothing on the page goes wrong when a
    /// Purchase fires twice, which is exactly why it survives to production and
    /// then inflates reported revenue.
    @Test("The same event fired twice in quick succession is an error")
    func duplicateFires() {
        let findings = TagValidation.duplicates(in: [
            event("Purchase", at: 1000, id: "a", parameters: ["value": "49.99"]),
            event("Purchase", at: 1200, id: "b", parameters: ["value": "49.99"]),
        ])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .error)
        #expect(findings[0].title.contains("twice"))
    }

    @Test("The same event much later is not a duplicate")
    func spacedOut() {
        let findings = TagValidation.duplicates(in: [
            event("PageView", at: 0, id: "a"),
            event("PageView", at: 30_000, id: "b"),
        ])
        #expect(findings.isEmpty)
    }

    /// Two genuinely different purchases close together is unusual but not a
    /// bug, and flagging it would train people to ignore the warning.
    @Test("Two different values are two purchases, not a double-fire")
    func differentValues() {
        let findings = TagValidation.duplicates(in: [
            event("Purchase", at: 0, id: "a", parameters: ["value": "10"]),
            event("Purchase", at: 500, id: "b", parameters: ["value": "25"]),
        ])
        #expect(findings.isEmpty)
    }

    @Test("Events to different accounts are not duplicates of each other")
    func differentAccounts() {
        let findings = TagValidation.duplicates(in: [
            event("Purchase", account: "1", at: 0, id: "a"),
            event("Purchase", account: "2", at: 100, id: "b"),
        ])
        #expect(findings.isEmpty)
    }

    @Test("A purchase without value or currency is flagged")
    func missingParameters() {
        let findings = TagValidation.missingParameters(in: [
            event("Purchase", id: "a", parameters: ["content_ids": "SKU1"]),
        ])
        #expect(findings.count == 1)
        #expect(findings[0].title.contains("value"))
        #expect(findings[0].severity == .warning)
    }

    @Test("A complete purchase passes")
    func completePurchase() {
        let findings = TagValidation.missingParameters(in: [
            event("Purchase", id: "a", parameters: ["value": "10", "currency": "USD"]),
        ])
        #expect(findings.isEmpty)
    }

    @Test("Two account ids for one vendor is a half-finished migration")
    func multipleAccounts() {
        let findings = TagValidation.multipleAccounts(in: [
            DetectedTag(vendorId: "meta", name: "Meta Pixel", category: .advertising,
                        accountIds: ["111", "222"], eventCount: 2),
        ])
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("111"))
    }

    /// A tag that loaded and then threw looks identical to one that works.
    @Test("A tag that never fires is worth mentioning")
    func silentTag() {
        let findings = TagValidation.silentTags(in: [
            DetectedTag(vendorId: "tiktok", name: "TikTok Pixel", category: .advertising,
                        evidence: ["window.ttq"], eventCount: 0),
        ])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .info)
    }

    @Test("A tag manager that hasn't fired isn't reported as silent")
    func tagManagersExempt() {
        let findings = TagValidation.silentTags(in: [
            DetectedTag(vendorId: "gtm", name: "Google Tag Manager",
                        category: .tagManager, eventCount: 0),
        ])
        #expect(findings.isEmpty)
    }

    /// Reported as an observation about ordering, never as a compliance
    /// verdict — whether it's permitted depends on jurisdiction and on what the
    /// visitor chose, neither of which a browser can see.
    @Test("Advertising before a consent signal is described, not ruled on")
    func consentOrdering() {
        let findings = TagValidation.consentOrder(
            [event("Purchase", at: 100, id: "a")], consentAt: 500
        )
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("depends on your jurisdiction"))
        #expect(!findings[0].detail.lowercased().contains("violation"))
    }

    @Test("Advertising after consent is not flagged")
    func consentRespected() {
        let findings = TagValidation.consentOrder(
            [event("Purchase", at: 900, id: "a")], consentAt: 500
        )
        #expect(findings.isEmpty)
    }

    @Test("Analytics is not treated as advertising for consent ordering")
    func analyticsExempt() {
        let findings = TagValidation.consentOrder(
            [event("page_view", at: 100, id: "a", category: .analytics)], consentAt: 500
        )
        #expect(findings.isEmpty)
    }
}

@Suite("Advertiser naming")
struct AdvertiserNameTests {

    /// The correction that came out of reading a tool which does this for a
    /// living: it asks its user for brand names rather than deriving them from
    /// domains, because ad libraries are indexed by advertiser, not by host.
    /// Searching `shop.example.com` in Meta's library finds nothing.
    @Test("The site's own name wins when it declares one")
    func prefersSiteName() {
        #expect(
            AdvertiserName.guess(
                siteName: "Acme Outdoors", title: "Tents | Acme", domain: "shop.acme.com"
            ) == "Acme Outdoors"
        )
    }

    /// A title is usually "page — brand", and the brand is the part worth
    /// searching for.
    @Test("A title is split on its separator, taking the brand end")
    func splitsTitle() {
        #expect(
            AdvertiserName.guess(siteName: "", title: "Blue Tent — Acme", domain: "acme.com")
                == "Acme"
        )
        #expect(
            AdvertiserName.guess(siteName: "", title: "Checkout | Acme Store", domain: "acme.com")
                == "Acme Store"
        )
    }

    /// A whole sentence of SEO title is not an advertiser name.
    @Test("An over-long title falls through to the domain")
    func longTitleFallsThrough() {
        let sprawling = "Buy the best tents online with free shipping and returns in 2026"
        #expect(AdvertiserName.guess(siteName: "", title: sprawling, domain: "acme.com") == "acme")
    }

    @Test("The apex label is taken from the host, past any public suffix")
    func apexExtraction() {
        #expect(AdvertiserName.apex(of: "www.acme.com") == "acme")
        #expect(AdvertiserName.apex(of: "shop.acme.co.uk") == "acme")
        #expect(AdvertiserName.apex(of: "acme.com") == "acme")
        #expect(AdvertiserName.apex(of: "localhost") == "localhost")
    }

    @Test("With nothing to go on, the domain is still better than empty")
    func fallback() {
        #expect(AdvertiserName.guess(siteName: "", title: "", domain: "store.acme.com") == "acme")
    }
}
