import Testing

@testable import SurfCore

@Suite("Selector suggestion")
struct CSSSelectorSuggestionTests {

    @Test("Most specific first: id, full compound, first class, tag")
    func ordering() {
        let candidates = CSSSelectorSuggestion.candidates(
            tag: "DIV", id: "hero", classes: ["card", "wide"]
        )
        #expect(candidates == ["#hero", "div.card.wide", ".card", "div"])
    }

    @Test("No id and no classes leaves just the tag")
    func bareElement() {
        #expect(CSSSelectorSuggestion.candidates(tag: "p", id: nil, classes: []) == ["p"])
    }

    @Test("One class produces no duplicate compound")
    func singleClass() {
        let candidates = CSSSelectorSuggestion.candidates(
            tag: "a", id: nil, classes: ["mw-redirect"]
        )
        #expect(candidates == ["a.mw-redirect", ".mw-redirect", "a"])
    }

    @Test("Empty and whitespace classes are dropped")
    func junkClasses() {
        let candidates = CSSSelectorSuggestion.candidates(
            tag: "span", id: nil, classes: ["", "  ", "ok"]
        )
        #expect(candidates == ["span.ok", ".ok", "span"])
    }

    @Test("Characters CSS treats as syntax get escaped")
    func escaping() {
        #expect(CSSSelectorSuggestion.escape("a:b") == "a\\:b")
        #expect(CSSSelectorSuggestion.escape("w-1/2") == "w-1\\/2")
        #expect(CSSSelectorSuggestion.escape("plain-name_9") == "plain-name_9")
    }

    @Test("A leading digit is hex-escaped, as CSS.escape does")
    func leadingDigit() {
        #expect(CSSSelectorSuggestion.escape("2col") == "\\32 col")
    }

    @Test("A Tailwind-style class survives into a valid selector")
    func tailwind() {
        let candidates = CSSSelectorSuggestion.candidates(
            tag: "div", id: nil, classes: ["md:flex", "w-1/2"]
        )
        #expect(candidates.first == "div.md\\:flex.w-1\\/2")
    }
}
