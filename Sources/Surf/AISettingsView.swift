import SurfCore
import SwiftUI

/// The AI tab in Settings.
///
/// Surf doesn't ship a model or ask for an API key. It borrows the AI CLIs
/// already on this Mac — Claude Code, Codex — under whatever account they're
/// already signed into. One dropdown picks whose account runs things; below
/// it, each AI feature is its own toggle and its own model choice.
///
/// Detection is passive: config files are read, the Keychain is not, and
/// nothing here can start a login, a session, or a charge. The one button
/// with side effects — Update — says exactly what it runs.
struct AISettingsView: View {
    @AppStorage(PreferenceKeys.aiProvider) private var storedProvider = ""

    private var detector: AICLIDetector { .shared }

    private var installedProviders: [AICLIProvider] {
        AICLIProvider.allCases.filter { detector.status($0).isInstalled }
    }

    /// The dropdown's actual value: the stored pick while it exists on this
    /// machine, the first CLI found otherwise.
    private var selectedProvider: AICLIProvider? {
        if let pick = AICLIProvider(rawValue: storedProvider),
           installedProviders.contains(pick) {
            return pick
        }
        // Same rule as `AIPreferences.selectedProvider`: a CLI that can run
        // beats one that's merely present.
        return installedProviders.first { detector.status($0).isUsable }
            ?? installedProviders.first
    }

    var body: some View {
        Form {
            providerSection
            if let provider = selectedProvider, detector.status(provider).isUsable {
                featureSection(provider)
            }
            rescanSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.font, Typeface.figtree(size: 13))
        // Fresh every time the tab is shown: the user may have just installed
        // or signed into a CLI precisely because this tab told them to.
        .onAppear { detector.refresh() }
        // And when Surf comes back to the front: signing in happens in a
        // Terminal window, and the moment of return is the moment the answer
        // changed.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            detector.refresh()
        }
    }

    // MARK: - Provider

    @ViewBuilder
    private var providerSection: some View {
        Section {
            if installedProviders.isEmpty {
                if detector.statuses.values.contains(where: { $0.executableURL == nil }) {
                    // Haven't finished looking; saying anything would be a guess.
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for AI tools…").foregroundStyle(.secondary)
                    }
                } else {
                    explain("""
                    No AI CLI was found on this Mac. Install Claude Code \
                    (claude.com/code) or Codex (`npm install -g @openai/codex`), \
                    sign in, and Surf will pick it up here.
                    """)
                }
            } else {
                Picker("Provider", selection: providerBinding) {
                    ForEach(installedProviders) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                if let provider = selectedProvider {
                    providerDetails(detector.status(provider))
                }
            }
        } header: {
            HStack(spacing: 5) {
                Text("Provider")
                InfoButton(text: """
                Surf has no model and no API key of its own. AI features run \
                through a CLI already on this Mac, under the account it's \
                already signed into — its plan, its limits, its bill.
                """)
            }
        }
    }

    /// Writes the pick through even when it matches the fallback: an explicit
    /// choice should stay chosen when a second CLI appears later.
    private var providerBinding: Binding<String> {
        Binding(
            get: { selectedProvider?.rawValue ?? "" },
            set: { storedProvider = $0 }
        )
    }

    @ViewBuilder
    private func providerDetails(_ status: AICLIDetector.Status) -> some View {
        let provider = status.provider

        switch status.login {
        case .loggedIn(let account):
            LabeledContent("Account") {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(account.email ?? account.detail ?? "Signed in")
                        if account.email != nil, let detail = account.detail {
                            Text(detail).foregroundStyle(.secondary)
                        }
                    }
                    // Verified by the CLI itself this scan, not read off a file.
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("Confirmed by \(provider.displayName) itself — not just its config file.")
                }
            }
        case .expired(let account):
            LabeledContent("Account") {
                VStack(alignment: .trailing, spacing: 1) {
                    if let email = account.email { Text(email) }
                    Text("Session expired").foregroundStyle(.orange)
                }
            }
            signInRow(provider, verb: "Sign In Again")
            explain("""
            \(provider.displayName) says this session has lapsed and it \
            couldn't renew it. AI features are paused until you sign in again.
            """, isCaveat: true)
        case .loggedOut:
            LabeledContent("Account") {
                Text("Not signed in").foregroundStyle(.orange)
            }
            signInRow(provider, verb: "Sign In")
        case .unknown:
            LabeledContent("Account") {
                Text("Couldn't read").foregroundStyle(.secondary)
            }
            explain("""
            Signed-in state couldn't be read — the CLI's config format may \
            have changed. It may still work; Surf just can't confirm it here.
            """, isCaveat: true)
        }

        versionRow(status)
    }

    @ViewBuilder
    private func signInRow(_ provider: AICLIProvider, verb: String) -> some View {
        HStack(spacing: 6) {
            Button(verb + "…") { detector.signIn(provider) }
            InfoButton(text: """
            Opens a Terminal window running \(provider.displayName)'s own \
            sign-in — your password or key goes to \(provider.vendor)'s tool, \
            never through Surf. When it finishes, come back and Surf will \
            re-check on its own.
            """)
        }
    }

    /// Version, and — when the registry says a newer one exists — the update.
    @ViewBuilder
    private func versionRow(_ status: AICLIDetector.Status) -> some View {
        let provider = status.provider
        if let version = status.version {
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    if status.updateAvailable, let latest = status.latestVersion {
                        Text("\(version) → \(latest)").foregroundStyle(.secondary)
                        Button("Update") { detector.update(provider) }
                            .disabled(detector.updating.contains(provider))
                    } else {
                        Text(version).foregroundStyle(.secondary)
                    }
                    if detector.updating.contains(provider) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            switch detector.updateOutcomes[provider] {
            case .updated:
                explain("Updated.")
            case .failed(let message):
                explain(message, isCaveat: true)
            case nil:
                if status.updateAvailable {
                    explain("""
                    Updating runs \(provider.displayName)'s own updater — the \
                    same thing it does for itself in a terminal.
                    """)
                }
            }
        }
    }

    // MARK: - Features

    private func featureSection(_ provider: AICLIProvider) -> some View {
        Section {
            ForEach(AIFeature.allCases) { feature in
                FeatureRow(feature: feature, status: detector.status(provider))
                    // Identity includes the provider so a switch re-reads the
                    // right per-provider model key.
                    .id(feature.rawValue + provider.rawValue)
            }
        } header: {
            HStack(spacing: 5) {
                Text("Features")
                InfoButton(text: """
                Off until you turn them on — each one sends a little of what \
                you're doing (a page title, a filename) to \(provider.vendor). \
                Fast is the recommended model: these are two-word asks, where \
                the speed gap between tiers is the whole experience and the \
                quality gap is invisible.
                """)
            }
        }
    }

    // MARK: - Rescan

    private var rescanSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if detector.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Again") { detector.refresh() }
                        .disabled(detector.isScanning)
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Detection")
                    InfoButton(text: """
                    Detection is read-only: Surf looks for the binaries and \
                    reads each CLI's own record of who's signed in. It never \
                    opens a session, asks for the Keychain, or uses your \
                    quota to check.
                    """)
                }
            }
        }
    }

    // MARK: - Copy

    private func explain(_ text: String, isCaveat: Bool = false) -> some View {
        SettingsExplanation(text: text, isCaveat: isCaveat)
    }
}

/// One feature: its toggle, and — while it's on — its model.
private struct FeatureRow: View {
    let feature: AIFeature
    let status: AICLIDetector.Status

    @AppStorage private var enabled: Bool
    @AppStorage private var model: String

    init(feature: AIFeature, status: AICLIDetector.Status) {
        self.feature = feature
        self.status = status
        // Dynamic keys: per feature, and per provider for the model, so a
        // pinned Claude model is never replayed onto Codex.
        _enabled = AppStorage(wrappedValue: false, feature.enabledKey)
        _model = AppStorage(wrappedValue: "", feature.modelKey(for: status.provider))
    }

    var body: some View {
        Toggle(feature.label, isOn: $enabled)
        if enabled {
            // Indented under its toggle: the model belongs to this feature,
            // and the layout should say so before any words do.
            Picker(selection: $model) {
                Text(fastLabel).tag("")
                Divider()
                ForEach(status.modelOptions) { option in
                    Text(option.label).tag(option.id)
                }
            } label: {
                Label("Model", systemImage: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
            }
            .pickerStyle(.menu)
            .padding(.leading, 24)
        }
    }

    /// The Fast entry names the model it resolves to, so "recommended" isn't
    /// asking for blind trust.
    private var fastLabel: String {
        let fast = status.provider.fastModel(
            from: status.modelOptions, descriptions: status.modelDescriptions
        )
        guard let fast else { return "Fast — recommended" }
        return "Fast — \(fast.label), recommended"
    }
}

/// A small ⓘ that keeps a paragraph out of the layout until it's asked for.
private struct InfoButton: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(Typeface.figtree(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

/// The explanatory line under a control. Shared with the General tab's
/// `explain` styling — one look for one job.
struct SettingsExplanation: View {
    let text: String
    var isCaveat = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isCaveat ? Color.orange.opacity(0.9) : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }
}
