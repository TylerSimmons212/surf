import SurfCore
import SwiftUI

/// What the element's text is actually set in — the used family said plainly,
/// the stack shown as the audition it is, and the page's webfonts with their
/// load status.
///
/// The stack chips are the point. `font-family` is a wish list, and every
/// pane that prints it as a string leaves the reader to guess which wish came
/// true. Here the family that renders is marked, the ones that aren't
/// installed are dimmed and struck, and a webfont that failed to load shows
/// its status instead of silently being the reason the page looks wrong.
struct FontsCard: View {
    let report: FontReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headline
            if report.stack.count > 1 || !(report.stack.first?.isAvailable ?? true) {
                stackChips
            }
            if !report.webfonts.isEmpty {
                webfontList
            }
        }
        .padding(DevToolsTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.cardCorner, style: .continuous)
                .fill(DevToolsTheme.cardFill)
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(report.used.isEmpty ? "unknown family" : report.used)
                .font(DevToolsTheme.prose.weight(.medium))
                // The page's own approximation, honestly labeled: fallback
                // happens per glyph, and a missing character borrows from
                // the next family down where no page script can see it.
                .help(
                    "Resolved by probing the font stack. Individual characters "
                    + "the family lacks fall back further — that part isn't "
                    + "visible from page script."
                )

            Text("\(report.size) · \(report.weight)\(styleSuffix)")
                .font(DevToolsTheme.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)
        }
    }

    private var styleSuffix: String {
        report.style == "normal" || report.style.isEmpty ? "" : " · \(report.style)"
    }

    private var stackChips: some View {
        FlowLayout(spacing: 3, rowSpacing: 3) {
            ForEach(Array(report.stack.enumerated()), id: \.offset) { _, entry in
                let isUsed = entry.family == report.used
                Text(entry.family)
                    .font(DevToolsTheme.caption.monospaced())
                    .strikethrough(!entry.isAvailable, color: .secondary.opacity(0.6))
                    .foregroundStyle(
                        isUsed
                            ? AnyShapeStyle(Color.accentColor)
                            : entry.isAvailable
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.tertiary)
                    )
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        Capsule().fill(
                            isUsed
                                ? DevToolsTheme.selectedFill
                                : DevToolsTheme.hoverFill
                        )
                    }
                    .help(chipHelp(entry, isUsed: isUsed))
            }
        }
    }

    private func chipHelp(_ entry: FontReport.StackEntry, isUsed: Bool) -> String {
        if isUsed { return "This family renders the text" }
        if entry.isGeneric { return "Generic family — always resolves" }
        return entry.isAvailable
            ? "Available, but a family earlier in the stack won"
            : "Not available here — the stack falls past it"
    }

    private var webfontList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Webfonts on this page")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
            ForEach(Array(report.webfonts.enumerated()), id: \.offset) { _, font in
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(font.status))
                        .frame(width: 5, height: 5)
                        .help(font.status)
                    Text(font.family)
                        .font(DevToolsTheme.caption.monospaced())
                    Text("\(font.weight)\(font.style == "normal" ? "" : " \(font.style)")")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "loaded": .green
        case "loading": .orange
        case "error": .red
        default: .secondary
        }
    }
}
