import Foundation

/// Amazon's pages, as the site lens renders them.
///
/// Where the YouTube lens reads a JSON payload the site publishes for its own
/// use, this reads the page as drawn. That is a worse position to be in and
/// the models are shaped around it: every field is optional, every record can
/// be dropped, and nothing here fails a whole page over one missing string.
///
/// The one rule that is not negotiable: a record that cannot name itself is
/// dropped rather than rendered. A card with no product id is a card that
/// cannot be clicked.

// MARK: - Search results

/// One product in the results grid.
public struct AmazonResult: Equatable, Sendable, Identifiable {
    /// The ten-character product id, which is also what the grid diffs on.
    public var id: String
    public var title: String
    /// The price as Amazon showed it. Nil for the genuinely priceless: used-
    /// only listings, "see options" parents.
    public var price: AmazonPrice?
    /// "$5.00/count" — Amazon's own rate, kept as text because it is only
    /// ever read, never compared.
    public var unitPrice: String?
    public var stars: Double?
    public var reviewCount: Int?
    public var imageURL: String
    /// "FREE delivery Saturday, August 29" — one line, already trimmed of
    /// Amazon's second and third delivery sentences.
    public var delivery: String
    /// "Overall Pick", "Best Seller", "Amazon's Choice".
    public var badge: String

    public init(
        id: String, title: String = "", price: AmazonPrice? = nil,
        unitPrice: String? = nil, stars: Double? = nil, reviewCount: Int? = nil,
        imageURL: String = "", delivery: String = "", badge: String = ""
    ) {
        self.id = id
        self.title = title
        self.price = price
        self.unitPrice = unitPrice
        self.stars = stars
        self.reviewCount = reviewCount
        self.imageURL = imageURL
        self.delivery = delivery
        self.badge = badge
    }

    public var productURL: URL? { AmazonPage.productURL(asin: id) }

    /// The picture at a size worth drawing. The grid's own thumbnails are
    /// 166 pixels across, which is soft in a card three hundred points wide.
    public func imageURL(width: Int) -> String {
        AmazonImage.sized(imageURL, width: width)
    }

    /// Reads the cards the bridge copied, in the order the site ranked them.
    ///
    /// Three things happen here, and all three are the point of the feature:
    /// sponsored cards are dropped, cards that cannot name a product are
    /// dropped, and a product that appears twice appears once. Amazon repeats
    /// a paid placement as an organic result further down the same page —
    /// measured, not assumed.
    public static func parse(cards: [AmazonCardWire]) -> [AmazonResult] {
        var results: [AmazonResult] = []
        var seen = Set<String>()
        for card in cards {
            guard !card.isSponsored else { continue }
            guard let result = parse(card: card), !seen.contains(result.id)
            else { continue }
            seen.insert(result.id)
            results.append(result)
        }
        return results
    }

    static func parse(card: AmazonCardWire) -> AmazonResult? {
        let asin = AmazonText.tidy(card.asin ?? "").uppercased()
        guard AmazonPage.isValidASIN(asin) else { return nil }
        let title = AmazonText.tidy(card.title ?? "")
        // A card with no title is a shelf header or an advert frame that
        // happened to carry a product id. Nothing to render.
        guard !title.isEmpty else { return nil }

        let split = AmazonPrice.split(
            candidates: card.prices ?? [], containerText: card.priceText ?? ""
        )
        return AmazonResult(
            id: asin,
            title: title,
            price: split.item,
            unitPrice: split.unit,
            stars: AmazonRating.stars(card.rating ?? ""),
            reviewCount: AmazonRating.count(card.reviews ?? ""),
            imageURL: AmazonText.tidy(card.image ?? ""),
            delivery: AmazonDelivery.headline(card.delivery ?? ""),
            badge: AmazonText.tidy(card.badge ?? "")
        )
    }
}

// MARK: - The product page

/// One product, as the decision column renders it.
public struct AmazonProduct: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// "Visit the Anker Store", reduced to "Anker".
    public var brand: String
    public var price: AmazonPrice?
    /// "$5.00 per count". Omitted by 81% of product pages, and its absence is
    /// what turns "which of these two is cheaper" into arithmetic done by
    /// hand — measured in supermarkets as roughly a 1–3% difference in what
    /// people end up spending.
    public var unitPrice: String?
    /// The struck-through price, when Amazon claims a discount.
    public var listPrice: AmazonPrice?
    public var stars: Double?
    public var reviewCount: Int?
    /// "In Stock", "Currently unavailable", "Only 3 left in stock".
    public var availability: String
    public var delivery: String
    /// Who takes the money.
    public var seller: String
    /// Who posts it. A different question from who sold it, and the one that
    /// decides whose delivery promise and whose returns desk stand behind
    /// the order.
    public var shipsFrom: String
    /// "FREE Returns", "30-day refund/replacement". Six in ten shoppers look
    /// for this on the product page, and four in ten pages don't carry it.
    public var returnsPolicy: String
    /// Amazon's own badge. Rendered as a fact about the listing, never
    /// restyled into a recommendation of ours.
    public var isAmazonsChoice: Bool
    /// "10K+ bought in past month" — Amazon counting, not us.
    public var boughtRecently: String
    public var images: [String]
    public var bullets: [String]
    /// Label/value rows from the tech-spec table, in the site's order.
    public var specs: [AmazonSpec]
    /// Amazon's own curated overview, which it publishes separately from the
    /// full sheet and then buries. Baymard: summarising the critical specs
    /// above the full table is a thing only 3% of sites do — and here the
    /// curation is already done for us.
    public var keySpecs: [AmazonSpec]
    public var variations: [AmazonVariationGroup]
    /// Whether the page offered an Add to Cart control at all. False for a
    /// digital item, an offer-listing page, or something out of stock — and
    /// when it is false our chrome draws no button, rather than a dead one.
    public var canAddToCart: Bool
    /// The most Amazon will sell you in one go, which is not a constant:
    /// measured at 99 on a cable and 4 on a Fire TV Stick. A stepper that
    /// lets someone pick 30 of something capped at 4 is a stepper that
    /// produces an error on the other side.
    public var quantityMax: Int
    /// The gallery, at the size the photographs were published.
    public var gallery: [AmazonGalleryImage]

    public init(
        id: String, title: String = "", brand: String = "",
        price: AmazonPrice? = nil, unitPrice: String? = nil,
        listPrice: AmazonPrice? = nil,
        stars: Double? = nil, reviewCount: Int? = nil,
        availability: String = "", delivery: String = "", seller: String = "",
        shipsFrom: String = "", returnsPolicy: String = "",
        isAmazonsChoice: Bool = false, boughtRecently: String = "",
        images: [String] = [], bullets: [String] = [],
        specs: [AmazonSpec] = [], keySpecs: [AmazonSpec] = [],
        variations: [AmazonVariationGroup] = [],
        canAddToCart: Bool = false, quantityMax: Int = 30,
        gallery: [AmazonGalleryImage] = []
    ) {
        self.id = id
        self.title = title
        self.brand = brand
        self.price = price
        self.unitPrice = unitPrice
        self.listPrice = listPrice
        self.stars = stars
        self.reviewCount = reviewCount
        self.availability = availability
        self.delivery = delivery
        self.seller = seller
        self.shipsFrom = shipsFrom
        self.returnsPolicy = returnsPolicy
        self.isAmazonsChoice = isAmazonsChoice
        self.boughtRecently = boughtRecently
        self.images = images
        self.bullets = bullets
        self.specs = specs
        self.keySpecs = keySpecs
        self.variations = variations
        self.canAddToCart = canAddToCart
        self.quantityMax = quantityMax
        self.gallery = gallery
    }

    /// What the page must have before it is worth drawing at all.
    ///
    /// A title and an id, plus either a price or an explicit statement that
    /// there isn't one. Below this the reading failed, and the lens should
    /// show the real page rather than a convincing-looking empty card.
    public var meetsQuorum: Bool {
        guard AmazonPage.isValidASIN(id), !title.isEmpty else { return false }
        return price != nil || !availability.isEmpty
    }

    /// What you save, in money.
    ///
    /// Shown next to the percentage rather than instead of it, and that is a
    /// deliberate break with what the persuasion literature recommends.
    /// Krishna et al.'s meta-analysis (345 observations) finds the percentage
    /// frame dominates the dollar frame for *perceived* savings — which is
    /// exactly why a page that picks one is picking the one that flatters the
    /// discount. Both numbers together are the only presentation that leaves
    /// the reader able to judge the offer instead of feel it.
    ///
    /// This lens is read by the person spending the money, not the person
    /// taking it. Where the evidence on persuasion and the evidence on
    /// comparison disagree, it follows comparison.
    public var savingsAmount: AmazonPrice? {
        guard let now = price?.amount, let was = listPrice?.amount,
              was > now, now > 0
        else { return nil }
        let saved = was - now
        let symbol = price?.currency ?? ""
        // Always two places. A saving of thirty pounds renders as "$30.00"
        // beside a price of "$9.99", because "$30" and "$9.99" in the same
        // line look like two different kinds of number.
        let text = String(
            format: "%.2f", NSDecimalNumber(decimal: saved).doubleValue
        )
        return AmazonPrice(
            display: "\(symbol)\(text)", amount: saved, currency: symbol
        )
    }

    /// How much Amazon says you save, when both numbers are readable and the
    /// claim actually holds. A "discount" whose list price is lower than the
    /// price is Amazon's markup being strange, and we decline to repeat it.
    public var savingsPercent: Int? {
        guard let now = price?.amount, let was = listPrice?.amount,
              was > now, now > 0
        else { return nil }
        let ratio = (was - now) / was
        let percent = NSDecimalNumber(decimal: ratio * 100).doubleValue
        let rounded = Int(percent.rounded())
        return (rounded > 0 && rounded < 100) ? rounded : nil
    }

    /// Every picture, preferring the published gallery over the markup's
    /// forty-pixel thumbnail strip.
    public var pictures: [AmazonGalleryImage] {
        gallery.isEmpty
            ? images.map { AmazonGalleryImage(url: $0, thumb: $0) }
            : gallery
    }

    /// The description, as headline-and-paragraph rather than a bullet wall.
    public var highlights: [AmazonHighlight] {
        AmazonHighlight.parse(bullets: bullets)
    }

    /// The full sheet minus anything the summary above it already said.
    /// Baymard asks for the key specs to be repeated in place; Amazon's two
    /// tables often overlap completely, and printing the same four rows twice
    /// in a row reads as a rendering bug rather than a summary.
    public var remainingSpecs: [AmazonSpec] {
        guard !keySpecs.isEmpty else { return specs }
        let named = Set(keySpecs.map { $0.label.lowercased() })
        return specs.filter { !named.contains($0.label.lowercased()) }
    }

    public func imageURL(at index: Int, width: Int) -> String? {
        let all = pictures
        guard all.indices.contains(index) else { return nil }
        return AmazonImage.sized(all[index].url, width: width)
    }
}

/// One row of the tech-spec table.
public struct AmazonSpec: Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// Reads "Brand Anker" style rows, which arrive as a label and a value
    /// already separated by the markup.
    public static func parse(rows: [AmazonSpecWire]) -> [AmazonSpec] {
        var specs: [AmazonSpec] = []
        var seen = Set<String>()
        for row in rows {
            let label = AmazonText.tidy(row.label ?? "")
            let value = AmazonText.tidy(row.value ?? "")
            guard !label.isEmpty, !value.isEmpty, !seen.contains(label) else { continue }
            seen.insert(label)
            specs.append(AmazonSpec(label: label, value: value))
        }
        return specs
    }
}

// MARK: - Highlights

/// One thing worth knowing about the product, as a headline and a sentence.
///
/// Baymard's largest single content failure on product pages is that 78% of
/// sites present the description as an undifferentiated wall — where the
/// tested remedy is two to six features, each a short headline over one
/// paragraph. Users move from surface scanning to actually reading.
///
/// Amazon hands us that structure for free and then throws it away by
/// rendering it as bullets: its feature list is almost always written
/// "Durable Design: Reinforced nylon exterior…". Splitting on that colon is
/// the whole trick.
public struct AmazonHighlight: Equatable, Sendable, Identifiable {
    public var headline: String
    public var body: String
    public var id: String { headline.isEmpty ? body : headline }

    public init(headline: String, body: String) {
        self.headline = headline
        self.body = body
    }

    /// The most to show. Baymard's range is two to six; past that the
    /// structure stops helping and becomes the wall it replaced.
    public static let limit = 6

    public static func parse(bullets: [String]) -> [AmazonHighlight] {
        var highlights: [AmazonHighlight] = []
        var seen = Set<String>()
        for bullet in bullets {
            let text = AmazonText.tidy(bullet)
            guard !text.isEmpty else { continue }
            // Split first, then un-shout each half on its own. Casing the
            // whole string first leaves the body starting in lower case,
            // because the colon it followed has gone by then.
            var highlight = split(text)
            highlight.headline = AmazonText.sentenceCased(highlight.headline)
            highlight.body = AmazonText.sentenceCased(highlight.body)
            let key = highlight.id.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            highlights.append(highlight)
            if highlights.count == limit { break }
        }
        return highlights
    }

    /// "Durable design: Reinforced nylon…" → headline and body.
    ///
    /// Only when the part before the colon reads like a label: short, and
    /// without the punctuation that would make it a sentence. "Note: this
    /// cable does not…" qualifies and should — Amazon uses that shape for its
    /// caveats, and a caveat with a heading is easier to notice, not harder.
    static func split(_ text: String) -> AmazonHighlight {
        guard let colon = text.firstIndex(of: ":") else {
            return AmazonHighlight(headline: "", body: text)
        }
        let head = AmazonText.tidy(String(text[text.startIndex..<colon]))
        let rest = AmazonText.tidy(String(text[text.index(after: colon)...]))
        // A label, not a sentence that happens to contain a colon. Amazon's
        // own headings run one to four words — "Note", "Fast Charging",
        // "High-Speed Data Transfer" — while "Works with the following
        // devices:" is prose introducing a list, and promoting it to a
        // heading would cut the sentence in half.
        let words = head.split(separator: " ").count
        guard !head.isEmpty, !rest.isEmpty, head.count <= 42, words <= 4,
              !head.contains(". "), !head.contains(",")
        else { return AmazonHighlight(headline: "", body: text) }
        return AmazonHighlight(headline: head, body: rest)
    }
}

// MARK: - Variations

/// One dimension of choice: Size, Colour, Number of Items.
public struct AmazonVariationGroup: Equatable, Sendable, Identifiable {
    /// "size_name", which is also the identity.
    public var id: String
    /// "Size".
    public var label: String
    public var options: [AmazonVariationOption]
    /// The option currently on screen, by its value.
    public var selected: String

    public init(
        id: String, label: String, options: [AmazonVariationOption],
        selected: String = ""
    ) {
        self.id = id
        self.label = label
        self.options = options
        self.selected = selected
    }
}

/// One swatch. Choosing it is a navigation to a different product id, which
/// is the whole reason this is not a picker over local state.
public struct AmazonVariationOption: Equatable, Sendable, Identifiable {
    public var value: String
    public var asin: String
    public var isAvailable: Bool
    /// What this one costs, when the page says. Seeing that black is $9.99
    /// and red is $12.99 without opening both is the most useful thing a
    /// variation row can tell you.
    public var price: String?
    public var id: String { value }

    public init(
        value: String, asin: String, isAvailable: Bool = true, price: String? = nil
    ) {
        self.value = value
        self.asin = asin
        self.isAvailable = isAvailable
        self.price = price
    }
}

// MARK: - The gallery

/// One picture of the product.
public struct AmazonGalleryImage: Equatable, Sendable, Identifiable {
    /// The largest Amazon published for it.
    public var url: String
    /// Amazon's own 40-pixel thumbnail, for the strip.
    public var thumb: String
    /// "MAIN", "PT01" — which shot in the set this is.
    public var variant: String
    /// Amazon's own description of the picture, when the seller wrote one.
    public var alt: String
    public var id: String { url }

    public init(url: String, thumb: String = "", variant: String = "", alt: String = "") {
        self.url = url
        self.thumb = thumb
        self.variant = variant
        self.alt = alt
    }
}

/// Amazon's real gallery, which is not the one in the markup.
///
/// `#altImages` renders forty-pixel thumbnails — the strip you click, not the
/// pictures. The photographs themselves are published as JSON inside a script
/// tag, at 1500 pixels, and that is what a gallery worth looking at needs.
///
/// The script copies the blob across without reading it. This parses it,
/// which is the same division as everywhere else: selection there,
/// interpretation here, under test.
public enum AmazonGallery {

    public static func parse(blob: String) -> [AmazonGalleryImage] {
        let text = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var images: [AmazonGalleryImage] = []
        var seen = Set<String>()
        for entry in entries {
            // hiRes is the photograph. `large` is the fallback for the
            // occasional entry that has no high-resolution version rather
            // than a reason to drop the picture.
            let url = (entry["hiRes"] as? String)
                ?? (entry["large"] as? String) ?? ""
            let clean = AmazonText.tidy(url)
            guard clean.hasPrefix("https://"), !seen.contains(clean) else { continue }
            seen.insert(clean)
            images.append(AmazonGalleryImage(
                url: clean,
                thumb: AmazonText.tidy(entry["thumb"] as? String ?? ""),
                variant: AmazonText.tidy(entry["variant"] as? String ?? ""),
                alt: AmazonText.tidy(entry["altText"] as? String ?? "")
            ))
        }
        return images
    }
}

// MARK: - Reviews

/// One customer review.
public struct AmazonReview: Equatable, Sendable, Identifiable {
    public var id: String
    public var stars: Double?
    public var title: String
    public var author: String
    /// "Reviewed in the United States on July 29, 2026", reduced to the date.
    public var date: String
    public var isVerified: Bool
    public var body: String
    /// "5 people found this helpful".
    public var helpful: String
    /// "Size: 3.3FT*2, Color: Black" — which variation this was written
    /// against, which Amazon shows because it genuinely changes the review.
    public var variation: String

    public init(
        id: String, stars: Double? = nil, title: String = "",
        author: String = "", date: String = "", isVerified: Bool = false,
        body: String = "", helpful: String = "", variation: String = ""
    ) {
        self.id = id
        self.stars = stars
        self.title = title
        self.author = author
        self.date = date
        self.isVerified = isVerified
        self.body = body
        self.helpful = helpful
        self.variation = variation
    }

    /// Amazon's interface, removed from what a person actually wrote.
    ///
    /// The review node carries the controls that operate on it — the expander
    /// ("Read more"), the accessibility hints ("Brief content visible, double
    /// tap to read full content"), and the whole vote-and-report machinery
    /// with all of its states pre-rendered ("Sending feedback...", "Thank you
    /// for your feedback", "Sorry, we failed to record your vote"). Any text
    /// walk picks them up, and a review that ends in three error messages
    /// nobody triggered reads as gibberish.
    ///
    /// Matched as whole phrases rather than by node, because which of them
    /// appears varies by widget version and none of them is a phrase a person
    /// writing about a cable would produce.
    static let interfaceNoise = [
        "Brief content visible, double tap to read full content.",
        "Full content visible, double tap to read brief content.",
        "Sending feedback...",
        "Thank you for your feedback.",
        "Sorry, we failed to record your vote. Please try again",
        "Thanks, we'll investigate in the next few days.",
        "Sorry, We failed to report this review. Please try again",
        "Translate review to English",
        "Read more",
        "Read less",
    ]

    public static func strip(_ raw: String) -> String {
        var text = AmazonText.tidy(raw)
        for phrase in interfaceNoise {
            text = text.replacingOccurrences(of: phrase, with: " ")
        }
        // The buttons that are only ever a single word sit at the very end,
        // where they can be taken off without touching prose that happens to
        // contain them.
        //
        // Until nothing more comes off, rather than once per word: they
        // appear in either order, and a single pass that has already checked
        // "Helpful" cannot take it off after removing the "Report" that was
        // sitting behind it.
        var tidied = AmazonText.tidy(text)
        var changed = true
        while changed {
            changed = false
            for trailing in ["Helpful", "Report"] where tidied.hasSuffix(trailing) {
                tidied = AmazonText.tidy(String(tidied.dropLast(trailing.count)))
                changed = true
            }
        }
        return tidied
    }

    public static func parse(reviews: [AmazonReviewWire]) -> [AmazonReview] {
        var parsed: [AmazonReview] = []
        var seen = Set<String>()
        for (index, wire) in reviews.enumerated() {
            let body = AmazonReview.strip(wire.body ?? "")
            // A review with nothing written in it is a rating, and the
            // histogram already counts those.
            guard !body.isEmpty else { continue }
            // Amazon's own review id when there is one; position otherwise,
            // because SwiftUI needs something stable to diff on.
            let id = AmazonText.tidy(wire.id ?? "").isEmpty
                ? "review-\(index)" : AmazonText.tidy(wire.id ?? "")
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            parsed.append(AmazonReview(
                id: id,
                stars: AmazonRating.stars(wire.stars ?? ""),
                title: AmazonText.tidy(wire.title ?? ""),
                author: AmazonText.tidy(wire.author ?? ""),
                date: AmazonDelivery.reviewDate(wire.date ?? ""),
                isVerified: wire.verified ?? false,
                body: body,
                helpful: AmazonText.tidy(wire.helpful ?? ""),
                variation: AmazonText.tidy(wire.variation ?? "")
            ))
        }
        return parsed
    }
}

/// How the stars are distributed, as Amazon reports it: percentages, not
/// counts.
public struct AmazonHistogram: Equatable, Sendable {
    /// Index 0 is five stars, index 4 is one star — the order Amazon draws
    /// them and the order they read.
    public var percentages: [Int]

    public init(percentages: [Int]) {
        self.percentages = percentages
    }

    /// Reads a distribution from either spelling Amazon uses.
    ///
    /// Two, and they read in opposite directions:
    ///
    ///     "5 star 87%"                          — visible text
    ///     "87 percent of reviews have 5 stars"  — the aria-label
    ///
    /// The aria-label is the one to trust and the one the selectors ask for
    /// first: the visible rows nest such that a single `li` can contain all
    /// five percentages at once, which reads as one row saying "5 star 82%
    /// 10% 3% 1% 4%". Both are handled because Amazon serves both, and
    /// because a parser that silently prefers the wrong number here draws a
    /// chart of a product's reviews that is not that product's.
    ///
    /// Returns nil unless all five are present and they roughly total a
    /// hundred. Half a chart implies a distribution, and a wrong implication
    /// is worse than no chart.
    public static func parse(rows: [String]) -> AmazonHistogram? {
        var found = [Int](repeating: -1, count: 5)
        for row in rows {
            let text = AmazonText.tidy(row)
            guard let reading = read(row: text) else { continue }
            let index = 5 - reading.star
            guard found.indices.contains(index), found[index] < 0 else { continue }
            found[index] = reading.percent
        }
        guard found.allSatisfy({ $0 >= 0 }) else { return nil }
        let total = found.reduce(0, +)
        // Amazon rounds each row, so the total lands near a hundred rather
        // than on it.
        guard total >= 95, total <= 105 else { return nil }
        return AmazonHistogram(percentages: found)
    }

    /// Which number is the rating and which is the share.
    ///
    /// In the aria phrasing the percentage comes first, so reading "the first
    /// number is the star rating" gets 87 stars out of "87 percent of reviews
    /// have 5 stars" — out of range, rejected, and the whole chart lost.
    static func read(row text: String) -> (star: Int, percent: Int)? {
        let numbers = AmazonPrice.amounts(in: text).map {
            NSDecimalNumber(decimal: $0).intValue
        }
        if text.range(of: "percent of reviews", options: .caseInsensitive) != nil {
            guard numbers.count >= 2 else { return nil }
            let percent = numbers[0], star = numbers[1]
            guard (1...5).contains(star), (0...100).contains(percent) else { return nil }
            return (star, percent)
        }
        guard let star = numbers.first, (1...5).contains(star),
              let percent = percentage(in: text)
        else { return nil }
        return (star, percent)
    }

    private static func percentage(in text: String) -> Int? {
        guard let sign = text.firstIndex(of: "%") else { return nil }
        var digits = ""
        for character in text[text.startIndex..<sign].reversed() {
            if character.isNumber { digits.insert(character, at: digits.startIndex) }
            else if !digits.isEmpty { break }
        }
        guard let value = Int(digits), value >= 0, value <= 100 else { return nil }
        return value
    }
}

// MARK: - Delivery and dates

public enum AmazonDelivery {

    /// Amazon stacks two or three delivery sentences in one cell:
    ///
    ///     Join Prime to get FREE delivery Tomorrow, Aug 25
    ///     Or Non-members get FREE delivery Sat, Aug 29 on $35 of items…
    ///
    /// The card has room for one line, and the useful one is the first.
    /// Split on the sentence Amazon uses to join them rather than on length,
    /// so the line stays a whole thought.
    public static func headline(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { AmazonText.tidy(String($0)) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        // A single run-on line still splits, because textContent doesn't
        // always keep the break.
        if let joiner = first.range(of: " Or ") {
            return String(first[first.startIndex..<joiner.lowerBound])
        }
        return first
    }

    /// "Reviewed in the United States on July 29, 2026" → "July 29, 2026".
    ///
    /// The country is Amazon telling you the review was translated or
    /// imported, which matters to Amazon and not to the reader.
    public static func reviewDate(_ raw: String) -> String {
        let text = AmazonText.tidy(raw)
        guard let marker = text.range(of: " on ") else { return text }
        return String(text[marker.upperBound...])
    }

    /// "Visit the Anker Store" → "Anker". "Brand: Anker" → "Anker".
    public static func brand(_ raw: String) -> String {
        var text = AmazonText.tidy(raw)
        if let colon = text.firstIndex(of: ":") {
            text = AmazonText.tidy(String(text[text.index(after: colon)...]))
        }
        for prefix in ["Visit the ", "Brand: ", "Shop "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for suffix in [" Store", " store"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return AmazonText.tidy(text)
    }
}
