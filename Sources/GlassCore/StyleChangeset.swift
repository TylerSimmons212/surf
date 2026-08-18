import Foundation

/// One property that ended up different from how the page shipped it.
///
/// A *net* difference, not an event. Nudging a value twelve times is one
/// change, and nudging it back to where it started is none — because the thing
/// this exists to produce is the patch you apply in your editor, and a keystroke
/// log is not that.
public struct StyleChange: Sendable, Equatable, Identifiable {
    public var ruleId: Int
    /// `.btn` — or `element.style` for the style attribute.
    public var selector: String
    public var sourceLabel: String
    public var layer: String?
    public var conditions: [String]
    public var property: String
    /// Nil when the declaration wasn't there before: this is an addition.
    public var original: String?
    /// Nil when the declaration is gone now: a removal, or one switched off.
    public var updated: String?
    public var wasImportant: Bool
    public var isImportant: Bool
    /// Filled in after the edit lands, from what the page resolved the new
    /// value to — the colour of `oklch(...)` isn't knowable until then.
    public var updatedColor: CSSColor?

    public var id: String { "\(ruleId).\(property)" }

    public init(
        ruleId: Int,
        selector: String,
        sourceLabel: String = "",
        layer: String? = nil,
        conditions: [String] = [],
        property: String,
        original: String?,
        updated: String?,
        wasImportant: Bool = false,
        isImportant: Bool = false,
        updatedColor: CSSColor? = nil
    ) {
        self.ruleId = ruleId
        self.selector = selector
        self.sourceLabel = sourceLabel
        self.layer = layer
        self.conditions = conditions
        self.property = property
        self.original = original
        self.updated = updated
        self.wasImportant = wasImportant
        self.isImportant = isImportant
        self.updatedColor = updatedColor
    }

    public enum Kind: Sendable, Equatable {
        case added, removed, changed
    }

    public var kind: Kind {
        if original == nil { return .added }
        if updated == nil { return .removed }
        return .changed
    }

    /// Back where it started, so it isn't a change at all.
    public var isNoOp: Bool {
        original == updated && wasImportant == isImportant
    }

    /// `color: red !important`
    public var declarationText: String {
        guard let updated else { return "" }
        return "\(property): \(updated)\(isImportant ? " !important" : "")"
    }

    public var originalText: String {
        guard let original else { return "" }
        return "\(property): \(original)\(wasImportant ? " !important" : "")"
    }
}

/// Everything the session has altered, in one place.
///
/// The gap this closes is the reason devtools editing feels disposable: you
/// spend twenty minutes finding the right four values, and then the only record
/// of them is pixels on a screen you have to read back by hand. Collecting the
/// net difference turns fiddling into something you can paste.
public struct StyleChangeset: Sendable, Equatable {

    /// Keyed so a second edit of the same property replaces the first rather
    /// than stacking. This is what makes the result a diff rather than a log.
    private var entries: [String: StyleChange] = [:]
    /// Insertion order, so the list reads in the order the work happened.
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public var changes: [StyleChange] {
        order.compactMap { entries[$0] }
    }

    /// Records an edit, keeping the *earliest* original and the latest value.
    ///
    /// Keeping the earliest original is the whole trick: after three edits the
    /// interesting comparison is still against what the page shipped, not
    /// against the previous keystroke.
    public mutating func record(_ change: StyleChange) {
        var merged = change
        if let existing = entries[change.id] {
            merged.original = existing.original
            merged.wasImportant = existing.wasImportant
        }
        if merged.isNoOp {
            // Edited back to where it started. Leaving a "changed nothing" row
            // in the list would be worse than useless — you'd copy it.
            entries.removeValue(forKey: merged.id)
            order.removeAll { $0 == merged.id }
            return
        }
        if entries[merged.id] == nil { order.append(merged.id) }
        entries[merged.id] = merged
    }

    /// Picks up the colours the page resolved for the new values.
    ///
    /// A separate pass because the answer doesn't exist at the moment of the
    /// edit: what `oklch(0.7 0.1 200)` looks like is known only once the engine
    /// has been handed it.
    public mutating func refreshColors(from rules: [MatchedRule]) {
        for rule in rules {
            for declaration in rule.declarations {
                let key = "\(rule.id).\(declaration.name)"
                guard var change = entries[key] else { continue }
                change.updatedColor = declaration.segments.compactMap(\.color).first
                entries[key] = change
            }
        }
    }

    /// Forgets everything about one rule — what reverting it means.
    public mutating func clear(ruleId: Int) {
        let doomed = order.filter { entries[$0]?.ruleId == ruleId }
        for key in doomed { entries.removeValue(forKey: key) }
        order.removeAll { doomed.contains($0) }
    }

    public mutating func clear() {
        entries.removeAll()
        order.removeAll()
    }

    // MARK: - Grouping

    public struct RuleGroup: Sendable, Equatable, Identifiable {
        public var ruleId: Int
        public var selector: String
        public var sourceLabel: String
        public var layer: String?
        public var conditions: [String]
        public var changes: [StyleChange]

        public var id: Int { ruleId }
    }

    public struct SourceGroup: Sendable, Equatable, Identifiable {
        public var sourceLabel: String
        public var rules: [RuleGroup]

        public var id: String { sourceLabel }
        public var count: Int { rules.reduce(0) { $0 + $1.changes.count } }
    }

    /// By stylesheet, then by rule — the shape of the files you're about to go
    /// and edit, rather than the order you happened to click in.
    public var grouped: [SourceGroup] {
        var sourceOrder: [String] = []
        var ruleOrder: [String: [Int]] = [:]
        var rules: [Int: RuleGroup] = [:]

        for change in changes {
            let source = change.sourceLabel.isEmpty ? "element" : change.sourceLabel
            if ruleOrder[source] == nil { sourceOrder.append(source) }
            if rules[change.ruleId] == nil {
                ruleOrder[source, default: []].append(change.ruleId)
                rules[change.ruleId] = RuleGroup(
                    ruleId: change.ruleId,
                    selector: change.selector,
                    sourceLabel: source,
                    layer: change.layer,
                    conditions: change.conditions,
                    changes: []
                )
            }
            rules[change.ruleId]?.changes.append(change)
        }

        return sourceOrder.map { source in
            SourceGroup(
                sourceLabel: source,
                rules: (ruleOrder[source] ?? []).compactMap { rules[$0] }
            )
        }
    }

    // MARK: - Output

    /// The changes as CSS you can paste into a stylesheet.
    ///
    /// Nested back inside the `@media`, `@supports` and `@layer` they were
    /// found in, because a declaration lifted out of its condition is not the
    /// same declaration — pasting it unwrapped would apply it everywhere.
    public var cssPatch: String {
        var out: [String] = []

        for source in grouped {
            out.append("/* \(source.sourceLabel) */")
            for rule in source.rules {
                var depth = 0
                var block: [String] = []

                func line(_ text: String) {
                    block.append(String(repeating: "  ", count: depth) + text)
                }

                for condition in rule.conditions {
                    line("\(condition) {")
                    depth += 1
                }
                if let layer = rule.layer {
                    line("@layer \(layer) {")
                    depth += 1
                }

                line("\(rule.selector) {")
                depth += 1
                for change in rule.changes {
                    switch change.kind {
                    case .added:
                        line("\(change.declarationText);")
                    case .changed:
                        line("\(change.declarationText); /* was \(change.original ?? "") */")
                    case .removed:
                        // Commented rather than omitted: "delete this line" is
                        // itself part of the patch, and silently dropping it
                        // would make the diff look shorter than it is.
                        line("/* remove: \(change.originalText); */")
                    }
                }
                depth -= 1
                line("}")

                if rule.layer != nil { depth -= 1; line("}") }
                for _ in rule.conditions { depth -= 1; line("}") }

                out.append(contentsOf: block)
            }
            out.append("")
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// "3 changes in 2 rules" — the one-line summary a button can carry.
    public var summary: String {
        let ruleCount = Set(changes.map(\.ruleId)).count
        let changeWord = count == 1 ? "change" : "changes"
        let ruleWord = ruleCount == 1 ? "rule" : "rules"
        return "\(count) \(changeWord) in \(ruleCount) \(ruleWord)"
    }
}
