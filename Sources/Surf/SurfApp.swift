import SurfCore
import SwiftUI

@main
struct SurfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One session for the app. Held here rather than in `ContentView` so the
    /// menu commands below can drive the same tabs the window is showing.
    @State private var session: BrowserSession

    init() {
        // Must precede BrowserSession, which consults these on construction.
        PrivacySettings.registerDefaults()
        // First of all: it prints what would be injected and exits, so it
        // should not pay for anything set up after it.
        PageScripts.dumpAndExitIfAsked()

        // Also before the session, and for a sharper reason: the session may
        // start loading a page the moment it exists, and rules that arrive
        // after the first request arrive too late for it.
        ContentBlocker.shared.prepare()
        _session = State(initialValue: BrowserSession())
    }

    /// Mirrors ContentView's storage, so the menu item reflects and drives the
    /// same preference.
    @AppStorage(PreferenceKeys.sidebarPinned) private var isSidebarPinned = false

    /// Also mirrored in Settings. Both write the same key, and both re-apply on
    /// change, so whichever the user reaches for the other agrees immediately.
    @AppStorage(PreferenceKeys.appearanceMode) private var appearanceMode = AppearanceMode.default

    var body: some Scene {
        WindowGroup("Surf") {
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

            // A submenu with checkmarks, which is what a Picker becomes in a
            // menu. No keyboard shortcut: every free ⌘-key near this is already
            // spoken for somewhere in the browser, and a scheme is not
            // something anyone flips often enough to need one.
            Picker("Appearance", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: appearanceMode) { _, mode in
                AppearanceController.apply(mode)
            }

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

        CommandMenu("Islands") {
            Button("New Island") {
                session.select(island: session.createIsland())
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            // ⌥⌘← / ⌥⌘→ rather than anything with ⌘⇧ brackets: those are tabs,
            // and an island is a bigger move than a tab — the arrows read as
            // travelling somewhere.
            Button("Previous Island") { session.cycleIsland(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Island") { session.cycleIsland(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(session.islands.count < 2)

            // Named for what it does. "Delete Island" reads like closing a
            // window; this throws away every login inside it.
            Button("Delete Island and Its Data", role: .destructive) {
                session.requestDeleteIsland(session.currentIsland)
            }
            .disabled(session.currentIsland.isHome)

            Divider()

            // ⌥⌘1–⌥⌘9. ⌘1–⌘9 are spoken for by tabs, and ⌃1–⌃9 — the obvious
            // second choice — never reach the app at all: macOS takes them for
            // Mission Control's desktop switching, silently. So Option-Command
            // is the island modifier throughout, arrows included.
            ForEach(1...9, id: \.self) { index in
                Button("Show Island \(index)") { session.selectIsland(atOneBasedIndex: index) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index)")),
                        modifiers: [.command, .option]
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

            // Named for what it is. Surf can't host a JS debugger at all, and
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

        // Here rather than in `SurfApp.init`, which runs before `NSApp`
        // exists. Everything inherits from the application object, so this one
        // line reaches every window and every tab's web view.
        AppearanceController.apply()

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
