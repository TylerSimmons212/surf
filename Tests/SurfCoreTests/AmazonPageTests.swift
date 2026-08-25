import Foundation
import Testing
@testable import SurfCore

@Suite("Amazon page addresses")
struct AmazonPageTests {

    private func page(_ address: String) -> AmazonPage {
        AmazonPage.of(URL(string: address))
    }

    // MARK: - Classifying

    @Test("The front page is the front page, with or without a trailing slash")
    func readsHome() {
        #expect(page("https://www.amazon.com") == .home)
        #expect(page("https://www.amazon.com/") == .home)
    }

    /// The bug this exists to prevent: Amazon form-encodes its queries, so a
    /// space arrives as "+". Percent-decoding alone leaves it there, and the
    /// lens's own search field then shows the site's encoding back to the
    /// user.
    @Test("A search query comes back as the words that were typed")
    func decodesSearchQuery() {
        #expect(page("https://www.amazon.com/s?k=usb+c+cable")
            == .search(query: "usb c cable"))
        #expect(page("https://www.amazon.com/s?k=usb%20c%20cable")
            == .search(query: "usb c cable"))
    }

    /// The other half of that bug: a real plus sign arrives already escaped,
    /// and must survive the space repair.
    @Test("A real plus sign survives")
    func keepsLiteralPlus() {
        #expect(page("https://www.amazon.com/s?k=c%2B%2B+books")
            == .search(query: "c++ books"))
    }

    @Test("Amazon's older keyword parameter still resolves")
    func readsLegacyKeywords() {
        #expect(page("https://www.amazon.com/s?field-keywords=tripod")
            == .search(query: "tripod"))
    }

    @Test("A results page with no query is the search box, not a search")
    func emptySearchIsHome() {
        #expect(page("https://www.amazon.com/s") == .home)
        #expect(page("https://www.amazon.com/s?k=") == .home)
        #expect(page("https://www.amazon.com/s?ref=nb_sb_noss") == .home)
    }

    @Test("Extra query parameters don't disturb the query")
    func ignoresTrackingParameters() {
        #expect(page("https://www.amazon.com/s?k=tripod&ref=nb_sb_noss&crid=2M09")
            == .search(query: "tripod"))
    }

    // MARK: - Products

    @Test("A product id is found wherever Amazon hangs it", arguments: [
        "https://www.amazon.com/dp/B088NRLMPV",
        "https://www.amazon.com/dp/B088NRLMPV/",
        "https://www.amazon.com/gp/product/B088NRLMPV",
        "https://www.amazon.com/Anker-USB-C-Cable-Charging/dp/B088NRLMPV/ref=sr_1_6?dib=eyJ2IjoiMSJ9",
        "https://www.amazon.com/dp/B088NRLMPV/ref=sr_1_6?th=1",
    ])
    func readsProductID(address: String) {
        #expect(page(address) == .product(asin: "B088NRLMPV"))
    }

    /// A book keeps its ISBN as its product id, so "starts with B0" would
    /// have been the wrong rule.
    @Test("An ISBN is a product id too")
    func acceptsISBN() {
        #expect(page("https://www.amazon.com/dp/0439708184")
            == .product(asin: "0439708184"))
    }

    /// The reason the marker search exists. A slug can contain a ten-character
    /// uppercase word, and scanning the path for anything ASIN-shaped would
    /// pick it up and build an address to nothing.
    @Test("A slug that looks like a product id is not mistaken for one")
    func slugIsNotAnID() {
        #expect(page("https://www.amazon.com/ABCDEFGHIJ/dp/B088NRLMPV")
            == .product(asin: "B088NRLMPV"))
        #expect(page("https://www.amazon.com/ABCDEFGHIJ/ref=foo") == .other)
    }

    @Test("A malformed id is not a product page")
    func rejectsMalformedID() {
        #expect(page("https://www.amazon.com/dp/TOOSHORT") == .other)
        #expect(page("https://www.amazon.com/dp/B088NRLMPVEXTRA") == .other)
        #expect(page("https://www.amazon.com/dp/") == .other)
    }

    // MARK: - The pages the lens must not frame

    @Test("Sign-in and order history are recognised, and demand the real site")
    func recognisesWalledPages() {
        let signIn = page("https://www.amazon.com/ap/signin?openid.return_to=x")
        let orders = page("https://www.amazon.com/gp/css/order-history?ref=nav")
        #expect(signIn == .signIn)
        #expect(orders == .orders)
        #expect(signIn.demandsTheRealSite)
        #expect(orders.demandsTheRealSite)
    }

    /// Amazon interposes sign-in on paths that still carry a product segment.
    /// If the product match won, the lens would draw a product page over a
    /// password field.
    @Test("Sign-in wins over a product id in the same path")
    func signInBeatsProduct() {
        #expect(page("https://www.amazon.com/ap/signin?next=/dp/B088NRLMPV") == .signIn)
    }

    @Test("The cart is recognised in both of its spellings")
    func recognisesCart() {
        #expect(page("https://www.amazon.com/gp/cart/view.html") == .cart)
        #expect(page("https://www.amazon.com/cart") == .cart)
        #expect(page("https://www.amazon.com/gp/cart/view.html").demandsTheRealSite == false)
    }

    @Test("A page with no lens of its own falls through")
    func fallsThroughToOther() {
        #expect(page("https://www.amazon.com/gp/bestsellers") == .other)
        #expect(page("https://www.amazon.com/stores/Anker/page/12345") == .other)
        #expect(AmazonPage.of(nil) == .other)
    }

    // MARK: - Building

    /// The round trip is the assertion that matters: an address the lens
    /// builds has to read back as the query it was built from, or the field
    /// and the grid disagree about what is on screen.
    @Test("A search address reads back as the query it was built from", arguments: [
        "usb c cable",
        "c++ books",
        "50% off",
        "sony a7 & lens",
        "caf\u{00E9} press",
        "what is 2+2?",
        "\"exact phrase\"",
    ])
    func searchURLRoundTrips(query: String) throws {
        let url = try #require(AmazonPage.searchURL(for: query))
        #expect(AmazonPage.of(url) == .search(query: query))
    }

    @Test("An empty search builds no address")
    func refusesEmptySearch() {
        #expect(AmazonPage.searchURL(for: "") == nil)
        #expect(AmazonPage.searchURL(for: "   \n ") == nil)
    }

    @Test("A product address round-trips, and a bad id builds nothing")
    func productURLRoundTrips() throws {
        let url = try #require(AmazonPage.productURL(asin: "B088NRLMPV"))
        #expect(AmazonPage.of(url) == .product(asin: "B088NRLMPV"))
        #expect(AmazonPage.productURL(asin: "nope") == nil)
        #expect(AmazonPage.productURL(asin: "") == nil)
    }

    /// Amazon writes ids uppercase everywhere, but a hand-typed or
    /// lower-cased link should still land on the product rather than nowhere.
    @Test("A lower-case id is accepted and normalised")
    func normalisesCase() throws {
        let url = try #require(AmazonPage.productURL(asin: "b088nrlmpv"))
        #expect(AmazonPage.of(url) == .product(asin: "B088NRLMPV"))
        #expect(AmazonPage.of(URL(string: "https://www.amazon.com/dp/b088nrlmpv"))
            == .product(asin: "B088NRLMPV"))
    }

    // MARK: - Id shape

    @Test("A product id is ten uppercase alphanumerics")
    func validatesASIN() {
        #expect(AmazonPage.isValidASIN("B088NRLMPV"))
        #expect(AmazonPage.isValidASIN("0439708184"))
        #expect(AmazonPage.isValidASIN("B088NRLMP") == false)   // nine
        #expect(AmazonPage.isValidASIN("B088NRLMPVX") == false) // eleven
        #expect(AmazonPage.isValidASIN("b088nrlmpv") == false)  // lower case
        #expect(AmazonPage.isValidASIN("B088-RLMPV") == false)  // punctuation
        #expect(AmazonPage.isValidASIN("") == false)
        #expect(AmazonPage.isValidASIN("B088NRLMP\u{00C9}") == false) // non-ASCII
    }

    // MARK: - Accessors

    @Test("The query and the id are readable without a switch")
    func exposesPayloads() {
        #expect(AmazonPage.search(query: "tripod").searchQuery == "tripod")
        #expect(AmazonPage.product(asin: "B088NRLMPV").productASIN == "B088NRLMPV")
        #expect(AmazonPage.home.searchQuery == nil)
        #expect(AmazonPage.home.productASIN == nil)
    }
}

@Suite("Sites Focus has a lens for")
struct SiteFocusAmazonTests {

    @Test("amazon.com is claimed, with or without www")
    func claimsAmazon() {
        #expect(SiteFocusSite.matching(URL(string: "https://www.amazon.com/s?k=x")) == .amazon)
        #expect(SiteFocusSite.matching(URL(string: "https://amazon.com/")) == .amazon)
        #expect(SiteFocusSite.amazon.claims(URL(string: "https://www.amazon.com/dp/B088NRLMPV")))
    }

    /// Every one of these runs different markup, a different currency, or is
    /// not a storefront at all. Reading a price wrong is worse than declining
    /// to offer, so the allowlist stays narrow until each is actually driven.
    @Test("Nothing else wearing the Amazon name is claimed", arguments: [
        "https://www.amazon.co.uk/s?k=x",
        "https://www.amazon.de/",
        "https://www.amazon.com.au/",
        "https://smile.amazon.com/",
        "https://m.media-amazon.com/images/I/x.jpg",
        "https://aws.amazon.com/",
        "https://notamazon.com/",
        "https://amazon.com.evil.example/",
    ])
    func refusesLookalikes(address: String) {
        #expect(SiteFocusSite.matching(URL(string: address)) != .amazon)
    }

    @Test("The two lenses don't claim one another's pages")
    func lensesStayApart() {
        #expect(SiteFocusSite.amazon.claims(URL(string: "https://www.youtube.com/")) == false)
        #expect(SiteFocusSite.youtube.claims(URL(string: "https://www.amazon.com/")) == false)
    }

    @Test("Every site has a name to put on the pill")
    func namesEverySite() {
        for site in SiteFocusSite.allCases {
            #expect(site.displayName.isEmpty == false)
        }
    }
}
