import SurfCore
import SwiftUI

/// Everything you've altered this session, grouped by the file you'll go and
/// alter it in.
///
/// This closes the loop that makes devtools editing feel disposable. You spend
/// twenty minutes finding the right four values, and the only record of them is
/// pixels on a screen you then read back by hand into your editor — usually
/// missing one. Chrome's answer is Local Overrides, which is a lot of setup for
/// what should be "show me what I changed".
///
/// What's collected is the *net* difference, not a history: nudging a value
/// twelve times is one line, and nudging it back to where it started is none.
/// The output is meant to be pasted, so declarations stay nested inside the
/// `@media` and `@layer` they were found in — lifted out, they'd apply
/// everywhere.
struct ChangesList: View {
    @Bindable var session: DevToolsSession

    @State private var justCopied = false

    var body: some View {
        if session.changeset.isEmpty {
            DevToolsPlaceholder(
                symbol: "square.and.pencil",
                title: "No changes yet",
                detail: "Edit a value in Rules and it'll be collected here."
            )
            .frame(minHeight: 180)
        } else {
            header
            if session.didReplayEdits || !session.replayMisses.isEmpty { replayReport }
            ForEach(session.changeset.grouped) { source in
                SourceSection(source: source, session: session)
            }
            patch
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.changeset.summary)
                .font(DevToolsTheme.chrome.weight(.medium))

            Toggle("Keep on reload", isOn: $session.preservesStyleEditsOnReload)
                .toggleStyle(.checkbox)
                .font(DevToolsTheme.chrome)
                // Surf owns the browser, so this needs none of the setup
                // Chrome's Local Overrides asks for.
                .help("Re-apply these edits after reloading the same page")

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.changeset.cssPatch, forType: .string)
                withAnimation(.easeOut(duration: 0.12)) { justCopied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
                }
            } label: {
                Label(
                    justCopied ? "Copied" : "Copy as CSS",
                    systemImage: justCopied ? "checkmark" : "doc.on.doc"
                )
                .font(DevToolsTheme.chrome)
            }
            .buttonStyle(.borderless)

            Button("Revert All") {
                Task { @MainActor in await session.revertAll() }
            }
            .buttonStyle(.borderless)
            .font(DevToolsTheme.chrome)
        }
        .padding(.bottom, 2)
    }

    /// What happened when the edits were put back.
    ///
    /// Reported rather than assumed, because a page whose CSS changed under the
    /// edits will not take all of them — and an edit that quietly failed to
    /// return is worse than one that never claimed it would.
    private var replayReport: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: session.replayMisses.isEmpty
                    ? "arrow.clockwise.circle" : "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(session.replayMisses.isEmpty
                    ? "Edits re-applied after reload"
                    : "\(session.replayMisses.count) edit\(session.replayMisses.count == 1 ? "" : "s") couldn't be re-applied")
                    .font(DevToolsTheme.chrome.weight(.medium))
                Spacer(minLength: 4)
                Button("Dismiss") { session.dismissReplayReport() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(session.replayMisses.isEmpty ? Color.secondary : .orange)

            ForEach(session.replayMisses, id: \.property) { miss in
                Text("\(miss.selector) · \(miss.property) — \(miss.reason)")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(session.replayMisses.isEmpty
                    ? DevToolsTheme.inputFill : Color.orange.opacity(0.10))
        }
    }

    /// The patch itself, ready to paste. Shown rather than hidden behind the
    /// copy button, because reading it is how you decide whether it's right.
    private var patch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("As CSS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(session.changeset.cssPatch)
                .font(DevToolsTheme.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                        .fill(DevToolsTheme.inputFill)
                }
        }
        .padding(.top, 6)
    }
}

private struct SourceSection: View {
    let source: StyleChangeset.SourceGroup
    let session: DevToolsSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(source.sourceLabel)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(source.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
            .foregroundStyle(.secondary)

            ForEach(source.rules) { rule in
                RuleChanges(rule: rule, session: session)
            }
        }
    }
}

private struct RuleChanges: View {
    let rule: StyleChangeset.RuleGroup
    let session: DevToolsSession

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(rule.selector)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(StylesStyle.selector)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let layer = rule.layer {
                    Label(layer, systemImage: "square.3.layers.3d")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(StylesStyle.layer)
                }
                ForEach(rule.conditions, id: \.self) { condition in
                    Text(condition)
                        .font(DevToolsTheme.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isHovering {
                    Button("Revert") {
                        Task { @MainActor in await session.revertRule(id: rule.ruleId) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                }
            }

            ForEach(rule.changes) { change in
                ChangeRow(change: change)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
        .onHover { isHovering = $0 }
    }
}

private struct ChangeRow: View {
    let change: StyleChange

    var body: some View {
        // Spacing zero, with the gaps written into the strings: a declaration
        // reads as `name: value`, and stack spacing around the colon pushes it
        // off the name it belongs to.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The sign carries the kind, so the list scans the way a diff does
            // without needing a legend.
            Text(marker)
                .font(DevToolsTheme.mono.weight(.bold))
                .foregroundStyle(markerColor)
                .frame(width: 12, alignment: .leading)

            Text(change.property)
                .foregroundStyle(ElementsStyle.attributeColor)

            Text(": ")
                .foregroundStyle(.secondary)

            if let updated = change.updated {
                if let swatch = change.updatedColor {
                    ColorSwatch(color: swatch)
                        .padding(.trailing, 3)
                }
                Text(updated)
                    .foregroundStyle(ElementsStyle.valueColor)
                if change.isImportant {
                    Text(" !important")
                        .foregroundStyle(StylesStyle.important)
                }
            }

            if let original = change.original, change.kind != .added {
                Text(change.kind == .removed ? original : "  was \(original)")
                    .foregroundStyle(.tertiary)
                    .strikethrough(change.kind == .removed, color: .secondary)
            }

            Spacer(minLength: 4)
        }
        .font(DevToolsTheme.mono)
        .padding(.leading, 2)
    }

    private var marker: String {
        switch change.kind {
        case .added: "+"
        case .removed: "−"
        case .changed: "~"
        }
    }

    private var markerColor: Color {
        switch change.kind {
        case .added: ElementsStyle.valueColor
        case .removed: StylesStyle.important
        case .changed: Color.accentColor
        }
    }
}
