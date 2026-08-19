import SurfCore
import SwiftUI

/// Every property's final value, after the cascade has finished arguing.
struct ComputedList: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let filter: String
    let authoredOnly: Bool

    var body: some View {
        let variables = session.stylePayload?.variables ?? [:]

        if !variables.isEmpty {
            SectionLabel(text: "Custom properties", symbol: "number")
            ForEach(variables.keys.sorted().filter(matches), id: \.self) { name in
                ComputedRow(
                    name: name, value: variables[name] ?? "",
                    trace: styles.traces[name], session: session, isVariable: true
                )
            }
        }

        SectionLabel(
            text: authoredOnly ? "Set by a rule" : "All computed values",
            symbol: "list.bullet"
        )

        let names = properties
        if names.isEmpty {
            Text(session.computed.isEmpty ? "Reading…" : "Nothing matches.")
                .font(DevToolsTheme.chrome)
                .foregroundStyle(.secondary)
        }
        ForEach(names, id: \.self) { name in
            ComputedRow(
                name: name, value: session.computed[name] ?? "",
                trace: styles.traces[name], session: session, isVariable: false
            )
        }
    }

    private var properties: [String] {
        let declared = styles.declaredProperties
        return session.computed.keys
            .filter { !$0.hasPrefix("--") }
            .filter { !authoredOnly || declared.contains($0) }
            .filter(matches)
            .sorted()
    }

    private func matches(_ name: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || (session.computed[name] ?? "").lowercased().contains(needle)
    }
}

struct ComputedRow: View {
    let name: String
    let value: String
    let trace: PropertyTrace?
    let session: DevToolsSession
    let isVariable: Bool

    @State private var isHovering = false
    @State private var isTracing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .foregroundStyle(isVariable ? StylesStyle.variable : ElementsStyle.attributeColor)
                    // Wide enough for `border-bottom-left-radius`, because the
                    // part that distinguishes one longhand from its siblings is
                    // in the middle, where truncation eats it.
                    .frame(width: 185, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let swatch = session.computedColors[name] {
                    ColorSwatch(color: swatch)
                        .padding(.trailing, 3)
                }

                Text(value)
                    .foregroundStyle(ElementsStyle.valueColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let trace, trace.isContested {
                    Text("\(trace.entries.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isTracing ? Color.accentColor : .secondary)
                        .padding(.horizontal, 4)
                        .background { Capsule().fill(DevToolsTheme.hoverFill) }
                        .help("\(trace.entries.count) rules set this")
                }
            }
            .font(DevToolsTheme.mono)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovering ? DevToolsTheme.hoverFill : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture {
                guard trace != nil else { return }
                withAnimation(.easeOut(duration: 0.14)) { isTracing.toggle() }
            }

            if isTracing, let trace {
                CascadeTraceCard(trace: trace)
                    .padding(.vertical, 4)
            }
        }
    }
}
