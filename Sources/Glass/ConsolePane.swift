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
                        ConsoleRow(entry: entry)
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
    let entry: ConsoleEntry

    @State private var isHovering = false

    var body: some View {
        switch entry.kind {
        case .navigation(let url):
            navigationDivider(url)
        case .message:
            message
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

    private var arguments: some View {
        // Wrapping rather than a horizontal stack: a long log line should read
        // like a paragraph, not scroll sideways.
        Text(rendered)
            .font(.system(size: 11.5).monospaced())
            .foregroundStyle(ConsoleStyle.textColor(for: entry.level))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                entry.level.isProblem
                    ? ConsoleStyle.color(for: entry.level).opacity(0.07)
                    : (isHovering ? Color.primary.opacity(0.04) : .clear)
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
