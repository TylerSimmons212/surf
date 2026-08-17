import GlassCore
import SwiftUI

/// The console: a filter bar and the log.
struct ConsolePane: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            log
            Divider()
            ConsolePrompt(session: session)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            IconButton(
                systemName: "trash",
                size: 11,
                weight: .medium,
                width: 24,
                height: 22,
                cornerRadius: 6,
                isEnabled: !session.console.isEmpty,
                help: "Clear Console"
            ) {
                session.clearConsole()
            }

            Divider().frame(height: 14)

            ForEach(ConsoleLevel.allCases, id: \.self) { level in
                LevelChip(
                    level: level,
                    count: session.consoleCounts[level] ?? 0,
                    isOn: session.consoleLevels.contains(level)
                ) {
                    session.toggleConsoleLevel(level)
                }
            }

            Spacer(minLength: 8)

            Toggle("Preserve log", isOn: $session.preservesLogOnNavigation)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Keep output across page loads instead of clearing it")

            searchField
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Filter", text: $session.consoleQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 120)

            if !session.consoleQuery.isEmpty {
                IconButton(
                    systemName: "xmark.circle.fill",
                    size: 10,
                    weight: .medium,
                    width: 16,
                    height: 16,
                    cornerRadius: 8,
                    help: "Clear filter"
                ) {
                    session.consoleQuery = ""
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    // MARK: - Log

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.visibleConsoleEntries) { entry in
                        ConsoleRow(session: session, entry: entry)
                            .id(entry.id)
                    }
                    // An anchor rather than scrolling to the last row: the last
                    // row changes identity when a repeat folds into it, and
                    // scrolling to a moving target stutters.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .overlay {
                if session.visibleConsoleEntries.isEmpty { emptyState }
            }
            .onChange(of: session.console.entries.count) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "glass.console.bottom"

    @ViewBuilder
    private var emptyState: some View {
        if session.isConsoleFiltered && !session.console.isEmpty {
            // Said explicitly, because an empty console under an active filter
            // otherwise reads as "the page stopped logging".
            DevToolsPlaceholder(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No matching output",
                detail: "\(session.console.entries.count) hidden by the current filter."
            )
        } else {
            DevToolsPlaceholder(
                symbol: "terminal",
                title: "No output yet",
                detail: "Messages, errors and failed requests appear here."
            )
        }
    }
}

// MARK: - Rows

private struct LevelChip: View {
    let level: ConsoleLevel
    let count: Int
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: isOn ? .medium : .regular))
                if count > 0 {
                    Text(count > 999 ? "999+" : "\(count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(count > 0 && level.isProblem ? tint : .secondary)
                }
            }
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isOn ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
    }

    private var fill: Color {
        if isOn { return tint.opacity(level.isProblem ? 0.16 : 0.10) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    private var label: String {
        switch level {
        case .debug: "Debug"
        case .log: "Logs"
        case .info: "Info"
        case .warning: "Warnings"
        case .error: "Errors"
        }
    }

    private var tint: Color { ConsoleStyle.color(for: level) }
}

private struct ConsoleRow: View {
    let session: DevToolsSession
    let entry: ConsoleEntry

    @State private var isHovering = false

    var body: some View {
        switch entry.kind {
        case .navigation(let url):
            navigationDivider(url)
        case .message, .input, .result:
            message
        }
    }

    /// A chevron for what you typed, and one pointing back for the answer, so
    /// the log reads as a conversation rather than a stream of unattributed
    /// values.
    private var promptGlyph: String? {
        switch entry.kind {
        case .input: "chevron.right"
        case .result: "chevron.left"
        default: nil
        }
    }

    private func navigationDivider(_ url: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            Text(url)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 6) {
            // A coloured bar rather than a glyph per row: at a glance the shape
            // of the log is what matters, and forty icons is noise.
            Rectangle()
                .fill(ConsoleStyle.color(for: entry.level))
                .frame(width: 2)
                .opacity(entry.level.isProblem ? 1 : 0)

            if let promptGlyph {
                Image(systemName: promptGlyph)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(entry.kind == .input ? Color.secondary : Color.accentColor)
                    .frame(width: 10)
            }

            if entry.repeatCount > 1 {
                Text("\(entry.repeatCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ConsoleStyle.color(for: entry.level).opacity(0.75)))
                    .help("This message repeated \(entry.repeatCount) times")
            }

            arguments
                .padding(.leading, CGFloat(entry.groupDepth) * 14)

            Spacer(minLength: 8)

            if let frame = entry.frameLabel {
                Image(systemName: "square.on.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Logged from a subframe: \(frame)")
            }

            if let source = entry.source {
                Text(source.shortLabel)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("\(source.url):\(source.line):\(source.column)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if let source = entry.source {
                Button("Copy Source Location") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "\(source.url):\(source.line):\(source.column)", forType: .string
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var arguments: some View {
        if entry.arguments.contains(where: { $0.objectId != nil }) {
            // At least one value can be opened, so each gets its own row with
            // its own disclosure rather than being flattened into a sentence.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entry.arguments.enumerated()), id: \.offset) { _, object in
                    RemoteObjectView(session: session, object: object)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Wrapping rather than a horizontal stack: a long log line should
            // read like a paragraph, not scroll sideways.
            Text(rendered)
                .font(.system(size: 11.5).monospaced())
                .foregroundStyle(ConsoleStyle.textColor(for: entry.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Top-level strings print bare; everything nested is quoted, so an array
    /// of strings can't be mistaken for an array of identifiers.
    private var rendered: String {
        entry.arguments.map { object in
            var text = object.description
            if let preview = object.preview, !preview.entries.isEmpty {
                text += " " + ConsoleStyle.previewText(preview, subtype: object.subtype)
            }
            return text
        }
        .joined(separator: " ")
    }

    private var background: some View {
        Rectangle()
            .fill(
                entry.kind == .input
                    ? Color.primary.opacity(0.04)
                    : (entry.level.isProblem
                        ? ConsoleStyle.color(for: entry.level).opacity(0.07)
                        : (isHovering ? Color.primary.opacity(0.04) : .clear))
            )
    }
}

enum ConsoleStyle {
    static func color(for level: ConsoleLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .log, .debug: .secondary
        }
    }

    /// Values are coloured by type, the way every console does it: strings
    /// read as data, numbers as quantities, and `null`/`undefined` recede.
    static func valueColor(for object: RemoteObject) -> Color {
        switch object.type {
        case .string: .init(red: 0.78, green: 0.28, blue: 0.24)
        case .number, .bigint: .init(red: 0.15, green: 0.35, blue: 0.75)
        case .boolean: .init(red: 0.45, green: 0.25, blue: 0.70)
        case .undefined: .secondary
        case .function: .init(red: 0.30, green: 0.45, blue: 0.30)
        case .symbol: .purple
        case .object: object.subtype == .null ? .secondary : .primary
        }
    }

    static func textColor(for level: ConsoleLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .debug: .secondary
        case .log, .info: .primary
        }
    }

    /// `{ name: "ada", … }` or `[1, 2, …]`, depending on what it is.
    static func previewText(_ preview: ObjectPreview, subtype: RemoteObjectSubtype?) -> String {
        let isList = subtype == .array || subtype == .set
        let body = preview.entries.map { entry in
            guard let key = entry.key else { return entry.value.quotedDescription }
            return "\(key): \(entry.value.quotedDescription)"
        }
        .joined(separator: ", ")

        let tail = preview.overflow ? (body.isEmpty ? "…" : ", …") : ""
        return isList ? "[\(body)\(tail)]" : "{\(body)\(tail)}"
    }
}


// MARK: - Prompt

/// The JavaScript prompt.
///
/// Uses `GlassTextField` rather than SwiftUI's, because the field editor eats
/// Return and the arrow keys before any SwiftUI handler sees them — and those
/// three keys *are* the interaction: submit, and walk back through history.
private struct ConsolePrompt: View {
    let session: DevToolsSession

    @State private var input = ""
    /// -1 means "at the prompt". Walking up moves into history; walking back
    /// down returns to whatever was half-typed.
    @State private var historyOffset = -1
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)

            GlassTextField(
                text: $input,
                placeholder: "Run JavaScript on this page",
                font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                selectsAllOnFocus: false,
                onSubmit: submit,
                onMove: recall,
                onCancel: { input = ""; historyOffset = -1 }
            )
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func submit() {
        let entry = input
        input = ""
        historyOffset = -1
        draft = ""
        Task { @MainActor in await session.evaluate(entry) }
    }

    /// Up walks back through what was typed; down walks forward and finally
    /// restores the half-written line you left behind.
    private func recall(_ direction: Int) {
        let history = session.inputHistory
        guard !history.isEmpty else { return }

        if historyOffset == -1 && direction < 0 { draft = input }

        let next = historyOffset + (direction < 0 ? 1 : -1)
        guard next >= -1, next < history.count else { return }
        historyOffset = next
        input = next == -1 ? draft : history[history.count - 1 - next]
    }
}
