import Testing

@testable import GlassCore

@Suite("Style changeset")
struct StyleChangesetTests {

    private func change(
        _ property: String,
        from original: String?,
        to updated: String?,
        rule: Int = 1,
        selector: String = ".btn",
        source: String = "app.css",
        important: Bool = false
    ) -> StyleChange {
        StyleChange(
            ruleId: rule, selector: selector, sourceLabel: source,
            property: property, original: original, updated: updated,
            isImportant: important
        )
    }

    /// The point of the whole thing: nudging a value twelve times is one line
    /// in the patch, and the comparison stays against what the page shipped
    /// rather than against the previous keystroke.
    @Test("Editing one property repeatedly collapses to a single change")
    func coalesces() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        set.record(change("color", from: "red", to: "green"))
        set.record(change("color", from: "green", to: "teal"))

        #expect(set.count == 1)
        #expect(set.changes[0].original == "blue")
        #expect(set.changes[0].updated == "teal")
    }

    /// A row saying "changed nothing" is worse than useless — you'd paste it.
    @Test("Editing a value back to where it started leaves no change")
    func noOpDisappears() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        set.record(change("color", from: "red", to: "blue"))
        #expect(set.isEmpty)
    }

    @Test("Toggling importance back and forth also cancels out")
    func importanceNoOp() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "blue", important: true))
        #expect(set.count == 1)
        set.record(change("color", from: "blue", to: "blue", important: false))
        #expect(set.isEmpty)
    }

    @Test("A missing original marks an addition, a missing value a removal")
    func kinds() {
        #expect(change("color", from: nil, to: "red").kind == .added)
        #expect(change("color", from: "red", to: nil).kind == .removed)
        #expect(change("color", from: "red", to: "blue").kind == .changed)
    }

    @Test("Changes group by stylesheet and then by rule")
    func grouping() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        set.record(change("padding", from: "1px", to: "8px"))
        set.record(change("margin", from: "0", to: "4px", rule: 2, selector: ".card"))
        set.record(change("gap", from: "0", to: "8px", rule: 3, source: "theme.css"))

        let grouped = set.grouped
        #expect(grouped.map(\.sourceLabel) == ["app.css", "theme.css"])
        #expect(grouped[0].rules.count == 2)
        #expect(grouped[0].rules[0].changes.count == 2)
        #expect(grouped[0].count == 3)
    }

    @Test("Reverting a rule forgets only that rule's changes")
    func clearOneRule() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        set.record(change("margin", from: "0", to: "4px", rule: 2))
        set.clear(ruleId: 1)
        #expect(set.count == 1)
        #expect(set.changes[0].property == "margin")
    }

    /// A declaration lifted out of its `@media` is not the same declaration —
    /// pasted unwrapped it would apply at every width.
    @Test("The patch keeps declarations inside the conditions they were found in")
    func patchPreservesContext() {
        var set = StyleChangeset()
        var entry = change("color", from: "blue", to: "red")
        entry.conditions = ["@media (min-width: 768px)"]
        entry.layer = "components"
        set.record(entry)

        let patch = set.cssPatch
        #expect(patch.contains("@media (min-width: 768px) {"))
        #expect(patch.contains("@layer components {"))
        #expect(patch.contains("color: red;"))
        // Opened three blocks, so it must close three.
        #expect(patch.filter { $0 == "{" }.count == patch.filter { $0 == "}" }.count)
    }

    @Test("The patch notes the old value and spells out removals")
    func patchAnnotates() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        set.record(change("padding", from: "8px", to: nil))
        set.record(change("gap", from: nil, to: "4px"))

        let patch = set.cssPatch
        #expect(patch.contains("color: red; /* was blue */"))
        // Silently omitting a removal would make the patch look shorter than
        // the work actually was.
        #expect(patch.contains("/* remove: padding: 8px; */"))
        #expect(patch.contains("gap: 4px;"))
    }

    @Test("The summary counts changes and the rules they land in")
    func summary() {
        var set = StyleChangeset()
        set.record(change("color", from: "blue", to: "red"))
        #expect(set.summary == "1 change in 1 rule")
        set.record(change("padding", from: "1px", to: "8px"))
        set.record(change("margin", from: "0", to: "4px", rule: 2))
        #expect(set.summary == "3 changes in 2 rules")
    }
}

@Suite("Cascade escalation")
struct CascadeEscalationTests {

    private func rule(
        _ id: Int,
        _ selector: String,
        _ property: String,
        _ value: String,
        important: Bool = false,
        layer: String? = nil,
        inline: Bool = false,
        order: Int? = nil
    ) -> MatchedRule {
        MatchedRule(
            id: id,
            selector: selector,
            layer: layer,
            sourceOrder: order ?? id,
            declarations: [
                CSSDeclaration(index: 0, name: property, value: value, isImportant: important),
            ],
            isStyleAttribute: inline
        )
    }

    private func ref(_ id: Int) -> DeclarationRef { DeclarationRef(ruleId: id, index: 0) }

    @Test("A declaration already in force needs nothing")
    func alreadyWins() {
        let rules = [rule(1, ".btn", "color", "red"), rule(2, "#main", "color", "blue")]
        #expect(
            CascadeEscalation.escalation(for: ref(2), property: "color", rules: rules)
                == .alreadyWins
        )
    }

    @Test("Losing on specificity is fixed by !important")
    func importantIsEnough() {
        let rules = [rule(1, ".btn", "color", "red"), rule(2, "#main", "color", "blue")]
        #expect(
            CascadeEscalation.escalation(for: ref(1), property: "color", rules: rules)
                == .addImportant
        )
    }

    /// The case a heuristic gets wrong. Adding `!important` here does nothing,
    /// because the winner is already important *and* heavier — so the honest
    /// answer is to send you to the other rule.
    @Test("Against a heavier !important rule, nothing here can win")
    func mustEditTheWinner() {
        let rules = [
            rule(1, ".btn", "color", "red"),
            rule(2, "#main .btn", "color", "blue", important: true),
        ]
        let result = CascadeEscalation.escalation(for: ref(1), property: "color", rules: rules)
        #expect(result == .editTheWinner(selector: "#main .btn", value: "blue"))
    }

    /// Layered `!important` reverses the layer order, which is exactly the sort
    /// of thing that has to be computed rather than assumed.
    @Test("!important is enough even when layers reverse")
    func layeredImportant() {
        let rules = [
            rule(1, ".btn", "color", "red", layer: "base", order: 1),
            rule(2, ".btn", "color", "blue", layer: "components", order: 2),
        ]
        // Normally components wins; marking base important reverses the order.
        #expect(
            CascadeEscalation.escalation(
                for: ref(1), property: "color", rules: rules,
                layerOrder: ["base", "components"]
            ) == .addImportant
        )
    }

    @Test("A rule can out-important the style attribute")
    func beatsInline() {
        let rules = [rule(1, ".btn", "color", "red"), rule(2, "", "color", "blue", inline: true)]
        #expect(
            CascadeEscalation.escalation(for: ref(1), property: "color", rules: rules)
                == .addImportant
        )
    }

    @Test("The advice names the rule to go and edit")
    func advice() {
        let rules = [
            rule(1, ".btn", "color", "red"),
            rule(2, "#main .btn", "color", "blue", important: true),
        ]
        let result = CascadeEscalation.escalation(for: ref(1), property: "color", rules: rules)
        #expect(result.advice.contains("#main .btn"))
    }
}

@Suite("CSS colour")
struct CSSColorTests {

    /// The page's own parser answers, so nothing here needs to know the 148
    /// named colours or what `oklch()` means — only how to read four bytes.
    @Test("A resolved colour decodes from the page's four bytes")
    func decode() {
        let color = CSSWire.decodeColor([0, 170, 255, 255])
        #expect(color == CSSColor(red: 0, green: 170, blue: 255))
        #expect(color?.hex == "#00aaff")
        #expect(color?.isOpaque == true)
    }

    /// Alpha has to survive, because a swatch for `rgba(0, 0, 0, 0.05)` drawn
    /// as opaque black is a lie about a value people specifically go looking
    /// for.
    @Test("Alpha survives and shows in the hex")
    func alpha() {
        let color = CSSWire.decodeColor([0, 0, 0, 128])
        #expect(color?.isOpaque == false)
        #expect(color?.hex == "#00000080")
        #expect((color?.opacity ?? 0) > 0.5 && (color?.opacity ?? 0) < 0.51)
    }

    @Test("Anything that isn't four numbers is not a colour")
    func rejectsJunk() {
        #expect(CSSWire.decodeColor(nil) == nil)
        #expect(CSSWire.decodeColor([0, 170]) == nil)
        #expect(CSSWire.decodeColor("red") == nil)
    }

    /// `border: 1px solid red` is one swatch in the middle of a sentence, not
    /// a swatch for the whole declaration.
    @Test("A value splits around the colours inside it")
    func segments() {
        let segments = CSSWire.decodeSegments([
            ["text": "1px solid "],
            ["text": "red", "rgba": [255, 0, 0, 255]],
        ])
        #expect(segments.count == 2)
        #expect(segments[0].color == nil)
        #expect(segments[1].color?.hex == "#ff0000")
    }

    @Test("A value with no colours reads as a single plain run")
    func noColors() {
        let declaration = CSSDeclaration(index: 0, name: "padding", value: "8px")
        #expect(declaration.valueSegments.map(\.text) == ["8px"])
        #expect(!declaration.hasColor)
    }

    @Test("Out-of-range bytes are clamped rather than trusted")
    func clamps() {
        let color = CSSColor(red: 300, green: -20, blue: 128, alpha: 999)
        #expect(color.red == 255)
        #expect(color.green == 0)
        #expect(color.alpha == 255)
    }
}

@Suite("Picked colour notation")
struct CSSColorNotationTests {

    /// Picking a colour shouldn't quietly rewrite the notation around it. The
    /// diff you take back to your editor is meant to read as a change of
    /// colour, not a change of colour *and* a change of style.
    @Test("A value written as rgb() comes back as rgb()")
    func keepsFunctional() {
        let color = CSSColor(red: 0, green: 170, blue: 255)
        #expect(color.css(matching: "rgb(1, 2, 3)") == "rgb(0, 170, 255)")
        #expect(color.css(matching: "rgba(1, 2, 3, 0.5)") == "rgb(0, 170, 255)")
    }

    @Test("A value written as hex comes back as hex")
    func keepsHex() {
        let color = CSSColor(red: 0, green: 170, blue: 255)
        #expect(color.css(matching: "#123456") == "#00aaff")
        #expect(color.css(matching: "red") == "#00aaff")
    }

    /// There's no honest way to keep `oklch()` once a colour has been picked
    /// out of an sRGB panel, so it becomes hex rather than pretending.
    @Test("Modern syntax becomes hex rather than pretending to survive")
    func modernSyntaxFallsBack() {
        let color = CSSColor(red: 255, green: 0, blue: 0)
        #expect(color.css(matching: "oklch(0.65 0.19 24)") == "#ff0000")
        #expect(color.css(matching: "color-mix(in oklab, red, blue)") == "#ff0000")
    }

    @Test("Alpha survives into both notations")
    func alpha() {
        let color = CSSColor(red: 0, green: 0, blue: 0, alpha: 128)
        #expect(color.css(matching: "#000") == "#00000080")
        #expect(color.css(matching: "rgb(0, 0, 0)") == "rgba(0, 0, 0, 0.5)")
    }

    @Test("A fully opaque colour never emits a pointless alpha")
    func noRedundantAlpha() {
        let color = CSSColor(red: 17, green: 34, blue: 51)
        #expect(color.css(matching: "#000") == "#112233")
        #expect(color.css(matching: "rgb(0,0,0)") == "rgb(17, 34, 51)")
    }
}
