import SurfCore
import SwiftUI

/// The rules that reach the element, in three groups.
///
/// Split out of `StylesPane`, which had grown to just under a thousand lines
/// — long enough that the cascade work about to land on it would have been
/// unreviewable as a diff.
struct RuleSections: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let filter: String

    var body: some View {
        let own = styles.rules.filter { !$0.isInherited }
        let inherited = styles.rules.filter(\.isInherited)

        if own.isEmpty && inherited.isEmpty && styles.stateRules.isEmpty {
            Text("No rules reach this element.")
                .font(DevToolsTheme.chrome)
                .foregroundStyle(.secondary)
        }

        ForEach(visible(own)) { rule in
            RuleCard(session: session, styles: styles, rule: rule, filter: filter)
        }

        // Grouped by which ancestor supplied them, nearest first, because
        // "inherited from" is the answer to a different question than "matched".
        ForEach(inheritedGroups(inherited), id: \.label) { group in
            SectionLabel(
                text: "Inherited from \(group.label)",
                symbol: "arrow.down.to.line"
            )
            ForEach(group.rules) { rule in
                RuleCard(session: session, styles: styles, rule: rule, filter: filter)
            }
        }

        let states = visible(styles.stateRules)
        if !states.isEmpty {
            SectionLabel(
                text: "Only in a state you're not in",
                symbol: "cursorarrow.motionlines"
            )
            ForEach(states) { rule in
                RuleCard(session: session, styles: styles, rule: rule, filter: filter)
            }
        }

        // Said plainly rather than left to be discovered as a wrong answer.
        // WebKit exposes no user-agent stylesheet through the CSSOM at all, so
        // a browser default that beats a page rule — a button's own font, say —
        // is a fight this list cannot show. Computed is still the truth.
        if !visible(own).isEmpty || !inherited.isEmpty || !states.isEmpty {
            Text("Browser default rules aren't listed — WebKit doesn't expose them.")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    /// A rule with nothing matching the filter is hidden entirely — but a rule
    /// is never hidden because its *selector* didn't match, only because none
    /// of its declarations did.
    private func visible(_ rules: [MatchedRule]) -> [MatchedRule] {
        // An inherited rule whose properties don't inherit reaches nothing.
        // The style attribute stays even when empty: its card is where "add
        // a declaration to just this element" lives, and the agent now emits
        // it for every inspected element for exactly that reason.
        let reaching = rules.filter {
            $0.isStyleAttribute || $0.isInspectorRule || $0.hasVisibleDeclarations
        }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return reaching }
        return reaching.filter { rule in
            rule.selector.lowercased().contains(needle)
                || rule.displayDeclarations.contains {
                    $0.name.lowercased().contains(needle)
                        || $0.value.lowercased().contains(needle)
                }
        }
    }

    private func inheritedGroups(_ rules: [MatchedRule]) -> [(label: String, rules: [MatchedRule])] {
        var order: [String] = []
        var buckets: [String: [MatchedRule]] = [:]
        for rule in visible(rules) {
            let label = rule.inheritedLabel ?? "an ancestor"
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(rule)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct SectionLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

struct RuleCard: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let rule: MatchedRule
    let filter: String

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if !rule.conditions.isEmpty || rule.layer != nil { context }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(rule.displayDeclarations) { declaration in
                    DeclarationRow(
                        session: session,
                        styles: styles,
                        rule: rule,
                        declaration: declaration
                    )
                }

                // Only where typing would do something you can see: an
                // inherited rule belongs to an ancestor, and a state rule
                // isn't currently applying — adding into either is a write
                // you then have to go hunting for.
                if rule.isActive, !rule.isInherited {
                    AddDeclarationRow(session: session, rule: rule)
                }
            }
            .padding(.leading, DevToolsTheme.indent)
            .padding(.top, 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(rule.isActive ? DevToolsTheme.inputFill : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .strokeBorder(
                    rule.isActive
                        ? Color.primary.opacity(isHovering ? 0.10 : 0.05)
                        : Color.primary.opacity(0.10),
                    style: StrokeStyle(
                        lineWidth: 0.5,
                        // A dashed edge for a rule that isn't applying: it reads
                        // as provisional at a glance, before any label is read.
                        dash: rule.isActive ? [] : [3, 2]
                    )
                )
        }
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(rule.isStyleAttribute ? "element.style" : rule.selector)
                .font(DevToolsTheme.mono)
                .foregroundStyle(
                    rule.isStyleAttribute ? ElementsStyle.attributeColor : StylesStyle.selector
                )
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)

            if !rule.states.isEmpty {
                ForEach(rule.states, id: \.self) { state in
                    Text(state)
                        .font(.system(size: 9, weight: .semibold).monospaced())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                        }
                }
            }

            // Applying, but only because the strip says so — worth a badge,
            // or the pane would claim the page always looks like this.
            if rule.isForced {
                Text("forced")
                    .font(DevToolsTheme.badge)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background { Capsule().fill(Color.orange.opacity(0.12)) }
                    .help("Applying because its state is simulated in the :hov strip")
            }

            Spacer(minLength: 6)

            if !rule.isStyleAttribute {
                SpecificityBadge(specificity: rule.specificity)
            }

            Text(rule.sourceLabel)
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(rule.href ?? "inline <style> block")
        }
    }

    private var context: some View {
        HStack(spacing: 5) {
            if let layer = rule.layer {
                Label(layer, systemImage: "square.3.layers.3d")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(StylesStyle.layer)
                    .help("@layer \(layer)")
            }
            ForEach(rule.conditions, id: \.self) { condition in
                Text(condition)
                    .font(DevToolsTheme.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
