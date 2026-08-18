import Foundation

/// A parsed CSS gradient.
///
/// Everything the parser doesn't fully understand is kept as written and put
/// back untouched. That's the whole safety posture: a gradient we rewrite
/// wrongly is a visible defect on someone's page, while one we hand back
/// verbatim is merely a spot this feature hasn't reached.
public struct CSSGradient: Equatable, Sendable {

    public enum Item: Equatable, Sendable {
        /// A colour stop, with its position text preserved exactly — positions
        /// carry units and even double-position shorthand, none of which the
        /// theme has any business touching.
        case stop(CSSColor, position: String?)
        /// An interpolation hint, a `var()` we can't resolve, or anything else
        /// we decline to interpret.
        case verbatim(String)
    }

    /// The function as written, vendor prefix and `repeating-` included.
    public var function: String
    /// Direction, shape, or interpolation space — `to bottom`, `45deg`,
    /// `in oklch`, `circle at center`. Never a colour, so never transformed.
    public var preamble: String?
    public var items: [Item]

    public var stops: [CSSColor] {
        items.compactMap { if case .stop(let color, _) = $0 { color } else { nil } }
    }
}

extension CSSGradient {

    static let functionSuffixes = ["linear-gradient", "radial-gradient", "conic-gradient"]

    /// Whether a function name is a gradient, allowing `repeating-` and the
    /// vendor prefixes that are still all over the web.
    static func isGradientFunction(_ name: String) -> Bool {
        functionSuffixes.contains { name.hasSuffix($0) }
    }

    /// Parses a single gradient function. Nil if it isn't one.
    public init?(css text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<open]).lowercased()
        guard CSSGradient.isGradientFunction(name) else { return nil }

        let body = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        let arguments = CSSGradient.splitTopLevel(body, on: ",")
        guard !arguments.isEmpty else { return nil }

        var preamble: String?
        var items: [Item] = []
        for (index, argument) in arguments.enumerated() {
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if let (color, position) = CSSGradient.leadingColor(of: text) {
                items.append(.stop(color, position: position))
            } else if index == 0 {
                // Only the first argument may be a direction or shape.
                preamble = text
            } else {
                items.append(.verbatim(text))
            }
        }
        // A gradient with nothing we recognise as a colour is one to leave be.
        guard items.contains(where: { if case .stop = $0 { true } else { false } }) else {
            return nil
        }

        self.function = name
        self.preamble = preamble
        self.items = items
    }

    public var css: String {
        var parts: [String] = []
        if let preamble { parts.append(preamble) }
        for item in items {
            switch item {
            case .stop(let color, let position):
                parts.append([color.css, position].compactMap { $0 }.joined(separator: " "))
            case .verbatim(let text):
                parts.append(text)
            }
        }
        return "\(function)(\(parts.joined(separator: ", ")))"
    }

    /// Remaps the gradient into the target scheme.
    ///
    /// The stops move together — see `ThemeTransform.transformGradient` for why
    /// moving them one at a time turns a gradient inside out.
    public func transformed(to target: ColorSchemeTarget) -> CSSGradient {
        let originals = stops
        guard !originals.isEmpty else { return self }
        let perceptual = originals.map { OKLCH($0.rgb) }

        // A brand gradient comes back as the same bytes, not merely the same
        // colours. Round-tripping it through the colour space would shift the
        // last bit of each channel and rewrite a declaration we had decided not
        // to touch — which turns a no-op into a diff, and a diff into a risk.
        guard !ThemeTransform.isAccentGradient(perceptual) else { return self }

        let transformed = ThemeTransform.transformGradient(perceptual, target: target)

        var result = self
        var next = 0
        result.items = items.map { item in
            guard case .stop(let color, let position) = item else { return item }
            defer { next += 1 }
            guard next < transformed.count else { return item }
            // Alpha is compositing, not colour, so it rides through untouched.
            return .stop(
                CSSColor(rgb: transformed[next].displayable, alpha: color.alpha),
                position: position
            )
        }
        return result
    }

    // MARK: - Whole values

    /// Transforms every gradient inside a full property value.
    ///
    /// `background-image` routinely carries several layers, and the commas
    /// between them look exactly like the commas between stops — so this walks
    /// the string with a paren depth rather than splitting it. Anything that
    /// isn't a gradient, `url()` above all, is passed through untouched.
    public static func transformValue(_ value: String, to target: ColorSchemeTarget) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            guard let open = value[index...].firstIndex(of: "(") else {
                result += value[index...]
                break
            }
            // Walk back over the function name to see what this paren belongs to.
            var nameStart = open
            while nameStart > index {
                let previous = value.index(before: nameStart)
                let character = value[previous]
                guard character.isLetter || character.isNumber || character == "-" else { break }
                nameStart = previous
            }
            let name = String(value[nameStart..<open]).lowercased()

            guard let close = matchingParen(in: value, openedAt: open) else {
                result += value[index...]
                break
            }
            let whole = String(value[nameStart...close])

            result += value[index..<nameStart]
            if isGradientFunction(name), let gradient = CSSGradient(css: whole) {
                result += gradient.transformed(to: target).css
            } else {
                result += whole
            }
            index = value.index(after: close)
        }
        return result
    }

    // MARK: - Scanning

    /// The closing paren matching the one at `openedAt`, quotes respected.
    static func matchingParen(in text: String, openedAt open: String.Index) -> String.Index? {
        var depth = 0
        var quote: Character?
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits on a separator that isn't nested inside parens or quotes.
    ///
    /// The reason this can't be `split(separator:)`: in
    /// `linear-gradient(red, rgb(0 0 0, 0.5))` the commas are at two different
    /// depths and mean entirely different things.
    static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for character in text {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth -= 1
                current.append(character)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    /// Pulls a colour off the front of a stop, returning it and whatever
    /// position text followed.
    ///
    /// Has to cope with a colour that contains spaces of its own —
    /// `rgb(255 0 0) 10%` — so a plain split on whitespace won't do.
    static func leadingColor(of text: String) -> (CSSColor, String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A function call: take it whole, up to its matching paren.
        if let open = trimmed.firstIndex(of: "("),
           !trimmed[trimmed.startIndex..<open].contains(" "),
           let close = matchingParen(in: trimmed, openedAt: open) {
            let colorText = String(trimmed[trimmed.startIndex...close])
            guard let color = CSSColor(css: colorText) else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (color, rest.isEmpty ? nil : rest)
        }

        // Otherwise the colour is the first whitespace-delimited token.
        let pieces = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let color = CSSColor(css: pieces[0]) else { return nil }
        let rest = pieces.count > 1
            ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (color, rest.isEmpty ? nil : rest)
    }
}
