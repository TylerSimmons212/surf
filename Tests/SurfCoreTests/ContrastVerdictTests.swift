import Testing

@testable import SurfCore

@Suite("Contrast verdict")
struct ContrastVerdictTests {

    private let black = SRGB(r: 0, g: 0, b: 0)
    private let white = SRGB(r: 1, g: 1, b: 1)
    private let midGrey = SRGB(r: 0.55, g: 0.55, b: 0.55)

    @Test("Black on white passes everything")
    func blackOnWhite() {
        let verdict = ContrastVerdict(
            foreground: black, background: white, fontSizePx: 16, isBold: false
        )
        #expect(verdict.ratio > 20)
        #expect(verdict.passesAA)
        #expect(verdict.passesAAA)
        #expect(verdict.suggestion == nil)
    }

    @Test("Mid grey on white fails normal text but passes large")
    func sizeMatters() {
        let small = ContrastVerdict(
            foreground: midGrey, background: white, fontSizePx: 14, isBold: false
        )
        let large = ContrastVerdict(
            foreground: midGrey, background: white, fontSizePx: 28, isBold: false
        )
        #expect(!small.passesAA)
        #expect(large.passesAA)
    }

    @Test("The bold clause: 19px bold is large, 19px regular is not")
    func boldClause() {
        let bold = ContrastVerdict(
            foreground: midGrey, background: white, fontSizePx: 19, isBold: true
        )
        let regular = ContrastVerdict(
            foreground: midGrey, background: white, fontSizePx: 19, isBold: false
        )
        #expect(bold.isLargeText)
        #expect(!regular.isLargeText)
    }

    @Test("A failing pair gets a suggestion, and the suggestion passes")
    func suggestionPasses() {
        let verdict = ContrastVerdict(
            foreground: midGrey, background: white, fontSizePx: 14, isBold: false
        )
        #expect(verdict.suggestion != nil)
        if let fixed = verdict.suggestion {
            #expect(Contrast.ratio(fixed, white) >= 4.5)
        }
    }

    @Test("Weight parsing: numbers and keywords")
    func weights() {
        #expect(ContrastVerdict.isBoldWeight("700"))
        #expect(ContrastVerdict.isBoldWeight("800"))
        #expect(!ContrastVerdict.isBoldWeight("400"))
        #expect(ContrastVerdict.isBoldWeight("bold"))
        #expect(!ContrastVerdict.isBoldWeight("normal"))
    }

    @Test("cssText writes bytes the engine reads back")
    func cssText() {
        #expect(SRGB(r: 1, g: 0.5, b: 0).cssText == "rgb(255 128 0)")
        #expect(SRGB(r: 0, g: 0, b: 0).cssText == "rgb(0 0 0)")
    }
}
