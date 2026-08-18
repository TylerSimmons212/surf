import Foundation

/// Why a declaration didn't win.
///
/// This is the feature the whole Styles pane is built around. Every browser
/// shows you *that* a declaration lost — a line through it — and none of them
/// shows you *why*. "Specificity 0-1-0 loses to 0-2-0" and "same weight,
/// declared earlier" and "the winner is in a later layer" are three completely
/// different problems with three different fixes, and today you work out which
/// one you have by reading the list and doing the cascade in your head.
public enum CascadeOutcome: Sendable, Equatable {
    case winner
    /// The element declares this itself, so an ancestor's value never arrives.
    case lostToNearerElement
    case lostToImportant
    case lostToOrigin(CSSOrigin)
    case lostToStyleAttribute
    case lostToLayer(winner: String?, loser: String?)
    case lostToSpecificity(mine: Specificity, winner: Specificity)
    /// Equal in every way that counts, so the later one wins.
    case lostToOrder
    /// The same rule sets the property again further down.
    case shadowedInSameRule

    public var isWinner: Bool { self == .winner }

    /// One line, in the words someone would use to explain it out loud.
    public var explanation: String {
        switch self {
        case .winner:
            "Applied"
        case .lostToNearerElement:
            "the element declares this itself, so nothing inherited reaches it"
        case .lostToImportant:
            "the winning declaration is !important"
        case .lostToOrigin(let origin):
            "a \(origin.label) rule takes precedence"
        case .lostToStyleAttribute:
            "the element's style attribute wins"
        case .lostToLayer(let winner, let loser):
            switch (winner, loser) {
            case (let winner?, let loser?):
                "layer \(loser) is overridden by layer \(winner)"
            case (nil, let loser?):
                "unlayered rules override layer \(loser)"
            case (let winner?, nil):
                "layer \(winner) is marked !important, which reverses layer order"
            default:
                "a later cascade layer wins"
            }
        case .lostToSpecificity(let mine, let winner):
            "specificity \(mine) loses to \(winner)"
        case .lostToOrder:
            "same specificity, declared earlier"
        case .shadowedInSameRule:
            "set again further down in the same rule"
        }
    }
}

/// Everything about one property, across every rule that touches it.
///
/// The inversion that makes this useful: a Styles pane is normally *rule*-first
/// — here are the rules, hunt for your property inside them. When the question
/// is "why is this blue", rule-first is the wrong index, and you end up
/// scanning a dozen blocks for struck-through text. This is the other index.
public struct PropertyTrace: Sendable, Equatable, Identifiable {
    public var property: String
    /// Winner first, then the losers strongest to weakest.
    public var entries: [TraceEntry]

    public var id: String { property }
    public var winner: TraceEntry? { entries.first }
    public var value: String { winner?.value ?? "" }
    /// Worth showing a "why" affordance for at all — one declaration and
    /// nothing beat it, so there's no story to tell.
    public var isContested: Bool { entries.count > 1 }
}

public struct TraceEntry: Sendable, Equatable, Identifiable {
    public var ref: DeclarationRef
    /// The branch of the selector list that matched.
    public var selector: String
    public var sourceLabel: String
    public var specificity: Specificity
    public var origin: CSSOrigin
    public var layer: String?
    /// As authored: `margin`, not `margin-top`.
    public var declaredName: String
    public var value: String
    public var isImportant: Bool
    public var isStyleAttribute: Bool
    public var inheritedLabel: String?
    public var outcome: CascadeOutcome

    public var id: String { "\(ref.ruleId).\(ref.index).\(declaredName)" }
}

/// How a declaration should be drawn.
public enum DeclarationStatus: Sendable, Equatable {
    case active
    case overridden
    /// A shorthand where only some of what it sets was beaten. `margin: 8px`
    /// with a later `margin-top: 0` is neither applied nor overridden, and
    /// drawing it as either is wrong.
    case partiallyOverridden([String])
    /// From a rule that isn't currently applying — a `:hover` block shown so
    /// you can read it without having to hover.
    case inactive
}

public struct ResolvedStyles: Sendable {
    /// Cascade order, strongest first — the order a Styles pane lists them in.
    public var rules: [MatchedRule]
    /// Rules shown but not applying: `:hover`, `:focus`, and the rest.
    public var stateRules: [MatchedRule]
    /// By longhand property name.
    public var traces: [String: PropertyTrace]
    private var lost: [DeclarationRef: Set<String>]

    init(
        rules: [MatchedRule],
        stateRules: [MatchedRule],
        traces: [String: PropertyTrace],
        lost: [DeclarationRef: Set<String>]
    ) {
        self.rules = rules
        self.stateRules = stateRules
        self.traces = traces
        self.lost = lost
    }

    public func status(
        of declaration: CSSDeclaration, in rule: MatchedRule
    ) -> DeclarationStatus {
        guard rule.isActive else { return .inactive }
        let ref = DeclarationRef(ruleId: rule.id, index: declaration.index)
        guard let beaten = lost[ref], !beaten.isEmpty else { return .active }
        if beaten.count >= declaration.longhands.count { return .overridden }
        return .partiallyOverridden(declaration.longhands.filter { beaten.contains($0) }.sorted())
    }

    /// The properties actually in force, which is what a computed view should
    /// mark as authored rather than inherited-from-the-defaults.
    public var declaredProperties: Set<String> {
        Set(traces.keys)
    }
}

// MARK: - The cascade itself

public enum CSSCascade {

    /// Sorts every declaration that reaches the element and works out, for each
    /// property, which one wins and why the others didn't.
    ///
    /// - Parameters:
    ///   - rules: everything the page reported, own and inherited.
    ///   - layerOrder: the document's resolved `@layer` order, first declared
    ///     first. Unlayered rules sort *after* all of these.
    ///   - pseudoElement: resolve `::before` rather than the element itself.
    ///     Pseudo-elements cascade separately and mixing them produces
    ///     strikethroughs that make no sense.
    public static func resolve(
        rules allRules: [MatchedRule],
        layerOrder: [String] = [],
        pseudoElement: String? = nil
    ) -> ResolvedStyles {
        let scoped = allRules.filter { $0.pseudoElement == pseudoElement }
        let active = scoped.filter(\.isActive)
        let states = scoped.filter { !$0.isActive }

        // The declared order, plus any layer that turned up without having been
        // announced — `@layer` blocks establish order by first appearance when
        // no statement listed them up front.
        var effectiveLayers = layerOrder
        for rule in active {
            guard let layer = rule.layer, !effectiveLayers.contains(layer) else { continue }
            effectiveLayers.append(layer)
        }

        var ranks: [Int: Rank] = [:]
        for rule in active {
            ranks[rule.id] = Rank(rule: rule, layerIndex: layerIndex(of: rule, in: effectiveLayers))
        }

        // One entry per longhand per declaration. Inherited rules contribute
        // only what actually inherits.
        var candidates: [String: [Candidate]] = [:]
        for rule in active {
            guard let rank = ranks[rule.id] else { continue }
            for declaration in rule.declarations {
                for longhand in declaration.longhands {
                    if rule.isInherited, !CSSInheritance.isInheritable(longhand) { continue }
                    candidates[longhand, default: []].append(
                        Candidate(rule: rule, declaration: declaration, rank: rank)
                    )
                }
            }
        }

        var traces: [String: PropertyTrace] = [:]
        var lost: [DeclarationRef: Set<String>] = [:]

        for (property, group) in candidates {
            // Strongest first. `sorted` is stable, so equal ranks keep the
            // order they were collected in, which is document order.
            let ordered = group.sorted { $0.key > $1.key }
            guard let winner = ordered.first else { continue }

            var entries: [TraceEntry] = [entry(for: winner, outcome: .winner)]
            for loser in ordered.dropFirst() {
                entries.append(entry(for: loser, outcome: outcome(loser: loser, winner: winner)))
                lost[
                    DeclarationRef(ruleId: loser.rule.id, index: loser.declaration.index),
                    default: []
                ].insert(property)
            }
            traces[property] = PropertyTrace(property: property, entries: entries)
        }

        return ResolvedStyles(
            rules: active.sorted { lhs, rhs in
                (ranks[lhs.id] ?? .weakest).key > (ranks[rhs.id] ?? .weakest).key
            },
            stateRules: states,
            traces: traces,
            lost: lost
        )
    }

    // MARK: - Ranking

    /// Where a rule sits in the author layer order.
    ///
    /// The two counter-intuitive parts, both of which the spec states plainly
    /// and everyone forgets: unlayered rules come *after* every named layer, so
    /// they win; and the style attribute behaves as one more layer after that.
    private static func layerIndex(of rule: MatchedRule, in layers: [String]) -> Int {
        if rule.isStyleAttribute { return layers.count + 1 }
        guard let layer = rule.layer else { return layers.count }
        return layers.firstIndex(of: layer) ?? layers.count
    }

    private struct Rank {
        /// Nearer elements win outright: inheritance is not a tiebreak, it's
        /// what happens when the element declared nothing at all.
        var proximity: Int
        var layerIndex: Int
        var specificity: Specificity
        var order: Int
        var origin: CSSOrigin

        static let weakest = Rank(
            proximity: .min, layerIndex: .min, specificity: .zero,
            order: .min, origin: .userAgent
        )

        init(proximity: Int, layerIndex: Int, specificity: Specificity, order: Int, origin: CSSOrigin) {
            self.proximity = proximity
            self.layerIndex = layerIndex
            self.specificity = specificity
            self.order = order
            self.origin = origin
        }

        init(rule: MatchedRule, layerIndex: Int) {
            self.init(
                proximity: -rule.inheritDistance,
                layerIndex: layerIndex,
                specificity: rule.specificity,
                order: rule.sourceOrder,
                origin: rule.origin
            )
        }

        /// The rule's own standing, for ordering the list on screen. Rules are
        /// listed as though nothing in them were `!important`, because a rule
        /// isn't important — declarations are.
        var key: Key { key(important: false, declarationIndex: 0) }

        func key(important: Bool, declarationIndex: Int) -> Key {
            // Ascending precedence. Importance flips the origin order, which is
            // the rule that lets a user stylesheet's !important beat the page's
            // — the accessibility guarantee the cascade exists to provide.
            let bucket: Int = switch (origin, important) {
            case (.userAgent, false): 0
            case (.user, false): 1
            case (.author, false): 2
            case (.author, true): 3
            case (.user, true): 4
            case (.userAgent, true): 5
            }
            return Key(
                proximity: proximity,
                origin: bucket,
                // Importance reverses layer order too.
                layer: important ? -layerIndex : layerIndex,
                specificity: specificity,
                // The declaration's own position breaks ties inside one rule,
                // where the later of two settings of a property wins.
                order: order * 1024 + declarationIndex
            )
        }

        struct Key: Comparable {
            var proximity: Int
            var origin: Int
            var layer: Int
            var specificity: Specificity
            var order: Int

            static func < (lhs: Self, rhs: Self) -> Bool {
                if lhs.proximity != rhs.proximity { return lhs.proximity < rhs.proximity }
                if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
                if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
                if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
                return lhs.order < rhs.order
            }
        }
    }

    private struct Candidate {
        var rule: MatchedRule
        var declaration: CSSDeclaration
        var rank: Rank

        /// Importance is settled per *declaration*, not per rule, so the bucket
        /// and the layer direction are only decided here.
        var key: Rank.Key {
            rank.key(important: declaration.isImportant, declarationIndex: declaration.index)
        }
    }

    private static func entry(for candidate: Candidate, outcome: CascadeOutcome) -> TraceEntry {
        TraceEntry(
            ref: DeclarationRef(
                ruleId: candidate.rule.id, index: candidate.declaration.index
            ),
            selector: candidate.rule.isStyleAttribute
                ? "style attribute" : candidate.rule.matchedSelector,
            sourceLabel: candidate.rule.sourceLabel,
            specificity: candidate.rule.specificity,
            origin: candidate.rule.origin,
            layer: candidate.rule.layer,
            declaredName: candidate.declaration.name,
            value: candidate.declaration.value,
            isImportant: candidate.declaration.isImportant,
            isStyleAttribute: candidate.rule.isStyleAttribute,
            inheritedLabel: candidate.rule.inheritedLabel,
            outcome: outcome
        )
    }

    /// The first axis on which the two actually differ — which is precisely the
    /// reason, and the only one worth reporting. Saying "lower specificity"
    /// about a rule that lost on origin sends someone off to add a class that
    /// cannot possibly help.
    private static func outcome(loser: Candidate, winner: Candidate) -> CascadeOutcome {
        let mine = loser.key
        let theirs = winner.key

        if mine.proximity != theirs.proximity {
            return .lostToNearerElement
        }
        if mine.origin != theirs.origin {
            if loser.rule.origin == winner.rule.origin { return .lostToImportant }
            return .lostToOrigin(winner.rule.origin)
        }
        if mine.layer != theirs.layer {
            if winner.rule.isStyleAttribute { return .lostToStyleAttribute }
            return .lostToLayer(winner: winner.rule.layer, loser: loser.rule.layer)
        }
        if mine.specificity != theirs.specificity {
            return .lostToSpecificity(mine: mine.specificity, winner: theirs.specificity)
        }
        if loser.rule.id == winner.rule.id { return .shadowedInSameRule }
        return .lostToOrder
    }
}
