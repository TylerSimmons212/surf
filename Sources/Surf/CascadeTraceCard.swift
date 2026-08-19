import AppKit
import SurfCore
import SwiftUI

/// One property, every declaration that tried to set it, and the reason each
/// one lost — drawn as a staircase.
///
/// The thing no browser will tell you. Chrome and Safari both draw a line
/// through the loser and stop there — which is the *observation*, not the
/// answer. "Lost on specificity", "lost on order" and "lost because the winner
/// is in a later layer" are three different problems with three different
/// fixes, and today you tell them apart by reading every rule in the pane and
/// running the cascade in your head. Adding a class to beat a rule that
/// actually beat you on `!important` is a wasted ten minutes that this card
/// exists to prevent.
///
/// What changed here is the *index*, not the information. This was a flat list
/// of rows with a dot-and-line rail down the side, which meant you read every
/// reason before you knew the shape of the fight. Now depth carries rank: the
/// winner sits flush, and each loser steps one level right in the order it
/// fell. You can see "four tried, this one won" before reading a word, which
/// is the part nobody should have to read.
///
/// `CascadeStack` decides how far the staircase steps and what happens past
/// the cap. That is a value type in the core with its own tests, because the
/// edge cases are real: a property set a dozen times would otherwise walk off
/// the right edge and take the reasons with it.
struct CascadeTraceCard: View {
    let trace: PropertyTrace

    @State private var isShowingRest = false

    private var stack: CascadeStack { CascadeStack(trace) }

    var body: some View {
        VStack(alignment: .leading, spacing: DevToolsTheme.cardGap) {
            header

            ForEach(stack.steps) { step in
                StepCard(step: step)
                    .padding(.leading, CGFloat(step.depth) * DevToolsTheme.indent)
            }

            if let summary = stack.hiddenSummary {
                foldLine(summary)
                if isShowingRest { rest }
            }
        }
        .padding(DevToolsTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.cardCorner, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
        }
    }

    /// States the outcome in a sentence before the staircase repeats it in
    /// shape — the property, what it ended up as, and how contested that was.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(trace.property)
                .font(DevToolsTheme.mono.weight(.semibold))
                .foregroundStyle(ElementsStyle.attributeColor)

            Text("is")
                .font(DevToolsTheme.prose)
                .foregroundStyle(.secondary)

            Text(trace.value)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.valueColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text("\(trace.entries.count) rules set it")
                .font(DevToolsTheme.prose)
                .foregroundStyle(.secondary)
        }
    }

    private func foldLine(_ summary: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isShowingRest.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isShowingRest ? "chevron.down" : "chevron.right")
                    .font(DevToolsTheme.badge)
                Text(summary)
                    .font(DevToolsTheme.prose)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(CascadeStack.maxDepth) * DevToolsTheme.indent)
        .help("Show the rest of the rules that set \(trace.property)")
    }

    /// The folded remainder, deliberately *not* drawn as more staircase.
    ///
    /// Indent means rank in this card, and these are past the point where
    /// indent can carry it. Stacking them flush at one level would claim they
    /// all tied; giving them their own flat group says what is true — they are
    /// the rest, in order, and the ordering is the list rather than the shape.
    private var rest: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(stack.hidden) { entry in
                StepCard(step: CascadeStack.Step(entry: entry, depth: -1))
            }
        }
        .padding(.leading, CGFloat(CascadeStack.maxDepth) * DevToolsTheme.indent)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// One tread of the staircase.
///
/// A `depth` of -1 means "outside the staircase" — one of the folded
/// remainder, drawn without the border so the group reads as a list rather
/// than as more steps.
private struct StepCard: View {
    let step: CascadeStack.Step

    @State private var isHovering = false

    private var entry: TraceEntry { step.entry }
    private var isWinner: Bool { step.isWinner }
    private var isInStaircase: Bool { step.depth >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            top
            reason
        }
        .padding(.horizontal, isInStaircase ? 8 : 4)
        .padding(.vertical, isInStaircase ? 5 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isInStaircase {
                RoundedRectangle(cornerRadius: DevToolsTheme.cardCorner, style: .continuous)
                    .fill(isWinner ? Color.accentColor.opacity(0.12) : DevToolsTheme.cardFill)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DevToolsTheme.hoverFill)
            }
        }
        .overlay {
            if isInStaircase {
                RoundedRectangle(cornerRadius: DevToolsTheme.cardCorner, style: .continuous)
                    .strokeBorder(
                        isWinner
                            ? Color.accentColor.opacity(0.35)
                            : DevToolsTheme.cardStroke,
                        lineWidth: 0.5
                    )
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Selector") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.selector, forType: .string)
            }
        }
    }

    private var top: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // A tick for the winner, nothing for the rest. The old rail drew a
            // hollow dot per loser, which spent a column on saying "also ran"
            // once for every row; the staircase already says that with shape.
            if isWinner {
                Image(systemName: "checkmark")
                    .font(DevToolsTheme.badge)
                    .foregroundStyle(Color.accentColor)
            }

            Text(entry.value)
                .font(DevToolsTheme.mono)
                .foregroundStyle(isWinner ? ElementsStyle.valueColor : Color.secondary)
                .strikethrough(!isWinner, color: .secondary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)

            if entry.isImportant {
                Text("!important")
                    .font(DevToolsTheme.badge)
                    .foregroundStyle(StylesStyle.important)
            }

            Text(entry.selector)
                .font(DevToolsTheme.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if !entry.isStyleAttribute {
                SpecificityBadge(specificity: entry.specificity, compact: true)
            }
        }
    }

    private var reason: some View {
        HStack(spacing: 4) {
            if let inherited = entry.inheritedLabel {
                Label(inherited, systemImage: "arrow.down.to.line")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.tertiary)
            }
            if let layer = entry.layer {
                Label(layer, systemImage: "square.3.layers.3d")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(StylesStyle.layer)
            }
            // The card's whole reason for existing. "Lost on specificity" and
            // "lost on order" are different problems with different fixes, so
            // that sentence is set as one.
            Text(entry.outcome.explanation)
                .font(DevToolsTheme.prose)
                .foregroundStyle(isWinner ? Color.accentColor : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `0-2-1`, with the leading zeros dimmed.
///
/// Worth the pixels because the comparison is lexicographic and not a sum —
/// eleven classes lose to one id — and that is the single most misremembered
/// rule in CSS. Neither Chrome nor Safari shows this number anywhere, so
/// working out which of two rules is heavier is done by eye, from the selector,
/// which is exactly the calculation people get wrong.
struct SpecificityBadge: View {
    let specificity: Specificity
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            component(specificity.ids, isLeading: specificity.ids == 0)
            separator
            component(
                specificity.classes,
                isLeading: specificity.ids == 0 && specificity.classes == 0
            )
            separator
            component(specificity.types, isLeading: false)
        }
        .font(.system(size: compact ? 9 : 9.5, weight: .medium).monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .background {
            Capsule().fill(DevToolsTheme.hoverFill)
        }
        .help("Specificity \(specificity.description) — ids, classes, elements")
    }

    private func component(_ value: Int, isLeading: Bool) -> some View {
        Text("\(value)")
            // A leading zero carries no information and shouldn't compete with
            // the digit that decides the comparison.
            .foregroundStyle(isLeading ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary))
    }

    private var separator: some View {
        Text("-").foregroundStyle(.quaternary)
    }
}
