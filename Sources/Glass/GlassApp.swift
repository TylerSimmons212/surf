import GlassCore
import SwiftUI

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One session for the app. Held here rather than in `ContentView` so the
    /// menu commands below can drive the same tabs the window is showing.
    @State private var session: BrowserSession

    init() {
        // Must precede BrowserSession, which consults these on construction.
        PrivacySettings.registerDefaults()
        _session = State(initialValue: BrowserSession())
    }

    /// Mirrors ContentView's storage, so the menu item reflects and drives the
    /// same preference.
    @AppStorage(PreferenceKeys.sidebarPinned) private var isSidebarPinned = false

    var body: some Scene {
        WindowGroup("Glass") {
            ContentView(session: session)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
        .commands { tabCommands }

        Settings {
            SettingsView()
        }
    }

    /// Standard browser shortcuts. These live in the menu bar because that's
    /// what makes ⌘-keys work app-wide, even while a web view has focus.
    @CommandsBuilder
    private var tabCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { session.openNewTabAndPrompt() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") { session.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)

            Button("Reopen Closed Tab") { session.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!session.canReopenClosedTab)

            // ⌘W belongs to the tab in a browser, so the window moves up one.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // Replaces the stock Edit-menu find items, which act on text fields and
        // know nothing about the page.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { session.requestFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(session.selectedTab.mode != .browsing)

            Button("Find Next") { session.stepFind(forward: true) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(session.selectedTab.mode != .browsing)

            Button("Find Previous") { session.stepFind(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session.selectedTab.mode != .browsing)
        }

        CommandGroup(after: .toolbar) {
            Button(isSidebarPinned ? "Unpin Sidebar" : "Pin Sidebar") {
                isSidebarPinned.toggle()
            }
            .keyboardShortcut("s", modifiers: .command)

            Divider()

            Button("Show Next Tab") { session.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Button("Show Previous Tab") { session.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Divider()

            Button("Open Location…") { session.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)

            Divider()

            // With the toolbar gone these are the primary way to navigate when
            // the sidebar is hidden.
            Button("Back") { session.selectedTab.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!session.selectedTab.canGoBack)

            Button("Forward") { session.selectedTab.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!session.selectedTab.canGoForward)

            Button("Reload") { session.selectedTab.reload() }
                .keyboardShortcut("r", modifiers: .command)

            Button("Reload Ignoring Cache") { session.selectedTab.reloadIgnoringCache() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Stop") { session.selectedTab.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!session.selectedTab.isLoading)

            Divider()

            // Zoom is per-tab, so these read against whatever is on screen.
            Button("Zoom In") { session.selectedTab.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") { session.selectedTab.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") { session.selectedTab.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!session.selectedTab.isZoomed)

            Divider()

            // ⌘1–⌘9 jump by position; ⌘9 means "last", per convention.
            ForEach(1...9, id: \.self) { index in
                Button("Show Tab \(index)") { session.selectTab(atOneBasedIndex: index) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index)")),
                        modifiers: .command
                    )
            }
        }

        CommandMenu("Develop") {
            Button(
                DevToolsController.shared.isOpen(for: session.selectedTab)
                    ? "Hide Developer Tools"
                    : "Show Developer Tools"
            ) {
                DevToolsController.shared.toggle(session.selectedTab)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Inspect Element") {
                DevToolsController.shared.beginPicking(session.selectedTab)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button("Show JavaScript Console") {
                DevToolsController.shared.open(session.selectedTab, pane: .console)
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])

            Divider()

            // Named for what it is. Glass can't host a JS debugger at all, and
            // burying that behind a disabled menu item would be worse than
            // saying so and pointing at the one place it does work.
            Button("Debug in Safari…") {
                DevToolsController.shared.handOffToSafari(session.selectedTab)
            }
        }
    }
}

/// Makes a SwiftPM-built executable behave like a real app:
/// shows in the Dock, takes focus, and quits when the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Returns immediately unless a week has passed, and never blocks
        // anything the user can see.
        UpdateManager.shared.checkIfDue()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Erasing data is async, and a normal quit won't wait for it. `.terminateLater`
    /// holds the app open until the clear finishes and we explicitly reply —
    /// otherwise the promise in Settings would be silently broken at the exact
    /// moment it's supposed to be kept.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let categories = PrivacyPolicy.categoriesToClearOnQuit(.current)
        guard !categories.isEmpty else { return .terminateNow }

        Task { @MainActor in
            await BrowsingDataCleaner.clear(categories)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
