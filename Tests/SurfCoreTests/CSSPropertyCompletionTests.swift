import Testing

@testable import SurfCore

@Suite("CSS property completion")
struct CSSPropertyCompletionTests {

    private let names = [
        "color", "margin", "margin-top", "margin-inline-start", "max-width",
        "grid-template-areas", "background-color", "-webkit-line-clamp",
        "-webkit-mask", "mask", "font-size", "font-family",
    ]

    @Test("A prefix match beats a substring match")
    func prefixBeatsSubstring() {
        let matches = CSSPropertyCompletion.matches("mar", in: names)
        // grid-template-areas contains "ar" but must trail every margin-*.
        #expect(matches.first == "margin")
        #expect(matches.contains("margin-top"))
    }

    @Test("The shorthand outranks its own longhands")
    func shortFirst() {
        let matches = CSSPropertyCompletion.matches("margin", in: names)
        #expect(matches == ["margin-top", "margin-inline-start"])
    }

    @Test("Typing the full name offers the longhands, not an echo")
    func noEcho() {
        let matches = CSSPropertyCompletion.matches("color", in: names)
        #expect(!matches.contains("color"))
        #expect(matches.contains("background-color"))
    }

    @Test("Prefixed properties sink unless the dash was typed")
    func prefixedSink() {
        // "k" lands mask, background-color and both -webkit-* in one
        // substring band — the only place the dash rule can actually bite.
        let plain = CSSPropertyCompletion.matches("k", in: names)
        #expect(plain.first == "mask")
        let webkit = plain.firstIndex { $0.hasPrefix("-webkit") }
        let background = plain.firstIndex(of: "background-color")
        if let webkit, let background { #expect(background < webkit) }

        let dashed = CSSPropertyCompletion.matches("-web", in: names)
        #expect(dashed.first?.hasPrefix("-webkit") == true)
    }

    @Test("Empty and whitespace input complete to nothing")
    func emptyInput() {
        #expect(CSSPropertyCompletion.matches("", in: names).isEmpty)
        #expect(CSSPropertyCompletion.matches("   ", in: names).isEmpty)
    }

    @Test("The limit is honoured")
    func limited() {
        let matches = CSSPropertyCompletion.matches("m", in: names, limit: 3)
        #expect(matches.count == 3)
    }

    @Test("Case never matters")
    func caseInsensitive() {
        #expect(CSSPropertyCompletion.matches("MAR", in: names).first == "margin")
    }
}
