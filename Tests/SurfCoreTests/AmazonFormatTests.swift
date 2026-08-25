import Foundation
import Testing
@testable import SurfCore

/// The strings in these tests were copied out of amazon.com, newlines and
/// all, rather than written to be convenient. Where a fixture looks strange —
/// "Price, product page $9.99 $9 . 99 ( $5.00 $5.00/count)" — that is what
/// `textContent` actually returns for a price cell.

@Suite("Amazon prices")
struct AmazonPriceTests {

    @Test("A plain price reads as a number and keeps its display text")
    func readsPlainPrice() throws {
        let price = try #require(AmazonPrice.parse("$9.99"))
        #expect(price.display == "$9.99")
        #expect(price.amount == Decimal(string: "9.99"))
        #expect(price.currency == "$")
        #expect(price.isRange == false)
    }

    @Test("Grouping separators don't inflate the number", arguments: [
        ("$1,299.00", "1299.00"),
        ("$87,229.50", "87229.50"),
        ("$1,234,567.89", "1234567.89"),
        ("$0.33", "0.33"),
        ("$5", "5"),
    ])
    func readsGroupedNumbers(raw: String, expected: String) throws {
        let price = try #require(AmazonPrice.parse(raw))
        #expect(price.amount == Decimal(string: expected))
    }

    /// Not a locale we serve today, but the reader shouldn't turn 1.299,00
    /// into a hundred and thirty thousand if it ever sees one.
    @Test("A comma decimal point is read as a decimal point")
    func readsEuropeanFormat() throws {
        let price = try #require(AmazonPrice.parse("1.299,00 \u{20AC}"))
        #expect(price.amount == Decimal(string: "1299.00"))
        #expect(price.currency == "\u{20AC}")
    }

    @Test("A parent product's price range is marked as one")
    func marksRange() throws {
        let price = try #require(AmazonPrice.parse("$12.99 - $24.99"))
        #expect(price.isRange)
        #expect(price.amount == Decimal(string: "12.99"))
        #expect(price.display == "$12.99 - $24.99")
    }

    @Test("A label with no number is not a price")
    func rejectsLabels() {
        #expect(AmazonPrice.parse("Price, product page") == nil)
        #expect(AmazonPrice.parse("") == nil)
        #expect(AmazonPrice.parse("   \n  ") == nil)
        #expect(AmazonPrice.parse("Currently unavailable") == nil)
    }

    /// The rule at the top of AmazonFormat: a string we can't turn into a
    /// number still renders. Blank is a nuisance; confidently wrong is not.
    @Test("An unreadable price keeps its display text and loses its number")
    func keepsDisplayWithoutAmount() throws {
        let price = try #require(AmazonPrice.parse("$--.--9"))
        #expect(price.display == "$--.--9")
        #expect(price.currency == "$")
    }

    // MARK: - Telling the price from the rate

    /// Captured verbatim from a `data-cy="price-recipe"` cell.
    private let recipe = """
        Price, product page
        $9.99
        $9
        .
        99 (
        $5.00
        $5.00/count)
        """

    /// The rate is rendered one way whatever punctuation the page used.
    /// Amazon writes "$5.00/count" on a search card and "$5.00 / count" on a
    /// product page, and echoing each verbatim would put both spellings in
    /// front of the same reader on the same visit.
    @Test("The item price is told from the per-unit price")
    func splitsItemFromUnit() throws {
        let split = AmazonPrice.split(
            candidates: ["$9.99", "$5.00"], containerText: recipe
        )
        #expect(try #require(split.item).amount == Decimal(string: "9.99"))
        #expect(split.unit == "$5.00 per count")
    }

    /// The test that proves this isn't "first one wins". Amazon reorders
    /// these nodes across layouts, and position alone would have us render
    /// the rate as the price the day it happens.
    @Test("Reversing the order doesn't change which one is the price")
    func splitIgnoresOrder() throws {
        let split = AmazonPrice.split(
            candidates: ["$5.00", "$9.99"], containerText: recipe
        )
        #expect(try #require(split.item).amount == Decimal(string: "9.99"))
        #expect(split.unit == "$5.00 per count")
    }

    @Test("A card with one price has no unit price")
    func splitHandlesLonePrice() throws {
        let split = AmazonPrice.split(
            candidates: ["$19.99"], containerText: "Price, product page $19.99 $19 . 99"
        )
        #expect(try #require(split.item).amount == Decimal(string: "19.99"))
        #expect(split.unit == nil)
    }

    @Test("A card with no prices yields none")
    func splitHandlesNothing() {
        let split = AmazonPrice.split(candidates: [], containerText: "")
        #expect(split.item == nil)
        #expect(split.unit == nil)
    }

    /// If every candidate looked like a rate, the reading was wrong — not the
    /// item free. Falling back beats rendering a card with no price at all.
    @Test("When every candidate looks like a rate, the first is still used")
    func splitFallsBack() throws {
        let split = AmazonPrice.split(
            candidates: ["$5.00"], containerText: "$5.00/count"
        )
        #expect(try #require(split.item).amount == Decimal(string: "5.00"))
    }
}

@Suite("Amazon ratings")
struct AmazonRatingTests {

    @Test("Stars are read from both spellings the site uses", arguments: [
        ("4.7 out of 5 stars", 4.7),
        ("4.6 out of 5 stars, rating details", 4.6),
        ("5 out of 5 stars", 5.0),
        ("4.7 out of 5", 4.7),
    ])
    func readsStars(raw: String, expected: Double) throws {
        let stars = try #require(AmazonRating.stars(raw))
        #expect(abs(stars - expected) < 0.001)
    }

    /// This number decides how many stars get drawn. A payload saying 47
    /// should lose its rating rather than paint a row off the card.
    @Test("A rating outside the scale is refused")
    func boundsStars() {
        #expect(AmazonRating.stars("47 out of 5 stars") == nil)
        #expect(AmazonRating.stars("out of 5 stars") == nil)
        #expect(AmazonRating.stars("") == nil)
    }

    @Test("Review counts read the same whether spelled out or compacted", arguments: [
        ("(87,229)", 87_229),
        ("87,229", 87_229),
        ("(16.1K)", 16_100),
        ("(10.7K)", 10_700),
        ("(1.2M)", 1_200_000),
        ("1,234 ratings", 1_234),
        ("(3)", 3),
    ])
    func readsCounts(raw: String, expected: Int) {
        #expect(AmazonRating.count(raw) == expected)
    }

    /// A regression, and a real one. `a[aria-label*="rating"]` matches the
    /// rating popover before the count link, and reading that as a count
    /// turns 87,229 reviews into 47. The selector was fixed; this makes the
    /// same mistake fail loudly next time rather than render a plausible
    /// wrong number.
    @Test("A sentence describing a rating is never read as a count")
    func refusesRatingsAsCounts() {
        #expect(AmazonRating.count("4.7 out of 5 stars, rating details") == nil)
        #expect(AmazonRating.count("4.7 out of 5 stars") == nil)
        // The real thing still reads.
        #expect(AmazonRating.count("87,229 ratings") == 87_229)
        #expect(AmazonRating.count("3 ratings") == 3)
    }

    @Test("A count with no number is no count")
    func rejectsEmptyCounts() {
        #expect(AmazonRating.count("") == nil)
        #expect(AmazonRating.count("()") == nil)
        #expect(AmazonRating.count("ratings") == nil)
    }
}

@Suite("Amazon images")
struct AmazonImageTests {

    private let thumb =
        "https://m.media-amazon.com/images/I/71IE9dLBduL._AC_UY218_.jpg"

    /// The measured reason this exists: the grid ships 166×218, which is soft
    /// in a 300pt card, and the same picture at SX679 is 679 across.
    @Test("A thumbnail can be asked for at a usable size")
    func resizes() {
        #expect(AmazonImage.sized(thumb, width: 679)
            == "https://m.media-amazon.com/images/I/71IE9dLBduL._AC_SX679_.jpg")
    }

    /// The gallery's main image carries a bundle overlay in its modifier.
    /// Replacing the whole block is intentional: we want the product, not
    /// Amazon's "2-pack" sticker burned into the pixels.
    @Test("A modifier with overlays is replaced whole")
    func replacesCompoundModifier() {
        let bundled = "https://m.media-amazon.com/images/I/"
            + "71IE9dLBduL._AC_SY355_PIbundle-2,TopRight,0,0_SH20_.jpg"
        #expect(AmazonImage.sized(bundled, width: 679)
            == "https://m.media-amazon.com/images/I/71IE9dLBduL._AC_SX679_.jpg")
    }

    @Test("Dropping the modifier asks for the original")
    func stripsToOriginal() {
        #expect(AmazonImage.original(thumb)
            == "https://m.media-amazon.com/images/I/71IE9dLBduL.jpg")
    }

    /// The defensive half, and the more important one. Rewriting a filename
    /// we don't understand turns a working picture into a 404, so anything
    /// unfamiliar comes back exactly as it arrived.
    @Test("Anything unfamiliar is returned untouched", arguments: [
        "https://example.com/images/I/71IE9dLBduL._AC_UY218_.jpg",
        "https://m.media-amazon.com/gp/thing.html",
        "https://m.media-amazon.com/images/I/71IE9dLBduL.jpg",
        "not a url at all",
        "",
    ])
    func leavesUnknownAddressesAlone(address: String) {
        #expect(AmazonImage.sized(address, width: 679) == address)
        #expect(AmazonImage.original(address) == address)
    }

    @Test("A nonsense width changes nothing")
    func refusesBadWidth() {
        #expect(AmazonImage.sized(thumb, width: 0) == thumb)
        #expect(AmazonImage.sized(thumb, width: -10) == thumb)
    }

    @Test("Resizing is idempotent")
    func resizeIsStable() {
        let once = AmazonImage.sized(thumb, width: 679)
        #expect(AmazonImage.sized(once, width: 679) == once)
    }
}

@Suite("Amazon text")
struct AmazonTextTests {

    /// Everything crosses the bridge as `textContent`, which keeps the
    /// markup's own indentation. This runs before anything else looks at a
    /// string.
    @Test("Markup whitespace collapses to single spaces")
    func tidies() {
        #expect(AmazonText.tidy("  Anker USB C\n\n  to USB C Cable \t ")
            == "Anker USB C to USB C Cable")
        #expect(AmazonText.tidy("") == "")
        #expect(AmazonText.tidy("\n \t ") == "")
    }

    @Test("A field with several candidate selectors takes the first with anything in it")
    func picksFirstNonEmpty() {
        #expect(AmazonText.firstNonEmpty(["", "  \n ", "Anker", "Belkin"]) == "Anker")
        #expect(AmazonText.firstNonEmpty([]) == "")
        #expect(AmazonText.firstNonEmpty(["", ""]) == "")
    }
}

@Suite("Amazon prices on the product page")
struct AmazonProductPriceTests {

    /// Copied verbatim from `#corePriceDisplay_desktop_feature_div`. The
    /// spaced-out "$ 9 . 99" is Amazon rendering the same price a second time
    /// character by character for its own layout.
    private let container = "$9.99 $ 9 . 99 $5.00 per count ( $5.00 $5.00 / count)"

    /// The regression. The first version of `split` asked whether a candidate
    /// was followed by a slash with no space, and trusted the order of the
    /// price nodes. On this page it read a $9.99 cable as costing $5.00 —
    /// rendering the rate as the price, in the largest type on the screen.
    @Test("The price is the price, not the rate")
    func readsTheItemPrice() throws {
        let split = AmazonPrice.split(
            candidates: ["$9.99", "$5.00", "", "$5.00"], containerText: container
        )
        #expect(try #require(split.item).amount == Decimal(string: "9.99"))
        #expect(split.unit == "$5.00 per count")
    }

    /// The spacing around the slash varies between Amazon's own layouts —
    /// "$5.00/count" on a search card, "$5.00 / count" on a product page —
    /// and so does the word it uses for it.
    @Test("Every spelling of a rate is recognised as one", arguments: [
        "$9.99 ($5.00/count)",
        "$9.99 ( $5.00 / count)",
        "$9.99 $5.00 per count",
        "$9.99  $5.00  /  count",
    ])
    func recognisesRates(container: String) throws {
        let split = AmazonPrice.split(
            candidates: ["$9.99", "$5.00"], containerText: container
        )
        #expect(try #require(split.item).amount == Decimal(string: "9.99"))
        #expect(split.unit?.hasPrefix("$5.00 per") == true)
    }

    /// Node order is no longer consulted at all: the container's text is the
    /// reading order, because it is what a person reads.
    @Test("The order of the price nodes cannot change the answer")
    func ignoresNodeOrder() throws {
        for candidates in [["$9.99", "$5.00"], ["$5.00", "$9.99"], ["$5.00", "$5.00", "$9.99"]] {
            let split = AmazonPrice.split(candidates: candidates, containerText: container)
            #expect(try #require(split.item).amount == Decimal(string: "9.99"))
        }
    }

    /// A page that spells the price out character by character must not read
    /// as a page with several prices on it.
    @Test("A price spelled out in pieces is not a second price")
    func ignoresSpelledOutPrices() {
        let tokens = AmazonPrice.priceTokens(in: container)
        #expect(tokens.map(\.text) == ["$9.99", "$5.00", "$5.00", "$5.00"])
    }

    @Test("A currency mark in prose is not a price")
    func ignoresLooseSymbols() {
        #expect(AmazonPrice.priceTokens(in: "Free delivery on orders over $ and more").isEmpty)
        #expect(AmazonPrice.priceTokens(in: "costs $").isEmpty)
    }

    /// With no container to read, the nodes are still all there is.
    @Test("An empty container falls back to the nodes")
    func fallsBackToNodes() throws {
        let split = AmazonPrice.split(candidates: ["$14.99"], containerText: "")
        #expect(try #require(split.item).amount == Decimal(string: "14.99"))
        #expect(split.unit == nil)
    }
}
