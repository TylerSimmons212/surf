import Foundation

/// Turns what someone typed into the console into something worth evaluating.
///
/// A console prompt is not a `<script>` tag, and pretending otherwise produces
/// three surprises that every REPL has to solve:
///
/// - `{a: 1}` is a *block* containing a labelled statement, not an object. It
///   evaluates to `undefined`, which looks like a bug in the browser rather
///   than in JavaScript.
/// - `let x = 1` in one entry leaves `x` undefined in the next, because each
///   evaluation is its own scope.
/// - `await fetch(…)` is a syntax error outside an async function.
///
/// All three are fixed by rewriting the source before it runs, which is pure
/// text work and therefore lives here rather than in the page.
public enum ConsoleREPL {

    public struct Wrapped: Equatable, Sendable {
        /// What to hand the page. Empty for input that is only whitespace.
        public var source: String
        /// Whether the result needs awaiting before it can be described.
        public var usesAwait: Bool
        /// Whether a `let`/`const`/`class` was rewritten so it survives to the
        /// next entry. Surfaced so the UI could mention it; mostly diagnostic.
        public var rewroteDeclarations: Bool

        public init(source: String, usesAwait: Bool = false, rewroteDeclarations: Bool = false) {
            self.source = source
            self.usesAwait = usesAwait
            self.rewroteDeclarations = rewroteDeclarations
        }
    }

    public static func wrap(_ input: String) -> Wrapped {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Wrapped(source: "") }

        // An object literal has to be parenthesised before anything else looks
        // at it, and once it is, it's an expression and nothing else applies.
        if looksLikeObjectLiteral(trimmed) {
            let source = "(\(trimmed))"
            return Wrapped(source: source, usesAwait: containsAwait(trimmed))
        }

        let rewritten = persistingDeclarations(in: trimmed)
        let needsAwait = containsAwait(trimmed)

        guard needsAwait else {
            return Wrapped(
                source: rewritten.source,
                rewroteDeclarations: rewritten.changed
            )
        }

        // `await` is only legal inside an async function, so the whole entry
        // moves into one. An expression keeps its value through an arrow's
        // implicit return; a statement list has no single value to keep.
        let source = isExpression(trimmed)
            ? "(async () => (\(rewritten.source)))()"
            : "(async () => { \(rewritten.source) })()"

        return Wrapped(source: source, usesAwait: true, rewroteDeclarations: rewritten.changed)
    }

    // MARK: - Object literals

    /// `{}` and `{a: 1}` are objects; `{ let x = 1; }` is a block.
    ///
    /// Deliberately conservative — treating a real block as an object would
    /// turn working code into a syntax error, which is far worse than leaving
    /// an object literal printing `undefined`.
    static func looksLikeObjectLiteral(_ text: String) -> Bool {
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return false }
        // The braces have to be one pair wrapping the whole thing, or this is
        // two blocks and parenthesising it is nonsense.
        guard isSingleBalancedGroup(text) else { return false }

        let inner = String(text.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty { return true }

        // A statement keyword means it's a block, whatever else it contains.
        for keyword in ["var ", "let ", "const ", "return", "if ", "if(", "for ", "for(",
                        "while ", "while(", "throw ", "function", "class "] where inner.hasPrefix(keyword) {
            return false
        }
        // A key/value separator at the top level is the giveaway. `{ ...spread }`
        // and shorthand `{ a, b }` count too.
        return scan(inner) { char, depth, _ in
            depth == 0 && (char == ":" || char == ",")
        } || inner.hasPrefix("...")
    }

    private static func isSingleBalancedGroup(_ text: String) -> Bool {
        var depth = 0
        var closedEarly = false
        _ = scan(text) { char, _, isLast in
            if char == "{" || char == "(" || char == "[" { depth += 1 }
            if char == "}" || char == ")" || char == "]" {
                depth -= 1
                if depth == 0 && !isLast { closedEarly = true }
            }
            return false
        }
        return !closedEarly
    }

    // MARK: - Persistence

    /// Rewrites top-level `let`/`const`/`class` to `var`.
    ///
    /// The page evaluates each entry with an indirect `eval`, which runs in
    /// global scope — so `var` lands on the global object and is still there
    /// next time, while `let` and `const` are scoped to the evaluation and
    /// vanish with it. Chrome's console makes the same substitution, and for
    /// the same reason: at a prompt, redeclaring a name is normal rather than
    /// an error worth enforcing.
    static func persistingDeclarations(in text: String) -> (source: String, changed: Bool) {
        var result = ""
        var changed = false
        var index = text.startIndex
        var atStatementStart = true
        var depth = 0
        var state = ScanState()

        while index < text.endIndex {
            let char = text[index]

            if state.consume(char) {
                result.append(char)
                index = text.index(after: index)
                continue
            }

            if char == "{" || char == "(" || char == "[" { depth += 1 }
            if char == "}" || char == ")" || char == "]" { depth -= 1 }

            if atStatementStart, depth == 0 {
                if let replaced = declarationRewrite(in: text, from: index) {
                    result += replaced.text
                    index = replaced.next
                    changed = true
                    atStatementStart = false
                    continue
                }
            }

            if !char.isWhitespace {
                atStatementStart = (char == ";" || char == "{" || char == "}")
            }
            result.append(char)
            index = text.index(after: index)
        }

        return (result, changed)
    }

    private static func declarationRewrite(
        in text: String,
        from index: String.Index
    ) -> (text: String, next: String.Index)? {
        for keyword in ["let", "const"] {
            if let next = match(keyword, in: text, at: index) {
                return ("var", next)
            }
        }
        // `class Foo {}` becomes `var Foo = class Foo {}`, which both persists
        // and keeps the class's own name intact for stack traces.
        if let afterClass = match("class", in: text, at: index) {
            var cursor = afterClass
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            var name = ""
            while cursor < text.endIndex,
                  text[cursor].isLetter || text[cursor].isNumber
                    || text[cursor] == "_" || text[cursor] == "$" {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard !name.isEmpty else { return nil }
            return ("var \(name) = class \(name)", cursor)
        }
        return nil
    }

    /// Matches a whole word, so `letter` is not a `let`.
    private static func match(
        _ keyword: String,
        in text: String,
        at index: String.Index
    ) -> String.Index? {
        var cursor = index
        for character in keyword {
            guard cursor < text.endIndex, text[cursor] == character else { return nil }
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }
        let next = text[cursor]
        guard next.isWhitespace || next == "[" || next == "{" else { return nil }
        return cursor
    }

    // MARK: - Shape

    /// Whether the whole entry is one expression, and so has a value worth
    /// returning from an async wrapper.
    static func isExpression(_ text: String) -> Bool {
        let statementKeywords = [
            "var", "let", "const", "if", "for", "while", "do", "switch",
            "try", "throw", "return", "function", "class", "debugger",
        ]
        for keyword in statementKeywords where match(keyword, in: text, at: text.startIndex) != nil {
            return false
        }
        // A top-level semicolon means more than one statement — except a
        // trailing one, which people type out of habit.
        let body = text.hasSuffix(";") ? String(text.dropLast()) : text
        return !scan(body) { char, depth, _ in depth == 0 && char == ";" }
    }

    static func containsAwait(_ text: String) -> Bool {
        var found = false
        var index = text.startIndex
        var state = ScanState()

        while index < text.endIndex {
            let char = text[index]
            if state.consume(char) {
                index = text.index(after: index)
                continue
            }
            if char == "a", match("await", in: text, at: index) != nil {
                // Not `x.await` or `obj.await()`, which are property names.
                let isProperty = index > text.startIndex
                    && text[text.index(before: index)] == "."
                if !isProperty { found = true; break }
            }
            index = text.index(after: index)
        }
        return found
    }

    // MARK: - Scanning

    /// Tracks strings, template literals and comments so a brace inside `"{"`
    /// never counts as structure.
    struct ScanState {
        private var inSingle = false
        private var inDouble = false
        private var inTemplate = false
        private var inLineComment = false
        private var inBlockComment = false
        private var escaped = false
        private var previous: Character?

        /// Returns true when the character is inside a string or comment and
        /// should be skipped by structural logic.
        mutating func consume(_ char: Character) -> Bool {
            defer { previous = char }

            if escaped { escaped = false; return true }
            if inSingle || inDouble || inTemplate {
                if char == "\\" { escaped = true; return true }
                if inSingle && char == "'" { inSingle = false; return true }
                if inDouble && char == "\"" { inDouble = false; return true }
                if inTemplate && char == "`" { inTemplate = false; return true }
                return true
            }
            if inLineComment {
                if char == "\n" { inLineComment = false }
                return true
            }
            if inBlockComment {
                if char == "/" && previous == "*" { inBlockComment = false }
                return true
            }
            if char == "'" { inSingle = true; return true }
            if char == "\"" { inDouble = true; return true }
            if char == "`" { inTemplate = true; return true }
            if char == "/" && previous == "/" { inLineComment = true; return true }
            if char == "*" && previous == "/" { inBlockComment = true; return true }
            return false
        }
    }

    /// Walks the text outside strings and comments, tracking bracket depth.
    /// Stops and returns true the first time `predicate` does.
    @discardableResult
    private static func scan(
        _ text: String,
        _ predicate: (Character, Int, Bool) -> Bool
    ) -> Bool {
        var depth = 0
        var state = ScanState()
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            let isLast = next == text.endIndex

            if state.consume(char) {
                index = next
                continue
            }
            if predicate(char, depth, isLast) { return true }
            if char == "{" || char == "(" || char == "[" { depth += 1 }
            if char == "}" || char == ")" || char == "]" { depth -= 1 }
            index = next
        }
        return false
    }
}
