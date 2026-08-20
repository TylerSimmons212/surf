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
    /// The in-flight live write, kept so the next keystroke can cancel it.
    @State private var liveWrite: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var status: DeclarationStatus {
        styles.status(of: declaration, in: rule)
    }

    /// Why winning didn't matter — the cascade card's sibling question.
    ///
    /// Asked only of declarations that are *applying*: an overridden one
    /// already has its explanation (the trace), and stacking "also, it
    /// wouldn't have worked" on a loser is trivia. The misleading case is
    /// the winner that does nothing — width on an inline element sits there
    /// looking perfectly healthy while the box refuses to move.
    private var inactiveReason: String? {
        guard status == .active, rule.isActive, !isOff else { return nil }
        return CSSInactive.reason(for: declaration.name, in: styles.context)
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
                CascadeTraceCard(trace: trace)
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
            // Dimmed, not struck: a strikethrough means "beaten by another
            // rule", and this declaration beat nobody and was beaten by
            // nobody — it just does nothing where it landed.
            .opacity(inactiveReason == nil ? 1 : 0.55)

            if let inactiveReason, !isEditing {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "moon.zzz")
                        .font(DevToolsTheme.badge)
                        .foregroundStyle(.tertiary)
                    Text(inactiveReason)
                        .font(DevToolsTheme.prose)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 14)
                .padding(.top, 1)
            }

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
                // Up and down nudge the number, the way every other inspector
                // does. A single-line field has nothing useful to do with
                // these keys otherwise — they only jump the caret to the ends
                // — so intercepting them costs nothing.
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { nudge($0) }
                // The page follows the field. Editing a style you cannot see
                // the effect of is a text box with extra steps, and the live
                // path already exists — it is what dragging a number uses.
                .onChange(of: draft) { _, new in liveApply(new) }
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

    /// Steps the first number in the draft.
    ///
    /// The first, not the one under the caret, because SwiftUI's `TextField`
    /// exposes no selection — so `margin: 8px 12px` nudges the 8. Dragging a
    /// number still addresses each one exactly, which is the affordance to
    /// reach for on a multi-value property.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard let number = CSSValueScrub.numbers(in: draft).first else { return .ignored }
        let step = CSSValueScrub.step(
            for: number.unit,
            coarse: press.modifiers.contains(.shift),
            fine: press.modifiers.contains(.option)
        )
        let direction: Double = press.key == .upArrow ? 1 : -1
        draft = CSSValueScrub.replacing(
            draft,
            number: number,
            with: CSSValueScrub.adjusted(number, by: direction, unit: step)
        )
        // `onChange(of: draft)` writes it to the page.
        return .handled
    }

    /// Writes the draft to the page without rebuilding the pane.
    ///
    /// Cancel-and-replace rather than one task per keystroke, because separate
    /// tasks have no ordering: type fast enough and an earlier value can land
    /// after a later one, leaving the page showing something you already
    /// typed past. Only the newest survives, and the short delay keeps a held
    /// arrow key from queueing a write per repeat.
    private func liveApply(_ value: String) {
        liveWrite?.cancel()
        liveWrite = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            await session.setValue(value, of: declaration, in: rule, live: true)
        }
    }

    private func commit() {
        liveWrite?.cancel()
        let value = draft
        isEditing = false
        isFocused = false
        guard value != declaration.value else { return }
        Task { @MainActor in await session.setValue(value, of: declaration, in: rule) }
    }

    /// Escape has to put the page back, not just shut the field.
    ///
    /// It used to be enough to stop editing, because nothing had been written
    /// until you pressed return. Now that the page follows every keystroke,
    /// closing the field without reverting would leave the element wearing an
    /// edit you explicitly cancelled. The changeset drops the entry on its own
    /// — a change recorded back to its original value is a no-op and gets
    /// removed rather than left in the Changes list.
    private func cancel() {
        liveWrite?.cancel()
        let original = declaration.value
        let touched = draft != original
        isEditing = false
        isFocused = false
        guard touched else { return }
        Task { @MainActor in
            await session.setValue(original, of: declaration, in: rule)
        }
    }

    private func toggleTrace() {
        guard trace?.isContested == true else { return }
        withAnimation(.easeOut(duration: 0.14)) { isTracing.toggle() }
    }

    /// The way into the cascade card, and the pane's best idea — so it says
    /// what it is and how much is behind it, at rest.
    ///
    /// It used to be a bare 9pt question mark that only grew the word "why" on
    /// hover. That made the one feature no other inspector has discoverable
    /// exclusively by accident: you had to already suspect a property was
    /// contested, hover the right row, and notice a glyph appear. The count is
    /// the honest hook — "3 rules" on a line whose value looks perfectly
    /// settled is the thing that makes you look.
    private var whyButton: some View {
        Button(action: toggleTrace) {
            HStack(spacing: 3) {
                Image(systemName: isTracing ? "chevron.down" : "questionmark.circle")
                    .font(DevToolsTheme.badge)
                Text("\(trace?.entries.count ?? 0) rules")
                    .font(DevToolsTheme.caption)
            }
            .foregroundStyle(isTracing ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule().fill(
                    isTracing ? Color.accentColor.opacity(0.14) : DevToolsTheme.hoverFill
                )
            }
            .contentShape(Capsule())
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
