import SurfCore
import SwiftUI

/// The blank line at the bottom of a rule — where a declaration that doesn't
/// exist yet gets typed into existence.
///
/// Every inspector has this and Surf didn't, which made the Styles pane
/// read-mostly in a way nobody advertises: you could change any value on the
/// page but never say a new thing about it. The affordance is a visible row
/// rather than Chrome's click-the-blank-space, because an invisible feature
/// is a feature for people who already know it's there.
///
/// Property names complete from the engine's own vocabulary
/// (`CSS.propertyNames`), ranked by `CSSPropertyCompletion` — prefix matches
/// first, shorthands before their longhands, `-webkit-` sunk unless the dash
/// was typed.
struct AddDeclarationRow: View {
    let session: DevToolsSession
    let rule: MatchedRule

    private enum Field { case name, value }

    @State private var isAdding = false
    @State private var name = ""
    @State private var value = ""
    /// Which completion the arrow keys have reached; nil means none taken.
    @State private var picked: Int?
    /// The engine looked at the finished declaration and shrugged.
    @State private var rejected: String?
    @State private var isHovering = false
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isAdding { editor } else { invitation }
            if let rejected {
                Text("The engine didn't accept \u{201C}\(rejected)\u{201D}")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - At rest

    private var invitation: some View {
        Button {
            begin()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(DevToolsTheme.badge)
                Text("declaration")
                    .font(DevToolsTheme.caption)
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Add a declaration to \(rule.isStyleAttribute ? "this element" : rule.selector)")
    }

    // MARK: - Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                field($name, placeholder: "property", focused: .name)
                    .frame(minWidth: 60, maxWidth: 180)
                    .onKeyPress(keys: [.downArrow, .upArrow], phases: .down) { press in
                        move(press.key == .downArrow ? 1 : -1)
                    }
                    .onKeyPress(.tab) { acceptCompletionIfAny() }
                    .onSubmit {
                        _ = acceptCompletionIfAny()
                        focus = .value
                    }

                Text(": ")
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(.tertiary)

                field($value, placeholder: "value", focused: .value)
                    .frame(minWidth: 80, maxWidth: 260)
                    .onSubmit { commit() }
            }

            if focus == .name, !completions.isEmpty {
                suggestions
            }
        }
        .onExitCommand { cancel() }
        .onAppear { session.loadPropertyNamesIfNeeded() }
    }

    private func field(
        _ text: Binding<String>, placeholder: String, focused: Field
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(DevToolsTheme.mono)
            .focused($focus, equals: focused)
            .onChange(of: text.wrappedValue) { _, _ in
                rejected = nil
                if focused == .name { picked = nil }
            }
            .padding(.horizontal, 3)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DevToolsTheme.inputFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        focus == focused
                            ? Color.accentColor.opacity(0.5)
                            : Color.clear,
                        lineWidth: 0.5
                    )
            }
    }

    // MARK: - Completion

    private var completions: [String] {
        CSSPropertyCompletion.matches(name, in: session.cssPropertyNames)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.enumerated()), id: \.element) { index, candidate in
                Button {
                    take(candidate)
                } label: {
                    Text(candidate)
                        .font(DevToolsTheme.mono)
                        .foregroundStyle(index == picked ? Color.accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if index == picked {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(DevToolsTheme.selectedFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let list = completions
        guard !list.isEmpty else { return .ignored }
        let current = picked ?? -1
        picked = min(max(current + delta, 0), list.count - 1)
        return .handled
    }

    private func acceptCompletionIfAny() -> KeyPress.Result {
        let list = completions
        guard !list.isEmpty else { return .ignored }
        take(list[picked ?? 0])
        return .handled
    }

    private func take(_ candidate: String) {
        name = candidate
        picked = nil
        focus = .value
    }

    // MARK: - Lifecycle

    private func begin() {
        session.loadPropertyNamesIfNeeded()
        isAdding = true
        rejected = nil
        focus = .name
    }

    private func commit() {
        let property = name.trimmingCharacters(in: .whitespaces)
        let newValue = value.trimmingCharacters(in: .whitespaces)
        guard !property.isEmpty, !newValue.isEmpty else { cancel(); return }

        Task { @MainActor in
            if await session.addDeclaration(property, newValue, to: rule) {
                // Straight into the next one, because additions come in runs —
                // a display, then its flex-direction, then its gap. Escape or
                // clicking away ends the run.
                name = ""
                value = ""
                picked = nil
                rejected = nil
                focus = .name
            } else {
                rejected = "\(property): \(newValue)"
            }
        }
    }

    private func cancel() {
        isAdding = false
        name = ""
        value = ""
        picked = nil
        rejected = nil
        focus = nil
    }
}
