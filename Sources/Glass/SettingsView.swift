import GlassCore
import SwiftUI

/// The Settings window (⌘,).
///
/// Each toggle carries a plain-language explanation of what it actually does,
/// including where the guarantees stop. A privacy setting the user misreads is
/// worse than no setting at all.
struct SettingsView: View {
    @AppStorage(PreferenceKeys.rememberHistory) private var rememberHistory = false
    @AppStorage(PreferenceKeys.keepSignedIn) private var keepSignedIn = true
    @AppStorage(PreferenceKeys.restoreTabs) private var restoreTabs = true
    @AppStorage(PreferenceKeys.clearTracesOnQuit) private var clearTracesOnQuit = true

    @AppStorage(PreferenceKeys.autoPopOutVideo) private var autoPopOutVideo = true
    @AppStorage(PreferenceKeys.ytdlpPath) private var ytdlpPath = ""

    @State private var isClearing = false
    @State private var clearedMessage: String?

    /// Resolved once at launch, so this reports the copy actually in use rather
    /// than what the path field currently says.
    private var extractorStatus: String {
        guard let url = MediaExtractor.shared.executableURL else { return "yt-dlp not found" }
        return url.path
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remember browsing history", isOn: $rememberHistory)
                    .onChange(of: rememberHistory) { _, isOn in
                        // Turning it off must erase what was already written,
                        // not just stop writing more.
                        if isOn { HistoryStore.shared.saveNow() }
                        else { HistoryStore.shared.handlePersistenceDisabled() }
                    }
                explain("""
                Off by default. Glass keeps no record of the pages you visit. \
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

                Divider()

                LabeledContent("Stream downloads") {
                    Text(extractorStatus)
                        .font(.callout)
                        .foregroundStyle(MediaExtractor.shared.isAvailable ? .green : .secondary)
                }
                explain("""
                Videos streamed in segments have no file to save, so Glass uses \
                yt-dlp to reassemble them. A copy ships with Glass; set a path \
                below to use your own, newer one instead.
                """)

                TextField("yt-dlp path", text: $ytdlpPath, prompt: Text("Bundled copy"))
                    .textFieldStyle(.roundedBorder)
                if !MediaExtractor.shared.hasFFmpeg {
                    explain("""
                    ffmpeg wasn't found, so downloads are limited to the best \
                    single stream a site offers — often 720p. Install it with \
                    `brew install ffmpeg` for full quality.
                    """, isCaveat: true)
                }
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
