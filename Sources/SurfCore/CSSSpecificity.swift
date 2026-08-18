import Foundation

/// A selector's weight, as the cascade counts it.
///
/// Three numbers, compared left to right: ids, then classes (with attribute
/// selectors and pseudo-classes), then element names (with pseudo-elements).
/// The comparison is lexicographic and *not* additive — a thousand classes
/// never outweigh a single id — which is exactly the rule people misremember,
/// and the reason this is worth showing on screen rather than leaving implied.
public struct Specificity: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var ids: Int
    public var classes: Int
    public var types: Int

    public init(_ ids: Int = 0, _ classes: Int = 0, _ types: Int = 0) {
        self.ids = ids
        self.classes = classes
        self.types = types
    }

    public static let zero = Specificity()

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.ids, lhs.classes, lhs.types) < (rhs.ids, rhs.classes, rhs.types)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Specificity(lhs.ids + rhs.ids, lhs.classes + rhs.classes, lhs.types + rhs.types)
    }

    /// `0-2-1`, the notation every CSS reference uses.
    public var description: String { "\(ids)-\(classes)-\(types)" }
}

/// Counts a selector's weight without a browser.
///
/// Done here rather than in the page for two reasons. The DOM exposes no API
/// for it at all — `getMatchedCSSRules()` was removed from WebKit years ago and
/// nothing replaced it — so it has to be computed by hand wherever it lives.
/// And doing it in Swift means the whole table of awkward cases (`:where()`,
/// nested `:is()`, an escaped `\#` that isn't an id) is covered by tests that
/// run in milliseconds instead of by clicking around a page.
public enum CSSSpecificity {

    /// The weight of a selector, or of the heaviest branch of a selector list.
    public static func calculate(_ selector: String) -> Specificity {
        splitList(selector).map { compute(Array($0)) }.max() ?? .zero
    }

    /// Splits `a, b:is(c, d), e` on its *top-level* commas only.
    ///
    /// The commas inside `:is()` and inside `[title="a,b"]` are not separators,
    /// and splitting on them naively produces fragments that parse as different
    /// — usually heavier — selectors than what was written.
    public static func splitList(_ list: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false

        for character in list {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[":
                depth += 1
                current.append(character)
            case ")", "]":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    // MARK: - Scanner

    /// Pseudo-elements that predate the double colon and are still written with
    /// one. They count as elements, not classes, despite looking like a
    /// pseudo-class to a naive scanner.
    private static let legacyPseudoElements: Set<String> = [
        "before", "after", "first-line", "first-letter",
    ]

    /// Pseudo-classes whose weight is the weight of their heaviest argument
    /// rather than a class of their own.
    private static let transparent: Set<String> = [
        "is", "not", "has", "matches", "any", "-webkit-any", "-moz-any",
    ]

    private static func compute(_ chars: [Character]) -> Specificity {
        var result = Specificity()
        var index = 0
        // Whether the last thing counted was a type name, so a namespace bar
        // can take it back: in `svg|circle` the `svg` is a prefix, not a tag.
        var lastWasType = false

        while index < chars.count {
            let character = chars[index]

            switch character {
            case "\\":
                // An escape is part of whatever ident it sits in; if it opens
                // one, that ident is a type name.
                if !lastWasType { result.types += 1 }
                lastWasType = true
                index = skipIdentifier(chars, from: index)

            case "#":
                result.ids += 1
                lastWasType = false
                index = skipIdentifier(chars, from: index + 1)

            case ".":
                result.classes += 1
                lastWasType = false
                index = skipIdentifier(chars, from: index + 1)

            case "[":
                result.classes += 1
                lastWasType = false
                index = skipBalanced(chars, from: index, open: "[", close: "]")

            case ":":
                let (weight, next) = pseudo(chars, from: index)
                result = result + weight
                lastWasType = false
                index = next

            case "*":
                lastWasType = false
                index += 1

            case "|":
                // A namespace prefix. `ns|div` read as two type names until
                // now, so give one back. `*|div` and `|div` cost nothing here.
                if lastWasType { result.types = max(0, result.types - 1) }
                lastWasType = false
                index += 1

            case " ", "\t", "\n", ">", "+", "~", ",":
                lastWasType = false
                index += 1

            default:
                if isIdentifierStart(character) {
                    result.types += 1
                    lastWasType = true
                    index = skipIdentifier(chars, from: index)
                } else {
                    lastWasType = false
                    index += 1
                }
            }
        }
        return result
    }

    /// Weighs one pseudo-class or pseudo-element starting at a colon, and
    /// reports where it ends.
    private static func pseudo(_ chars: [Character], from start: Int) -> (Specificity, Int) {
        var index = start + 1
        var isElement = false
        if index < chars.count, chars[index] == ":" {
            isElement = true
            index += 1
        }

        let nameEnd = skipIdentifier(chars, from: index)
        let name = String(chars[index..<nameEnd]).lowercased()
        index = nameEnd

        var argument: String?
        if index < chars.count, chars[index] == "(" {
            let close = skipBalanced(chars, from: index, open: "(", close: ")")
            argument = String(chars[(index + 1)..<max(index + 1, close - 1)])
            index = close
        }

        // A pseudo-element weighs as an element and its argument never counts —
        // `::slotted(.a.b.c)` is one type, not three classes.
        if isElement || legacyPseudoElements.contains(name) {
            return (Specificity(0, 0, 1), index)
        }

        switch name {
        case "where":
            // Deliberately weightless. The entire point of `:where()` is to
            // contribute nothing, and getting this wrong makes a reset
            // stylesheet look like it should be winning fights it can't.
            return (.zero, index)

        case _ where transparent.contains(name):
            return (argument.map { calculate($0) } ?? .zero, index)

        case "nth-child", "nth-last-child":
            // `:nth-child(2n of .item)` is one class for the pseudo plus the
            // weight of the selector list after `of`.
            var weight = Specificity(0, 1, 0)
            if let argument, let range = argument.range(of: " of ") {
                weight = weight + calculate(String(argument[range.upperBound...]))
            }
            return (weight, index)

        case "host", "host-context":
            return (Specificity(0, 1, 0) + (argument.map { calculate($0) } ?? .zero), index)

        default:
            return (Specificity(0, 1, 0), index)
        }
    }

    // MARK: - Character work

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "-"
            || character.unicodeScalars.first.map { $0.value >= 0x80 } ?? false
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static func skipIdentifier(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count {
            if chars[index] == "\\" {
                // `\#` is a literal hash inside a name, not an id — the single
                // most common way a hand-rolled counter overcounts.
                index += 2
                continue
            }
            guard isIdentifierPart(chars[index]) else { break }
            index += 1
        }
        // Always make progress, even on a lone `\` at the end.
        return max(index, start + 1)
    }

    /// The index just past the bracket that closes the one at `start`.
    private static func skipBalanced(
        _ chars: [Character], from start: Int, open: Character, close: Character
    ) -> Int {
        var index = start
        var depth = 0
        var quote: Character?

        while index < chars.count {
            let character = chars[index]
            if character == "\\" { index += 2; continue }
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return chars.count
    }
}
