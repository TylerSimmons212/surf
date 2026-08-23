import AppKit
import SurfCore
import SwiftUI

/// The Settings window (⌘,).
///
/// One pane per subject rather than one long scroll. Everything used to live
/// under General, which grew to seven sections and a window taller than the
/// screen — and could not be scrolled, because the form was pinned to its own
/// intrinsic height by a `fixedSize`. A fixed frame here and no `fixedSize`
/// below is what makes each pane scroll inside the window instead of pushing
/// the window past the end of the display.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            LinkSettingsView()
                .tabItem { Label("Links", systemImage: "link") }
            ReaderSettingsView()
                .tabItem { Label("Reader", systemImage: "text.page") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 500, height: 430)
    }
}

// MARK: - Explanations

/// The detail behind a setting, one click away.
///
/// Every switch here still carries a plain-language account of what it actually
/// does and where its guarantees stop — a privacy setting the user misreads is
/// worse than no setting at all. What changed is when they say it. Printed
/// under every row at once, the page became something to scroll past rather
/// than read, which is its own way of not being read.
private struct InfoTip: View {
    let text: String
    /// The part that is a warning rather than an explanation: a setting that
    /// can visibly break a page, or that writes something to disk.
    var caveat: String?

    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: caveat == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(caveat == nil ? Color.secondary : Color.orange)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                if let caveat {
                    Text(caveat).foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280, alignment: .leading)
            .padding(14)
        }
    }
}

/// A row's label with its explanation beside it.
private struct TipLabel: View {
    let title: String
    let tip: String
    var caveat: String?

    init(_ title: String, tip: String, caveat: String? = nil) {
        self.title = title
        self.tip = tip
        self.caveat = caveat
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            InfoTip(text: tip, caveat: caveat)
        }
    }
}

/// Shared by every pane, so they read as one window rather than five.
private extension View {
    func settingsPane() -> some View {
        formStyle(.grouped)
            // Set on the environment rather than per row: `Form` supplies its
            // own text styles, and this replaces the face while leaving every
            // size and weight it chose intact.
            .environment(\.font, Typeface.figtree(size: 13))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(PreferenceKeys.appearanceMode) private var appearanceMode = AppearanceMode.default
    @AppStorage(PreferenceKeys.synthesizeTheme) private var synthesizeTheme = false
    @AppStorage(PreferenceKeys.autoPopOutVideo) private var autoPopOutVideo = true

    /// One number, and it's Surf's.
    ///
    /// Surf runs helper binaries with their own release cadences, and they
    /// update themselves in the background. None of that is surfaced: a version
    /// the user can't act on is noise, and "Surf is current" has to mean
    /// everything inside it is current too, or the number means nothing.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private var updater: SoftwareUpdater { SoftwareUpdater.shared }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker(selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    TipLabel("Scheme", tip: """
                    System follows the Mac, including when it switches at \
                    sunset. Light and Dark stay put.

                    This tells sites which scheme you want. Sites with a dark \
                    mode of their own will use it — the site's own design, \
                    rather than an approximation of it.
                    """)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { _, mode in
                    AppearanceController.apply(mode)
                }

                Toggle(isOn: $synthesizeTheme) {
                    TipLabel("Restyle sites that don't offer it", tip: """
                    For the sites that have no dark mode, Surf builds one. Each \
                    site's own colours are kept: backgrounds and text are moved \
                    between light and dark, while brand colours hold their hue \
                    and shift only as far as legibility needs. Images are never \
                    recoloured.
                    """, caveat: """
                    This is a real change to how a page looks, and some sites \
                    will come out wrong. Turn it off and they go back to \
                    exactly as their authors drew them.
                    """)
                }
                .onChange(of: synthesizeTheme) { _, _ in
                    // Takes effect on the pages already open, not just the
                    // next one — a setting that needs a reload to be believed
                    // reads as broken.
                    AppearanceController.notifyChanged()
                }
            }

            Section("Media") {
                Toggle(isOn: $autoPopOutVideo) {
                    TipLabel("Pop out video when switching tabs", tip: """
                    Leaving a tab that's playing video floats it in a small \
                    window that stays on top. Returning to the tab puts it back.
                    """)
                }
            }

            Section("Updates") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(version).foregroundStyle(.secondary)
                        if updater.isAvailable {
                            Button("Check Now") { updater.checkForUpdates() }
                                .disabled(!updater.canCheck)
                        }
                    }
                } label: {
                    TipLabel("Version", tip: """
                    Surf asks one address for one file listing the current \
                    version. It sends nothing about you or your Mac along \
                    with the question, and an update is only installed after \
                    its signature is checked against a key built into this app.
                    """)
                }

                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.checksAutomatically },
                        set: { updater.checksAutomatically = $0 }
                    ))
                    if let last = updater.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named))).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Only in the state it explains, and an instruction rather
                    // than a description — the same bar the Links pane sets.
                    Text("This build can't update itself: updating replaces an "
                         + "app bundle, and this one was launched from the command line.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @AppStorage(PreferenceKeys.blockAds) private var blockAds = true
    @AppStorage(PreferenceKeys.rememberHistory) private var rememberHistory = false
    @AppStorage(PreferenceKeys.keepSignedIn) private var keepSignedIn = true
    @AppStorage(PreferenceKeys.restoreTabs) private var restoreTabs = true
    @AppStorage(PreferenceKeys.clearTracesOnQuit) private var clearTracesOnQuit = true

    @State private var isClearing = false
    @State private var clearedMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $blockAds) {
                    TipLabel("Block ads and trackers", tip: """
                    On by default. Requests to ad and tracking domains are \
                    refused before they leave your Mac, using \
                    \(FilterList.displayName) — the two filter lists most ad \
                    blockers are built on. The shield in the sidebar lists what \
                    was blocked on the page you're looking at.
                    """, caveat: """
                    Some sites break when their ad code can't load. The same \
                    shield pauses blocking for that site alone, and leaves it \
                    on everywhere else.
                    """)
                }
                .onChange(of: blockAds) { _, _ in
                    // Every open tab picks this up where it stands. A setting
                    // that needs a reload to be believed reads as broken.
                    ContentBlocker.shared.enabledDidChange()
                }
            } header: {
                Text("Blocking")
            } footer: {
                if ContentBlocker.shared.blockedDomainCount > 0 {
                    Text("""
                    \(ContentBlocker.shared.blockedDomainCount.formatted()) known ad and \
                    tracking domains blocked, refreshed weekly.
                    """)
                    .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Toggle(isOn: $rememberHistory) {
                    TipLabel("Remember browsing history", tip: """
                    Off by default. Surf keeps no record of the pages you \
                    visit. With this on, each tab's back and forward list is \
                    also saved to disk between launches.
                    """)
                }
                .onChange(of: rememberHistory) { _, isOn in
                    // Turning it off must erase what was already written, not
                    // just stop writing more.
                    if isOn { HistoryStore.shared.saveNow() }
                    else { HistoryStore.shared.handlePersistenceDisabled() }
                }

                Toggle(isOn: $keepSignedIn) {
                    TipLabel("Keep me signed in", tip: """
                    Keeps cookies so your logins survive quitting. This is \
                    separate from history — signing in doesn't require \
                    recording where you went.
                    """)
                }
            }

            Section("On Disk") {
                Toggle(isOn: $restoreTabs) {
                    TipLabel("Reopen tabs on launch", tip: """
                    Saves the address of each open tab so they come back.
                    """, caveat: """
                    This does write those addresses to disk — if you want \
                    nothing stored at all, turn this off.
                    """)
                }

                Toggle(isOn: $clearTracesOnQuit) {
                    TipLabel("Clear caches when quitting", tip: """
                    Erases WebKit's caches and per-site storage at quit. Your \
                    cookies are never touched by this, so you stay signed in.
                    """)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Clear Browsing Data Now") { clearNow() }
                        .disabled(isClearing)

                    if isClearing {
                        ProgressView().controlSize(.small)
                    }
                    if let clearedMessage {
                        Text(clearedMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    InfoTip(text: """
                    Erases caches and site storage immediately. Respects the \
                    "Keep me signed in" setting above.
                    """)
                }
            }
        }
        .settingsPane()
    }

    private func clearNow() {
        isClearing = true
        clearedMessage = nil
        Task {
            // Same policy as quit, so the button can't contradict the toggles.
            var settings = PrivacySettings.current
            settings.clearTracesOnQuit = true
            await BrowsingDataCleaner.clear(PrivacyPolicy.categoriesToClearOnQuit(settings))
            // Autocomplete history is ours, not WebKit's, so clear it too.
            HistoryStore.shared.clear()
            isClearing = false
            withAnimation { clearedMessage = "Cleared." }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { clearedMessage = nil }
        }
    }
}

// MARK: - Links

struct LinkSettingsView: View {
    @AppStorage(PreferenceKeys.externalLinksInMiniWindow)
    private var externalLinksInMiniWindow = true

    var body: some View {
        Form {
            Section("From Other Apps") {
                Toggle(isOn: $externalLinksInMiniWindow) {
                    TipLabel("Open in a mini window", tip: """
                    A link from Mail or Slack arrives in a small floating \
                    window with the page in it, and one button to keep it as a \
                    tab. Turn this off and those links open straight into the \
                    island you're already in.
                    """)
                }

                if DefaultBrowser.isSurf {
                    LabeledContent("Default browser") {
                        Text("Surf").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        // Shown even when it cannot work, and disabled instead
                        // of hidden. A control that is missing reads as a
                        // feature that is missing; a disabled one with the
                        // reason beside it tells you what to go and do.
                        Button("Make Surf the default browser…") {
                            DefaultBrowser.request()
                        }
                        .disabled(!DefaultBrowser.canAsk)

                        Spacer(minLength: 0)

                        InfoTip(text: """
                        macOS will ask you to confirm. Until Surf is the \
                        default, no other app will hand it links, and mini \
                        windows can only be opened from inside Surf.
                        """)
                    }

                    if !DefaultBrowser.canAsk {
                        // The one place inline text still earns its keep: it
                        // appears only in the state it explains, and it is an
                        // instruction rather than a description.
                        Text("Only a built app can be registered. "
                             + "Run ./scripts/bundle.sh, then open Surf.app.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .settingsPane()
    }
}

/// Focus's settings: today, the reading voice.
struct ReaderSettingsView: View {
    @State private var installer = VoiceInstaller.shared
    @AppStorage(PreferenceKeys.focusEnhancedVoice) private var useEnhancedVoice = true

    var body: some View {
        Form {
            Section {
                switch installer.phase {
                case .absent, .failed:
                    Button("Download Enhanced Voice (\(VoiceComponent.totalMegabytes) MB)") {
                        installer.install()
                    }
                    if case .failed(let message) = installer.phase {
                        Text(message)
                            .font(Typeface.figtree(size: 11))
                            .foregroundStyle(.orange)
                    }

                case .downloading(let progress):
                    ProgressView(value: progress) {
                        Text("Downloading… \(Int(progress * 100))%")
                    }

                case .installing:
                    ProgressView {
                        Text("Installing…")
                    }

                case .installed:
                    Toggle("Read with the enhanced voice", isOn: $useEnhancedVoice)
                    Button("Remove Enhanced Voice") {
                        installer.remove()
                    }
                }
            } header: {
                Text("Reading Voice")
            } footer: {
                Text("""
                    Focus can read articles aloud. Out of the box it uses \
                    the best voice installed on this Mac. The enhanced voice \
                    is a neural model (Kokoro, via sherpa-onnx) that runs \
                    entirely on this machine — nothing that is read leaves \
                    it. Applies from the next reading. English only, for now.
                    """)
                    .font(Typeface.figtree(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .environment(\.font, Typeface.figtree(size: 13))
    }
}
