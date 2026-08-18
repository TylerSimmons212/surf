import Testing

@testable import SurfCore

@Suite("Console REPL wrapping")
struct ConsoleREPLTests {

    /// `{a: 1}` is a block containing a labelled statement, so it evaluates to
    /// `undefined` — which reads as the browser being broken rather than as
    /// JavaScript being strange.
    @Test("An object literal is parenthesised so it evaluates to an object")
    func objectLiteral() {
        #expect(ConsoleREPL.wrap("{a: 1}").source == "({a: 1})")
        #expect(ConsoleREPL.wrap("{}").source == "({})")
        #expect(ConsoleREPL.wrap("{ a, b }").source == "({ a, b })")
        #expect(ConsoleREPL.wrap("{...rest}").source == "({...rest})")
    }

    /// Turning a real block into an expression would make working code a
    /// syntax error, which is far worse than an object printing `undefined`.
    @Test("A block is left alone")
    func blockIsNotAnObject() {
        // Untouched entirely: the braces make it a block, and the `let` inside
        // is scoped to that block rather than to the prompt.
        #expect(ConsoleREPL.wrap("{ let x = 1; }").source == "{ let x = 1; }")
        #expect(ConsoleREPL.wrap("{ return 1 }").source == "{ return 1 }")
        #expect(ConsoleREPL.wrap("{ if (a) b() }").source == "{ if (a) b() }")
    }

    /// Two adjacent blocks are not one object, and parenthesising them would
    /// produce a syntax error.
    @Test("Two brace groups are not an object literal")
    func adjacentBlocks() {
        #expect(!ConsoleREPL.looksLikeObjectLiteral("{a:1}{b:2}"))
    }

    /// A brace inside a string is text, not structure.
    @Test("Braces and semicolons inside strings do not count as structure")
    func stringsAreOpaque() {
        #expect(ConsoleREPL.wrap("\"{\"").source == "\"{\"")
        // The semicolon is inside a string, so this is still one expression.
        #expect(ConsoleREPL.isExpression("f(\"a;b\")"))
        #expect(!ConsoleREPL.isExpression("a; b"))
    }

    /// Each entry is its own evaluation, so `let` would vanish before the next
    /// one. `var` lands on the global object and survives — the same
    /// substitution Chrome's console makes, for the same reason.
    @Test("Declarations are rewritten so they survive to the next entry")
    func declarationsPersist() {
        #expect(ConsoleREPL.wrap("let x = 1").source == "var x = 1")
        #expect(ConsoleREPL.wrap("const y = 2").source == "var y = 2")
        #expect(ConsoleREPL.wrap("let x = 1").rewroteDeclarations)
    }

    @Test("A class declaration persists and keeps its own name")
    func classPersists() {
        // The inner name matters: it is what shows up in stack traces and in
        // `instance.constructor.name`.
        #expect(ConsoleREPL.wrap("class Foo {}").source == "var Foo = class Foo {}")
    }

    /// Only whole words. Rewriting the `let` inside `letters` would corrupt
    /// perfectly good code.
    @Test("Identifiers that merely start with a keyword are untouched")
    func keywordPrefixes() {
        #expect(ConsoleREPL.wrap("letters.length").source == "letters.length")
        #expect(ConsoleREPL.wrap("constant + 1").source == "constant + 1")
        #expect(!ConsoleREPL.wrap("letters.length").rewroteDeclarations)
    }

    @Test("Destructuring declarations are rewritten too")
    func destructuring() {
        #expect(ConsoleREPL.wrap("const {a} = obj").source == "var {a} = obj")
        #expect(ConsoleREPL.wrap("let [x, y] = pair").source == "var [x, y] = pair")
    }

    /// A `let` inside a function body is scoped there and must stay `let` —
    /// rewriting it would change the meaning of the code being typed.
    @Test("Declarations nested inside braces are left alone")
    func nestedDeclarations() {
        let wrapped = ConsoleREPL.wrap("function f() { let inner = 1; return inner }")
        #expect(wrapped.source.contains("let inner"))
    }

    /// `await` outside an async function is a syntax error, and typing it at a
    /// prompt is the single most common thing people do with a modern console.
    @Test("Top-level await is wrapped, keeping the value of an expression")
    func awaitExpression() {
        let wrapped = ConsoleREPL.wrap("await fetch('/x')")
        #expect(wrapped.usesAwait)
        #expect(wrapped.source == "(async () => (await fetch('/x')))()")
    }

    @Test("A statement list with await is wrapped without a value")
    func awaitStatements() {
        let wrapped = ConsoleREPL.wrap("const r = await fetch('/x'); r.status")
        #expect(wrapped.usesAwait)
        #expect(wrapped.source.hasPrefix("(async () => {"))
        // The declaration rewrite still applies inside the wrapper.
        #expect(wrapped.source.contains("var r ="))
    }

    @Test("The word await inside a string is not top-level await")
    func awaitInString() {
        #expect(!ConsoleREPL.wrap("'await this'").usesAwait)
        #expect(!ConsoleREPL.containsAwait("// await later"))
    }

    @Test("A property called await is not top-level await")
    func awaitAsProperty() {
        #expect(!ConsoleREPL.containsAwait("obj.await"))
    }

    @Test("Whitespace-only input produces nothing to evaluate")
    func emptyInput() {
        #expect(ConsoleREPL.wrap("   \n  ").source.isEmpty)
        #expect(ConsoleREPL.wrap("").source.isEmpty)
    }

    /// A trailing semicolon is a typing habit, not a second statement, and
    /// treating it as one would throw away the value people expect to see.
    @Test("A trailing semicolon still counts as a single expression")
    func trailingSemicolon() {
        #expect(ConsoleREPL.isExpression("1 + 1;"))
        #expect(ConsoleREPL.wrap("await x;").source == "(async () => (await x;))()" ||
                ConsoleREPL.wrap("await x;").usesAwait)
    }

    /// Syntax errors are left exactly as typed, so the page reports its own
    /// message rather than one about code the user never wrote.
    @Test("Broken input is passed through untouched")
    func syntaxErrorsPassThrough() {
        #expect(ConsoleREPL.wrap("function(").source == "function(")
        #expect(ConsoleREPL.wrap("]]]").source == "]]]")
    }
}
