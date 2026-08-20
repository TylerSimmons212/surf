import Foundation

/// The text form of an element's attributes — `class="card" id="hero"` — and
/// the machinery to round-trip it.
///
/// This is the editing surface for the Elements tree: the row swaps its
/// markup for one editable line of attributes, and what comes back has to be
/// parsed, diffed against what the element had, and turned into the smallest
/// set of set/remove operations. Parse and diff are pure and live here so
/// their edge cases — quotes, boolean attributes, a value containing the
/// other quote — are tests rather than bug reports.
public enum DOMAttributeText {

    public struct Attribute: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    // MARK: - Serialize

    /// One line of `name="value"` pairs, quoting with whichever quote the
    /// value doesn't contain. A value containing both gets double quotes
    /// with the doubles escaped — rare enough to be correct rather than
    /// pretty.
    public static func serialize(_ attributes: [Attribute]) -> String {
        attributes.map { attribute in
            let value = attribute.value
            if value.isEmpty { return attribute.name }
            if !value.contains("\"") { return "\(attribute.name)=\"\(value)\"" }
            if !value.contains("'") { return "\(attribute.name)='\(value)'" }
            let escaped = value.replacingOccurrences(of: "\"", with: "&quot;")
            return "\(attribute.name)=\"\(escaped)\""
        }
        .joined(separator: " ")
    }

    // MARK: - Parse

    /// `nil` means the text isn't a valid attribute list — an unclosed quote,
    /// a stray `=` — and the edit should be refused rather than guessed at.
    public static func parse(_ text: String) -> [Attribute]? {
        var out: [Attribute] = []
        var index = text.startIndex

        func skipSpace() {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }

        skipSpace()
        while index < text.endIndex {
            // Name: up to whitespace, `=`, or end.
            var name = ""
            while index < text.endIndex, !text[index].isWhitespace, text[index] != "=" {
                name.append(text[index])
                index = text.index(after: index)
            }
            guard !name.isEmpty else { return nil }
            skipSpace()

            // Bare name: a boolean attribute.
            guard index < text.endIndex, text[index] == "=" else {
                out.append(Attribute(name: name, value: ""))
                continue
            }
            index = text.index(after: index)  // consume =
            skipSpace()
            guard index < text.endIndex else { return nil }  // trailing =

            var value = ""
            let first = text[index]
            if first == "\"" || first == "'" {
                index = text.index(after: index)
                var closed = false
                while index < text.endIndex {
                    let ch = text[index]
                    index = text.index(after: index)
                    if ch == first { closed = true; break }
                    value.append(ch)
                }
                guard closed else { return nil }  // unclosed quote
                if first == "\"" {
                    value = value.replacingOccurrences(of: "&quot;", with: "\"")
                }
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            out.append(Attribute(name: name, value: value))
            skipSpace()
        }

        // Later occurrences win, as they do when a browser parses real HTML.
        var seen = Set<String>()
        return out.reversed().filter { seen.insert($0.name).inserted }.reversed()
    }

    // MARK: - Diff

    public enum Change: Sendable, Equatable {
        case set(name: String, value: String)
        case remove(name: String)
    }

    /// The smallest set of operations turning `old` into `new`.
    ///
    /// Smallest matters beyond tidiness: every set fires a mutation the
    /// panel's own observer reports back, so writing unchanged attributes
    /// would echo a storm of non-changes through the tree.
    public static func diff(old: [Attribute], new: [Attribute]) -> [Change] {
        let before = Dictionary(old.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        var changes: [Change] = []
        var kept = Set<String>()
        for attribute in new {
            kept.insert(attribute.name)
            if before[attribute.name] != attribute.value {
                changes.append(.set(name: attribute.name, value: attribute.value))
            }
        }
        for attribute in old where !kept.contains(attribute.name) {
            changes.append(.remove(name: attribute.name))
        }
        return changes
    }
}
