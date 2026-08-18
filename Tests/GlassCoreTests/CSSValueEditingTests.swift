import Testing

@testable import GlassCore

@Suite("Scrubbing CSS numbers")
struct CSSValueScrubTests {

    @Test("A number and its unit are read together")
    func parsing() {
        let numbers = CSSValueScrub.numbers(in: "12px")
        #expect(numbers.count == 1)
        #expect(numbers[0].value == 12)
        #expect(numbers[0].unit == "px")
        #expect(numbers[0].wasInteger)
    }

    /// `margin: 8px 16px` has two, and grabbing one must not disturb the other
    /// — the same reason a colour swatch belongs to its token.
    @Test("Every number in a compound value is found separately")
    func multiple() {
        let numbers = CSSValueScrub.numbers(in: "8px 16px 4px 0")
        #expect(numbers.map(\.value) == [8, 16, 4, 0])
        #expect(numbers.map(\.unit) == ["px", "px", "px", ""])
        #expect(numbers.map(\.offset) == [0, 4, 9, 13])
    }

    @Test("Decimals, negatives and percentages all read correctly")
    func shapes() {
        #expect(CSSValueScrub.numbers(in: "1.5rem")[0].value == 1.5)
        #expect(CSSValueScrub.numbers(in: "-4px")[0].value == -4)
        #expect(CSSValueScrub.numbers(in: "50%")[0].unit == "%")
        #expect(!CSSValueScrub.numbers(in: "1.5rem")[0].wasInteger)
    }

    /// The digits in a colour are not a quantity, and scrubbing one would turn
    /// `#ff0000` into something that isn't a colour at all.
    @Test("Hex colours are not mistaken for numbers")
    func hexIsNotANumber() {
        #expect(CSSValueScrub.numbers(in: "#ff0000").isEmpty)
        #expect(CSSValueScrub.numbers(in: "2px solid #00aaff").map(\.value) == [2])
    }

    /// The `2` in `h2` is part of a name, not a length.
    @Test("Digits inside an identifier are left alone")
    func identifiersAreNotNumbers() {
        #expect(CSSValueScrub.numbers(in: "translateX").isEmpty)
        #expect(CSSValueScrub.numbers(in: "var(--space-2)").isEmpty)
    }

    @Test("Numbers inside a function are still scrubbable")
    func insideFunctions() {
        let numbers = CSSValueScrub.numbers(in: "translateY(12px)")
        #expect(numbers.map(\.value) == [12])
    }

    // MARK: - Stepping

    /// One pixel is a nudge and one em is a redesign, so a drag can't move both
    /// by the same amount and feel right for either.
    @Test("The step suits the unit")
    func steps() {
        #expect(CSSValueScrub.step(for: "px") == 1)
        #expect(CSSValueScrub.step(for: "rem") == 0.1)
        #expect(CSSValueScrub.step(for: "") == 0.1)
        #expect(CSSValueScrub.step(for: "px", coarse: true) == 10)
        #expect(CSSValueScrub.step(for: "px", fine: true) == 0.1)
    }

    @Test("An integer stays an integer while it can")
    func integersStayIntegers() {
        let twelve = CSSValueScrub.numbers(in: "12px")[0]
        #expect(CSSValueScrub.adjusted(twelve, by: 3, unit: 1) == "15px")
        #expect(CSSValueScrub.adjusted(twelve, by: -12, unit: 1) == "0px")
    }

    /// A drag accumulates dozens of steps, and floating-point noise in any one
    /// of them ends up in the diff you paste into your editor.
    @Test("Dragging doesn't accumulate floating-point noise")
    func precision() {
        let value = CSSValueScrub.numbers(in: "1.5rem")[0]
        #expect(CSSValueScrub.adjusted(value, by: 1, unit: 0.1) == "1.6rem")
        #expect(CSSValueScrub.adjusted(value, by: 3, unit: 0.1) == "1.8rem")
        // Not 1.7999999999999998rem.
        #expect(!CSSValueScrub.adjusted(value, by: 3, unit: 0.1).contains("999"))
    }

    @Test("Replacing a number leaves everything around it alone")
    func replacement() {
        let value = "8px 16px 4px"
        let numbers = CSSValueScrub.numbers(in: value)
        #expect(
            CSSValueScrub.replacing(value, number: numbers[1], with: "20px")
                == "8px 20px 4px"
        )
        #expect(
            CSSValueScrub.replacing(value, number: numbers[0], with: "0")
                == "0 16px 4px"
        )
    }

    @Test("Replacing inside a shorthand with a colour keeps the colour")
    func replacementWithColor() {
        let value = "2px solid #00aaff"
        let numbers = CSSValueScrub.numbers(in: value)
        #expect(
            CSSValueScrub.replacing(value, number: numbers[0], with: "6px")
                == "6px solid #00aaff"
        )
    }
}

@Suite("CSS keyword menus")
struct CSSKeywordTests {

    @Test("Properties with a closed set of values offer them")
    func options() {
        #expect(CSSKeywords.options(for: "display").contains("inline-flex"))
        #expect(CSSKeywords.options(for: "position") == ["static", "relative", "absolute", "fixed", "sticky"])
        #expect(CSSKeywords.options(for: "DISPLAY").contains("grid"))
    }

    @Test("Properties with open-ended values offer nothing")
    func noOptions() {
        #expect(CSSKeywords.options(for: "color").isEmpty)
        #expect(CSSKeywords.options(for: "margin").isEmpty)
        #expect(CSSKeywords.options(for: "--custom").isEmpty)
    }

    /// A menu on `1px solid red` would replace far more than the part being
    /// changed, so it's offered only where the whole value is one word.
    @Test("A menu is offered only for a bare keyword")
    func singleKeyword() {
        #expect(CSSKeywords.isSingleKeyword("flex"))
        #expect(CSSKeywords.isSingleKeyword("space-between"))
        #expect(!CSSKeywords.isSingleKeyword("1px solid red"))
        #expect(!CSSKeywords.isSingleKeyword(""))
        #expect(!CSSKeywords.isSingleKeyword("var(--x)"))
    }
}
