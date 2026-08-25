import Foundation

/// The cart, as the sidebar renders it.
///
/// The happiest surprise in the whole lens. Where the product page had to be
/// read out of prose — a price reassembled from three spans, a rating dug out
/// of a `title` attribute — every fact about a cart line is already an
/// attribute on the line itself. Measured on a live cart:
///
///     data-asin="B088NRLMPV"          data-quantity="1"
///     data-itemid="ecd26f38-…"        data-price="9.99"
///     data-producttitle="Anker USB…"  data-minquantity="1"
///     data-outofstock="0"             data-isprimeasin="0"
///
/// So the doctrine costs nothing here. Nothing is parsed, classified or
/// decided in JavaScript; the script copies eight attributes per row and every
/// judgement below happens in Swift, under test.
public struct AmazonCartItem: Equatable, Sendable, Identifiable {

    /// Amazon's own handle for this line, and the only safe address for a
    /// write. Not the ASIN: the same product added twice in different
    /// variations is two lines with one ASIN, and a quantity change addressed
    /// by ASIN would be a change to whichever one Amazon happened to return
    /// first.
    public var id: String
    public var asin: String
    public var title: String
    public var price: AmazonPrice?
    public var quantity: Int
    /// Amazon's floor for this line. Usually 1, and occasionally more for a
    /// multipack or a subscription.
    public var minQuantity: Int
    public var isOutOfStock: Bool
    /// `data-isprimeasin`. The cart's own answer to the question the product
    /// page needs an attribute on the delivery cell to answer.
    public var isPrime: Bool
    public var image: String

    public init(
        id: String, asin: String = "", title: String = "",
        price: AmazonPrice? = nil, quantity: Int = 1, minQuantity: Int = 1,
        isOutOfStock: Bool = false, isPrime: Bool = false, image: String = ""
    ) {
        self.id = id
        self.asin = asin
        self.title = title
        self.price = price
        self.quantity = quantity
        self.minQuantity = minQuantity
        self.isOutOfStock = isOutOfStock
        self.isPrime = isPrime
        self.image = image
    }

    /// What this line costs, which Amazon does not state — `data-price` is the
    /// price of one.
    public var lineTotal: AmazonPrice? {
        guard let price, let amount = price.amount, !price.isRange else { return nil }
        let total = amount * Decimal(quantity)
        return AmazonPrice(
            display: AmazonPrice.format(total, currency: price.currency),
            amount: total,
            currency: price.currency
        )
    }

    /// Whether the minus control may be pressed at all.
    ///
    /// The trap this exists for: Amazon's own stepper turns its minus into a
    /// delete once the quantity reaches the floor, so a control wired straight
    /// through would silently remove the line instead of refusing to go lower.
    /// Removing is a thing somebody has to ask for.
    public var canDecrement: Bool { quantity > minQuantity }
}

/// Every active line, plus what Amazon says they come to.
public struct AmazonCart: Equatable, Sendable {

    public var items: [AmazonCartItem]
    /// Amazon's own subtotal, not a sum of the lines.
    ///
    /// Arithmetic here would be a guess wearing a currency symbol: the number
    /// on the page carries promotions, subscribe-and-save, per-line coupons
    /// and quantity pricing, none of which are on the lines. When Amazon does
    /// not give one, the sidebar says nothing rather than showing a total that
    /// is quietly wrong.
    public var subtotal: AmazonPrice?
    /// Amazon's count, which counts *units* and not lines.
    public var unitCount: Int?

    public init(
        items: [AmazonCartItem] = [], subtotal: AmazonPrice? = nil, unitCount: Int? = nil
    ) {
        self.items = items
        self.subtotal = subtotal
        self.unitCount = unitCount
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Units, from the lines, for when Amazon's own label is missing.
    public var countedUnits: Int { items.reduce(0) { $0 + $1.quantity } }

    /// The line with this id, which is how every write finds its subject.
    public func item(id: String) -> AmazonCartItem? { items.first { $0.id == id } }
}

/// Turning what the script copied into a cart.
public enum AmazonCartParse {

    /// Amazon's flags are `"0"` and `"1"`, and an absent attribute is neither.
    public static func flag(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": true
        default: false
        }
    }

    /// A count from an attribute. Nil rather than zero when it isn't a number,
    /// so a missing quantity can be told from a quantity of none.
    public static func number(_ raw: String?) -> Int? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return Int(text)
    }

    /// One line, or nil when it carries no id to address a write to.
    ///
    /// A line without an id is not merely incomplete — it is unmodifiable, and
    /// rendering a quantity stepper next to something no write can reach is
    /// worse than not rendering the line at all.
    public static func item(
        id: String?, asin: String?, title: String?, price: String?,
        quantity: String?, minQuantity: String?, outOfStock: String?,
        prime: String?, image: String?
    ) -> AmazonCartItem? {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return nil
        }
        return AmazonCartItem(
            id: id,
            asin: (asin ?? "").trimmingCharacters(in: .whitespaces),
            title: AmazonText.tidy(title ?? ""),
            price: money(price),
            quantity: max(1, number(quantity) ?? 1),
            minQuantity: max(1, number(minQuantity) ?? 1),
            isOutOfStock: flag(outOfStock),
            isPrime: flag(prime),
            image: AmazonText.tidy(image ?? "")
        )
    }

    /// The unit count out of Amazon's own subtotal label — "Subtotal (3
    /// items):".
    ///
    /// Its own reader, and not `AmazonRating.count`, which is a *compact*
    /// number grammar built for "16.1K ratings". Pointed at a sentence it
    /// looks for a K or an M to scale by, and this sentence has an M in
    /// "items". The header read three as three million.
    ///
    /// `AmazonRating.count` has been tightened so the suffix must be attached
    /// to the number, which fixes that particular collision. This exists
    /// anyway, because a label is not a compact number and reaching for that
    /// function here was the actual mistake.
    public static func unitCount(fromLabel raw: String) -> Int? {
        guard let digits = raw.range(of: "[0-9][0-9,]*", options: .regularExpression) else {
            return nil
        }
        return Int(raw[digits].replacingOccurrences(of: ",", with: ""))
    }

    /// `data-price` is a bare decimal — `"9.99"`, no symbol. Everything else
    /// in the lens arrives already formatted, so this is the one place a
    /// number has to be turned back into money.
    static func money(_ raw: String?) -> AmazonPrice? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let amount = Decimal(string: text), amount >= 0
        else { return nil }
        return AmazonPrice(
            display: AmazonPrice.format(amount, currency: "$"), amount: amount, currency: "$"
        )
    }
}

/// The three things a cart write can be. A closed set rather than a string,
/// because the string crosses into the page and picks a control there.
public enum AmazonCartAction: String, Equatable, Sendable {
    case increment
    case decrement
    case remove
}
