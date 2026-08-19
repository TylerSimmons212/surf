import SurfCore
import SwiftUI

/// One declaration: its name, its value, whether it is in force, and — for a
/// property more than one rule tried to set — the story of how it was decided.
struct DeclarationRow: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let rule: MatchedRule
    let declaration: CSSDeclaration

    @State private var isHovering = false
    @State private var isTracing = false
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var status: DeclarationStatus {
        styles.status(of: declaration, in: rule)
    }

    /// Which longhand's story to tell. A shorthand has several, so the one
    /// worth opening is the one that was actually contested.
    private var tracedProperty: String? {
        declaration.longhands.first { styles.traces[$0]?.isContested == true }
            ?? declaration.longhands.first { styles.traces[$0] != nil }
    }

    private var trace: PropertyTrace? {
        tracedProperty.flatMap { styles.traces[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isTracing, let trace {
                CascadeTraceCard(trace: trace, session: session)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                enableBox

                Text(declaration.name)
                    .foregroundStyle(nameColor)
                    .strikethrough(isStruck, color: .secondary)

                Text(": ")
                    .foregroundStyle(.secondary)

                value

                if declaration.isImportant {
                    Text(" !important")
                        .foregroundStyle(isStruck ? .secondary : StylesStyle.important)
                }

                Text(";")
                    .foregroundStyle(.secondary)

                if let resolved = resolvedVariable, !isEditing {
                    // `var(--brand)` on its own tells you nothing. What it came
                    // out as is the thing you opened the pane to find out.
                    Text(" \u{2192} \(resolved)")
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 6)

                if case .partiallyOverridden(let lost) = status, !isEditing {
                    partialBadge(lost)
                }
                if trace?.isContested == true, !isEditing {
                    whyButton
                }
            }
            .font(DevToolsTheme.mono)

            if isEditing { editingFooter }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovering && !isEditing ? DevToolsTheme.hoverFill : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Declaration") { copy(declaration.text) }
            Button("Copy Value") { copy(declaration.value) }
            if let rule = ruleText { Button("Copy Rule") { copy(rule) } }
            Divider()
            Button(declaration.isImportant ? "Remove !important" : "Mark !important") {
                Task { @MainActor in
                    await session.setImportant(!declaration.isImportant, of: declaration, in: rule)
                }
            }
            if session.editedRuleIds.contains(rule.id) {
                Button("Revert This Rule") {
                    Task { @MainActor in await session.revert(rule) }
                }
            }
        }
        .help(helpText)
    }

    private var isStruck: Bool { status == .overridden || isOff }
    private var isOff: Bool { session.isDisabled(declaration, in: rule) }

    /// Switching a declaration off is the fastest question you can ask a page:
    /// "what does this actually do?" It's a checkbox because that's what it is.
    @ViewBuilder
    private var enableBox: some View {
        if rule.isActive {
            Button {
                Task { @MainActor in await session.setEnabled(isOff, declaration, in: rule) }
            } label: {
                Image(systemName: isOff ? "square" : "checkmark.square.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isOff ? Color.secondary : Color.accentColor.opacity(0.75))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Reserved even when hidden, so nothing shifts under the pointer
            // as you move down a block.
            .opacity(isHovering || isOff ? 1 : 0)
            .help(isOff ? "Turn this declaration back on" : "Turn this declaration off")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    @ViewBuilder
    private var value: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(DevToolsTheme.mono)
                .focused($isFocused)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .padding(.horizontal, 3)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DevToolsTheme.inputFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 0.5)
                }
        } else {
            ColoredValue(
                declaration: declaration,
                color: valueColor,
                isStruck: isStruck,
                onPick: colorPicker,
                onScrub: numberScrubber,
                onScrubEnd: { session.commitLiveEdit() },
                onEditText: beginEditing
            )
            .contextMenu {
                // A closed set of values is pure recall to type, and the sort
                // of thing people misspell — so offer it rather than test them.
                let options = CSSKeywords.options(for: declaration.name)
                if !options.isEmpty, CSSKeywords.isSingleKeyword(declaration.value) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            Task { @MainActor in
                                await session.setValue(option, of: declaration, in: rule)
                            }
                        } label: {
                            // The current value is marked, so the menu says
                            // what it is as well as what it could be.
                            Text(option == declaration.value ? "✓ \(option)" : option)
                        }
                    }
                }
            }
        }
    }

    /// What the edit is up against, shown while the field is open rather than
    /// discovered afterwards by the page not moving.
    @ViewBuilder
    private var editingFooter: some View {
        let escalation = session.escalation(for: declaration, in: rule)

        HStack(spacing: 6) {
            if session.rejectedEdit == DeclarationRef(ruleId: rule.id, index: declaration.index) {
                Label("Not a value \(declaration.name) accepts", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else {
                switch escalation {
                case .addImportant:
                    Label("This won't take effect", systemImage: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Button("Make it win") {
                        Task { @MainActor in
                            await session.setImportant(true, of: declaration, in: rule)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))

                case .editTheWinner(let selector, _):
                    Label(
                        "Overridden by \(selector) — nothing here can win",
                        systemImage: "eye.slash"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)

                case .alreadyWins, .none:
                    Text("\u{21A9} to apply \u{00B7} esc to cancel")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 14)
    }

    /// Live while dragging: the page moves under the pointer, and one read
    /// settles it when the gesture ends.
    private var numberScrubber: ((Int, String) -> Void)? {
        guard rule.isActive, !isOff else { return nil }
        return { offset, replacement in
            Task { @MainActor in
                await session.setNumber(
                    replacement, at: offset, of: declaration, in: rule, live: true
                )
            }
        }
    }

    /// Absent for a rule that isn't applying or a declaration switched off —
    /// picking a colour you can't see the effect of is a trap, not a feature.
    private var colorPicker: ((Int, ResolvedColor) -> Void)? {
        guard rule.isActive, !isOff else { return nil }
        return { segment, current in pickColor(segment, current) }
    }

    /// Opens the system picker on one colour in this value, and follows it.
    ///
    /// Written to the page as the wheel is dragged rather than on dismissal,
    /// because the whole point of picking against a live page is seeing it —
    /// and a colour you have to commit before you can look at is just a text
    /// field with extra steps.
    private func pickColor(_ segment: Int, _ current: ResolvedColor) {
        ColorPanelController.shared.present(startingAt: current) { picked in
            Task { @MainActor in
                await session.setColor(
                    picked, segment: segment, of: declaration, in: rule, live: true
                )
            }
        } onFinish: {
            session.commitLiveEdit()
        }
    }

    private func beginEditing() {
        guard rule.isActive, !isOff else { return }
        draft = declaration.value
        isEditing = true
        isFocused = true
    }

    private func commit() {
        let value = draft
        isEditing = false
        isFocused = false
        guard value != declaration.value else { return }
        Task { @MainActor in await session.setValue(value, of: declaration, in: rule) }
    }

    private func cancel() {
        isEditing = false
        isFocused = false
    }

    private func toggleTrace() {
        guard trace?.isContested == true else { return }
        withAnimation(.easeOut(duration: 0.14)) { isTracing.toggle() }
    }

    private var whyButton: some View {
        Button(action: toggleTrace) {
            HStack(spacing: 2) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9, weight: .semibold))
                if isHovering || isTracing {
                    Text("why")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(isTracing ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Show every rule that set this, and why the others lost")
    }

    /// The state every other inspector renders as a flat strikethrough: three
    /// of a shorthand's four sides still apply, and drawing the whole thing as
    /// dead is simply false.
    private func partialBadge(_ lost: [String]) -> some View {
        Text(lost.count == 1 ? "\(lost[0]) overridden" : "\(lost.count) parts overridden")
            .font(.system(size: 9))
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background { Capsule().fill(Color.orange.opacity(0.12)) }
            .help(lost.joined(separator: ", "))
    }

    private var nameColor: Color {
        // A switched-off declaration is still in the page's source but not in
        // its styles, so it reads like anything else that isn't in force.
        if isOff { return .secondary }
        switch status {
        case .active:
            return declaration.isCustomProperty
                ? StylesStyle.variable : ElementsStyle.attributeColor
        case .overridden, .inactive:
            return .secondary
        case .partiallyOverridden:
            return ElementsStyle.attributeColor
        }
    }

    private var valueColor: Color {
        if isOff { return .secondary }
        switch status {
        case .active, .partiallyOverridden: return ElementsStyle.valueColor
        case .overridden, .inactive: return .secondary
        }
    }

    /// The value a `var()` in this declaration resolves to.
    private var resolvedVariable: String? {
        guard let range = declaration.value.range(of: "var(--") else { return nil }
        let rest = declaration.value[range.lowerBound...].dropFirst(4)
        let name = rest.prefix { $0 != ")" && $0 != "," }
        guard let value = session.resolvedVariable(String(name)), !value.isEmpty else { return nil }
        return value
    }

    private var ruleText: String? {
        guard !rule.isStyleAttribute else { return nil }
        let body = rule.declarations.map { "  \($0.text);" }.joined(separator: "\n")
        return "\(rule.selector) {\n\(body)\n}"
    }

    private var helpText: String {
        switch status {
        case .active: declaration.text
        case .overridden: "Overridden — click for why"
        case .partiallyOverridden(let lost): "Partly overridden: \(lost.joined(separator: ", "))"
        case .inactive: "Applies only \(rule.states.joined(separator: " and "))"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
