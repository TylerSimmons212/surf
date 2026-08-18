import Testing

@testable import SurfCore

@Suite("Console completion")
struct ConsoleCompletionTests {

    @Test("A dotted path completes against the object before the dot")
    func dottedPath() {
        let query = ConsoleCompletion.query(for: "document.body.chi")
        #expect(query?.base == "document.body")
        #expect(query?.prefix == "chi")
        #expect(query?.replacedLength == 3)
    }

    /// A trailing dot means "show me everything on this", which is how anyone
    /// explores an unfamiliar object.
    @Test("A trailing dot lists everything with no prefix")
    func trailingDot() {
        let query = ConsoleCompletion.query(for: "navigator.")
        #expect(query?.base == "navigator")
        #expect(query?.prefix == "")
    }

    /// The whole reason the base is restricted: resolving `save().x` means
    /// *calling* `save()`. A console that fires your functions while you type
    /// is worse than one that doesn't complete at all.
    @Test("A base that would have to be executed is refused")
    func refusesSideEffects() {
        #expect(ConsoleCompletion.query(for: "save().chi") == nil)
        #expect(ConsoleCompletion.query(for: "items[0].chi") == nil)
        #expect(ConsoleCompletion.query(for: "(a + b).chi") == nil)
    }

    @Test("A bare word completes against the globals")
    func bareWord() {
        let query = ConsoleCompletion.query(for: "docu")
        #expect(query?.base == "")
        #expect(query?.prefix == "docu")
    }

    /// Popping a list open on the first keystroke would fight the typing.
    @Test("A single character is not enough to suggest globals")
    func needsTwoCharacters() {
        #expect(ConsoleCompletion.query(for: "d") == nil)
        #expect(ConsoleCompletion.query(for: "do") != nil)
    }

    @Test("Nothing is suggested after whitespace or on empty input")
    func quietWhenIdle() {
        #expect(ConsoleCompletion.query(for: "") == nil)
        #expect(ConsoleCompletion.query(for: "document.body ") == nil)
    }

    /// `3.14` is a number, not a property access on `3`.
    @Test("A decimal number is not a property access")
    func numbersAreNotPaths() {
        #expect(ConsoleCompletion.query(for: "3.14") == nil)
        #expect(ConsoleCompletion.query(for: "42") == nil)
    }

    @Test("Only the partial name is replaced, not the whole line")
    func applyReplacesTheNameOnly() {
        let input = "document.body.chi"
        let query = ConsoleCompletion.query(for: input)!
        #expect(ConsoleCompletion.apply("children", to: input, query: query)
                == "document.body.children")
    }

    @Test("Accepting from a bare word keeps what came before it")
    func applyKeepsPrefixText() {
        let input = "const a = docu"
        let query = ConsoleCompletion.query(for: input)!
        #expect(ConsoleCompletion.apply("document", to: input, query: query)
                == "const a = document")
    }

    /// Typing `add` should reach `addEventListener` immediately, not after
    /// scrolling past every longer name that also matches.
    @Test("Shorter and exactly-cased matches rank first")
    func ranking() {
        let ranked = ConsoleCompletion.rank(
            ["addEventListenerOnce", "AddSomething", "addEventListener", "add"],
            matching: "add"
        )
        #expect(ranked == ["add", "addEventListener", "addEventListenerOnce", "AddSomething"])
    }

    @Test("Non-matching names are dropped")
    func rankingFilters() {
        #expect(ConsoleCompletion.rank(["alpha", "beta"], matching: "al") == ["alpha"])
    }

    /// `__proto__` and friends are real, but never what someone is reaching
    /// for, so they sort to the bottom rather than the top.
    @Test("Underscore-prefixed names sort last")
    func internalNamesSortLast() {
        let ranked = ConsoleCompletion.rank(["__proto__", "id", "className"], matching: "")
        #expect(ranked.last == "__proto__")
    }

    @Test("Safe paths are identifiers and dots, nothing else")
    func safePaths() {
        #expect(ConsoleCompletion.isSafePath("document.body"))
        #expect(ConsoleCompletion.isSafePath("$el"))
        #expect(!ConsoleCompletion.isSafePath("a()"))
        #expect(!ConsoleCompletion.isSafePath("a["))
        #expect(!ConsoleCompletion.isSafePath("a..b"))
        #expect(!ConsoleCompletion.isSafePath(""))
    }
}
