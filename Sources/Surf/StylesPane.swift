import SurfCore
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
    @State private var showsClasses = false
    @State private var showsStates = false
    @State private var newClass = ""
    @State private var filter = ""
    /// Only what someone actually wrote, rather than all three-hundred-odd
    /// computed properties. The default, because the authored set is the answer
    /// to nearly every question and the rest is the specification's defaults
    /// reprinted for every element on earth.
    @State private var authoredOnly = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if showsClasses, mode == .rules {
                Divider()
                classStrip
            }
            if showsStates, mode == .rules {
                Divider()
                stateStrip
            }
            Divider()
            content
        }
        .background(.background)
        // On appear as well as on change: computed values are fetched lazily,
        // and hanging that solely off a *transition* means a pane that opens
        // already in Computed never asks for them and sits on "Reading…".
        // Escape reaches the page's own handler only while the page has
        // focus. If the panel is what's focused, this is the one that fires.
        .onKeyPress(.escape) {
            guard session.isPicking else { return .ignored }
            session.setPicking(false)
            return .handled
        }
        .onAppear { session.isShowingComputed = mode == .computed }
        .onChange(of: mode) { _, new in session.isShowingComputed = new == .computed }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // The picker belongs to whichever pane is answering a question
            // about an element, not to Elements alone. Styles is where you
            // most often want to change subject — you have just read why one
            // heading is the wrong colour and want the next one — and sending
            // you to Elements and back to do it is three clicks for something
            // that should be zero.
            IconButton(
                systemName: "cursorarrow.rays",
                size: 12,
                weight: .medium,
                width: 26,
                height: 22,
                cornerRadius: DevToolsTheme.corner,
                tint: session.isPicking ? Color.accentColor : nil,
                help: "Select an element on the page (⌥⌘C)"
            ) {
                session.setPicking(!session.isPicking)
            }

            Divider().frame(height: 14)

            // A native Menu, so the system supplies the popup, the metrics
            // and the announcement. Every item is a selector generated from
            // the element itself — valid and matching by construction — so
            // there is no invalid-selector path to design an error state for.
            Menu {
                ForEach(session.newRuleSelectors, id: \.self) { selector in
                    Button(selector) {
                        Task { @MainActor in _ = await session.addRule(selector) }
                    }
                }
            } label: {
                Label("New Rule", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.newRuleSelectors.isEmpty || mode != .rules)
            .help("New rule for the selected element")

            // ".cls" because that is what this thing is called in every
            // other inspector, and recognition beats invention in chrome
            // this small.
            Toggle(isOn: $showsClasses) {
                Text(".cls")
                    .font(DevToolsTheme.caption.monospaced())
            }
            .toggleStyle(.button)
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            .disabled(mode != .rules)
            .help(showsClasses ? "Hide the element's classes" : "Show and toggle the element's classes")

            Toggle(isOn: $showsStates) {
                Text(":hov")
                    .font(DevToolsTheme.caption.monospaced())
            }
            .toggleStyle(.button)
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            .disabled(mode != .rules)
            .help(showsStates ? "Hide element states" : "Simulate :hover, :focus and :active")

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

    // MARK: - Classes

    /// The element's classes as native toggles, plus a field for a new one.
    ///
    /// A class switched off stays in the strip unchecked — the session
    /// remembers what it took away — because a chip that vanished the moment
    /// it was turned off could only be turned back on by retyping it.
    private var classStrip: some View {
        FlowLayout(spacing: 4, rowSpacing: 4) {
            ForEach(session.elementClasses, id: \.name) { entry in
                Toggle(isOn: Binding(
                    get: { entry.isOn },
                    set: { on in
                        Task { @MainActor in await session.setClass(entry.name, enabled: on) }
                    }
                )) {
                    Text(".\(entry.name)")
                        .font(DevToolsTheme.caption.monospaced())
                }
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .controlSize(.small)
            }

            TextField("add class", text: $newClass)
                .textFieldStyle(.plain)
                .font(DevToolsTheme.caption.monospaced())
                .frame(width: 88)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                        .fill(DevToolsTheme.inputFill)
                }
                .onSubmit {
                    let name = newClass.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    newClass = ""
                    Task { @MainActor in await session.setClass(name, enabled: true) }
                }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 5)
    }

    // MARK: - States

    /// The five forcible states as native toggles, and the word "simulated"
    /// said plainly.
    ///
    /// Chrome and Safari force state through an engine hook this browser
    /// cannot reach — page script has no way to set the real :hover bit. What
    /// runs instead is a copy of each state rule with the pseudo-class
    /// rewritten to an attribute of identical specificity, stamped onto this
    /// one element. Same cascade weights, same visible result, but not the
    /// engine's own state — so the strip says so instead of letting the
    /// difference be discovered as a bug.
    private var stateStrip: some View {
        HStack(spacing: 4) {
            ForEach(DevToolsSession.forcibleStates, id: \.self) { state in
                Toggle(isOn: Binding(
                    get: {
                        session.forcedNode == session.selectedNode
                            && session.forcedStates.contains(state)
                    },
                    set: { on in
                        Task { @MainActor in await session.setForcedState(state, enabled: on) }
                    }
                )) {
                    Text(":\(state)")
                        .font(DevToolsTheme.caption.monospaced())
                }
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .controlSize(.small)
            }

            Spacer(minLength: 8)

            Text("simulated")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .help(
                    "Surf copies each state rule with the pseudo-class rewritten "
                    + "to an attribute of equal specificity — the engine's own "
                    + "element state can't be set from here. Styling matches; "
                    + "engine side effects don't."
                )
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 5)
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
