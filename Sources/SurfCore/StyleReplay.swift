import Foundation

/// Re-applies collected edits to a freshly loaded document.
///
/// Every rule handle is minted against a live CSSOM object, so a reload
/// invalidates all of them — the edits have to find their rules again by what
/// the rule *is* rather than by the number it had. Matching is on the selector,
/// the stylesheet it came from, and the conditions around it, because a
/// `.btn` inside `@media (min-width: 768px)` is a different rule from a `.btn`
/// outside it and re-applying to the wrong one would silently restyle
/// something else.
public enum StyleReplay {

    public struct Outcome: Sendable, Equatable {
        public var applied: [StyleChange]
        /// Changes whose rule is no longer there, with why. Reported rather
        /// than dropped: an edit that quietly failed to come back is worse than
        /// one that never claimed to.
        public var missed: [(change: StyleChange, reason: String)]

        public var isComplete: Bool { missed.isEmpty }

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.applied == rhs.applied
                && lhs.missed.map(\.change) == rhs.missed.map(\.change)
                && lhs.missed.map(\.reason) == rhs.missed.map(\.reason)
        }
    }

    /// The rule in the new document that a change belongs to, if it survived.
    public static func match(_ change: StyleChange, in rules: [MatchedRule]) -> MatchedRule? {
        // The style attribute has no selector to match on; it belongs to the
        // element, and the element is identified separately.
        if change.selector == "element.style" {
            return rules.first { $0.isStyleAttribute }
        }

        let candidates = rules.filter { rule in
            !rule.isStyleAttribute
                && rule.selector == change.selector
                && rule.sourceLabel == change.sourceLabel
                && rule.conditions == change.conditions
                && rule.layer == change.layer
        }
        // Ambiguity is resolved by taking the first in document order, which is
        // the same rule the edit was made against when a page repeats a
        // selector — the alternative is refusing to replay anything on pages
        // that do, which is most of them.
        return candidates.min { $0.sourceOrder < $1.sourceOrder }
    }

    /// Works out what can come back and what can't, without applying anything.
    public static func plan(_ changeset: StyleChangeset, against rules: [MatchedRule]) -> Outcome {
        var applied: [StyleChange] = []
        var missed: [(StyleChange, String)] = []

        for change in changeset.changes {
            guard let rule = match(change, in: rules) else {
                missed.append((change, "its rule is no longer in the page"))
                continue
            }
            // An addition needs no existing declaration; everything else does.
            if change.kind != .added,
               !rule.declarations.contains(where: { $0.name == change.property }) {
                missed.append((change, "the \(change.property) declaration is gone"))
                continue
            }
            applied.append(change)
        }
        return Outcome(applied: applied, missed: missed)
    }

    /// The declaration block for a rule with a set of changes applied.
    public static func text(for rule: MatchedRule, applying changes: [StyleChange]) -> String {
        var declarations = rule.declarations
        var appended: [CSSDeclaration] = []

        for change in changes where change.property.isEmpty == false {
            guard let updated = change.updated else {
                // A removal: the declaration simply isn't in the block.
                declarations.removeAll { $0.name == change.property }
                continue
            }
            if let index = declarations.firstIndex(where: { $0.name == change.property }) {
                declarations[index].value = updated
                declarations[index].isImportant = change.isImportant
            } else {
                appended.append(CSSDeclaration(
                    index: declarations.count + appended.count,
                    name: change.property, value: updated, isImportant: change.isImportant
                ))
            }
        }

        return (declarations + appended).map(\.text).joined(separator: "; ")
    }
}
