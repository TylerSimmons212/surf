import Foundation

/// Works out what to complete as someone types at the console prompt.
///
/// The hard part isn't matching names, it's deciding what to *ask about*
/// without causing side effects. `document.body.chi` should list the
/// properties of `document.body`, but `save().chi` must not — resolving that
/// base means calling `save()`, and a console that silently fires your
/// functions while you type is worse than one with no completion at all.
///
/// So the base is only offered when it is a plain dotted path: identifiers and
/// dots, nothing else. Anything with a call, an index or an operator in it
/// falls back to no suggestions.
public enum ConsoleCompletion {

    public struct Query: Equatable, Sendable {
        /// The expression whose properties to list. Empty means the globals.
        public var base: String
        /// What has been typed of the name so far. May be empty when the input
        /// ends in a dot, which should list everything.
        public var prefix: String
        /// How many characters at the end of the input a chosen name replaces.
        public var replacedLength: Int

        public init(base: String, prefix: String, replacedLength: Int) {
            self.base = base
            self.prefix = prefix
            self.replacedLength = replacedLength
        }
    }

    /// Nil when there is nothing sensible to complete.
    public static func query(for input: String) -> Query? {
        // Trailing whitespace means the word is finished; suggesting into it
        // would fight the typing rather than help it.
        guard !input.isEmpty, input.last?.isWhitespace != true else { return nil }

        let characters = Array(input)
        var index = characters.count

        // The partial name being typed.
        var prefixStart = index
        while prefixStart > 0, isIdentifier(characters[prefixStart - 1]) {
            prefixStart -= 1
        }
        let prefix = String(characters[prefixStart..<index])
        index = prefixStart

        // No dot before it: this is a bare name, so complete against globals.
        guard index > 0, characters[index - 1] == "." else {
            guard prefix.count >= 2 else { return nil }
            // A number like `3.14` is not a property access, and `3` is not an
            // identifier worth completing.
            guard let first = prefix.first, !first.isNumber else { return nil }
            return Query(base: "", prefix: prefix, replacedLength: prefix.count)
        }
        index -= 1

        // Walk back over the dotted path.
        var baseEnd = index
        while index > 0 {
            let char = characters[index - 1]
            if isIdentifier(char) || char == "." {
                index -= 1
                continue
            }
            break
        }
        let base = String(characters[index..<baseEnd]).trimmingCharacters(in: .whitespaces)
        baseEnd = index

        guard isSafePath(base) else { return nil }
        // A dot immediately after something that isn't a plain path — `f().x` —
        // has already been rejected above, but an empty base means the input
        // began with a dot, which is nothing to resolve.
        guard !base.isEmpty else { return nil }

        return Query(base: base, prefix: prefix, replacedLength: prefix.count)
    }

    /// Replaces the partial name with the chosen one.
    public static func apply(_ name: String, to input: String, query: Query) -> String {
        let keep = max(0, input.count - query.replacedLength)
        return String(input.prefix(keep)) + name
    }

    /// Ranks matches so the useful ones come first.
    ///
    /// A prefix match beats a case-insensitive one, and a shorter name beats a
    /// longer one — typing `add` should offer `addEventListener` before
    /// `addEventListenerOnce`, and never bury an exact match.
    public static func rank(_ names: [String], matching prefix: String) -> [String] {
        guard !prefix.isEmpty else {
            return names.sorted { sortKey($0) < sortKey($1) }
        }
        let lowered = prefix.lowercased()

        return names
            .filter { $0.lowercased().hasPrefix(lowered) }
            .sorted { a, b in
                let exactA = a.hasPrefix(prefix)
                let exactB = b.hasPrefix(prefix)
                if exactA != exactB { return exactA }
                if a.count != b.count { return a.count < b.count }
                return sortKey(a) < sortKey(b)
            }
    }

    /// Internal and inherited names sort last: `__proto__` is real, but it is
    /// never what someone is reaching for.
    private static func sortKey(_ name: String) -> String {
        (name.hasPrefix("_") ? "\u{10FFFF}" : "") + name.lowercased()
    }

    private static func isIdentifier(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "$"
    }

    /// Identifiers and dots only. No calls, no indexing, no operators — the
    /// whole point is that resolving this can't run anything.
    static func isSafePath(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard !text.hasSuffix("."), !text.hasPrefix(".") else { return false }
        guard !text.contains("..") else { return false }
        guard text.allSatisfy({ isIdentifier($0) || $0 == "." }) else { return false }
        // Every segment has to be a legal identifier. Without this, `3.14`
        // parses as the property `14` of the object `3` — a number mistaken
        // for a property access.
        return text.split(separator: ".").allSatisfy { segment in
            guard let first = segment.first else { return false }
            return first.isLetter || first == "_" || first == "$"
        }
    }
}
