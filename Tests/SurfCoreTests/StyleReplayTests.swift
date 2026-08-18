import Testing

@testable import SurfCore

@Suite("Replaying style edits")
struct StyleReplayTests {

    private func rule(
        _ id: Int, _ selector: String, source: String = "app.css",
        conditions: [String] = [], layer: String? = nil, order: Int = 0,
        declarations: [(String, String)] = [("color", "blue")],
        inline: Bool = false
    ) -> MatchedRule {
        MatchedRule(
            id: id, selector: selector, layer: layer, conditions: conditions,
            sourceLabel: source, sourceOrder: order,
            declarations: declarations.enumerated().map {
                CSSDeclaration(index: $0.offset, name: $0.element.0, value: $0.element.1)
            },
            isStyleAttribute: inline
        )
    }

    private func change(
        _ property: String = "color", to updated: String? = "red",
        selector: String = ".btn", source: String = "app.css",
        conditions: [String] = [], layer: String? = nil, from original: String? = "blue"
    ) -> StyleChange {
        StyleChange(
            ruleId: 1, selector: selector, sourceLabel: source, layer: layer,
            conditions: conditions, property: property,
            original: original, updated: updated
        )
    }

    /// Rule handles are minted against live CSSOM objects, so a reload
    /// invalidates every one of them. Matching has to be on what the rule is.
    @Test("A change finds its rule again by selector, sheet and conditions")
    func matching() {
        let rules = [rule(99, ".btn"), rule(100, ".card")]
        #expect(StyleReplay.match(change(), in: rules)?.id == 99)
    }

    /// A `.btn` inside a media query is a different rule from a `.btn` outside
    /// it, and re-applying to the wrong one silently restyles something else.
    @Test("A rule inside a media query isn't confused with one outside it")
    func conditionsMatter() {
        let rules = [
            rule(1, ".btn"),
            rule(2, ".btn", conditions: ["@media (min-width: 768px)"]),
        ]
        let inMedia = change(conditions: ["@media (min-width: 768px)"])
        #expect(StyleReplay.match(inMedia, in: rules)?.id == 2)
        #expect(StyleReplay.match(change(), in: rules)?.id == 1)
    }

    @Test("The same selector in a different stylesheet is a different rule")
    func sheetMatters() {
        let rules = [rule(1, ".btn", source: "theme.css"), rule(2, ".btn", source: "app.css")]
        #expect(StyleReplay.match(change(source: "app.css"), in: rules)?.id == 2)
    }

    @Test("Layers are part of a rule's identity")
    func layersMatter() {
        let rules = [rule(1, ".btn", layer: "base"), rule(2, ".btn", layer: "components")]
        #expect(StyleReplay.match(change(layer: "components"), in: rules)?.id == 2)
    }

    @Test("The style attribute matches by belonging to the element")
    func inlineMatching() {
        let rules = [rule(1, ".btn"), rule(-5, "", inline: true)]
        #expect(StyleReplay.match(change(selector: "element.style"), in: rules)?.id == -5)
    }

    /// A page whose CSS changed under the edits has to be told about it rather
    /// than left believing everything came back.
    @Test("A change whose rule is gone is reported, not dropped")
    func missingRule() {
        let outcome = StyleReplay.plan(changeset(with: [change()]), against: [rule(1, ".card")])
        #expect(outcome.applied.isEmpty)
        #expect(outcome.missed.count == 1)
        #expect(outcome.missed[0].reason.contains("no longer in the page"))
        #expect(!outcome.isComplete)
    }

    @Test("A change whose declaration is gone is reported too")
    func missingDeclaration() {
        let rules = [rule(1, ".btn", declarations: [("padding", "4px")])]
        let outcome = StyleReplay.plan(changeset(with: [change()]), against: rules)
        #expect(outcome.missed.count == 1)
        #expect(outcome.missed[0].reason.contains("color"))
    }

    /// An addition had no declaration to begin with, so its absence is expected
    /// rather than a miss.
    @Test("An added declaration replays even though it isn't there yet")
    func additionsReplay() {
        let rules = [rule(1, ".btn", declarations: [("color", "blue")])]
        let addition = change("gap", to: "8px", from: nil)
        let outcome = StyleReplay.plan(changeset(with: [addition]), against: rules)
        #expect(outcome.applied.count == 1)
        #expect(outcome.isComplete)
    }

    // MARK: - Rebuilding the block

    @Test("Applying a change rewrites only that declaration")
    func rewritesOne() {
        let target = rule(1, ".btn", declarations: [("color", "blue"), ("padding", "4px")])
        let text = StyleReplay.text(for: target, applying: [change()])
        #expect(text == "color: red; padding: 4px")
    }

    @Test("A removal leaves the declaration out")
    func removal() {
        let target = rule(1, ".btn", declarations: [("color", "blue"), ("padding", "4px")])
        let text = StyleReplay.text(for: target, applying: [change(to: nil)])
        #expect(text == "padding: 4px")
    }

    @Test("An addition goes on the end")
    func addition() {
        let target = rule(1, ".btn", declarations: [("color", "blue")])
        let text = StyleReplay.text(for: target, applying: [change("gap", to: "8px", from: nil)])
        #expect(text == "color: blue; gap: 8px")
    }

    private func changeset(with changes: [StyleChange]) -> StyleChangeset {
        var set = StyleChangeset()
        for change in changes { set.record(change) }
        return set
    }
}
