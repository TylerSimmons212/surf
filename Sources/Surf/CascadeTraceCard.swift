import SurfCore
import SwiftUI

/// One property, every declaration that tried to set it, and the reason each
/// one lost.
///
/// The thing no browser will tell you. Chrome and Safari both draw a line
/// through the loser and stop there — which is the *observation*, not the
/// answer. "Lost on specificity", "lost on order" and "lost because the winner
/// is in a later layer" are three different problems with three different
/// fixes, and today you tell them apart by reading every rule in the pane and
/// running the cascade in your head. Adding a class to beat a rule that
/// actually beat you on `!important` is a wasted ten minutes that this card
/// exists to prevent.
struct CascadeTraceCard: View {
    let trace: PropertyTrace
    let session: DevToolsSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(trace.entries.enumerated()), id: \.element.id) { index, entry in
                TraceRow(
                    entry: entry,
                    isFirst: index == 0,
                    isLast: index == trace.entries.count - 1
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(trace.property)
                .font(DevToolsTheme.mono.weight(.semibold))
                .foregroundStyle(ElementsStyle.attributeColor)
            Text("set \(trace.entries.count) times")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.bottom, 4)
    }
}

private struct TraceRow: View {
    let entry: TraceEntry
    let isFirst: Bool
    let isLast: Bool

    @State private var isHovering = false

    private var isWinner: Bool { entry.outcome.isWinner }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            rail
            VStack(alignment: .leading, spacing: 1) {
                valueLine
                reasonLine
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovering ? DevToolsTheme.hoverFill : .clear)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Selector") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.selector, forType: .string)
            }
        }
    }

    /// A filled dot for the winner, hollow for the rest, joined by a line —
    /// so the shape of the fight reads before a single word does.
    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : Color.primary.opacity(0.12))
                .frame(width: 1, height: 5)
            Circle()
                .fill(isWinner ? Color.accentColor : Color.clear)
                .overlay {
                    Circle().strokeBorder(
                        isWinner ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1
                    )
                }
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(isLast ? Color.clear : Color.primary.opacity(0.12))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 6)
    }

    private var valueLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(entry.value)
                .font(DevToolsTheme.mono)
                .foregroundStyle(isWinner ? ElementsStyle.valueColor : Color.secondary)
                .strikethrough(!isWinner, color: .secondary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)

            if entry.isImportant {
                Text("!important")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StylesStyle.important)
            }

            Text(entry.selector)
                .font(DevToolsTheme.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !entry.isStyleAttribute {
                SpecificityBadge(specificity: entry.specificity, compact: true)
            }
        }
    }

    private var reasonLine: some View {
        HStack(spacing: 4) {
            if let inherited = entry.inheritedLabel {
                Label(inherited, systemImage: "arrow.down.to.line")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let layer = entry.layer {
                Label(layer, systemImage: "square.3.layers.3d")
                    .font(.system(size: 9))
                    .foregroundStyle(StylesStyle.layer)
            }
            Text(entry.outcome.explanation)
                .font(.system(size: 10))
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
