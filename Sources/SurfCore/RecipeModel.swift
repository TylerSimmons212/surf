import Foundation

/// A recipe, as the lens renders it — parsed out of the page's JSON-LD.
///
/// Recipe SEO guarantees the JSON-LD exists; nothing guarantees it's tidy.
/// Real sites ship `@graph` wrappers, arrays where the spec says strings,
/// strings where it says objects, entity-encoded apostrophes, and instruction
/// lists nested two sections deep. Every accessor here is lenient the same
/// way: take what's usable, drop what isn't, and never fail the recipe over
/// one field — which is exactly why this lives in SurfCore behind tests
/// rather than inline in a view.
public struct FocusRecipe: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var author: String
    public var image: String
    /// As declared — "4 servings", "12 cookies". Shown, not computed on.
    public var yieldText: String
    /// The number in the yield when there is one, for the serving scaler.
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var totalMinutes: Int?
    public var ingredients: [RecipeIngredient]
    public var steps: [RecipeStep]

    public init(
        title: String = "", summary: String = "", author: String = "",
        image: String = "", yieldText: String = "", servings: Double? = nil,
        prepMinutes: Int? = nil, cookMinutes: Int? = nil, totalMinutes: Int? = nil,
        ingredients: [RecipeIngredient] = [], steps: [RecipeStep] = []
    ) {
        self.title = title
        self.summary = summary
        self.author = author
        self.image = image
        self.yieldText = yieldText
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.totalMinutes = totalMinutes
        self.ingredients = ingredients
        self.steps = steps
    }

    /// Whether this is worth a lens: enough ingredients and steps that a
    /// cook could actually follow it. A "recipe" of one line is SEO wearing
    /// an apron.
    public var isSubstantial: Bool {
        ingredients.count >= 3 && steps.count >= 2
    }

    // MARK: - Parsing

    /// The first substantial Recipe in the page's JSON-LD scripts, or nil.
    public static func parse(fromJSONLD scripts: [String]) -> FocusRecipe? {
        for script in scripts {
            guard let data = script.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            var found: FocusRecipe?
            walk(root, depth: 0) { object in
                if found == nil, let recipe = recipe(from: object), recipe.isSubstantial {
                    found = recipe
                }
            }
            if let found { return found }
        }
        return nil
    }

    /// Visits every dictionary in a JSON-LD tree: bare objects, arrays of
    /// them, and `@graph` wrappers, which is how most sites actually ship it.
    private static func walk(
        _ node: Any, depth: Int, visit: ([String: Any]) -> Void
    ) {
        guard depth <= 4 else { return }
        if let array = node as? [Any] {
            for item in array { walk(item, depth: depth + 1, visit: visit) }
            return
        }
        guard let object = node as? [String: Any] else { return }
        visit(object)
        if let graph = object["@graph"] {
            walk(graph, depth: depth + 1, visit: visit)
        }
    }

    private static func recipe(from object: [String: Any]) -> FocusRecipe? {
        // @type is a string or an array of them; a Recipe is any that names it.
        let types: [String]
        if let one = object["@type"] as? String { types = [one] }
        else if let many = object["@type"] as? [String] { types = many }
        else { return nil }
        guard types.contains(where: { $0.caseInsensitiveCompare("Recipe") == .orderedSame })
        else { return nil }

        var recipe = FocusRecipe()
        recipe.title = text(object["name"])
        recipe.summary = text(object["description"])
        recipe.author = authorName(object["author"])
        recipe.image = imageURL(object["image"])
        recipe.yieldText = yieldText(object["recipeYield"])
        recipe.servings = leadingNumber(in: recipe.yieldText)
        recipe.prepMinutes = minutes(fromISODuration: object["prepTime"] as? String)
        recipe.cookMinutes = minutes(fromISODuration: object["cookTime"] as? String)
        recipe.totalMinutes = minutes(fromISODuration: object["totalTime"] as? String)

        // "recipeIngredient" is the spec; "ingredients" is the older key
        // plenty of sites still ship.
        let rawIngredients = strings(object["recipeIngredient"] ?? object["ingredients"])
        recipe.ingredients = rawIngredients.compactMap {
            let cleaned = cleanText($0)
            return cleaned.isEmpty ? nil : RecipeIngredient(text: cleaned)
        }
        recipe.steps = steps(from: object["recipeInstructions"])
        return recipe
    }

    /// Instructions arrive as a string, an array of strings, an array of
    /// HowToSteps, or HowToSections holding more of the same. Sections keep
    /// their names — "For the sauce" is information a cook uses.
    private static func steps(from node: Any?, section: String = "") -> [RecipeStep] {
        guard let node else { return [] }

        if let string = node as? String {
            // One blob: split on newlines when they're there; it beats one
            // step the height of the page.
            return string
                .components(separatedBy: .newlines)
                .map { cleanText($0) }
                .filter { !$0.isEmpty }
                .map { RecipeStep(text: $0, section: section) }
        }
        if let array = node as? [Any] {
            return array.flatMap { steps(from: $0, section: section) }
        }
        guard let object = node as? [String: Any] else { return [] }

        let type = (object["@type"] as? String) ?? ""
        if type.caseInsensitiveCompare("HowToSection") == .orderedSame {
            return steps(
                from: object["itemListElement"],
                section: cleanText(text(object["name"]))
            )
        }
        // A HowToStep, or an untyped object with text in it.
        let body = cleanText(text(object["text"] ?? object["name"]))
        guard !body.isEmpty else { return [] }
        return [RecipeStep(text: body, section: section)]
    }

    // MARK: - Lenient field readers

    private static func text(_ node: Any?) -> String {
        if let string = node as? String { return cleanText(string) }
        if let number = node as? NSNumber { return "\(number)" }
        return ""
    }

    private static func strings(_ node: Any?) -> [String] {
        if let one = node as? String { return [one] }
        return (node as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func authorName(_ node: Any?) -> String {
        if let string = node as? String { return cleanText(string) }
        if let object = node as? [String: Any] { return text(object["name"]) }
        if let array = node as? [Any], let first = array.first {
            return authorName(first)
        }
        return ""
    }

    private static func imageURL(_ node: Any?) -> String {
        if let string = node as? String { return string }
        if let object = node as? [String: Any] {
            return (object["url"] as? String) ?? ""
        }
        if let array = node as? [Any], let first = array.first {
            return imageURL(first)
        }
        return ""
    }

    private static func yieldText(_ node: Any?) -> String {
        if let number = node as? NSNumber { return "\(number) servings" }
        if let string = node as? String { return cleanText(string) }
        // An array is usually ["8", "8 servings"] — the wordier one reads.
        if let array = node as? [Any] {
            let candidates = array.map { text($0) }.filter { !$0.isEmpty }
            return candidates.max(by: { $0.count < $1.count }) ?? ""
        }
        return ""
    }

    private static func leadingNumber(in text: String) -> Double? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        return scanner.scanDouble()
    }

    /// "PT1H30M" → 90. Also tolerates the day field a slow-cooker recipe
    /// ships, and returns nil for the empty and the malformed alike.
    static func minutes(fromISODuration duration: String?) -> Int? {
        guard let duration, duration.hasPrefix("P") else { return nil }
        var total = 0.0
        var found = false
        var number = ""
        var inTime = false
        for character in duration.dropFirst() {
            switch character {
            case "T": inTime = true; number = ""
            case "0"..."9", ".", ",": number.append(character == "," ? "." : character)
            case "D":
                if let value = Double(number) { total += value * 24 * 60; found = true }
                number = ""
            case "H":
                if inTime, let value = Double(number) { total += value * 60; found = true }
                number = ""
            case "M":
                if inTime, let value = Double(number) { total += value; found = true }
                number = ""
            case "S":
                if inTime, let value = Double(number) { total += value / 60; found = true }
                number = ""
            default: number = ""
            }
        }
        guard found, total > 0 else { return nil }
        return Int(total.rounded())
    }

    /// "1 hr 30 min", for the meta chips.
    public static func label(forMinutes minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 && rest > 0 { return "\(hours) hr \(rest) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }

    /// Decodes the entities recipe JSON actually contains and drops any HTML
    /// that leaked into text fields.
    static func cleanText(_ text: String) -> String {
        var result = text
        if result.contains("<") {
            result = result.replacingOccurrences(
                of: "<[^>]+>", with: " ", options: .regularExpression
            )
        }
        if result.contains("&") {
            for (entity, character) in [
                ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                ("&#39;", "'"), ("&#039;", "'"), ("&apos;", "'"),
                ("&nbsp;", " "), ("&frac12;", "½"), ("&frac14;", "¼"),
                ("&frac34;", "¾"), ("&deg;", "°"), ("&ndash;", "–"),
                ("&mdash;", "—"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                ("&rdquo;", "”"), ("&ldquo;", "“"),
            ] {
                result = result.replacingOccurrences(of: entity, with: character)
            }
        }
        return result
            .replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One instruction, with the section it belongs to when the recipe has them.
public struct RecipeStep: Equatable, Sendable, Identifiable {
    public var id: Int = 0
    public var text: String
    /// "For the sauce" — empty for the common sectionless case.
    public var section: String

    public init(id: Int = 0, text: String, section: String = "") {
        self.id = id
        self.text = text
        self.section = section
    }
}

/// One ingredient line, with the quantity picked out so it can scale.
public struct RecipeIngredient: Equatable, Sendable, Identifiable {
    public var id: Int = 0
    /// The line as written — the fallback whenever parsing declines.
    public var text: String
    /// The leading quantity, when the line starts with one: "1 1/2 cups" →
    /// 1.5, with `remainder` = "cups flour, sifted". Nil for "salt to taste".
    public var quantity: Double?
    public var remainder: String

    public init(id: Int = 0, text: String) {
        self.id = id
        self.text = text
        let parsed = Self.parseQuantity(from: text)
        self.quantity = parsed.quantity
        self.remainder = parsed.remainder
    }

    /// The line at a scale: quantity multiplied and re-written as cook's
    /// fractions, the rest untouched. A line with no leading quantity comes
    /// back verbatim — scaling "salt to taste" would be arithmetic doing
    /// comedy.
    public func scaled(by factor: Double) -> String {
        guard let quantity, factor != 1 else { return text }
        let scaled = quantity * factor
        return "\(Self.format(scaled)) \(remainder)"
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Quantity parsing

    private static let unicodeFractions: [Character: Double] = [
        "½": 0.5, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "¼": 0.25, "¾": 0.75,
        "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8,
        "⅙": 1.0 / 6, "⅚": 5.0 / 6, "⅛": 0.125, "⅜": 0.375,
        "⅝": 0.625, "⅞": 0.875,
    ]

    /// Reads a leading quantity in the forms recipe lines actually use:
    /// "2", "1.5", "1 1/2", "3/4", "½", "1½". Stops at the first thing that
    /// isn't part of a number, which becomes the remainder.
    static func parseQuantity(from line: String) -> (quantity: Double?, remainder: String) {
        var total: Double?
        var index = line.startIndex

        func skipSpaces() {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        }

        func readNumber() -> Double? {
            skipSpaces()
            guard index < line.endIndex else { return nil }
            if let fraction = unicodeFractions[line[index]] {
                index = line.index(after: index)
                return fraction
            }
            var digits = ""
            var seenSlash = false
            var loop = index
            while loop < line.endIndex {
                let character = line[loop]
                // Before `isNumber`: Unicode counts "½" as a number, and it
                // must not fall into the digit accumulator as a character
                // `Double` can't read.
                if let fraction = unicodeFractions[character] {
                    guard !digits.isEmpty, !seenSlash else { break }
                    // "1½" — a whole number with the fraction glued on.
                    guard let whole = Double(digits) else { return nil }
                    index = line.index(after: loop)
                    return whole + fraction
                } else if character.isNumber || character == "." {
                    digits.append(character)
                } else if character == "/", !seenSlash, !digits.isEmpty {
                    digits.append(character)
                    seenSlash = true
                } else {
                    break
                }
                loop = line.index(after: loop)
            }
            guard !digits.isEmpty else { return nil }
            index = loop
            if seenSlash {
                let parts = digits.split(separator: "/")
                guard parts.count == 2,
                      let numerator = Double(parts[0]),
                      let denominator = Double(parts[1]), denominator != 0
                else { return nil }
                return numerator / denominator
            }
            return Double(digits)
        }

        guard let first = readNumber() else { return (nil, line) }
        total = first
        // "1 1/2" — a following fraction folds into the whole.
        let checkpoint = index
        if let second = readNumber(), second < 1, first == first.rounded() {
            total = first + second
        } else {
            index = checkpoint
        }

        skipSpaces()
        return (total, String(line[index...]))
    }

    /// A number the way a cook writes it: eighths as fractions, otherwise a
    /// short decimal. "0.75" on an ingredient line reads as a spreadsheet.
    /// Public because the yield chip scales through it too.
    public static func format(_ value: Double) -> String {
        let whole = Int(value)
        let fraction = value - Double(whole)
        let names: [(Double, String)] = [
            (0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.375, "⅜"), (0.5, "½"),
            (0.625, "⅝"), (2.0 / 3, "⅔"), (0.75, "¾"), (0.875, "⅞"),
        ]
        if fraction < 0.03 {
            return "\(whole)"
        }
        if fraction > 0.97 {
            return "\(whole + 1)"
        }
        for (target, glyph) in names where abs(fraction - target) < 0.03 {
            return whole == 0 ? glyph : "\(whole)\(glyph)"
        }
        // Nothing clean: one decimal, trailing zero dropped by %g.
        return String(format: "%g", (value * 10).rounded() / 10)
    }
}
