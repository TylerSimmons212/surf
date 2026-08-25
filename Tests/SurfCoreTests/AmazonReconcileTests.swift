import Foundation
import Testing
@testable import SurfCore

/// The tests that matter most in this feature.
///
/// Every wrong answer here puts a confident lie in front of someone: telling
/// them nothing matched when Amazon actually served a bot check, drawing a
/// product page over a password field, or showing an empty grid that means
/// our parser broke. The function is pure precisely so that all of this can
/// be asserted without a web view.
@Suite("Reading an Amazon page")
struct AmazonReconcileTests {

    private let searchURL = URL(string: "https://www.amazon.com/s?k=tripod")
    private let productURL = URL(string: "https://www.amazon.com/dp/B088NRLMPV")

    private func card(_ asin: String, sponsored: Bool = false) -> AmazonCardWire {
        AmazonCardWire(
            asin: asin, sponsored: sponsored ? "Sponsored" : nil, title: "A tripod"
        )
    }

    private var goodProduct: AmazonProductWire {
        AmazonProductWire(
            asin: "B088NRLMPV", title: "Anker USB C Cable",
            prices: ["$9.99"], priceText: "$9.99", availability: "In Stock"
        )
    }

    // MARK: - The page's content wins over its address

    /// Amazon serves this at the URL you asked for, with an ordinary body and
    /// a 503 that WebKit never reports as a failure. Nothing but the page's
    /// own content reveals it — which is exactly why the YouTube lens's
    /// "decide from the address" rule does not survive the trip here.
    @Test("A bot check is recognised even though it wears the search address")
    func recognisesBotCheck() {
        let reply = AmazonPageReply(cards: [], botCheck: true)
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .blocked(.botCheck))
    }

    @Test("A bot check outranks everything else the page might say")
    func botCheckOutranksContent() {
        let reply = AmazonPageReply(
            cards: [card("B000000001")], resultBar: "1-16 of 70,000", botCheck: true
        )
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .blocked(.botCheck))
    }

    @Test("A password field is never framed in our chrome")
    func recognisesSignIn() {
        let byContent = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"), url: productURL,
            reply: AmazonPageReply(signIn: true)
        )
        let byAddress = AmazonReconcile.read(
            expected: .cart,
            url: URL(string: "https://www.amazon.com/ap/signin?next=x"),
            reply: AmazonPageReply()
        )
        #expect(byContent == .blocked(.signIn))
        #expect(byAddress == .blocked(.signIn))
    }

    // MARK: - Results

    @Test("A page with organic results reads as results")
    func readsResults() {
        let reply = AmazonPageReply(
            cards: [card("B000000001", sponsored: true), card("B000000002")],
            resultBar: "1-16 of over 70,000 results for \"tripod\""
        )
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .results([AmazonResult(id: "B000000002", title: "A tripod")]))
    }

    /// Measured: a nonsense query returns eight cards, every one of them an
    /// advert, and an empty result bar. That is Amazon having nothing to
    /// say — and after our filter it looks exactly like our parser breaking,
    /// which is why the card count has to cross the bridge.
    @Test("A page of nothing but adverts is Amazon having no results")
    func readsAllSponsoredAsNoResults() {
        let reply = AmazonPageReply(
            cards: (1...8).map { card(String(format: "B%09d", $0), sponsored: true) }
        )
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .noResults(query: "tripod"))
    }

    /// Which query gets named when there is nothing to show: the one in the
    /// address, not the one we set out to run. Amazon rewrites queries — it
    /// corrects spelling and drops terms — and the honest message names what
    /// was actually searched for.
    @Test("The query in the message is the one Amazon actually ran")
    func namesTheQueryAmazonRan() {
        let reading = AmazonReconcile.read(
            expected: .search(query: "qxzjplmwvbn"),
            url: URL(string: "https://www.amazon.com/s?k=corrected+spelling"),
            reply: AmazonPageReply(cards: [card("B000000001", sponsored: true)])
        )
        #expect(reading == .noResults(query: "corrected spelling"))
    }

    @Test("Amazon saying so itself is taken at its word")
    func readsExplicitNoResults() {
        let reply = AmazonPageReply(cards: [], noResults: "No results for tripod")
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .noResults(query: "tripod"))
    }

    /// The failure this whole arrangement exists to catch. Amazon counted
    /// results, and not one of them reached us — so the page is fine and our
    /// reading is broken, and the honest response is to show the real site.
    @Test("Results counted but none read is our failure, not Amazon's")
    func readsCountedButUnreadAsBroken() {
        let reply = AmazonPageReply(
            cards: [], resultBar: "1-16 of over 70,000 results for \"tripod\""
        )
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: reply
        )
        #expect(reading == .blocked(.cannotRead))
    }

    @Test("An empty page with no markers at all is not yet a verdict")
    func waitsForAnUnmarkedPage() {
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL,
            reply: AmazonPageReply()
        )
        #expect(reading == .notReady)
    }

    @Test("No reply yet is not a verdict either")
    func waitsForAReply() {
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"), url: searchURL, reply: nil
        )
        #expect(reading == .notReady)
    }

    // MARK: - Products

    @Test("A readable product page reads as a product")
    func readsProduct() {
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"), url: productURL,
            reply: AmazonPageReply(product: goodProduct)
        )
        guard case .product(let product) = reading else {
            Issue.record("expected a product, got \(reading)")
            return
        }
        #expect(product.id == "B088NRLMPV")
    }

    /// Amazon canonicalises ids constantly — you ask for one and are handed
    /// its twin. That is normal, and the page's own id is the one that wins,
    /// because every write is gated on it matching the document.
    @Test("Landing on a different product id than requested keeps the page's id")
    func acceptsCanonicalisedID() {
        var other = goodProduct
        other.asin = "B0CFQ5T5F6"
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"),
            url: URL(string: "https://www.amazon.com/dp/B0CFQ5T5F6"),
            reply: AmazonPageReply(product: other)
        )
        guard case .product(let product) = reading else {
            Issue.record("expected a product, got \(reading)")
            return
        }
        #expect(product.id == "B0CFQ5T5F6")
    }

    @Test("A product below quorum hands the page back rather than drawing a shell")
    func refusesProductBelowQuorum() {
        var thin = goodProduct
        thin.prices = []
        thin.priceText = nil
        thin.availability = nil
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"), url: productURL,
            reply: AmazonPageReply(product: thin)
        )
        #expect(reading == .blocked(.cannotRead))
    }

    @Test("A product page that hasn't produced a product yet is not a verdict")
    func waitsForProduct() {
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"), url: productURL,
            reply: AmazonPageReply()
        )
        #expect(reading == .notReady)
    }

    // MARK: - Landing somewhere else entirely

    /// Amazon does this when an item is withdrawn: you ask for a product and
    /// get the front page. Drawing the previous product over it would be a
    /// lie about what is on screen.
    @Test("Aiming at a product and landing on the front page is not a product")
    func catchesRedirectAwayFromProduct() {
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"),
            url: URL(string: "https://www.amazon.com/"),
            reply: AmazonPageReply()
        )
        #expect(reading == .blocked(.unsupported))
    }

    @Test("A page we have no lens for is handed back")
    func handsBackUnsupportedPages() {
        let reading = AmazonReconcile.read(
            expected: .search(query: "tripod"),
            url: URL(string: "https://www.amazon.com/gp/offer-listing/B088NRLMPV"),
            reply: AmazonPageReply()
        )
        #expect(reading == .blocked(.unsupported))
    }

    @Test("Order history is handed back even when we aimed elsewhere")
    func handsBackOrders() {
        let reading = AmazonReconcile.read(
            expected: .whatever,
            url: URL(string: "https://www.amazon.com/gp/css/order-history"),
            reply: AmazonPageReply()
        )
        #expect(reading == .blocked(.unsupported))
    }

    /// Opening the lens on whatever is already on screen shouldn't declare a
    /// failure just because it isn't a search or a product.
    ///
    /// That sentence is unchanged, and it was always right. What was wrong was
    /// this test asserting `.notReady` to achieve it — a value whose whole
    /// meaning is "wait and read again", which after four rungs of the ladder
    /// declares precisely the failure the sentence forbids. The promise was
    /// tested by its mechanism instead of by its outcome, and the mechanism
    /// did not keep it.
    @Test("Opening on an ordinary page offers the field rather than failing")
    func offersTheFieldWhenNothingWasExpected() {
        let reading = AmazonReconcile.read(
            expected: .whatever,
            url: URL(string: "https://www.amazon.com/"),
            reply: AmazonPageReply()
        )
        #expect(reading == .nothingToShow)
    }
}

@Suite("The cart badge")
struct CartBadgeTests {

    @Test("A fresh document's number is taken as fact")
    func observesFromDocument() {
        let badge = CartBadge().observing("3")
        #expect(badge.count == 3)
        #expect(badge.confidence == .observed)
        #expect(badge.isTrustworthy)
    }

    /// A page with no cart node tells us nothing, which is a different thing
    /// from telling us zero.
    @Test("A page that says nothing about the cart changes nothing")
    func ignoresSilence() {
        let known = CartBadge(count: 3, confidence: .observed)
        #expect(known.observing(nil) == known)
        #expect(known.observing("") == known)
        #expect(known.observing("  ") == known)
    }

    @Test("After a write the number is a guess until the page agrees")
    func assumesAfterWrite() {
        let badge = CartBadge(count: 2).assuming(added: 1)
        #expect(badge.count == 3)
        #expect(badge.confidence == .assumed)
        #expect(badge.isTrustworthy)
    }

    @Test("The page agreeing settles it")
    func confirmationPromotes() {
        let badge = CartBadge(count: 2).assuming(added: 1).observing("3")
        #expect(badge.count == 3)
        #expect(badge.confidence == .observed)
    }

    /// The page disagreeing also settles it — in Amazon's favour, because
    /// Amazon is the one holding the cart.
    @Test("The page disagreeing settles it too, and Amazon wins")
    func documentBeatsGuess() {
        let badge = CartBadge(count: 2).assuming(added: 1).observing("7")
        #expect(badge.count == 7)
        #expect(badge.confidence == .observed)
    }

    /// The rule this type exists for: a number confidently wrong about
    /// someone's cart is the worst thing this feature can produce, so when
    /// waiting runs out the badge stops claiming to know.
    @Test("A guess that never gets confirmed stops being shown as fact")
    func givesUpHonestly() {
        let badge = CartBadge(count: 2).assuming(added: 1).givingUp()
        #expect(badge.count == 3)
        #expect(badge.confidence == .unsure)
        #expect(badge.isTrustworthy == false)
    }

    @Test("Giving up on something never guessed at changes nothing")
    func givingUpIsSafeOnObserved() {
        let observed = CartBadge(count: 4, confidence: .observed)
        #expect(observed.givingUp() == observed)
    }

    @Test("An observation after giving up restores confidence")
    func recovers() {
        let badge = CartBadge(count: 2).assuming(added: 1).givingUp().observing("3")
        #expect(badge.confidence == .observed)
        #expect(badge.isTrustworthy)
    }
}

@Suite("Amazon: entering Focus on a page with no lens")
struct AmazonEnteringFocusTests {

    /// Reported from real use: enter Focus and, with nothing touched, the lens
    /// says "Amazon didn't finish loading that."
    ///
    /// Entering Focus reads the page that is already open with no expectation
    /// in hand. On the front page — or a department, or an order list — there
    /// is nothing for the lens to draw, and that came back as `.notReady`: the
    /// answer that means "wait and read again". So the ladder waited, read
    /// again, ran out, and failed a page that was never going to become
    /// anything else.
    ///
    /// A page with no lens of its own is the search field's job, which is what
    /// the YouTube lens does in the same situation.
    @Test(
        "A page with no lens of its own is the search field, not a failure",
        arguments: [
            "https://www.amazon.com/",
            "https://www.amazon.com/gp/bestsellers",
            "https://www.amazon.com/b?node=283155",
        ]
    )
    func homeIsNotAFailure(address: String) {
        let reading = AmazonReconcile.read(
            expected: .whatever,
            url: URL(string: address),
            reply: AmazonPageReply()
        )
        #expect(reading == .nothingToShow, "\(address) gave \(reading)")
    }

    /// The distinction that has to survive: landing somewhere unexpected *in
    /// the middle of a navigation we started* is still a real problem, and
    /// still hands the page back.
    @Test("Aiming at a product and landing on the front page is still wrong")
    func aMissedNavigationStillBlocks() {
        let reading = AmazonReconcile.read(
            expected: .product(asin: "B088NRLMPV"),
            url: URL(string: "https://www.amazon.com/"),
            reply: AmazonPageReply()
        )
        #expect(reading == .blocked(.unsupported))
    }
}
