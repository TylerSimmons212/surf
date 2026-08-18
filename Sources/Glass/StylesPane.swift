import GlassCore
import SwiftUI

/// The rules that reach the selected element, in the order the cascade
/// considers them — and, for any property, the story of how it was decided.
///
/// The design brief was to beat the pane every other browser ships, and the
/// gap is not features, it's the index. A Styles pane is *rule*-first: here are
/// the blocks, hunt for your property inside them. But nobody opens it with a
/// rule in mind. They open it with a property in mind — "why is this blue" —
/// and rule-first makes them scan a dozen blocks for struck-through text and
/// then do the cascade in their head to work out which strike mattered.
///
/// So every property here is a question you can click. The rules stay, because
/// reading a block is how you learn what a component does. But underneath any
/// declaration is the other index: every rule that set that property, ordered,
/// with the reason each one lost stated in words.
struct StylesPane: View {
    @Bindable var session: DevToolsSession

    enum Mode: String, CaseIterable, Identifiable {
        case rules, computed, changes
        var id: String { rawValue }

        var label: String {
            switch self {
            case .rules: "Rules"
            case .computed: "Computed"
            case .changes: "Changes"
            }
        }
    }

    @State private var mode: Mode = .rules
    @State private var filter = ""
    /// Only what someone actually wrote, rather than all three-hundred-odd
    /// computed properties. The default, because the authored set is the answer
    /// to nearly every question and the rest is the specification's defaults
    /// reprinted for every element on earth.
    @State private var authoredOnly = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(.background)
        // On appear as well as on change: computed values are fetched lazily,
        // and hanging that solely off a *transition* means a pane that opens
        // already in Computed never asks for them and sits on "Reading…".
        .onAppear { session.isShowingComputed = mode == .computed }
        .onChange(of: mode) { _, new in session.isShowingComputed = new == .computed }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { option in
                    // The count rides in the label because a segmented control
                    // has nowhere to hang a badge — and an unlabelled tab is
                    // exactly what nobody thinks to click.
                    Text(
                        option == .changes && !session.changeset.isEmpty
                            ? "Changes (\(session.changeset.count))"
                            : option.label
                    ).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()

            if !session.availablePseudoElements.isEmpty {
                pseudoPicker
            }

            Spacer(minLength: 6)

            if mode == .computed {
                Toggle("Authored", isOn: $authoredOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(DevToolsTheme.chrome)
                    .help("Hide the hundreds of properties nobody set")
            }

            filterField
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    /// `::before` and `::after` cascade as separate boxes, so they're separate
    /// views rather than extra rules mixed into the element's own list — where
    /// they would strike out declarations they can't actually override.
    private var pseudoPicker: some View {
        Picker("Box", selection: $session.stylePseudo) {
            Text("Element").tag(String?.none)
            ForEach(session.availablePseudoElements, id: \.self) {
                Text($0).tag(String?.some($0))
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(DevToolsTheme.chrome)
                .frame(width: 100)

            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if mode == .changes {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ChangesList(session: session)
                }
                .padding(.horizontal, DevToolsTheme.unit * 2)
                .padding(.vertical, DevToolsTheme.unit * 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.selectedNode == nil {
            DevToolsPlaceholder(
                symbol: "paintbrush",
                title: "Nothing selected",
                detail: "Pick an element to see what styles it."
            )
        } else if let styles = session.styles {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Shown while anything is unread, being recovered, or has
                    // failed — the banner reports the outcome either way.
                    if !session.unreadableSheets.isEmpty || !session.recoveredSheets.isEmpty
                        || !session.failedRecoveries.isEmpty {
                        unreadableBanner
                    }

                    switch mode {
                    case .rules:
                        RuleSections(session: session, styles: styles, filter: filter)
                    case .computed:
                        ComputedList(
                            session: session, styles: styles,
                            filter: filter, authoredOnly: authoredOnly
                        )
                    case .changes:
                        // Handled above, where it can render without a
                        // selection — changes outlive the element you made them on.
                        EmptyView()
                    }
                }
                .padding(.horizontal, DevToolsTheme.unit * 2)
                .padding(.vertical, DevToolsTheme.unit * 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.isLoadingStyles {
            DevToolsPlaceholder(symbol: "paintbrush", title: "Reading styles…", detail: "")
        } else {
            DevToolsPlaceholder(
                symbol: "paintbrush",
                title: "No styles",
                detail: "Nothing in this document targets this node."
            )
        }
    }

    /// A cross-origin stylesheet is unreadable *to the page* — and therefore to
    /// every JS-based inspector, which shows nothing and leaves you to conclude
    /// the sheet had no rules. Saying so is the honest minimum.
    private var unreadableBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !session.recoveredSheets.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(session.recoveredSheets.count) cross-origin "
                            + "stylesheet\(session.recoveredSheets.count == 1 ? "" : "s") recovered"
                        )
                        .font(DevToolsTheme.chrome.weight(.medium))
                        // Worth stating: this is a capability, not a formality.
                        // The page is forbidden to read these, so no inspector
                        // built out of page script can show a rule from them.
                        Text(
                            "Fetched natively — the page itself can't read "
                            + "\(session.recoveredSheets.count == 1 ? "it" : "them")."
                        )
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
            }

            if session.isRecovering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching cross-origin stylesheets…")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(session.failedRecoveries.keys.sorted(), id: \.self) { href in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortName(href))
                            .font(DevToolsTheme.chrome.weight(.medium))
                        Text("Couldn't be recovered — \(session.failedRecoveries[href] ?? "")")
                            .font(DevToolsTheme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(
                    session.failedRecoveries.isEmpty
                        ? Color.green.opacity(0.08) : Color.orange.opacity(0.10)
                )
        }
    }

    private func shortName(_ url: String) -> String {
        URL(string: url)?.lastPathComponent ?? url
    }
}

// MARK: - Rules

private struct RuleSections: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let filter: String

    var body: some View {
        let own = styles.rules.filter { !$0.isInherited }
        let inherited = styles.rules.filter(\.isInherited)

        if own.isEmpty && inherited.isEmpty && styles.stateRules.isEmpty {
            Text("No rules reach this element.")
                .font(DevToolsTheme.chrome)
                .foregroundStyle(.secondary)
        }

        ForEach(visible(own)) { rule in
            RuleCard(session: session, styles: styles, rule: rule, filter: filter)
        }

        // Grouped by which ancestor supplied them, nearest first, because
        // "inherited from" is the answer to a different question than "matched".
        ForEach(inheritedGroups(inherited), id: \.label) { group in
            SectionLabel(
                text: "Inherited from \(group.label)",
                symbol: "arrow.down.to.line"
            )
            ForEach(group.rules) { rule in
                RuleCard(session: session, styles: styles, rule: rule, filter: filter)
            }
        }

        let states = visible(styles.stateRules)
        if !states.isEmpty {
            SectionLabel(
                text: "Only in a state you're not in",
                symbol: "cursorarrow.motionlines"
            )
            ForEach(states) { rule in
                RuleCard(session: session, styles: styles, rule: rule, filter: filter)
            }
        }

        // Said plainly rather than left to be discovered as a wrong answer.
        // WebKit exposes no user-agent stylesheet through the CSSOM at all, so
        // a browser default that beats a page rule — a button's own font, say —
        // is a fight this list cannot show. Computed is still the truth.
        if !visible(own).isEmpty || !inherited.isEmpty || !states.isEmpty {
            Text("Browser default rules aren't listed — WebKit doesn't expose them.")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    /// A rule with nothing matching the filter is hidden entirely — but a rule
    /// is never hidden because its *selector* didn't match, only because none
    /// of its declarations did.
    private func visible(_ rules: [MatchedRule]) -> [MatchedRule] {
        // An inherited rule whose properties don't inherit reaches nothing.
        let reaching = rules.filter(\.hasVisibleDeclarations)
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return reaching }
        return reaching.filter { rule in
            rule.selector.lowercased().contains(needle)
                || rule.displayDeclarations.contains {
                    $0.name.lowercased().contains(needle)
                        || $0.value.lowercased().contains(needle)
                }
        }
    }

    private func inheritedGroups(_ rules: [MatchedRule]) -> [(label: String, rules: [MatchedRule])] {
        var order: [String] = []
        var buckets: [String: [MatchedRule]] = [:]
        for rule in visible(rules) {
            let label = rule.inheritedLabel ?? "an ancestor"
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(rule)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

private struct SectionLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

private struct RuleCard: View {
    let session: DevToolsSession
    let styles: ResolvedStyles
    let rule: MatchedRule
    let filter: String

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if !rule.conditions.isEmpty || rule.layer != nil { context }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(rule.displayDeclarations) { declaration in
                    DeclarationRow(
                        session: session,
                        styles: styles,
                        rule: rule,
                        declaration: declaration
                    )
                }
            }
            .padding(.leading, DevToolsTheme.indent)
            .padding(.top, 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(rule.isActive ? DevToolsTheme.inputFill : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .strokeBorder(
                    rule.isActive
                        ? Color.primary.opacity(isHovering ? 0.10 : 0.05)
                        : Color.primary.opacity(0.10),
                    style: StrokeStyle(
                        lineWidth: 0.5,
                        // A dashed edge for a rule that isn't applying: it reads
                        // as provisional at a glance, before any label is read.
                        dash: rule.isActive ? [] : [3, 2]
                    )
                )
        }
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(rule.isStyleAttribute ? "element.style" : rule.selector)
                .font(DevToolsTheme.mono)
                .foregroundStyle(
                    rule.isStyleAttribute ? ElementsStyle.attributeColor : StylesStyle.selector
                )
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)

            if !rule.states.isEmpty {
                ForEach(rule.states, id: \.self) { state in
                    Text(state)
                        .font(.system(size: 9, weight: .semibold).monospaced())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                        }
                }
            }

            Spacer(minLength: 6)

            if !rule.isStyleAttribute {
                SpecificityBadge(specificity: rule.specificity)
            }

            Text(rule.sourceLabel)
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(rule.href ?? "inline <style> block")
        }
    }

    private var context: some View {
        HStack(spacing: 5) {
            if let layer = rule.layer {
                Label(layer, systemImage: "square.3.layers.3d")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(StylesStyle.layer)
                    .help("@layer \(layer)")
            }
            ForEach(rule.conditions, id: \.self) { condition in
                Text(condition)
                    .font(DevToolsTheme.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - One declaration

private struct DeclarationRow: View {
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
                onEditText: beginEditing
            )
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

    /// Absent for a rule that isn't applying or a declaration switched off —
    /// picking a colour you can't see the effect of is a trap, not a feature.
    private var colorPicker: ((Int, CSSColor) -> Void)? {
        guard rule.isActive, !isOff else { return nil }
        return { segment, current in pickColor(segment, current) }
    }

    /// Opens the system picker on one colour in this value, and follows it.
    ///
    /// Written to the page as the wheel is dragged rather than on dismissal,
    /// because the whole point of picking against a live page is seeing it —
    /// and a colour you have to commit before you can look at is just a text
    /// field with extra steps.
    private func pickColor(_ segment: Int, _ current: CSSColor) {
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

// MARK: - Computed

private struct ComputedList: View {
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

private struct ComputedRow: View {
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
                CascadeTraceCard(trace: trace, session: session)
                    .padding(.vertical, 4)
            }
        }
    }
}

enum StylesStyle {
    static let selector = DevToolsTheme.adaptive(
        light: (0.16, 0.34, 0.66), dark: (0.60, 0.78, 1.00)
    )
    static let layer = DevToolsTheme.adaptive(
        light: (0.48, 0.30, 0.70), dark: (0.78, 0.64, 0.98)
    )
    static let variable = DevToolsTheme.adaptive(
        light: (0.10, 0.45, 0.48), dark: (0.44, 0.86, 0.86)
    )
    static let important = DevToolsTheme.adaptive(
        light: (0.72, 0.18, 0.20), dark: (1.00, 0.55, 0.55)
    )
}
