import Foundation

/// What it would take to make a declaration you're editing actually apply.
public enum StyleEscalation: Sendable, Equatable {
    /// Nothing needed — it's already the winner.
    case alreadyWins
    /// Marking it `!important` is enough.
    case addImportant
    /// No change to this declaration can win; the fight has to be had where
    /// the winner is. Carries the winner so the panel can offer to go there.
    case editTheWinner(selector: String, value: String)

    public var advice: String {
        switch self {
        case .alreadyWins:
            "This is the value in force."
        case .addImportant:
            "Marking it !important would make it win."
        case .editTheWinner(let selector, _):
            "Nothing you can do here wins — edit \(selector) instead."
        }
    }
}

/// Works out why an edit isn't showing up, and what would fix it.
///
/// This is the dead end that makes devtools editing feel broken: you change a
/// value, the page doesn't move, and no browser says a word. You retype it,
/// doubt the spelling, try a different value. The declaration was overridden
/// the whole time.
///
/// Every answer here is *computed*, not guessed — the candidate change is
/// applied to a copy of the rules and the cascade is run again to see whether
/// it actually wins. A heuristic would be wrong in exactly the cases that are
/// confusing enough to need it: layered `!important`, which reverses, or an
/// inline style that no specificity can beat.
public enum CascadeEscalation {

    public static func escalation(
        for ref: DeclarationRef,
        property: String,
        rules: [MatchedRule],
        layerOrder: [String] = [],
        pseudoElement: String? = nil
    ) -> StyleEscalation {
        func winner(of candidates: [MatchedRule]) -> TraceEntry? {
            CSSCascade.resolve(
                rules: candidates, layerOrder: layerOrder, pseudoElement: pseudoElement
            ).traces[property]?.winner
        }

        if winner(of: rules)?.ref == ref { return .alreadyWins }

        // The one escalation available without touching another rule.
        let escalated = rules.map { rule -> MatchedRule in
            guard rule.id == ref.ruleId else { return rule }
            var copy = rule
            copy.declarations = rule.declarations.map { declaration in
                guard declaration.index == ref.index else { return declaration }
                var edited = declaration
                edited.isImportant = true
                return edited
            }
            return copy
        }
        if winner(of: escalated)?.ref == ref { return .addImportant }

        guard let current = winner(of: rules) else { return .alreadyWins }
        return .editTheWinner(
            selector: current.isStyleAttribute ? "the style attribute" : current.selector,
            value: current.value
        )
    }
}
