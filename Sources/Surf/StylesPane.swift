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
