import Foundation

/// Turning Amazon's on-screen strings into things Surf can render.
///
/// The injected script selects and copies; nothing here happens in
/// JavaScript. That split matters more on Amazon than it did on YouTube,
/// because Amazon's markup is presentational: a price is a screen-reader
/// string next to a pile of `<span>`s that spell the same number out
/// character by character, and deciding which of those is the price is a
/// judgement. Judgements belong here, where they are tested.
///
/// The rule throughout: **never invent a number.** A string this cannot read
/// keeps its display text and loses its numeric value, because a price that
/// renders as blank is a nuisance and a price that renders as confidently
/// wrong is the worst thing this feature can do.

// MARK: - Money

/// A price as Amazon showed it, and as a number when we could read one.
///
/// `Decimal` rather than `Double` deliberately. This is money on screen, and
/// `Double` cannot hold 9.99. Nothing here does arithmetic that would care
/// today, but the type is the place to be right about that once rather than
/// to discover it later in a savings calculation.
public struct AmazonPrice: Equatable, Sendable {
    /// Exactly what the page said, whitespace-normalised. Always present —
    /// this is what renders.
    public var display: String
    /// The numeric value, or nil when the string could not be read
    /// confidently. Never a guess.
    public var amount: Decimal?
    /// "$", "£", "€", or empty when the string carried no symbol.
    public var currency: String
    /// "$12.99 - $24.99" — a parent product whose children differ. There is
    /// no single amount to compare, so `amount` holds the low end and this
    /// says not to treat it as the price.
    public var isRange: Bool

    public init(
        display: String, amount: Decimal? = nil,
        currency: String = "", isRange: Bool = false
    ) {
        self.display = display
        self.amount = amount
        self.currency = currency
        self.isRange = isRange
    }

    /// Reads one price string.
    ///
    /// Returns nil only when there is no price here at all. A string with a
    /// number we cannot parse still comes back, carrying its display text —
    /// see the rule at the top of this file.
    public static func parse(_ raw: String) -> AmazonPrice? {
        let text = AmazonText.tidy(raw)
        guard !text.isEmpty else { return nil }
        // Something has to look like a number, or this is a label and not a
        // price at all ("Price, product page").
        guard text.contains(where: \.isNumber) else { return nil }

        let currency = symbol(in: text)
        let numbers = amounts(in: text)
        let isRange = numbers.count > 1 && text.contains("-")

        return AmazonPrice(
            display: text,
            amount: numbers.first,
            currency: currency,
            isRange: isRange
        )
    }

    /// Which price is the one you pay, and which is the rate.
    ///
    /// This is the most consequential function in the file, and the second
    /// version of it. The first trusted the order of the `.a-offscreen`
    /// nodes and asked whether a candidate was followed by a slash — which
    /// read a cable that costs $9.99 as costing $5.00, because the page
    /// writes the rate as "$5.00 / count" with spaces around the slash and
    /// the node order is not the reading order.
    ///
    /// So neither of those assumptions survives. The **container's text** is
    /// the source of truth for order, because it is what a person reads:
    ///
    ///     $9.99 $ 9 . 99 $5.00 per count ( $5.00 $5.00 / count)
    ///
    /// The first well-formed price in that string is the price. A price is a
    /// rate when the words after it say so — "per" or "/", with or without
    /// the spaces Amazon varies between its own layouts.
    ///
    /// The candidate list is kept only as a fallback for a container that
    /// came back empty. Selector order never decides anything again.
    public static func split(
        candidates: [String], containerText: String
    ) -> (item: AmazonPrice?, unit: String?) {
        let container = AmazonText.tidy(containerText)
        let tokens = priceTokens(in: container)

        var item: AmazonPrice?
        var unit: String?
        for token in tokens {
            if let rate = rate(after: token, in: container) {
                if unit == nil { unit = rate }
            } else if item == nil {
                item = parse(token.text)
            }
        }

        // No container, or nothing price-shaped in it. Fall back to the
        // nodes, in their order, with the same rate test.
        if item == nil {
            for candidate in candidates {
                let tidy = AmazonText.tidy(candidate)
                guard !tidy.isEmpty, parse(tidy) != nil else { continue }
                item = parse(tidy)
                break
            }
        }
        return (item, unit)
    }

    /// One price as it appears in a run of text, with where it appeared.
    struct PriceToken {
        var text: String
        var end: String.Index
    }

    /// Every well-formed price in a string, in reading order.
    ///
    /// Strict on purpose. Amazon also spells the price out character by
    /// character for its own layout — "$ 9 . 99" — and that spaced form must
    /// not be read as a second price, or a page with one price on it looks
    /// like a page with three.
    static func priceTokens(in text: String) -> [PriceToken] {
        var tokens: [PriceToken] = []
        var index = text.startIndex
        let symbols: Set<Character> = ["$", "£", "€", "¥", "₹"]

        while index < text.endIndex {
            guard symbols.contains(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            var digits = ""
            while cursor < text.endIndex {
                let character = text[cursor]
                guard character.isNumber || character == "," || character == "."
                else { break }
                digits.append(character)
                cursor = text.index(after: cursor)
            }
            // A symbol with no digits touching it is a currency mark in
            // prose, not a price.
            if digits.contains(where: \.isNumber) {
                tokens.append(PriceToken(
                    text: String(text[index]) + digits, end: cursor
                ))
            }
            index = cursor > index ? cursor : text.index(after: index)
        }
        return tokens
    }

    /// "$5.00 per count" or "$5.00 / count" when the price is a rate, and nil
    /// when it is a price.
    static func rate(after token: PriceToken, in container: String) -> String? {
        var cursor = token.end
        // Whatever spacing this layout happens to use.
        while cursor < container.endIndex, container[cursor] == " " {
            cursor = container.index(after: cursor)
        }
        guard cursor < container.endIndex else { return nil }

        let tail = container[cursor...]
        var unit: Substring
        if tail.hasPrefix("/") {
            unit = tail.dropFirst()
        } else if tail.lowercased().hasPrefix("per ") {
            unit = tail.dropFirst(4)
        } else {
            return nil
        }

        let stop = unit.firstIndex { $0 == ")" || $0 == "," || $0 == "(" || $0 == "$" }
        let name = String(unit[unit.startIndex..<(stop ?? unit.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return "\(token.text) per \(name)"
    }

    private static func symbol(in text: String) -> String {
        for symbol in ["$", "£", "€", "¥", "₹"] where text.contains(symbol) {
            return symbol
        }
        return ""
    }

    /// Every number in the string, in order, as decimals.
    ///
    /// Grouping separators are dropped and the last dot or comma with two
    /// digits behind it is treated as the decimal point, which reads both
    /// "1,299.00" and "1.299,00" without having to know the locale. A number
    /// whose shape matches neither is skipped rather than guessed at.
    static func amounts(in text: String) -> [Decimal] {
        var found: [Decimal] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            if let value = decimal(from: current) { found.append(value) }
        }
        for character in text {
            if character.isNumber || character == "." || character == "," {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    static func decimal(from raw: String) -> Decimal? {
        var text = raw
        // A trailing separator belongs to the sentence, not the number.
        while let last = text.last, last == "." || last == "," {
            text.removeLast()
        }
        guard !text.isEmpty, text.contains(where: \.isNumber) else { return nil }

        // The rightmost separator with exactly two digits after it is the
        // decimal point; everything else groups thousands. "1,299.00" and
        // "1.299,00" both land on 1299.00, and "1,299" stays 1299.
        var integer = text
        var fraction = ""
        if let index = text.lastIndex(where: { $0 == "." || $0 == "," }) {
            let after = text[text.index(after: index)...]
            if after.count == 2, after.allSatisfy(\.isNumber) {
                integer = String(text[text.startIndex..<index])
                fraction = String(after)
            }
        }
        let digits = integer.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Decimal(string: fraction.isEmpty ? digits : "\(digits).\(fraction)")
    }
}

// MARK: - Stars

/// A star rating and how many people left one.
public enum AmazonRating {

    /// "4.7 out of 5 stars" → 4.7. Also reads the search grid's longer
    /// "4.6 out of 5 stars, rating details".
    ///
    /// A rating is not money and is not parsed like money. The price reader
    /// treats a dot with one digit behind it as a thousands separator,
    /// because "1,299" is one thousand two hundred and ninety-nine — apply
    /// that grammar to "4.7" and you get a product rated forty-seven stars.
    /// Here a separator is always a decimal point.
    ///
    /// The other half is knowing which number is the rating. "out of 5" names
    /// the scale, so when the phrase is present the rating is whatever came
    /// before it — and a string with nothing before it ("out of 5 stars",
    /// which is what an unrated product renders) has no rating at all rather
    /// than a rating of five.
    ///
    /// Bounded to 0...5 rather than trusted: this number decides how many
    /// stars get drawn, and a payload saying 47 should lose its rating rather
    /// than paint a row off the edge of the card.
    public static func stars(_ raw: String) -> Double? {
        let text = AmazonText.tidy(raw)
        guard !text.isEmpty else { return nil }

        var scope = Substring(text)
        if let phrase = text.range(of: "out of", options: .caseInsensitive) {
            scope = text[text.startIndex..<phrase.lowerBound]
        }
        guard let value = scaleValue(in: scope) else { return nil }
        guard value >= 0, value <= 5 else { return nil }
        return value
    }

    /// The first number in a fragment, where a single separator is always a
    /// decimal point: "4.7" is four point seven, "4,7" likewise.
    static func scaleValue(in text: Substring) -> Double? {
        var digits = ""
        var seenSeparator = false
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if (character == "." || character == ",")
                && !digits.isEmpty && !seenSeparator {
                seenSeparator = true
                digits.append(".")
            } else if !digits.isEmpty {
                break
            }
        }
        // A separator with nothing behind it belongs to the sentence.
        while digits.hasSuffix(".") { digits.removeLast() }
        guard !digits.isEmpty else { return nil }
        return Double(digits)
    }

    /// "(87,229)" → 87229, "1,234 ratings" → 1234, "(16.1K)" → 16100.
    ///
    /// Amazon compacts counts on the search grid and spells them in full on
    /// the product page, so both spellings arrive at the same number.
    public static func count(_ raw: String) -> Int? {
        let text = AmazonText.tidy(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        guard !text.isEmpty else { return nil }

        // A sentence describing a rating is not a count, and this guard is
        // here because the mistake has already been made once: an
        // `a[aria-label*="rating"]` selector matches the rating popover
        // ("4.7 out of 5 stars, rating details") before it reaches the count
        // link ("87,229 ratings"), and read as a number that is 47 reviews
        // for a product with eighty-seven thousand. The selector was fixed;
        // this makes the same class of mistake fail loudly instead of
        // rendering a plausible wrong number.
        guard text.range(of: "out of", options: .caseInsensitive) == nil
        else { return nil }

        let multiplier: Decimal
        let upper = text.uppercased()
        if upper.contains("K") { multiplier = 1_000 }
        else if upper.contains("M") { multiplier = 1_000_000 }
        else { multiplier = 1 }

        guard var value = AmazonPrice.amounts(in: text).first else { return nil }
        if multiplier > 1 {
            // "16.1K" is 16,100 — but the amount reader treats the dot as a
            // decimal point only when two digits follow, so re-read it here
            // where we know a fraction is meant.
            value = compactValue(in: text) ?? value
            value *= multiplier
        }
        let number = NSDecimalNumber(decimal: value).doubleValue
        guard number >= 0, number < 1e12 else { return nil }
        return Int(number.rounded())
    }

    /// The number in front of a K or an M, where a single dot is always a
    /// decimal point: "16.1K" is 16.1, never 161.
    private static func compactValue(in text: String) -> Decimal? {
        var digits = ""
        for character in text {
            if character.isNumber || character == "." { digits.append(character) }
            else if !digits.isEmpty { break }
        }
        return digits.isEmpty ? nil : Decimal(string: digits)
    }
}

// MARK: - Pictures

/// Amazon's image addresses carry their size in the filename, and it can be
/// asked to be bigger.
///
/// The search grid ships 166×218 thumbnails, which look soft in a 300pt card.
/// The same picture at `._AC_SX679_.` is 679 wide, and with the modifier
/// dropped entirely it is the 1200×1500 original. Verified against
/// `m.media-amazon.com` rather than assumed.
public enum AmazonImage {

    /// The hosts whose addresses this understands. A URL from anywhere else
    /// is returned untouched — rewriting a filename we don't understand is
    /// how you turn a working picture into a 404.
    static let mediaHosts: Set<String> = [
        "m.media-amazon.com",
        "images-na.ssl-images-amazon.com",
        "images-eu.ssl-images-amazon.com",
    ]

    /// The same picture, asked for at roughly `width` pixels across.
    ///
    /// Returns the address unchanged whenever anything is unfamiliar: a host
    /// we don't know, a path that isn't an image, or a filename with no size
    /// modifier to replace. Unchanged is always safe; invented is not.
    public static func sized(_ address: String, width: Int) -> String {
        guard width > 0,
              let url = URL(string: address),
              let host = url.host()?.lowercased(),
              mediaHosts.contains(host),
              url.path.contains("/images/")
        else { return address }

        let name = url.lastPathComponent
        guard let rewritten = rewrite(filename: name, to: "_AC_SX\(width)_")
        else { return address }
        return address.replacingOccurrences(of: name, with: rewritten)
    }

    /// The picture at its native size, with every modifier dropped.
    public static func original(_ address: String) -> String {
        guard let url = URL(string: address),
              let host = url.host()?.lowercased(),
              mediaHosts.contains(host),
              url.path.contains("/images/")
        else { return address }

        let name = url.lastPathComponent
        guard let rewritten = rewrite(filename: name, to: nil) else { return address }
        return address.replacingOccurrences(of: name, with: rewritten)
    }

    /// `71IE9dLBduL._AC_UY218_.jpg` → `71IE9dLBduL._AC_SX679_.jpg`, or with
    /// `modifier` nil, → `71IE9dLBduL.jpg`.
    ///
    /// The modifier is everything between the first and last dot. A filename
    /// with only one dot has no modifier and is already the original, which
    /// is not a failure — it is nothing to do.
    static func rewrite(filename: String, to modifier: String?) -> String? {
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let stem = String(parts[0])
        let ext = String(parts[parts.count - 1])
        guard !stem.isEmpty, !ext.isEmpty else { return nil }
        guard let modifier else { return "\(stem).\(ext)" }
        return "\(stem).\(modifier).\(ext)"
    }
}

// MARK: - Text

public enum AmazonText {
    /// One space where the page had newlines, tabs and runs of spaces.
    ///
    /// Everything crossing the bridge is `textContent`, which preserves the
    /// markup's own indentation — so this runs on every string before
    /// anything else looks at it.
    public static func tidy(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Size: 6FT*2" → "Size".
    ///
    /// Amazon writes a variation row's heading as the dimension and the
    /// current value in one string. The heading is the half before the
    /// colon — which is the opposite end from `AmazonDelivery.brand`, and
    /// the reason these are two functions rather than one clever one.
    public static func label(_ raw: String) -> String {
        let text = tidy(raw)
        guard let colon = text.firstIndex(of: ":") else { return text }
        return tidy(String(text[text.startIndex..<colon]))
    }

    /// Vendor copy, un-shouted.
    ///
    /// Baymard: 52% of sites don't post-process the data their vendors give
    /// them, and Amazon is the largest such site in the world — its bullets
    /// and spec cells arrive in ALL CAPS often enough to be a house style.
    /// Normalising them is one of the few things a native renderer can do
    /// that the site itself does not.
    ///
    /// Only whole words that are shouted, and only when most of the string
    /// is: "USB C" and "60W" are how those things are spelled, and a
    /// sentence-caser that produces "Usb c" has made the copy worse.
    public static func sentenceCased(_ raw: String) -> String {
        let text = tidy(raw)
        let letters = text.filter(\.isLetter)
        guard letters.count >= 8 else { return text }
        let shouted = letters.filter(\.isUppercase).count
        // Comfortably more than a string that merely starts its sentences
        // and names a brand, and short of demanding every letter.
        guard Double(shouted) / Double(letters.count) > 0.75 else { return text }

        return text.split(separator: " ").enumerated().map { index, word in
            let lower = word.lowercased()
            // Inside a fully shouted string, "USB" and "AND" are the same
            // shape — nothing but a vocabulary can separate an initialism
            // from a function word. So short words stay as they are unless
            // they are on this list, which is the price of never printing
            // "Usb c cable". The cost is that a short shouted adjective can
            // survive; that is a cosmetic blemish rather than a mangled name,
            // and it is the right way round to be wrong.
            let isShort = word.count <= 4
            let keepsCase = word.contains(where: \.isNumber)
                || (isShort && !Self.shoutedStopwords.contains(lower))
            if keepsCase { return String(word) }
            return index == 0
                ? lower.prefix(1).uppercased() + lower.dropFirst()
                : lower
        }.joined(separator: " ")
    }

    /// Function words short enough to be mistaken for initialisms. Only
    /// consulted inside a string that is already shouting.
    static let shoutedStopwords: Set<String> = [
        "and", "the", "for", "with", "that", "this", "your", "from", "into",
        "onto", "are", "was", "all", "any", "can", "has", "its", "not", "our",
        "out", "per", "use", "you", "will", "when", "each", "also", "more",
        "than", "then", "only", "over", "such", "very", "just", "like", "been",
        "have", "they", "were", "what", "who", "why", "how", "but", "now",
        "get", "got", "one", "two", "new", "up", "to", "of", "in", "on", "at",
        "by", "or", "as", "is", "it", "be", "an", "a",
    ]

    /// The first of these that has anything in it, tidied. What a field with
    /// several candidate selectors collapses to.
    public static func firstNonEmpty(_ candidates: [String]) -> String {
        for candidate in candidates {
            let text = tidy(candidate)
            if !text.isEmpty { return text }
        }
        return ""
    }
}
