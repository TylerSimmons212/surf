import Testing

@testable import SurfCore

@Suite("CSS cascade")
struct CSSCascadeTests {

    // MARK: - Helpers

    private func rule(
        _ id: Int,
        _ selector: String,
        _ declarations: [(String, String)],
        important: Set<String> = [],
        origin: CSSOrigin = .author,
        layer: String? = nil,
        order: Int? = nil,
        inline: Bool = false,
        distance: Int = 0,
        from: String? = nil,
        states: [String] = [],
        pseudo: String? = nil,
        longhands: [String: [String]] = [:]
    ) -> MatchedRule {
        MatchedRule(
            id: id,
            selector: selector,
            origin: origin,
            layer: layer,
            sourceOrder: order ?? id,
            declarations: declarations.enumerated().map { index, pair in
                CSSDeclaration(
                    index: index,
                    name: pair.0,
                    value: pair.1,
                    isImportant: important.contains(pair.0),
                    longhands: longhands[pair.0] ?? [pair.0]
                )
            },
            pseudoElement: pseudo,
            states: states,
            isStyleAttribute: inline,
            inheritDistance: distance,
            inheritedLabel: from
        )
    }

    private func winner(_ resolved: ResolvedStyles, _ property: String) -> String? {
        resolved.traces[property]?.winner?.value
    }

    // MARK: - Ordering

    @Test("A heavier selector wins, and the loser knows why")
    func specificityWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ".row", [("color", "red")]),
            rule(2, "#main .row", [("color", "blue")]),
        ])

        #expect(winner(resolved, "color") == "blue")
        let loser = resolved.traces["color"]?.entries.last
        #expect(loser?.outcome == .lostToSpecificity(mine: Specificity(0, 1, 0), winner: Specificity(1, 1, 0)))
    }

    /// Equal weight is the case people find most confusing, because nothing on
    /// screen distinguishes the two rules. Saying "declared earlier" out loud
    /// is the whole answer.
    @Test("Equal weight is settled by document order")
    func orderWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ".row", [("color", "red")], order: 1),
            rule(2, ".row", [("color", "blue")], order: 2),
        ])
        #expect(winner(resolved, "color") == "blue")
        #expect(resolved.traces["color"]?.entries.last?.outcome == .lostToOrder)
    }

    @Test("!important beats a heavier selector, and says so rather than blaming specificity")
    func importantWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ".row", [("color", "red")], important: ["color"]),
            rule(2, "#main.row.wide", [("color", "blue")]),
        ])
        #expect(winner(resolved, "color") == "red")
        // The point of naming the axis: adding another class here would never
        // help, and "lower specificity" would send someone off to try.
        #expect(resolved.traces["color"]?.entries.last?.outcome == .lostToImportant)
    }

    @Test("The style attribute beats every author rule")
    func inlineWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "#main", [("color", "blue")]),
            rule(2, "", [("color", "green")], inline: true),
        ])
        #expect(winner(resolved, "color") == "green")
        #expect(resolved.traces["color"]?.entries.last?.outcome == .lostToStyleAttribute)
    }

    /// …but not one marked important, which is the exception that catches
    /// people out constantly.
    @Test("An !important author rule beats the style attribute")
    func importantBeatsInline() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ".row", [("color", "blue")], important: ["color"]),
            rule(2, "", [("color", "green")], inline: true),
        ])
        #expect(winner(resolved, "color") == "blue")
    }

    @Test("A page rule beats the browser's own default")
    func originWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "a:-webkit-any-link", [("color", "-webkit-link")], origin: .userAgent),
            rule(2, "a", [("color", "black")]),
        ])
        #expect(winner(resolved, "color") == "black")
        #expect(resolved.traces["color"]?.entries.last?.outcome == .lostToOrigin(.author))
    }

    // MARK: - Layers

    /// Layer order is declaration order, and a later layer wins — the opposite
    /// of the intuition that a layer declared first is "more base".
    @Test("A later layer overrides an earlier one")
    func layerOrder() {
        let resolved = CSSCascade.resolve(
            rules: [
                rule(1, ".btn", [("color", "red")], layer: "components", order: 2),
                rule(2, ".btn", [("color", "blue")], layer: "base", order: 1),
            ],
            layerOrder: ["base", "components"]
        )
        #expect(winner(resolved, "color") == "red")
        #expect(
            resolved.traces["color"]?.entries.last?.outcome
                == .lostToLayer(winner: "components", loser: "base")
        )
    }

    /// The rule nobody believes until they've been bitten: unlayered styles sit
    /// after every named layer, so a plain rule beats a layered one no matter
    /// how specific the layered one is.
    @Test("Unlayered rules beat every named layer")
    func unlayeredWins() {
        let resolved = CSSCascade.resolve(
            rules: [
                rule(1, "#main .btn.wide", [("color", "red")], layer: "components"),
                rule(2, ".btn", [("color", "blue")]),
            ],
            layerOrder: ["base", "components"]
        )
        #expect(winner(resolved, "color") == "blue")
    }

    /// And importance reverses the whole layer order, which means the earliest
    /// layer wins instead of the latest.
    @Test("!important reverses layer order")
    func importantReversesLayers() {
        let resolved = CSSCascade.resolve(
            rules: [
                rule(1, ".btn", [("color", "red")], important: ["color"], layer: "base"),
                rule(2, ".btn", [("color", "blue")], important: ["color"], layer: "components"),
            ],
            layerOrder: ["base", "components"]
        )
        #expect(winner(resolved, "color") == "red")
    }

    @Test("A layer nobody announced still orders by first appearance")
    func undeclaredLayer() {
        let resolved = CSSCascade.resolve(
            rules: [
                rule(1, ".btn", [("color", "red")], layer: "first", order: 1),
                rule(2, ".btn", [("color", "blue")], layer: "second", order: 2),
            ],
            layerOrder: []
        )
        #expect(winner(resolved, "color") == "blue")
    }

    // MARK: - Shorthands

    /// The case every devtools gets visibly wrong: `margin: 8px` followed by
    /// `margin-top: 0` is neither applied nor overridden. Three of its four
    /// sides are still in force.
    @Test("A shorthand can be beaten on only part of what it sets")
    func partialOverride() {
        let shorthand = rule(
            1, ".card", [("margin", "8px")],
            longhands: ["margin": ["margin-top", "margin-right", "margin-bottom", "margin-left"]]
        )
        let longhand = rule(2, ".card", [("margin-top", "0")], order: 2)
        let resolved = CSSCascade.resolve(rules: [shorthand, longhand])

        #expect(winner(resolved, "margin-top") == "0")
        #expect(winner(resolved, "margin-left") == "8px")
        #expect(
            resolved.status(of: shorthand.declarations[0], in: shorthand)
                == .partiallyOverridden(["margin-top"])
        )
        #expect(resolved.status(of: longhand.declarations[0], in: longhand) == .active)
    }

    @Test("A shorthand beaten on every side is simply overridden")
    func fullOverride() {
        let shorthand = rule(
            1, ".card", [("margin", "8px")],
            longhands: ["margin": ["margin-top", "margin-bottom"]]
        )
        let later = rule(
            2, ".card", [("margin", "0")], order: 2,
            longhands: ["margin": ["margin-top", "margin-bottom"]]
        )
        let resolved = CSSCascade.resolve(rules: [shorthand, later])
        #expect(resolved.status(of: shorthand.declarations[0], in: shorthand) == .overridden)
    }

    @Test("A property set twice in one rule keeps the later one")
    func shadowedInSameRule() {
        let twice = rule(1, ".row", [("color", "red"), ("color", "blue")])
        let resolved = CSSCascade.resolve(rules: [twice])
        #expect(winner(resolved, "color") == "blue")
        #expect(resolved.traces["color"]?.entries.last?.outcome == .shadowedInSameRule)
        #expect(resolved.status(of: twice.declarations[0], in: twice) == .overridden)
    }

    // MARK: - Inheritance

    /// Inheritance is not a tiebreak. An element's own declaration wins over an
    /// ancestor's however weak it is, and however heavy the ancestor's was.
    @Test("The element's own rule beats anything inherited, whatever the weight")
    func proximityBeatsSpecificity() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "div", [("color", "black")]),
            rule(2, "#page.theme-dark", [("color", "white")], distance: 1, from: "body#page"),
        ])
        #expect(winner(resolved, "color") == "black")
        #expect(
            resolved.traces["color"]?.entries.last?.outcome == .lostToNearerElement
        )
    }

    /// An ancestor's `display: flex` says nothing about its children. Listing
    /// it as though it applied sends people chasing a declaration that was
    /// never in play.
    @Test("Only inheritable properties travel down from an ancestor")
    func onlyInheritableTravels() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "body", [("display", "flex"), ("color", "navy")], distance: 1, from: "body"),
        ])
        #expect(winner(resolved, "color") == "navy")
        #expect(resolved.traces["display"] == nil)
    }

    /// Custom properties inherit, and a `--brand` set five ancestors up is
    /// exactly the thing that's invisible everywhere else.
    @Test("Custom properties inherit")
    func customPropertiesInherit() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ":root", [("--brand", "#0af")], distance: 3, from: "html"),
        ])
        #expect(winner(resolved, "--brand") == "#0af")
    }

    @Test("The nearer of two ancestors wins")
    func nearestAncestorWins() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "html", [("color", "red")], distance: 2, from: "html"),
            rule(2, "body", [("color", "blue")], distance: 1, from: "body"),
        ])
        #expect(winner(resolved, "color") == "blue")
    }

    // MARK: - Scoping

    /// A `:hover` block is worth showing — reading it beats having to hover to
    /// discover it — but it isn't applying, and must never strike anything out.
    @Test("State rules are kept aside rather than cascaded")
    func stateRules() {
        let hover = rule(2, ".btn:hover", [("color", "blue")], order: 2, states: [":hover"])
        let resolved = CSSCascade.resolve(rules: [
            rule(1, ".btn", [("color", "red")]),
            hover,
        ])
        #expect(winner(resolved, "color") == "red")
        #expect(resolved.stateRules.map(\MatchedRule.id) == [2])
        #expect(resolved.status(of: hover.declarations[0], in: hover) == .inactive)
    }

    /// `::before` cascades on its own. Mixing it with the element produces
    /// strikethroughs that make no sense on either side.
    @Test("A pseudo-element cascades separately from its element")
    func pseudoElementsAreSeparate() {
        let rules = [
            rule(1, ".card", [("color", "red")]),
            rule(2, ".card::before", [("color", "blue")], pseudo: "::before"),
        ]
        #expect(winner(CSSCascade.resolve(rules: rules), "color") == "red")
        #expect(winner(CSSCascade.resolve(rules: rules, pseudoElement: "::before"), "color") == "blue")
    }

    // MARK: - Display order

    @Test("Rules are listed strongest first")
    func displayOrder() {
        let resolved = CSSCascade.resolve(rules: [
            rule(1, "div", [("color", "a")]),
            rule(2, "#main", [("color", "b")]),
            rule(3, ".row", [("color", "c")]),
        ])
        #expect(resolved.rules.map(\.id) == [2, 3, 1])
    }

    /// Nothing here may fall over on an element with no styles at all, which is
    /// what a text node's parent looks like mid-navigation.
    @Test("An element with nothing matched resolves to nothing")
    func empty() {
        let resolved = CSSCascade.resolve(rules: [])
        #expect(resolved.rules.isEmpty)
        #expect(resolved.traces.isEmpty)
    }
}

@Suite("Inherited rule display")
struct InheritedRuleDisplayTests {

    /// The cascade already ignores an ancestor's `margin`, but listing it under
    /// "inherited from div.card" asserts something false, and whoever reads it
    /// goes off to fight a declaration that was never in play.
    @Test("An inherited rule only shows the properties that actually inherit")
    func filtersToInheritable() {
        let rule = MatchedRule(
            id: 1,
            selector: ".card",
            declarations: [
                CSSDeclaration(index: 0, name: "margin-top", value: "0"),
                CSSDeclaration(index: 1, name: "color", value: "navy"),
            ],
            inheritDistance: 1,
            inheritedLabel: "div.card"
        )
        #expect(rule.displayDeclarations.map(\.name) == ["color"])
        #expect(rule.hasVisibleDeclarations)
    }

    @Test("A rule matched on the element itself shows everything")
    func ownRuleUnfiltered() {
        let rule = MatchedRule(
            id: 1,
            selector: ".card",
            declarations: [CSSDeclaration(index: 0, name: "margin-top", value: "0")]
        )
        #expect(rule.displayDeclarations.count == 1)
    }

    /// A shorthand travels if any part of it does.
    @Test("A shorthand counts as inheritable when one of its longhands is")
    func shorthandWithInheritablePart() {
        let rule = MatchedRule(
            id: 1,
            selector: "body",
            declarations: [
                CSSDeclaration(
                    index: 0, name: "font", value: "12px/1.4 serif",
                    longhands: ["font-size", "line-height", "font-family"]
                ),
            ],
            inheritDistance: 1
        )
        #expect(rule.hasVisibleDeclarations)
    }

    @Test("An ancestor rule that inherits nothing is not shown at all")
    func nothingTravels() {
        let rule = MatchedRule(
            id: 1,
            selector: ".grid",
            declarations: [CSSDeclaration(index: 0, name: "display", value: "flex")],
            inheritDistance: 2
        )
        #expect(!rule.hasVisibleDeclarations)
    }
}
