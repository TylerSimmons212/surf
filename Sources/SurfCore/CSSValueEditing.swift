import Foundation

/// A number inside a CSS value, with whatever unit was written next to it.
public struct CSSNumber: Sendable, Equatable {
    public var value: Double
    public var unit: String
    /// As written, so replacing it can preserve everything around it.
    public var text: String
    /// Where it sits in the value string.
    public var offset: Int

    public init(value: Double, unit: String, text: String, offset: Int) {
        self.value = value
        self.unit = unit
        self.text = text
        self.offset = offset
    }

    /// Whether the original was written without a decimal point. Turning `2`
    /// into `2.0` on the first nudge is noise in a diff.
    public var wasInteger: Bool { !text.contains(".") }
}

/// Finding and adjusting the numbers in a declaration.
///
/// Dragging on a number is the interaction a design tool has and a devtools
/// pane usually doesn't: `padding: 12px` is a value you want to *feel* rather
/// than retype, and every retype costs a round trip through the keyboard to
/// find out you wanted 14.
public enum CSSValueScrub {

    /// Every number in a value, in order.
    ///
    /// Per number rather than per value, because `margin: 8px 16px` has two and
    /// grabbing one must not disturb the other — the same reason a colour
    /// swatch belongs to its token.
    public static func numbers(in value: String) -> [CSSNumber] {
        var found: [CSSNumber] = []
        let characters = Array(value)
        var index = 0

        while index < characters.count {
            // A `#` starts a colour; its digits are not a quantity.
            if characters[index] == "#" {
                index += 1
                while index < characters.count, characters[index].isHexDigit { index += 1 }
                continue
            }

            guard characters[index].isNumber
                    || (characters[index] == "-" && index + 1 < characters.count
                        && (characters[index + 1].isNumber || characters[index + 1] == "."))
                    || (characters[index] == "." && index + 1 < characters.count
                        && characters[index + 1].isNumber)
            else {
                index += 1
                continue
            }

            // A number preceded by a letter or digit is part of an identifier —
            // the `2` in `h2` or the `1` in `grid-column-1` is not a length.
            if index > 0 {
                let previous = characters[index - 1]
                if previous.isLetter || previous == "_" || previous == "-" && index > 1
                    && (characters[index - 2].isLetter || characters[index - 2].isNumber) {
                    index += 1
                    while index < characters.count,
                          characters[index].isNumber || characters[index] == "." { index += 1 }
                    continue
                }
            }

            let start = index
            if characters[index] == "-" { index += 1 }
            while index < characters.count,
                  characters[index].isNumber || characters[index] == "." { index += 1 }
            let numberEnd = index

            // The unit runs on directly: `12px`, `1.5rem`, `50%`.
            while index < characters.count,
                  characters[index].isLetter || characters[index] == "%" { index += 1 }

            let text = String(characters[start..<index])
            let numberText = String(characters[start..<numberEnd])
            guard let parsed = Double(numberText) else { continue }

            found.append(CSSNumber(
                value: parsed,
                unit: String(characters[numberEnd..<index]),
                text: text,
                offset: start
            ))
        }
        return found
    }

    /// How much one step of a drag moves a value.
    ///
    /// Scaled by unit, because the useful step differs by two orders of
    /// magnitude between them: one pixel is a nudge, one `em` is a redesign.
    public static func step(for unit: String, coarse: Bool = false, fine: Bool = false) -> Double {
        let base: Double = switch unit.lowercased() {
        case "": 0.1
        case "px", "%", "deg", "ms": 1
        case "em", "rem", "ch", "ex": 0.1
        case "s": 0.1
        case "vw", "vh", "vmin", "vmax": 0.5
        default: 1
        }
        if coarse { return base * 10 }
        if fine { return base / 10 }
        return base
    }

    /// The number after a drag, written the way the original was.
    public static func adjusted(_ number: CSSNumber, by steps: Double, unit step: Double) -> String {
        let raw = number.value + steps * step
        // Rounded to the step's own precision, or a drag accumulates a tail of
        // floating-point noise that ends up in the diff.
        let decimals = max(0, Int(ceil(-log10(step))))
        let rounded = (raw * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))

        let text: String
        if number.wasInteger, rounded == rounded.rounded() {
            text = String(Int(rounded))
        } else if rounded == rounded.rounded(), decimals == 0 {
            text = String(Int(rounded))
        } else {
            text = String(format: "%.\(decimals)f", rounded)
        }
        return text + number.unit
    }

    /// Replaces one number in a value, leaving the rest exactly as written.
    public static func replacing(
        _ value: String, number: CSSNumber, with replacement: String
    ) -> String {
        let characters = Array(value)
        guard number.offset >= 0, number.offset + number.text.count <= characters.count
        else { return value }
        let head = String(characters[0..<number.offset])
        let tail = String(characters[(number.offset + number.text.count)...])
        return head + replacement + tail
    }
}

/// The keyword sets worth offering as a menu.
///
/// Not a complete CSS dictionary — only the properties where the value is one
/// of a short, closed list and typing it is pure recall. `display` and
/// `position` are the ones people reach for constantly and misspell about as
/// often.
public enum CSSKeywords {

    private static let table: [String: [String]] = [
        "display": [
            "block", "inline", "inline-block", "flex", "inline-flex", "grid",
            "inline-grid", "flow-root", "contents", "table", "list-item", "none",
        ],
        "position": ["static", "relative", "absolute", "fixed", "sticky"],
        "flex-direction": ["row", "row-reverse", "column", "column-reverse"],
        "flex-wrap": ["nowrap", "wrap", "wrap-reverse"],
        "justify-content": [
            "flex-start", "flex-end", "center", "space-between",
            "space-around", "space-evenly", "start", "end",
        ],
        "align-items": ["stretch", "flex-start", "flex-end", "center", "baseline", "start", "end"],
        "align-self": ["auto", "stretch", "flex-start", "flex-end", "center", "baseline"],
        "text-align": ["left", "right", "center", "justify", "start", "end"],
        "text-transform": ["none", "capitalize", "uppercase", "lowercase"],
        "font-style": ["normal", "italic", "oblique"],
        "font-weight": [
            "100", "200", "300", "400", "500", "600", "700", "800", "900",
            "normal", "bold", "lighter", "bolder",
        ],
        "white-space": ["normal", "nowrap", "pre", "pre-wrap", "pre-line", "break-spaces"],
        "overflow": ["visible", "hidden", "clip", "scroll", "auto"],
        "overflow-x": ["visible", "hidden", "clip", "scroll", "auto"],
        "overflow-y": ["visible", "hidden", "clip", "scroll", "auto"],
        "visibility": ["visible", "hidden", "collapse"],
        "box-sizing": ["content-box", "border-box"],
        "cursor": [
            "auto", "default", "pointer", "text", "move", "not-allowed",
            "grab", "grabbing", "crosshair", "wait", "help",
        ],
        "text-decoration-line": ["none", "underline", "overline", "line-through"],
        "border-style": [
            "none", "hidden", "solid", "dashed", "dotted", "double", "groove", "ridge",
        ],
        "pointer-events": ["auto", "none"],
        "object-fit": ["fill", "contain", "cover", "none", "scale-down"],
        "text-wrap": ["wrap", "nowrap", "balance", "pretty", "stable"],
        "flex-grow": [], "flex-shrink": [],
    ]

    public static func options(for property: String) -> [String] {
        table[property.lowercased()] ?? []
    }

    /// Whether a value is a bare keyword this can offer a menu for — as opposed
    /// to a compound value like `1px solid red`, where a menu would replace
    /// far more than the part being changed.
    public static func isSingleKeyword(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
