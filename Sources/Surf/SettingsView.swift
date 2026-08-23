import AppKit
import SurfCore
import SwiftUI

/// The Settings window (⌘,).
///
/// Two tabs: General is everything about browsing; AI is the CLIs Surf can
/// borrow a model from. Separate because their audiences are — every user
/// touches General, and AI is empty machinery until a CLI is installed.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ReaderSettingsView()
                .tabItem { Label("Reader", systemImage: "text.page") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 460)
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

/// Each toggle carries a plain-language explanation of what it actually does,
/// including where the guarantees stop. A privacy setting the user misreads is
/// worse than no setting at all.
struct GeneralSettingsView: View {
    @AppStorage(PreferenceKeys.rememberHistory) private var rememberHistory = false
    @AppStorage(PreferenceKeys.keepSignedIn) private var keepSignedIn = true
    @AppStorage(PreferenceKeys.restoreTabs) private var restoreTabs = true
    @AppStorage(PreferenceKeys.clearTracesOnQuit) private var clearTracesOnQuit = true

    @AppStorage(PreferenceKeys.autoPopOutVideo) private var autoPopOutVideo = true
    @AppStorage(PreferenceKeys.appearanceMode) private var appearanceMode = AppearanceMode.default
    @AppStorage(PreferenceKeys.synthesizeTheme) private var synthesizeTheme = false
    @AppStorage(PreferenceKeys.blockAds) private var blockAds = true

    @State private var isClearing = false
    @State private var clearedMessage: String?

    /// One number, and it's Surf's.
    ///
    /// Surf runs helper binaries with their own release cadences, and they
    /// update themselves in the background. None of that is surfaced: a version
    /// the user can't act on is noise, and "Surf is current" has to mean
    /// everything inside it is current too, or the number means nothing.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    var body: some View {
        settingsForm
            // Set on the environment rather than per row: `Form` supplies its
            // own text styles, and this replaces the face while leaving every
            // size and weight it chose intact.
            .environment(\.font, Typeface.figtree(size: 13))
    }

    private var settingsForm: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { _, mode in
                    AppearanceController.apply(mode)
                }
                explain("""
                System follows the Mac, including when it switches at sunset. \
                Light and Dark stay put.
                """)
                explain("""
                This tells sites which scheme you want. Sites that have a dark \
                mode of their own will use it — the site's own design, rather \
                than an approximation of it.
                """)

                Toggle("Restyle sites that don't offer it", isOn: $synthesizeTheme)
                    .onChange(of: synthesizeTheme) { _, _ in
                        // Takes effect on the pages already open, not just the
                        // next one — a setting that needs a reload to be
                        // believed reads as broken.
                        AppearanceController.notifyChanged()
                    }
                explain("""
                For the sites that have no dark mode, Surf builds one. Each \
                site's own colours are kept: backgrounds and text are moved \
                between light and dark, while brand colours hold their hue and \
                shift only as far as legibility needs. Images are never recoloured.
                """)
                explain("""
                This is a real change to how a page looks, and some sites will \
                come out wrong. Turn it off and they go back to exactly as \
                their authors drew them.
                """, isCaveat: true)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Block ads and trackers", isOn: $blockAds)
                    .onChange(of: blockAds) { _, _ in
                        // Every open tab picks this up where it stands. A
                        // setting that needs a reload to be believed reads as
                        // broken.
                        ContentBlocker.shared.enabledDidChange()
                    }
                explain("""
                On by default. Requests to ad and tracking domains are refused \
                before they leave your Mac, using \(FilterList.displayName) — the \
                two filter lists most ad blockers are built on. The shield in \
                the sidebar lists what was blocked on the page you're looking \
                at, and lets you add anything else it contacted.
                """)
                explain("""
                Some sites break when their ad code can't load. The same shield \
                pauses blocking for that site alone, and leaves it on everywhere else.
                """, isCaveat: true)
                if ContentBlocker.shared.blockedDomainCount > 0 {
                    explain("""
                    \(ContentBlocker.shared.blockedDomainCount.formatted()) known ad and \
                    tracking domains blocked, refreshed weekly.
                    """)
                }
            } header: {
                Text("Content Blocking")
            }

            Section {
                Toggle("Remember browsing history", isOn: $rememberHistory)
                    .onChange(of: rememberHistory) { _, isOn in
                        // Turning it off must erase what was already written,
                        // not just stop writing more.
                        if isOn { HistoryStore.shared.saveNow() }
                        else { HistoryStore.shared.handlePersistenceDisabled() }
                    }
                explain("""
                Off by default. Surf keeps no record of the pages you visit. \
                With this on, each tab's back and forward list is also saved to \
                disk between launches.
                """)

                Toggle("Keep me signed in", isOn: $keepSignedIn)
                explain("""
                Keeps cookies so your logins survive quitting. This is separate \
                from history — signing in doesn't require recording where you went.
                """)
            } header: {
                Text("Privacy")
            }

            Section {
                Toggle("Pop out video when switching tabs", isOn: $autoPopOutVideo)
                explain("""
                Leaving a tab that's playing video floats it in a small window \
                that stays on top. Returning to the tab puts it back.
                """)

            } header: {
                Text("Media")
            }

            Section {
                Toggle("Reopen tabs on launch", isOn: $restoreTabs)
                explain("""
                Saves the address of each open tab so they come back. This does \
                write those addresses to disk — if you want nothing stored at \
                all, turn this off.
                """, isCaveat: true)

                Toggle("Clear caches when quitting", isOn: $clearTracesOnQuit)
                explain("""
                Erases WebKit's caches and per-site storage at quit. Your cookies \
                are never touched by this, so you stay signed in.
                """)
            } header: {
                Text("On Disk")
            }

            Section {
                HStack(spacing: 10) {
                    Button("Clear Browsing Data Now") {
                        clearNow()
                    }
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
                }
                explain("""
                Erases caches and site storage immediately. Respects the \
                "Keep me signed in" setting above.
                """)
            }

            Section {
                LabeledContent("Default browser") {
                    if isDefaultBrowser {
                        Text("Surf").foregroundStyle(.secondary)
                    } else {
                        Button("Make Surf the Default") { makeDefaultBrowser() }
                    }
                }
                explain("""
                Links clicked anywhere on the Mac open here. macOS will ask \
                you to confirm, and you can change it back in System Settings \
                whenever you like.
                """)
                if !isBundled {
                    explain("""
                    This build can't be the default browser: it was launched \
                    from the command line rather than from Surf.app, and macOS \
                    only offers apps it has registered.
                    """, isCaveat: true)
                }
            }

            Section {
                LabeledContent("Version") {
                    Text(version).foregroundStyle(.secondary)
                }
                explain("""
                Surf keeps itself current in the background. There is nothing \
                to install and nothing to check.
                """)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refreshDefaultBrowser() }
    }

    /// Whether macOS currently opens links with us.
    ///
    /// Asked of LaunchServices each time the window appears rather than
    /// remembered: System Settings can change this behind our back, and a
    /// remembered answer would be wrong the moment it did.
    @State private var isDefaultBrowser = false

    /// A bare `swift run` has no bundle for LaunchServices to register, so the
    /// button would fail silently. Better to say why.
    private var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func refreshDefaultBrowser() {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else {
            isDefaultBrowser = false
            return
        }
        isDefaultBrowser =
            handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefaultBrowser() {
        // Both schemes. macOS tracks them separately, and a browser that owns
        // http but not https is one that misses most of the links on the web.
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme
            ) { _ in
                Task { @MainActor in refreshDefaultBrowser() }
            }
        }
    }

    private func explain(_ text: String, isCaveat: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isCaveat ? Color.orange.opacity(0.9) : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
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
