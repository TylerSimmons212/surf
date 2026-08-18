import Foundation

/// What an attribute's value actually is, so it can be taken apart usefully.
public enum AttributeValueKind: String, Sendable, Equatable {
    /// Whitespace-separated names: `class`, `rel`, `sandbox`, `headers`.
    case tokenList
    /// `prop: value; prop: value` — an inline `style`.
    case styleRules
    /// Comma-separated candidates: `srcset`, `sizes`.
    case candidateList
    /// A value that parses as JSON, which many frameworks put in `data-*`.
    case json
    case url
    case plain
}

/// One piece of a broken-up attribute.
public struct AttributePart: Sendable, Equatable, Identifiable {
    public var index: Int
    /// The whole piece, as it appears in the source.
    public var text: String
    /// For a declaration or a JSON entry: what's on the left.
    public var key: String?
    /// For a declaration or a JSON entry: what's on the right.
    public var value: String?
    /// A Tailwind-style variant — the `md` in `md:flex`, the `hover` in
    /// `hover:bg-blue-500`. Nil for a plain token.
    public var group: String?

    public var id: Int { index }

    public init(
        index: Int,
        text: String,
        key: String? = nil,
        value: String? = nil,
        group: String? = nil
    ) {
        self.index = index
        self.text = text
        self.key = key
        self.value = value
        self.group = group
    }
}

/// Takes an attribute apart so it can be read.
///
/// The case that motivates all of this: a Tailwind element routinely carries
/// forty classes in one attribute, and every devtools shows them as a single
/// unbroken line that runs off the edge of the pane. The value is right there
/// and completely unreadable. The same is true of an inline `style` with a
/// dozen declarations, a `srcset` with six candidates, or a `data-` attribute
/// holding a JSON blob.
public enum AttributeBreakdown {

    /// Attributes whose values are whitespace-separated token lists, per HTML.
    private static let tokenListNames: Set<String> = [
        "class", "rel", "sandbox", "headers", "ping", "accesskey", "for",
        "itemprop", "itemref", "dropzone", "aria-labelledby", "aria-describedby",
        "aria-owns", "aria-controls", "aria-flowto",
    ]

    private static let candidateListNames: Set<String> = ["srcset", "sizes", "imagesrcset"]

    public static func kind(of name: String, value: String) -> AttributeValueKind {
        let lowered = name.lowercased()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if lowered == "style" { return .styleRules }
        if candidateListNames.contains(lowered) { return .candidateList }
        if tokenListNames.contains(lowered) {
            // A single token is not a list worth expanding.
            return splitTokens(trimmed).count > 1 ? .tokenList : .plain
        }
        if isJSON(trimmed) { return .json }
        if lowered == "href" || lowered == "src" || lowered == "action" { return .url }
        return .plain
    }

    /// The pieces, or a single piece when there's nothing to break up.
    public static func parts(of name: String, value: String) -> [AttributePart] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind(of: name, value: value) {
        case .tokenList:
            return splitTokens(trimmed).enumerated().map { index, token in
                AttributePart(index: index, text: token, group: variant(of: token))
            }

        case .styleRules:
            return splitDeclarations(trimmed).enumerated().map { index, declaration in
                let pair = declaration.split(separator: ":", maxSplits: 1).map(String.init)
                return AttributePart(
                    index: index,
                    text: declaration,
                    key: pair.first?.trimmingCharacters(in: .whitespaces),
                    value: pair.count > 1
                        ? pair[1].trimmingCharacters(in: .whitespaces)
                        : nil
                )
            }

        case .candidateList:
            return splitTopLevel(trimmed, on: ",").enumerated().map { index, candidate in
                AttributePart(index: index, text: candidate)
            }

        case .json:
            return jsonParts(trimmed)

        case .url, .plain:
            return [AttributePart(index: 0, text: trimmed)]
        }
    }

    /// A short line for the collapsed row: how many pieces, or the value.
    public static func summary(of name: String, value: String) -> String {
        let pieces = parts(of: name, value: value)
        guard pieces.count > 1 else { return value }

        switch kind(of: name, value: value) {
        case .tokenList: return "\(pieces.count) classes"
        case .styleRules: return "\(pieces.count) declarations"
        case .candidateList: return "\(pieces.count) candidates"
        case .json: return "\(pieces.count) keys"
        case .url, .plain: return value
        }
    }

    /// Whether breaking this one up would tell you anything.
    public static func isExpandable(name: String, value: String) -> Bool {
        parts(of: name, value: value).count > 1
    }

    // MARK: - Tokens

    static func splitTokens(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `md:hover:bg-blue-500` → `md:hover`. Grouping by this is what makes a
    /// long Tailwind list legible: the base styles separate from the responsive
    /// ones from the state ones, instead of forty chips in source order.
    static func variant(of token: String) -> String? {
        guard let lastColon = token.lastIndex(of: ":") else { return nil }
        let prefix = String(token[token.startIndex..<lastColon])
        // A leading colon, or a pseudo-selector-looking token, isn't a variant.
        return prefix.isEmpty ? nil : prefix
    }

    // MARK: - Declarations

    /// Splits on semicolons that are actually separators.
    ///
    /// `background: url(data:image/png;base64,iVBOR...)` contains two of them
    /// that are not, which is exactly the value someone would be trying to read.
    static func splitDeclarations(_ value: String) -> [String] {
        splitTopLevel(value, on: ";")
    }

    /// Splits on a separator, ignoring any inside brackets or quotes.
    static func splitTopLevel(_ value: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for character in value {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth = max(0, depth - 1)
                current.append(character)
            case separator where depth == 0:
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { parts.append(piece) }
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: - JSON

    static func isJSON(_ value: String) -> Bool {
        guard value.count > 1,
              let first = value.first, first == "{" || first == "[",
              let data = value.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func jsonParts(_ value: String) -> [AttributePart] {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [AttributePart(index: 0, text: value)] }

        if let dictionary = object as? [String: Any] {
            // Sorted, because JSON object order is not meaningful and a stable
            // order is easier to scan than whatever the page happened to emit.
            return dictionary.keys.sorted().enumerated().map { index, key in
                AttributePart(
                    index: index,
                    text: "\(key): \(describe(dictionary[key] ?? ""))",
                    key: key,
                    value: describe(dictionary[key] ?? "")
                )
            }
        }
        if let array = object as? [Any] {
            return array.enumerated().map { index, element in
                AttributePart(
                    index: index,
                    text: describe(element),
                    key: "\(index)",
                    value: describe(element)
                )
            }
        }
        return [AttributePart(index: 0, text: value)]
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case is NSNull: "null"
        case let array as [Any]: "[\(array.count) items]"
        case let dictionary as [String: Any]: "{\(dictionary.count) keys}"
        default: String(describing: value)
        }
    }
}
