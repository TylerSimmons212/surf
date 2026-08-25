import Foundation
import Testing
@testable import SurfCore

/// Fixtures here are shaped after a real `usb c cable` search and a real
/// product page, both read on amazon.com. The numbers that look arbitrary —
/// twenty-two cards, six of them sponsored, one product id appearing twice —
/// are measurements, not inventions.

// MARK: - The grid

@Suite("Amazon search results")
struct AmazonResultTests {

    private func card(
        _ asin: String, title: String = "A cable",
        sponsored: Bool = false
    ) -> AmazonCardWire {
        AmazonCardWire(
            asin: asin,
            sponsored: sponsored ? "Sponsored" : nil,
            title: title,
            image: "https://m.media-amazon.com/images/I/71IE9dLBduL._AC_UY218_.jpg",
            prices: ["$9.99", "$5.00"],
            priceText: "Price, product page $9.99 $9 . 99 ( $5.00 $5.00/count)",
            rating: "4.7 out of 5 stars",
            reviews: "(87,229)",
            delivery: "FREE delivery Sat, Aug 29",
            badge: "Overall Pick"
        )
    }

    @Test("A card reads into a result with everything the grid draws")
    func parsesACard() throws {
        let results = AmazonResult.parse(cards: [card("B088NRLMPV")])
        let result = try #require(results.first)
        #expect(result.id == "B088NRLMPV")
        #expect(result.title == "A cable")
        #expect(result.price?.amount == Decimal(string: "9.99"))
        #expect(result.unitPrice == "$5.00 per count")
        #expect(result.stars == 4.7)
        #expect(result.reviewCount == 87_229)
        #expect(result.badge == "Overall Pick")
        #expect(result.productURL?.absoluteString == "https://www.amazon.com/dp/B088NRLMPV")
    }

    /// The feature, in one assertion. Six of twenty-two cards on a real
    /// search were paid placements.
    @Test("Sponsored cards do not reach the grid")
    func dropsSponsored() {
        let cards = [
            card("B000000001", sponsored: true),
            card("B000000002"),
            card("B000000003", sponsored: true),
            card("B000000004"),
        ]
        let results = AmazonResult.parse(cards: cards)
        #expect(results.map(\.id) == ["B000000002", "B000000004"])
    }

    /// Measured on the live page: ASIN B0CFQ5T5F6 was the first sponsored
    /// card and also the sixth organic result. Amazon pays to show you
    /// something it was going to show you anyway.
    @Test("A product paid for and also earned appears once")
    func dedupesTheAdAndTheResult() {
        let cards = [
            card("B0CFQ5T5F6", sponsored: true),
            card("B000000002"),
            card("B0CFQ5T5F6"),
        ]
        let results = AmazonResult.parse(cards: cards)
        #expect(results.map(\.id) == ["B000000002", "B0CFQ5T5F6"])
    }

    @Test("The same product twice organically still appears once")
    func dedupesOrganicRepeats() {
        let results = AmazonResult.parse(cards: [
            card("B000000002"), card("B000000002"),
        ])
        #expect(results.count == 1)
    }

    /// `data-asin` sits on shelf headers and advert frames too. A card that
    /// cannot name a product is a card that cannot be clicked.
    @Test("A card that can't name a product is dropped", arguments: [
        AmazonCardWire(asin: nil, title: "A cable"),
        AmazonCardWire(asin: "", title: "A cable"),
        AmazonCardWire(asin: "TOOSHORT", title: "A cable"),
        AmazonCardWire(asin: "B088NRLMPV", title: nil),
        AmazonCardWire(asin: "B088NRLMPV", title: "   \n "),
    ])
    func dropsUnnameableCards(wire: AmazonCardWire) {
        #expect(AmazonResult.parse(cards: [wire]).isEmpty)
    }

    /// The rule from the top of the model file: one missing field never
    /// costs a whole card.
    @Test("A card missing everything optional still renders")
    func survivesMissingFields() throws {
        let bare = AmazonCardWire(asin: "B088NRLMPV", title: "A cable")
        let result = try #require(AmazonResult.parse(cards: [bare]).first)
        #expect(result.price == nil)
        #expect(result.stars == nil)
        #expect(result.reviewCount == nil)
        #expect(result.delivery.isEmpty)
    }

    @Test("The grid asks for a picture big enough to draw")
    func upscalesTheThumbnail() {
        let results = AmazonResult.parse(cards: [card("B088NRLMPV")])
        #expect(results.first?.imageURL(width: 679)
            == "https://m.media-amazon.com/images/I/71IE9dLBduL._AC_SX679_.jpg")
    }

    @Test("The site's ranking order is preserved")
    func keepsOrder() {
        let results = AmazonResult.parse(cards: [
            card("B000000003"), card("B000000001"), card("B000000002"),
        ])
        #expect(results.map(\.id) == ["B000000003", "B000000001", "B000000002"])
    }
}

// MARK: - The product page

@Suite("Amazon products")
struct AmazonProductTests {

    private var anker: AmazonProductWire {
        AmazonProductWire(
            asin: "B088NRLMPV",
            title: "Anker USB C to USB C Cable, 60W Fast Charging Cable",
            byline: "Visit the Anker Store",
            prices: ["$9.99", "$5.00"],
            priceText: "$9.99 ( $5.00 $5.00/count)",
            listPrice: "$19.99",
            rating: "4.7 out of 5 stars",
            reviews: "(87,229)",
            availability: "In Stock",
            delivery: "FREE delivery Saturday, August 29\nOr Prime members get it tomorrow",
            seller: "AnkerDirect",
            images: ["https://m.media-amazon.com/images/I/71IE9dLBduL._AC_SX679_.jpg"],
            bullets: ["Durable Design", "Fast Charging"],
            specs: [
                AmazonSpecWire(label: "Brand", value: "Anker"),
                AmazonSpecWire(label: "Connector Type", value: "USB Type C"),
                AmazonSpecWire(label: "Brand", value: "Duplicate"),
                AmazonSpecWire(label: "", value: "orphan"),
            ],
            variations: [
                AmazonVariationWire(
                    dimension: "size_name", label: "Size: 6FT*2", selected: "6FT*2",
                    options: [
                        AmazonVariationOptionWire(value: "3.3FT*2", asin: "B088NMR44C"),
                        AmazonVariationOptionWire(value: "6FT*2", asin: "B088NRLMPV"),
                    ]
                ),
                // One option is not a choice, and shouldn't draw a row.
                AmazonVariationWire(
                    dimension: "color_name", label: "Color: Black", selected: "Black",
                    options: [AmazonVariationOptionWire(value: "Black", asin: "B088NRLMPV")]
                ),
            ],
            addToCart: true
        )
    }

    @Test("A product page reads into the decision column")
    func parsesProduct() throws {
        let product = try #require(AmazonPageReply(product: anker).parsedProduct)
        #expect(product.id == "B088NRLMPV")
        #expect(product.brand == "Anker")
        #expect(product.price?.amount == Decimal(string: "9.99"))
        #expect(product.listPrice?.amount == Decimal(string: "19.99"))
        #expect(product.stars == 4.7)
        #expect(product.availability == "In Stock")
        #expect(product.seller == "AnkerDirect")
        #expect(product.canAddToCart)
        #expect(product.meetsQuorum)
    }

    /// Amazon stacks two or three delivery sentences in one cell and the
    /// card has room for one.
    @Test("Only the first delivery promise is kept")
    func keepsOneDeliveryLine() throws {
        let product = try #require(AmazonPageReply(product: anker).parsedProduct)
        #expect(product.delivery == "FREE delivery Saturday, August 29")
    }

    @Test("Spec rows are deduplicated and orphans dropped")
    func cleansSpecs() throws {
        let product = try #require(AmazonPageReply(product: anker).parsedProduct)
        #expect(product.specs.map(\.label) == ["Brand", "Connector Type"])
        #expect(product.specs.first?.value == "Anker")
    }

    @Test("A dimension with one option is not offered as a choice")
    func dropsSingleOptionDimensions() throws {
        let product = try #require(AmazonPageReply(product: anker).parsedProduct)
        #expect(product.variations.map(\.id) == ["size_name"])
        #expect(product.variations.first?.label == "Size")
        #expect(product.variations.first?.options.count == 2)
        #expect(product.variations.first?.selected == "6FT*2")
    }

    /// Verified against a live limited-time deal: $39.99 from a $69.99 list,
    /// which Amazon itself badges as -43%.
    @Test("A real discount reads in both frames, and money keeps its cents")
    func readsBothDiscountFrames() throws {
        let deal = AmazonProduct(
            id: "B0BP9MDCQZ", title: "Fire TV Stick",
            price: AmazonPrice.parse("$39.99"),
            listPrice: AmazonPrice.parse("$69.99")
        )
        #expect(deal.savingsPercent == 43)
        #expect(try #require(deal.savingsAmount).display == "$30.00")
    }

    @Test("Savings are computed only when the claim holds")
    func computesSavings() {
        func product(_ now: String, _ was: String) -> AmazonProduct {
            AmazonProduct(
                id: "B088NRLMPV", title: "x",
                price: AmazonPrice.parse(now), listPrice: AmazonPrice.parse(was)
            )
        }
        #expect(product("$10.00", "$20.00").savingsPercent == 50)
        #expect(product("$9.99", "$19.99").savingsPercent == 50)
        // A "discount" that isn't one is Amazon being strange, and we don't
        // repeat it.
        #expect(product("$20.00", "$10.00").savingsPercent == nil)
        #expect(product("$10.00", "$10.00").savingsPercent == nil)
        #expect(product("$0.00", "$10.00").savingsPercent == nil)
    }

    /// The quorum: below this the reading failed, and a convincing-looking
    /// empty card is worse than handing the page back.
    @Test("A product without the minimum doesn't meet quorum")
    func enforcesQuorum() {
        #expect(AmazonProduct(id: "B088NRLMPV", title: "").meetsQuorum == false)
        #expect(AmazonProduct(id: "nope", title: "A cable").meetsQuorum == false)
        #expect(AmazonProduct(id: "B088NRLMPV", title: "A cable").meetsQuorum == false)
        // A price is enough…
        #expect(AmazonProduct(
            id: "B088NRLMPV", title: "A cable", price: AmazonPrice.parse("$9.99")
        ).meetsQuorum)
        // …and so is Amazon saying out loud that there isn't one.
        #expect(AmazonProduct(
            id: "B088NRLMPV", title: "A cable", availability: "Currently unavailable"
        ).meetsQuorum)
    }

    /// A regression. The script sends `location.pathname`, not an id — the
    /// path is the only unambiguous statement of which product a page is —
    /// and reading it as an id gave "/DP/B088NRLMPV", which is not ten
    /// characters and so parsed as nothing. The product page came up blank
    /// and said nothing about why.
    @Test("The document's path is read for the id it contains", arguments: [
        "/dp/B088NRLMPV",
        "/Anker-USB-C-Cable/dp/B088NRLMPV/ref=sr_1_6",
        "/gp/product/B088NRLMPV",
        "B088NRLMPV",
    ])
    func readsIDFromPath(path: String) throws {
        let reply = AmazonPageReply(product: AmazonProductWire(
            asin: path, title: "Anker USB C Cable",
            prices: ["$9.99"], priceText: "$9.99"
        ))
        let product = try #require(reply.parsedProduct)
        #expect(product.id == "B088NRLMPV")
        #expect(product.meetsQuorum)
    }

    @Test("A product with no id at all doesn't parse")
    func refusesUnnamedProduct() {
        #expect(AmazonPageReply(product: AmazonProductWire(asin: nil)).parsedProduct == nil)
        #expect(AmazonPageReply(product: AmazonProductWire(asin: "junk")).parsedProduct == nil)
    }
}

// MARK: - Reviews

@Suite("Amazon reviews")
struct AmazonReviewTests {

    private let wire = AmazonReviewWire(
        id: "R1RLJMX8S5STRH",
        stars: "5 out of 5 stars",
        title: "Reliable cable with fast charging",
        author: "Angelina Hill",
        date: "Reviewed in the United States on July 29, 2026",
        verified: true,
        body: "I've bought several Anker cables over the years.",
        helpful: "5 people found this helpful",
        variation: "Size: 3.3FT*2 Color: Black"
    )

    @Test("A review reads into the sheet")
    func parsesReview() throws {
        let review = try #require(AmazonReview.parse(reviews: [wire]).first)
        #expect(review.id == "R1RLJMX8S5STRH")
        #expect(review.stars == 5)
        #expect(review.author == "Angelina Hill")
        #expect(review.isVerified)
        #expect(review.helpful == "5 people found this helpful")
    }

    /// The country is Amazon telling you the review was imported, which
    /// matters to Amazon and not to the reader.
    @Test("The date loses the country and keeps the date")
    func trimsReviewDate() throws {
        let review = try #require(AmazonReview.parse(reviews: [wire]).first)
        #expect(review.date == "July 29, 2026")
    }

    /// A rating with no words is already counted by the histogram; showing
    /// it as an empty card in the list says nothing twice.
    @Test("A review with nothing written in it is not a review")
    func dropsEmptyReviews() {
        var empty = wire
        empty.body = "  \n "
        #expect(AmazonReview.parse(reviews: [empty]).isEmpty)
    }

    /// Position, deliberately, rather than a hash of the text. Two people
    /// can both write "Great!", and folding identical short reviews together
    /// would delete one of them.
    @Test("A review with no id of its own is identified by position")
    func fallsBackToPositionalIDs() {
        var anonymous = wire
        anonymous.id = nil
        let reviews = AmazonReview.parse(reviews: [anonymous, anonymous])
        #expect(reviews.map(\.id) == ["review-0", "review-1"])
    }

    @Test("The same review twice appears once")
    func dedupesReviews() {
        #expect(AmazonReview.parse(reviews: [wire, wire]).count == 1)
    }
}

@Suite("Amazon rating histogram")
struct AmazonHistogramTests {

    /// The real distribution from the test product.
    private let rows = ["5 star 87%", "4 star 8%", "3 star 2%", "2 star 1%", "1 star 2%"]

    @Test("Five rows read into five bars, five stars first")
    func parsesHistogram() throws {
        let histogram = try #require(AmazonHistogram.parse(rows: rows))
        #expect(histogram.percentages == [87, 8, 2, 1, 2])
    }

    /// Half a chart implies a distribution that isn't the product's, which
    /// is worse than no chart.
    @Test("A partial histogram is refused")
    func refusesPartial() {
        #expect(AmazonHistogram.parse(rows: Array(rows.prefix(3))) == nil)
        #expect(AmazonHistogram.parse(rows: []) == nil)
    }

    @Test("Percentages that don't add up are refused")
    func refusesNonsense() {
        #expect(AmazonHistogram.parse(rows: [
            "5 star 10%", "4 star 8%", "3 star 2%", "2 star 1%", "1 star 2%",
        ]) == nil)
    }

    @Test("Amazon's rounding is tolerated")
    func toleratesRounding() throws {
        // Each row rounds, so the total lands near a hundred, not on it.
        let histogram = try #require(AmazonHistogram.parse(rows: [
            "5 star 86%", "4 star 8%", "3 star 2%", "2 star 1%", "1 star 2%",
        ]))
        #expect(histogram.percentages == [86, 8, 2, 1, 2])
    }
}

// MARK: - Odds and ends

@Suite("Amazon delivery and brand text")
struct AmazonDeliveryTests {

    @Test("A stacked delivery cell keeps its first promise", arguments: [
        ("Join Prime to get FREE delivery Tomorrow, Aug 25\nOr Non-members get FREE delivery Sat, Aug 29 on $35",
         "Join Prime to get FREE delivery Tomorrow, Aug 25"),
        ("FREE delivery Saturday, August 29 Or Prime members get it tomorrow",
         "FREE delivery Saturday, August 29"),
        ("FREE delivery Saturday, August 29", "FREE delivery Saturday, August 29"),
        ("", ""),
    ])
    func keepsHeadline(raw: String, expected: String) {
        #expect(AmazonDelivery.headline(raw) == expected)
    }

    @Test("A byline reduces to the brand", arguments: [
        ("Visit the Anker Store", "Anker"),
        ("Brand: Anker", "Anker"),
        ("Anker", "Anker"),
        ("", ""),
    ])
    func readsBrand(raw: String, expected: String) {
        #expect(AmazonDelivery.brand(raw) == expected)
    }

    /// The two halves of a colon go opposite ways, which is why these are
    /// two functions.
    @Test("A variation heading reduces to the dimension")
    func readsDimensionLabel() {
        #expect(AmazonText.label("Size: 6FT*2") == "Size")
        #expect(AmazonText.label("Number of Items: 2") == "Number of Items")
        #expect(AmazonText.label("Size") == "Size")
    }
}

// MARK: - The gallery

@Suite("Amazon gallery")
struct AmazonGalleryTests {

    /// Trimmed from the real `colorImages` blob on a product page. Amazon
    /// publishes the photographs as JSON in a script tag; the markup's strip
    /// is forty-pixel thumbnails.
    private let blob = """
        [{"hiRes":"https://m.media-amazon.com/images/I/71IE9dLBduL._AC_SL1500_.jpg",\
        "thumb":"https://m.media-amazon.com/images/I/512+rDPw5UL._AC_US40_.jpg",\
        "large":"https://m.media-amazon.com/images/I/512+rDPw5UL._AC_.jpg",\
        "variant":"MAIN","altText":"Two black braided cables"},\
        {"hiRes":"https://m.media-amazon.com/images/I/71uYJy6BgzL._AC_SL1500_.jpg",\
        "thumb":"https://m.media-amazon.com/images/I/41mOy5HTm5L._AC_US40_.jpg",\
        "variant":"PT01","altText":""}]
        """

    @Test("The published photographs are read at full size")
    func parsesGallery() throws {
        let images = AmazonGallery.parse(blob: blob)
        #expect(images.count == 2)
        let first = try #require(images.first)
        #expect(first.url.hasSuffix("71IE9dLBduL._AC_SL1500_.jpg"))
        #expect(first.variant == "MAIN")
        #expect(first.alt == "Two black braided cables")
        #expect(first.thumb.hasSuffix("_AC_US40_.jpg"))
    }

    /// An entry with no high-resolution version keeps its picture rather than
    /// losing it.
    @Test("A missing hiRes falls back to the large image")
    func fallsBackToLarge() throws {
        let images = AmazonGallery.parse(blob: """
            [{"large":"https://m.media-amazon.com/images/I/abc._AC_.jpg","variant":"MAIN"}]
            """)
        #expect(try #require(images.first).url.hasSuffix("abc._AC_.jpg"))
    }

    @Test("The same picture twice appears once")
    func dedupes() {
        let one = #"{"hiRes":"https://m.media-amazon.com/images/I/a._AC_SL1500_.jpg"}"#
        #expect(AmazonGallery.parse(blob: "[\(one),\(one)]").count == 1)
    }

    /// The blob is scraped out of a script tag by index, so a page that
    /// changes shape hands this something that isn't JSON. It returns no
    /// pictures; the product still renders.
    @Test("Anything that isn't a gallery yields no pictures", arguments: [
        "", "   ", "not json", "{}", "[]", "[{\"hiRes\":\"javascript:alert(1)\"}]",
        "[{\"hiRes\":\"http://insecure.example/x.jpg\"}]",
    ])
    func refusesRubbish(blob: String) {
        #expect(AmazonGallery.parse(blob: blob).isEmpty)
    }

    @Test("The gallery is preferred over the markup's thumbnail strip")
    func galleryBeatsMarkup() {
        let withGallery = AmazonProduct(
            id: "B088NRLMPV", title: "x",
            images: ["https://m.media-amazon.com/images/I/tiny._AC_US40_.jpg"],
            gallery: [AmazonGalleryImage(url: "https://m.media-amazon.com/images/I/big._AC_SL1500_.jpg")]
        )
        #expect(withGallery.pictures.count == 1)
        #expect(withGallery.pictures.first?.url.contains("big") == true)

        // …and the strip is still the fallback when there is no gallery.
        let withoutGallery = AmazonProduct(
            id: "B088NRLMPV", title: "x",
            images: ["https://m.media-amazon.com/images/I/tiny._AC_US40_.jpg"]
        )
        #expect(withoutGallery.pictures.first?.url.contains("tiny") == true)
    }
}

// MARK: - Reviews, cleaned of Amazon's own interface

@Suite("Amazon review text")
struct AmazonReviewStripTests {

    /// Every phrase here was observed inside a review node on amazon.com. The
    /// vote widget pre-renders all of its states, so a review can end in
    /// three error messages nobody triggered.
    @Test("Amazon's interface is removed from what a person wrote")
    func stripsInterface() {
        let raw = """
            Brief content visible, double tap to read full content. \
            Full content visible, double tap to read brief content. \
            I've bought several Anker cables over the years. Read more Read less \
            7 people found this helpful Helpful Sending feedback... \
            Thank you for your feedback. Report
            """
        let clean = AmazonReview.strip(raw)
        #expect(clean.contains("I've bought several Anker cables over the years."))
        for noise in ["double tap", "Read more", "Read less", "Sending feedback"] {
            #expect(clean.contains(noise) == false, "\(noise) survived")
        }
        #expect(clean.hasSuffix("Report") == false)
    }

    /// The trailing single-word buttons come off the end only. A review that
    /// says something was helpful keeps saying so.
    @Test("Prose that contains a button's word is not damaged")
    func keepsRealProse() {
        let clean = AmazonReview.strip("The manual was helpful and the cable is great.")
        #expect(clean == "The manual was helpful and the cable is great.")
    }

    @Test("A review that is nothing but interface comes back empty")
    func stripsToNothing() {
        #expect(AmazonReview.strip("Read more Read less Helpful Report").isEmpty)
        #expect(AmazonReview.strip("").isEmpty)
    }
}

// MARK: - The distribution, in both of Amazon's spellings

@Suite("Amazon histogram spellings")
struct AmazonHistogramSpellingTests {

    /// The aria-label, which is the only form that reliably gives one row per
    /// star — and which states the two numbers in the opposite order from the
    /// visible text.
    @Test("The aria phrasing reads percent-first")
    func readsAriaPhrasing() throws {
        let histogram = try #require(AmazonHistogram.parse(rows: [
            "87 percent of reviews have 5 stars",
            "8 percent of reviews have 4 stars",
            "2 percent of reviews have 3 stars",
            "1 percent of reviews have 2 stars",
            "2 percent of reviews have 1 stars",
        ]))
        #expect(histogram.percentages == [87, 8, 2, 1, 2])
    }

    /// The regression this guards. Read star-first, "87 percent of reviews
    /// have 5 stars" says the product is rated 87 — out of range, rejected,
    /// and every row lost with it.
    @Test("The two spellings agree on the same product")
    func spellingsAgree() throws {
        let visible = try #require(AmazonHistogram.parse(rows: [
            "5 star 87%", "4 star 8%", "3 star 2%", "2 star 1%", "1 star 2%",
        ]))
        let aria = try #require(AmazonHistogram.parse(rows: [
            "87 percent of reviews have 5 stars",
            "8 percent of reviews have 4 stars",
            "2 percent of reviews have 3 stars",
            "1 percent of reviews have 2 stars",
            "2 percent of reviews have 1 stars",
        ]))
        #expect(visible == aria)
    }

    /// Observed on a real page: the visible rows nest so that one `li` holds
    /// every percentage at once. It must not be read as a distribution.
    @Test("A row carrying every percentage at once is refused")
    func refusesCollapsedRows() {
        #expect(AmazonHistogram.parse(rows: [
            "5 star 4 star 3 star 2 star 1 star 5 star 82% 10% 3% 1% 4% 82%",
            "5 star 4 star 3 star 2 star 1 star 4 star 82% 10% 3% 1% 4% 10%",
        ]) == nil)
    }
}

// MARK: - Highlights

@Suite("Amazon highlights")
struct AmazonHighlightTests {

    /// Copied from a real feature list. Amazon writes "Headline: body" and
    /// then renders it as an undifferentiated bullet — which is precisely the
    /// structure Baymard finds missing on 78% of product pages.
    private let bullets = [
        "Durable Design: Reinforced nylon exterior and a robust core ensure this cable withstands up to 5,000 bends",
        "Fast Charging: Supports Power Delivery for up to 60W high-speed charging when paired with a USB-C charger",
        "Note: This is a USB C to USB C Cable, so it does not work with Lightning Port devices",
    ]

    @Test("A bullet becomes a headline and a paragraph")
    func splitsOnTheColon() throws {
        let highlights = AmazonHighlight.parse(bullets: bullets)
        #expect(highlights.count == 3)
        let first = try #require(highlights.first)
        #expect(first.headline == "Durable Design")
        #expect(first.body.hasPrefix("Reinforced nylon exterior"))
    }

    /// Amazon uses the same shape for its caveats, and a caveat with a
    /// heading is easier to notice rather than harder.
    @Test("A caveat keeps its heading")
    func keepsNoteHeadings() throws {
        let note = try #require(AmazonHighlight.parse(bullets: bullets).last)
        #expect(note.headline == "Note")
        #expect(note.body.hasPrefix("This is a USB C"))
    }

    /// Not every colon introduces a heading. A sentence that happens to
    /// contain one keeps its shape.
    @Test("A colon inside a sentence is not a heading", arguments: [
        "Works with the following devices: iPhone, iPad, MacBook, Galaxy, Pixel, and more besides",
        "Charges fast, and safely: the chip inside negotiates the right voltage for your device",
        "It is 6 feet long: about the distance from a wall socket to a bedside table in most rooms",
    ])
    func leavesProseAlone(bullet: String) {
        let highlight = AmazonHighlight.split(AmazonText.tidy(bullet))
        #expect(highlight.headline.isEmpty)
        #expect(highlight.body == AmazonText.tidy(bullet))
    }

    /// Baymard's range is two to six. Past that the structure stops helping
    /// and becomes the wall it was meant to replace.
    @Test("At most six highlights are kept")
    func capsAtSix() {
        let many = (1...12).map { "Feature \($0): does a thing that is useful to you" }
        #expect(AmazonHighlight.parse(bullets: many).count == 6)
    }

    @Test("The same bullet twice appears once")
    func dedupes() {
        #expect(AmazonHighlight.parse(bullets: [bullets[0], bullets[0]]).count == 1)
    }

    @Test("An empty bullet list yields nothing")
    func handlesNothing() {
        #expect(AmazonHighlight.parse(bullets: []).isEmpty)
        #expect(AmazonHighlight.parse(bullets: ["", "   "]).isEmpty)
    }
}

@Suite("Amazon vendor copy")
struct AmazonSentenceCaseTests {

    /// Amazon's vendors shout, and Amazon prints it. Baymard: 52% of sites
    /// don't post-process vendor data, and normalising it is one of the few
    /// things a native renderer can do that the site itself does not.
    @Test("Shouted copy is calmed down")
    func calmsShouting() {
        #expect(AmazonText.sentenceCased("DURABLE DESIGN AND STRONG BRAIDING")
            == "Durable design and strong braiding")
    }

    /// The half of the rule that matters more. A sentence-caser that turns
    /// "USB C" into "Usb c" has made the copy worse than it found it.
    @Test("Names, units and initialisms are left alone", arguments: [
        "USB C to USB C Cable, 60W Fast Charging",
        "Anker PowerLine III Flow",
        "Compatible with iPhone 17 Pro Max and MacBook Air M2",
        "5,000 bends",
        "USB",
    ])
    func leavesRealCopyAlone(text: String) {
        #expect(AmazonText.sentenceCased(text) == text)
    }

    /// The compromise stated plainly. Inside a fully shouted string nothing
    /// but a vocabulary separates "USB" from "AND", so short words are kept
    /// unless they are known function words. A shouted short adjective can
    /// survive — a blemish, and the right way round to be wrong, because the
    /// alternative is printing "Usb c cable".
    @Test("A short name survives a shouted sentence intact")
    func keepsShortNames() {
        let cased = AmazonText.sentenceCased("USB C CABLE WITH BRAIDED NYLON EXTERIOR")
        #expect(cased.hasPrefix("USB C"))
        #expect(cased.contains("with braided nylon"))
    }

    @Test("Words carrying digits survive a shouted sentence")
    func keepsModelNumbers() {
        let cased = AmazonText.sentenceCased("SUPPORTS UP TO 60W CHARGING FOR THE M2 MACBOOK")
        #expect(cased.contains("60W"))
        #expect(cased.contains("M2"))
        #expect(cased.hasPrefix("Supports"))
    }
}

@Suite("Amazon key specifications")
struct AmazonKeySpecTests {

    private func product(key: [(String, String)], full: [(String, String)]) -> AmazonProduct {
        AmazonProduct(
            id: "B088NRLMPV", title: "x",
            specs: full.map { AmazonSpec(label: $0.0, value: $0.1) },
            keySpecs: key.map { AmazonSpec(label: $0.0, value: $0.1) }
        )
    }

    /// Baymard asks for the critical specs above the full sheet. Amazon
    /// already curates that set and then buries it — but printing the same
    /// four rows twice running reads as a rendering fault, not a summary.
    @Test("The full sheet drops what the summary already said")
    func removesDuplicatedRows() {
        let p = product(
            key: [("Brand", "Anker"), ("Connector Type", "USB Type C")],
            full: [("Brand", "Anker"), ("Weight", "1.4 oz"), ("connector type", "USB Type C")]
        )
        #expect(p.remainingSpecs.map(\.label) == ["Weight"])
    }

    @Test("With no summary the full sheet is untouched")
    func keepsEverythingWithoutASummary() {
        let p = product(key: [], full: [("Brand", "Anker"), ("Weight", "1.4 oz")])
        #expect(p.remainingSpecs.count == 2)
    }
}

@Suite("Amazon variation rows")
struct AmazonVariationTests {

    private func reply(
        dimension: String, label: String?, selected: String?,
        options: [(String, String)]
    ) -> AmazonPageReply {
        AmazonPageReply(product: AmazonProductWire(
            asin: "/dp/B088NRLMPV", title: "Anker cable",
            prices: ["$9.99"], priceText: "$9.99",
            variations: [AmazonVariationWire(
                dimension: dimension, label: label, selected: selected,
                options: options.map {
                    AmazonVariationOptionWire(value: $0.0, asin: $0.1)
                }
            )]
        ))
    }

    /// The row names its dimension in its own id, and the raw id is not a
    /// heading anyone wants to read.
    @Test("The row id becomes a readable heading when the page gives none")
    func namesTheDimension() throws {
        let parsed = reply(
            dimension: "inline-twister-row-number_of_items", label: "", selected: "2",
            options: [("2", "B088NRLMPV"), ("4", "B0GGLTGND9")]
        ).parsedProduct
        let group = try #require(parsed?.variations.first)
        #expect(group.id == "number_of_items")
        #expect(group.label == "Number of Items")
    }

    @Test("The page's own heading wins over the derived one")
    func prefersThePagesHeading() throws {
        let parsed = reply(
            dimension: "inline-twister-row-size_name", label: "Size:", selected: "6FT*2",
            options: [("1FT*2", "B0CFZNZN25"), ("6FT*2", "B088NRLMPV")]
        ).parsedProduct
        let group = try #require(parsed?.variations.first)
        #expect(group.label == "Size")
        #expect(group.selected == "6FT*2")
    }

    /// The bug this exists to prevent. A selector that reached too far
    /// collected the whole option, and the lens rendered an entire buy box —
    /// price, rate and stock status — as the name of a colour.
    @Test("A buy box is never the name of a colour")
    func refusesBuyBoxAsSwatchName() throws {
        let parsed = reply(
            dimension: "inline-twister-row-color_name", label: "Color:", selected: "Black",
            options: [
                ("$9.99 $9.99 $5.00 per count ( $5.00 $5.00 / count) In Stock", "B088NRLMPV"),
                ("Black", "B088NRLMPV"),
                ("Red", "B088NVYZ66"),
            ]
        ).parsedProduct
        let group = try #require(parsed?.variations.first)
        #expect(group.options.map(\.value) == ["Black", "Red"])
    }

    @Test("Anything priced or overlong is not a swatch name", arguments: [
        "$12.99",
        "In Stock $9.99",
        "A description of this option that runs on far past any real swatch label",
        "\u{00A3}9.99",
    ])
    func rejectsImplausibleNames(value: String) {
        #expect(AmazonPageReply.isPlausibleOptionName(value) == false)
    }

    @Test("Real swatch names are kept", arguments: [
        "Black", "6FT*2", "3.3FT*2 (Pack of 2)", "2", "Midnight Blue", "XL",
    ])
    func keepsRealNames(value: String) {
        #expect(AmazonPageReply.isPlausibleOptionName(value))
    }

    /// If the only options were rubbish, the row is not a choice and should
    /// not be drawn at all.
    @Test("A row left with nothing usable is dropped")
    func dropsEmptiedRows() throws {
        let parsed = reply(
            dimension: "inline-twister-row-color_name", label: "Color:", selected: "Black",
            options: [("$9.99 In Stock", "B088NRLMPV"), ("$12.99 In Stock", "B088NVYZ66")]
        ).parsedProduct
        #expect(parsed?.variations.isEmpty == true)
    }
}

@Suite("Amazon trust signals")
struct AmazonTrustTests {

    private func product(
        seller: String? = nil, shipsFrom: String? = nil,
        returns: String? = nil, choice: Bool? = nil, bought: String? = nil
    ) -> AmazonProduct? {
        AmazonPageReply(product: AmazonProductWire(
            asin: "/dp/B088NRLMPV", title: "Anker cable",
            prices: ["$9.99"], priceText: "$9.99",
            seller: seller, shipsFrom: shipsFrom, returns: returns,
            choiceBadge: choice, bought: bought
        )).parsedProduct
    }

    /// Who sold it and who posts it are different questions — and the second
    /// one decides whose delivery promise and whose returns desk stand behind
    /// the order.
    @Test("Seller and shipper are read separately")
    func readsBothParties() throws {
        let p = try #require(product(seller: "AnkerDirect", shipsFrom: "Amazon"))
        #expect(p.seller == "AnkerDirect")
        #expect(p.shipsFrom == "Amazon")
    }

    @Test("The returns headline is carried")
    func readsReturns() throws {
        #expect(try #require(product(returns: "FREE Returns")).returnsPolicy == "FREE Returns")
    }

    /// The badge is presence, not prose: its own element carries the
    /// explanatory tooltip as a child, so reading its text yields a
    /// paragraph where a chip belongs.
    @Test("The badge is a flag, and absent by default")
    func readsBadge() throws {
        #expect(try #require(product(choice: true)).isAmazonsChoice)
        #expect(try #require(product()).isAmazonsChoice == false)
    }

    @Test("Amazon's own recent-purchase count is carried verbatim")
    func readsBought() throws {
        #expect(try #require(product(bought: "10K+ bought in past month")).boughtRecently
            == "10K+ bought in past month")
    }
}

@Suite("Amazon swatch prices")
struct AmazonSwatchPriceTests {

    private func options(_ swatches: [(String, String, String)]) -> [AmazonVariationOption] {
        AmazonPageReply(product: AmazonProductWire(
            asin: "/dp/B088NRLMPV", title: "Anker cable",
            prices: ["$9.99"], priceText: "$9.99",
            variations: [AmazonVariationWire(
                dimension: "inline-twister-row-color_name", label: "Color:",
                selected: "Black",
                options: swatches.map {
                    AmazonVariationOptionWire(value: $0.0, asin: $0.1, priceText: $0.2)
                }
            )]
        )).parsedProduct?.variations.first?.options ?? []
    }

    /// Copied from the real swatches: the selected one carries a rate as
    /// well as a price, the others carry a price and a stock line.
    @Test("Each swatch shows what that variation costs")
    func readsSwatchPrices() {
        let parsed = options([
            ("Black", "B088NRLMPV", "$9.99 $9.99 $5.00 per count ( $5.00 $5.00 / count) In Stock"),
            ("Red", "B088NLK5P5", "$12.99 $12.99 In Stock"),
            ("Silver", "B088N7KPZN", "$12.99 $12.99 In Stock"),
        ])
        #expect(parsed.map(\.value) == ["Black", "Red", "Silver"])
        #expect(parsed.map(\.price) == ["$9.99", "$12.99", "$12.99"])
    }

    /// The same reader the buy box uses, so a swatch cannot show a rate as
    /// though it were the price of the variation.
    @Test("A swatch never shows the rate as the price")
    func neverShowsTheRate() {
        let parsed = options([
            ("Black", "B088NRLMPV", "$9.99 ( $5.00 / count)"),
            ("Red", "B088NLK5P5", "$12.99"),
        ])
        #expect(parsed.first?.price == "$9.99")
    }

    @Test("A swatch with no price of its own simply has none")
    func toleratesMissingPrices() {
        let parsed = options([
            ("1FT*2", "B0CFZNZN25", ""),
            ("6FT*2", "B088NRLMPV", ""),
        ])
        #expect(parsed.allSatisfy { $0.price == nil })
    }
}
