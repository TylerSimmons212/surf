import Testing

@testable import SurfCore

@Suite("Attribute text")
struct DOMAttributeTextTests {
    typealias Attribute = DOMAttributeText.Attribute

    // MARK: - Round trip

    @Test("Serialize then parse returns what went in")
    func roundTrip() {
        let attributes = [
            Attribute(name: "class", value: "card wide"),
            Attribute(name: "id", value: "hero"),
            Attribute(name: "hidden", value: ""),
            Attribute(name: "title", value: "it's here"),
        ]
        let text = DOMAttributeText.serialize(attributes)
        #expect(DOMAttributeText.parse(text) == attributes)
    }

    @Test("A value with double quotes serializes in single quotes")
    func quoteChoice() {
        let attributes = [Attribute(name: "data-x", value: "say \"hi\"")]
        let text = DOMAttributeText.serialize(attributes)
        #expect(text == "data-x='say \"hi\"'")
        #expect(DOMAttributeText.parse(text) == attributes)
    }

    @Test("A value with both quote kinds still round-trips")
    func bothQuotes() {
        let attributes = [Attribute(name: "t", value: "it's \"x\"")]
        let text = DOMAttributeText.serialize(attributes)
        #expect(DOMAttributeText.parse(text) == attributes)
    }

    // MARK: - Parse

    @Test("Boolean, unquoted and quoted forms all parse")
    func forms() {
        let parsed = DOMAttributeText.parse("hidden class=card id=\"a\" x='b'")
        #expect(parsed == [
            Attribute(name: "hidden", value: ""),
            Attribute(name: "class", value: "card"),
            Attribute(name: "id", value: "a"),
            Attribute(name: "x", value: "b"),
        ])
    }

    @Test("Empty text is an empty list, not a failure")
    func emptyText() {
        #expect(DOMAttributeText.parse("") == [])
        #expect(DOMAttributeText.parse("   ") == [])
    }

    @Test("An unclosed quote refuses rather than guesses")
    func unclosedQuote() {
        #expect(DOMAttributeText.parse("class=\"card") == nil)
    }

    @Test("A trailing equals refuses rather than guesses")
    func trailingEquals() {
        #expect(DOMAttributeText.parse("class=") == nil)
    }

    @Test("A duplicated name keeps the last value, as HTML parsing does not")
    func duplicates() {
        // HTML keeps the first; an *editor* keeps the last, because the last
        // is the one the person just typed.
        let parsed = DOMAttributeText.parse("id=a id=b")
        #expect(parsed == [Attribute(name: "id", value: "b")])
    }

    // MARK: - Diff

    @Test("Only what changed is written")
    func minimalDiff() {
        let old = [Attribute(name: "class", value: "a"), Attribute(name: "id", value: "x")]
        let new = [Attribute(name: "class", value: "b"), Attribute(name: "id", value: "x")]
        #expect(DOMAttributeText.diff(old: old, new: new) == [.set(name: "class", value: "b")])
    }

    @Test("A missing attribute becomes a removal")
    func removal() {
        let old = [Attribute(name: "class", value: "a"), Attribute(name: "id", value: "x")]
        let new = [Attribute(name: "class", value: "a")]
        #expect(DOMAttributeText.diff(old: old, new: new) == [.remove(name: "id")])
    }

    @Test("A new attribute becomes a set")
    func addition() {
        let old = [Attribute(name: "class", value: "a")]
        let new = [Attribute(name: "class", value: "a"), Attribute(name: "role", value: "note")]
        #expect(DOMAttributeText.diff(old: old, new: new) == [.set(name: "role", value: "note")])
    }

    @Test("Identical lists change nothing")
    func noChanges() {
        let attributes = [Attribute(name: "class", value: "a")]
        #expect(DOMAttributeText.diff(old: attributes, new: attributes).isEmpty)
    }
}
