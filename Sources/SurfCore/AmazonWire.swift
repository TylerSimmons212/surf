import Foundation

/// The shapes the Amazon bridge's replies decode into, and the one function
/// that decides what the lens is actually looking at.
///
/// Everything here is deliberately shapeless, for the reason `YouTubeWire`
/// gives: a reply that half-arrives should decode and then be judged, not
/// fail to decode and be indistinguishable from a broken page. Every field is
/// optional, and the interpretation lives in `AmazonReconcile` and the model
/// types, where it is tested.
///
/// One departure from the YouTube wire worth naming. These carry strings the
/// script read with `textContent`, never `innerText`. `innerText` returns
/// nothing for an element inside a `display:none` subtree, and Surf compiles
/// EasyList's cosmetic rules into exactly that — so a scraper written the
/// obvious way would come back blank on whatever the blocker happened to hide
/// that week, and blank is the failure this whole file is arranged to avoid.

// MARK: - What the script copies

/// One card in the results grid.
public struct AmazonCardWire: Decodable, Sendable, Equatable {
    public var asin: String?
    /// The sponsored label's text, when the card carries one. Present as a
    /// string rather than a bool because the classification is Swift's job.
    public var sponsored: String?
    public var title: String?
    public var image: String?
    /// Every `.a-price .a-offscreen` in the card, in document order.
    public var prices: [String]?
    /// The price cell's whole text, which is what tells the item price from
    /// the per-unit rate.
    public var priceText: String?
    public var rating: String?
    public var reviews: String?
    public var delivery: String?
    public var badge: String?

    public init(
        asin: String? = nil, sponsored: String? = nil, title: String? = nil,
        image: String? = nil, prices: [String]? = nil, priceText: String? = nil,
        rating: String? = nil, reviews: String? = nil, delivery: String? = nil,
        badge: String? = nil
    ) {
        self.asin = asin
        self.sponsored = sponsored
        self.title = title
        self.image = image
        self.prices = prices
        self.priceText = priceText
        self.rating = rating
        self.reviews = reviews
        self.delivery = delivery
        self.badge = badge
    }

    /// Whether Amazon labelled this a paid placement.
    ///
    /// The label is the only honest signal — Amazon marks its own ads because
    /// it has to. Anything cleverer would be us guessing which results are
    /// paid, which is a thing we should never do.
    public var isSponsored: Bool {
        !AmazonText.tidy(sponsored ?? "").isEmpty
    }
}

public struct AmazonSpecWire: Decodable, Sendable, Equatable {
    public var label: String?
    public var value: String?

    public init(label: String? = nil, value: String? = nil) {
        self.label = label
        self.value = value
    }
}

public struct AmazonReviewWire: Decodable, Sendable, Equatable {
    public var id: String?
    public var stars: String?
    public var title: String?
    public var author: String?
    public var date: String?
    public var verified: Bool?
    public var body: String?
    public var helpful: String?
    public var variation: String?

    public init(
        id: String? = nil, stars: String? = nil, title: String? = nil,
        author: String? = nil, date: String? = nil, verified: Bool? = nil,
        body: String? = nil, helpful: String? = nil, variation: String? = nil
    ) {
        self.id = id
        self.stars = stars
        self.title = title
        self.author = author
        self.date = date
        self.verified = verified
        self.body = body
        self.helpful = helpful
        self.variation = variation
    }
}

public struct AmazonVariationWire: Decodable, Sendable, Equatable {
    /// "size_name".
    public var dimension: String?
    /// "Size: 6FT*2" — the label with the current value attached, which is
    /// how Amazon renders the row heading.
    public var label: String?
    public var selected: String?
    public var options: [AmazonVariationOptionWire]?

    public init(
        dimension: String? = nil, label: String? = nil,
        selected: String? = nil, options: [AmazonVariationOptionWire]? = nil
    ) {
        self.dimension = dimension
        self.label = label
        self.selected = selected
        self.options = options
    }
}

public struct AmazonVariationOptionWire: Decodable, Sendable, Equatable {
    public var value: String?
    public var asin: String?
    public var available: Bool?
    /// The swatch's own price cell, unparsed — "$12.99 $12.99 In Stock".
    public var priceText: String?

    public init(
        value: String? = nil, asin: String? = nil, available: Bool? = nil,
        priceText: String? = nil
    ) {
        self.value = value
        self.asin = asin
        self.available = available
        self.priceText = priceText
    }
}

/// The product page's own fields.
public struct AmazonProductWire: Decodable, Sendable, Equatable {
    public var asin: String?
    public var title: String?
    public var byline: String?
    public var prices: [String]?
    public var priceText: String?
    public var listPrice: String?
    public var rating: String?
    public var reviews: String?
    public var availability: String?
    public var delivery: String?
    public var seller: String?
    public var shipsFrom: String?
    public var returns: String?
    public var choiceBadge: Bool?
    public var bought: String?
    public var images: [String]?
    public var bullets: [String]?
    public var specs: [AmazonSpecWire]?
    public var keySpecs: [AmazonSpecWire]?
    public var variations: [AmazonVariationWire]?
    /// Whether `#add-to-cart-button` exists and is not disabled. The page
    /// decides; our chrome never draws a button the page doesn't have.
    public var addToCart: Bool?
    /// The `colorImages` JSON, copied across verbatim and parsed here. The
    /// markup's image strip is forty pixels wide; this is the photographs.
    public var gallery: String?
    /// How many the quantity selector actually offers.
    public var quantityMax: Int?

    public init(
        asin: String? = nil, title: String? = nil, byline: String? = nil,
        prices: [String]? = nil, priceText: String? = nil, listPrice: String? = nil,
        rating: String? = nil, reviews: String? = nil, availability: String? = nil,
        delivery: String? = nil, seller: String? = nil,
        shipsFrom: String? = nil, returns: String? = nil,
        choiceBadge: Bool? = nil, bought: String? = nil,
        images: [String]? = nil,
        bullets: [String]? = nil, specs: [AmazonSpecWire]? = nil,
        keySpecs: [AmazonSpecWire]? = nil,
        variations: [AmazonVariationWire]? = nil, addToCart: Bool? = nil,
        gallery: String? = nil, quantityMax: Int? = nil
    ) {
        self.asin = asin
        self.title = title
        self.byline = byline
        self.prices = prices
        self.priceText = priceText
        self.listPrice = listPrice
        self.rating = rating
        self.reviews = reviews
        self.availability = availability
        self.delivery = delivery
        self.seller = seller
        self.shipsFrom = shipsFrom
        self.returns = returns
        self.choiceBadge = choiceBadge
        self.bought = bought
        self.images = images
        self.bullets = bullets
        self.specs = specs
        self.keySpecs = keySpecs
        self.variations = variations
        self.addToCart = addToCart
        self.gallery = gallery
        self.quantityMax = quantityMax
    }
}

/// What Amazon's own navigation bar says, which is on every page it serves.
public struct AmazonNavWire: Decodable, Sendable, Equatable {
    public var cartCount: String?
    public var account: String?

    public init(cartCount: String? = nil, account: String? = nil) {
        self.cartCount = cartCount
        self.account = account
    }
}

/// One read of an Amazon page.
public struct AmazonPageReply: Decodable, Sendable, Equatable {
    public var cards: [AmazonCardWire]?
    /// "1-16 of over 70,000 results for …" — the positive marker that this
    /// really is a results page that found things.
    public var resultBar: String?
    /// Amazon's own "No results for …" block.
    public var noResults: String?
    /// `form[action*="validateCaptcha"]` is on the page.
    public var botCheck: Bool?
    /// A password field is on the page.
    public var signIn: Bool?
    public var product: AmazonProductWire?
    public var reviews: [AmazonReviewWire]?
    /// "5 star 87%" rows.
    public var histogram: [String]?
    public var nav: AmazonNavWire?
    /// How many nodes each selector matched, for the log. Costs nothing and
    /// turns "the grid is empty" into a sentence naming which selector went
    /// quiet.
    public var matches: [String: Int]?

    public init(
        cards: [AmazonCardWire]? = nil, resultBar: String? = nil,
        noResults: String? = nil, botCheck: Bool? = nil, signIn: Bool? = nil,
        product: AmazonProductWire? = nil, reviews: [AmazonReviewWire]? = nil,
        histogram: [String]? = nil, nav: AmazonNavWire? = nil,
        matches: [String: Int]? = nil
    ) {
        self.cards = cards
        self.resultBar = resultBar
        self.noResults = noResults
        self.botCheck = botCheck
        self.signIn = signIn
        self.product = product
        self.reviews = reviews
        self.histogram = histogram
        self.nav = nav
        self.matches = matches
    }

    // MARK: Interpretation

    public var results: [AmazonResult] {
        AmazonResult.parse(cards: cards ?? [])
    }

    public var parsedReviews: [AmazonReview] {
        AmazonReview.parse(reviews: reviews ?? [])
    }

    public var parsedHistogram: AmazonHistogram? {
        AmazonHistogram.parse(rows: histogram ?? [])
    }

    /// How many cards the page had before ours dropped the paid ones. The
    /// difference between "Amazon had only adverts for that" and "we failed
    /// to read the page" is this number, and nothing else can tell them
    /// apart.
    public var cardCount: Int { cards?.count ?? 0 }

    public var sponsoredCount: Int {
        (cards ?? []).count(where: \.isSponsored)
    }

    public var parsedProduct: AmazonProduct? {
        guard let wire = product else { return nil }
        // The script sends the document's path, not an id. That is
        // deliberate: the path is the only place a product states its own id
        // without ambiguity, and pulling the id out of it is a judgement —
        // Amazon writes it as /dp/B0…, /gp/product/B0…, and behind a slug
        // that can itself look like an id. So the script copies the path and
        // this decides, which is the same split as everywhere else.
        let raw = AmazonText.tidy(wire.asin ?? "")
        let asin = AmazonPage.isValidASIN(raw.uppercased())
            ? raw.uppercased()
            : (AmazonPage.productID(inPath: raw) ?? "")
        guard AmazonPage.isValidASIN(asin) else { return nil }

        let split = AmazonPrice.split(
            candidates: wire.prices ?? [], containerText: wire.priceText ?? ""
        )
        return AmazonProduct(
            id: asin,
            title: AmazonText.tidy(wire.title ?? ""),
            brand: AmazonDelivery.brand(wire.byline ?? ""),
            price: split.item,
            unitPrice: split.unit,
            listPrice: Self.formerPrice(wire.listPrice, comparedTo: split.item),
            stars: AmazonRating.stars(wire.rating ?? ""),
            reviewCount: AmazonRating.count(wire.reviews ?? ""),
            availability: AmazonText.tidy(wire.availability ?? ""),
            delivery: AmazonDelivery.headline(wire.delivery ?? ""),
            seller: AmazonText.tidy(wire.seller ?? ""),
            shipsFrom: AmazonText.tidy(wire.shipsFrom ?? ""),
            returnsPolicy: AmazonText.tidy(wire.returns ?? ""),
            isAmazonsChoice: wire.choiceBadge ?? false,
            boughtRecently: AmazonText.tidy(wire.bought ?? ""),
            images: (wire.images ?? []).map(AmazonText.tidy).filter { !$0.isEmpty },
            bullets: (wire.bullets ?? []).map(AmazonText.tidy).filter { !$0.isEmpty },
            specs: AmazonSpec.parse(rows: wire.specs ?? []),
            keySpecs: AmazonSpec.parse(rows: wire.keySpecs ?? []),
            variations: parseVariations(wire.variations ?? []),
            canAddToCart: wire.addToCart ?? false,
            // Clamped rather than trusted: this bounds a stepper, and a
            // payload saying nought or nine thousand should not make one.
            quantityMax: min(max(wire.quantityMax ?? 30, 1), 99),
            gallery: AmazonGallery.parse(blob: wire.gallery ?? "")
        )
    }

    /// A former price, kept only when it is actually former.
    ///
    /// Belt and braces over the selector. Anything not strictly larger than
    /// what the item costs today is not a price it used to be — it is some
    /// other number that happened to be struck through, and carrying it
    /// invites a later reader to compute a saving from it.
    static func formerPrice(
        _ raw: String?, comparedTo price: AmazonPrice?
    ) -> AmazonPrice? {
        guard let listed = AmazonPrice.parse(raw ?? "") else { return nil }
        // With nothing to compare against, the page's word is all there is.
        guard let now = price?.amount, let was = listed.amount else { return listed }
        return was > now ? listed : nil
    }

    /// Whether a string is a swatch's name rather than something swept up
    /// with it.
    ///
    /// A swatch is called "Black" or "6FT*2". It is never a paragraph and it
    /// never quotes a price — a value that does is the option's entire
    /// contents, collected by a selector that reached too far. Dropping it
    /// costs one swatch; rendering it puts a buy box inside a button, which
    /// is what the lens did.
    static func isPlausibleOptionName(_ value: String) -> Bool {
        guard value.count <= 40 else { return false }
        return !value.contains(where: { "$\u{00A3}\u{20AC}\u{00A5}\u{20B9}".contains($0) })
    }

    /// "size_name" → "Size". Used only when the page gave no heading of its
    /// own.
    static func title(forDimension dimension: String) -> String {
        // Connecting words stay lower case unless they lead, so
        // "number_of_items" reads as Amazon writes it — "Number of Items",
        // not "Number Of Items".
        let small: Set<String> = ["of", "and", "in", "for", "the", "with", "to", "per"]
        return dimension
            .replacingOccurrences(of: "_name", with: "")
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .enumerated()
            .map { index, word -> String in
                let lower = word.lowercased()
                if index > 0, small.contains(lower) { return lower }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private func parseVariations(
        _ wires: [AmazonVariationWire]
    ) -> [AmazonVariationGroup] {
        var groups: [AmazonVariationGroup] = []
        for wire in wires {
            // The row states its dimension in its own id:
            // "inline-twister-row-size_name".
            var dimension = AmazonText.tidy(wire.dimension ?? "")
            for prefix in ["inline-twister-row-", "variation_"]
            where dimension.hasPrefix(prefix) {
                dimension.removeFirst(prefix.count)
            }
            guard !dimension.isEmpty else { continue }
            var options: [AmazonVariationOption] = []
            var seen = Set<String>()
            for option in wire.options ?? [] {
                let value = AmazonText.tidy(option.value ?? "")
                guard !value.isEmpty, !seen.contains(value),
                      Self.isPlausibleOptionName(value)
                else { continue }
                seen.insert(value)
                let asin = AmazonText.tidy(option.asin ?? "").uppercased()
                // The same reader the buy box uses, so a swatch that shows
                // a rate rather than a price cannot smuggle one in.
                let swatch = AmazonPrice.split(
                    candidates: [], containerText: option.priceText ?? ""
                )
                options.append(AmazonVariationOption(
                    value: value,
                    // An option with no id of its own is still worth drawing
                    // as the current selection; it just cannot be navigated
                    // to, and the view reads the empty id as "already here".
                    asin: AmazonPage.isValidASIN(asin) ? asin : "",
                    isAvailable: option.available ?? true,
                    price: swatch.item?.display
                ))
            }
            // A dimension with one option is not a choice.
            guard options.count > 1 else { continue }
            let heading = AmazonText.label(wire.label ?? "")
            groups.append(AmazonVariationGroup(
                id: dimension,
                // "size_name" reads better as "Size" than as nothing, which
                // is what an empty heading rendered as: three unlabelled rows
                // of swatches with no way to tell which was which.
                label: heading.isEmpty
                    ? Self.title(forDimension: dimension) : heading,
                options: options,
                selected: AmazonText.tidy(wire.selected ?? "")
            ))
        }
        return groups
    }
}

// MARK: - Deciding what we are looking at

/// Where the lens meant to go. Recorded when it navigates, so that what comes
/// back can be compared against what was asked for.
///
/// The YouTube lens has no equivalent because it never needed one: the URL it
/// asked for is the URL it got. Amazon redirects — between marketplaces, from
/// one product id to its canonical twin, to a sign-in wall, and to a bot
/// check served at the address you requested.
public enum AmazonDestination: Equatable, Sendable {
    case search(query: String)
    case product(asin: String)
    case cart
    /// The lens didn't ask; the user navigated, or the lens just opened on
    /// whatever was already on screen.
    case whatever
}

/// Why the lens must get out of the way.
public enum AmazonBlock: Equatable, Sendable {
    /// Amazon is asking the user to prove they're a person. This is served at
    /// the URL that was requested, with an ordinary body, so nothing but the
    /// page's own content reveals it. Never solve one; show it.
    case botCheck
    /// A password field. Never framed in our chrome.
    case signIn
    /// A page we have no lens for — an offer listing, a Kindle sample, a
    /// storefront.
    case unsupported
    /// The page is one we should have been able to read and wasn't. The
    /// user came to shop, Amazon works fine, and our lens is the broken
    /// thing — so this reveals the site rather than apologising in front
    /// of it.
    case cannotRead
}

/// What one read of a page turned out to be.
public enum AmazonReading: Equatable, Sendable {
    case results([AmazonResult])
    case product(AmazonProduct)
    /// Amazon genuinely found nothing. Positively identified — never
    /// inferred from an empty list.
    case noResults(query: String)
    case blocked(AmazonBlock)
    /// The document hasn't finished becoming what it will be. The caller
    /// should wait and read again rather than draw anything.
    case notReady
}

/// The single most consequential function in the lens: given what we asked
/// for, where we ended up, and what the page said, decide what to draw.
///
/// It is pure, it is here rather than in the lens, and it has more tests than
/// anything else in the feature — because every way of being wrong here shows
/// the user a confident lie. Reporting "nothing came back for tripod" when
/// Amazon actually served a bot check is the specific failure this exists to
/// prevent.
public enum AmazonReconcile {

    public static func read(
        expected: AmazonDestination,
        url: URL?,
        reply: AmazonPageReply?
    ) -> AmazonReading {
        // 1. The page's own content, first and above everything. The URL
        //    cannot tell us any of this, which is the whole reason the
        //    YouTube lens's "decide from the address" rule doesn't survive
        //    the trip to Amazon.
        if reply?.botCheck == true { return .blocked(.botCheck) }
        if reply?.signIn == true { return .blocked(.signIn) }

        // 2. Where we actually landed, which is not always where we aimed.
        let page = AmazonPage.of(url)
        if page.demandsTheRealSite {
            return .blocked(page == .signIn ? .signIn : .unsupported)
        }

        guard let reply else { return .notReady }

        switch page {
        case .product(let asin):
            return readProduct(asin: asin, reply: reply)
        case .search(let query):
            return readResults(query: query, reply: reply)
        case .home, .cart, .other, .signIn, .orders:
            // We aimed at a product or a search and landed somewhere else.
            // Amazon does this when an item is withdrawn, and drawing the
            // previous product over it would be a lie about what is on
            // screen.
            switch expected {
            case .product, .search:
                return .blocked(.unsupported)
            case .cart, .whatever:
                return .notReady
            }
        }
    }

    private static func readProduct(
        asin: String, reply: AmazonPageReply
    ) -> AmazonReading {
        guard let product = reply.parsedProduct else { return .notReady }
        // Below quorum the reading failed, and a convincing-looking empty
        // card is worse than handing the page back.
        guard product.meetsQuorum else { return .blocked(.cannotRead) }
        // Amazon canonicalises ids: asking for one and being given its twin
        // is normal and fine. What is not fine is rendering under the id we
        // asked for, because every write is gated on that id matching the
        // document. So the product's own id always wins.
        guard product.id == asin || AmazonPage.isValidASIN(product.id) else {
            return .blocked(.cannotRead)
        }
        return .product(product)
    }

    private static func readResults(
        query: String, reply: AmazonPageReply
    ) -> AmazonReading {
        let results = reply.results
        if !results.isEmpty { return .results(results) }

        // Nothing survived the filter. Three different situations look
        // identical from here, and only a positive marker separates them.

        // Amazon said so itself.
        if !AmazonText.tidy(reply.noResults ?? "").isEmpty {
            return .noResults(query: query)
        }
        // Cards arrived and every one was an advert. Measured: a nonsense
        // query returns eight sponsored cards and no organic ones, which is
        // Amazon's way of having nothing to say.
        if reply.cardCount > 0, reply.sponsoredCount == reply.cardCount {
            return .noResults(query: query)
        }
        // A results bar that counted results, and yet none of them reached
        // us — that is our reading failing, not Amazon's page.
        if !AmazonText.tidy(reply.resultBar ?? "").isEmpty {
            return .blocked(.cannotRead)
        }
        // No cards, no bar, no marker: the document probably hasn't
        // finished. The caller retries; if it never resolves, the retry
        // ladder gives up on its own terms.
        return .notReady
    }
}

// MARK: - The cart badge

/// What the lens believes is in the cart, and how much it believes it.
///
/// `#nav-cart-count` is server-rendered into every page Amazon serves, which
/// makes it free to read and stale the moment anything changes. After a write
/// the number on screen is a guess until the page agrees with it, and this
/// type is the difference between showing a guess and showing a fact.
///
/// The rule it exists to enforce: a number that is confidently wrong about
/// someone's cart is the worst output this feature can produce, so when the
/// two disagree past the point of waiting, the badge stops claiming to know.
public struct CartBadge: Equatable, Sendable {
    public enum Confidence: Equatable, Sendable {
        /// Read from a document Amazon served.
        case observed
        /// We added something and expect this. Not yet confirmed.
        case assumed
        /// We expected a change, waited, and the page never agreed. The
        /// count is not rendered as fact.
        case unsure
    }

    public var count: Int
    public var confidence: Confidence

    public init(count: Int = 0, confidence: Confidence = .observed) {
        self.count = count
        self.confidence = confidence
    }

    /// Whether the number is worth putting in front of someone.
    public var isTrustworthy: Bool { confidence != .unsure }

    /// A fresh document's number always wins, because it came from Amazon.
    public func observing(_ raw: String?) -> CartBadge {
        guard let value = AmazonRating.count(raw ?? ""), value >= 0 else {
            // A page with no cart node tells us nothing — which is different
            // from telling us zero.
            return self
        }
        return CartBadge(count: value, confidence: .observed)
    }

    /// We just asked Amazon to add something.
    public func assuming(added: Int) -> CartBadge {
        CartBadge(count: count + max(0, added), confidence: .assumed)
    }

    /// The confirmation ladder ran out without the page agreeing.
    public func givingUp() -> CartBadge {
        confidence == .assumed
            ? CartBadge(count: count, confidence: .unsure)
            : self
    }
}
