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
    ///
    /// Split one computed property per menu. It was a single block before, and
    /// a single block is how View ended up holding navigation, tab switching,
    /// splits and groups: there was nowhere else for anything to go.
    @CommandsBuilder
    private var tabCommands: some Commands {
        fileCommands
        findCommands
        viewCommands
        historyCommands
        windowCommands
        islandCommands
        developCommands
    }

    // MARK: - File

    /// Replaces the stock "New Window" (⌘N) rather than sitting after it. Surf
    /// is one window: there is a single `BrowserSession` and each tab owns one
    /// `WKWebView`, which can be in one view hierarchy at a time — a second
    /// window from the same `WindowGroup` would share every tab and
    /// `WebViewContainer.present` would pull each page out of whichever window
    /// showed it last. ⌘N is left unbound on purpose. Pointing it at New Tab
    /// would mean a shortcut the menu cannot draw (one item, one key), and a
    /// key that beeps is easier to understand than one that does something the
    /// menu never admitted to.
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { session.openNewTabAndPrompt() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") { session.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)

            // ⌘W belongs to the tab in a browser, so the window moves up one.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])

            Divider()

            // Typing an address is how you open something, which is the verb
            // this menu is named for. It lived in View only because View was
            // where everything lived.
            Button("Open Location…") { session.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)

            Divider()

            // Beside the other "get something out of the page" verbs — a
            // screenshot is an export, not a view option.
            Button("Screenshot Area…") {
                session.selectedTab.beginAreaCapture()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Screenshot Visible Area") {
                let tab = session.selectedTab
                Task { @MainActor in
                    guard let image = await tab.captureVisibleArea() else { return }
                    ScreenshotPreviewController.shared.show(image, title: tab.displayTitle)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift, .option])

            Button("Screenshot Full Page") {
                let tab = session.selectedTab
                Task { @MainActor in
                    guard let image = await tab.captureFullPage() else { return }
                    ScreenshotPreviewController.shared.show(image, title: tab.displayTitle)
                }
            }
        }
    }

    // MARK: - Edit

    /// Replaces the stock Edit-menu find items, which act on text fields and
    /// know nothing about the page.
    private var findCommands: some Commands {
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
    }

    // MARK: - View

    /// Only what changes how the current page is presented. Everything that
    /// used to sit here alongside it — back and forward, tab switching, splits,
    /// groups, Open Location — was somewhere else's business.
    private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            // ⌘⇧L, not ⌘S: Save is the most universally spoken-for key on the
            // Mac, and Safari has trained the same hand to reach for ⌘⇧L to
            // show a browser sidebar.
            Button(isSidebarPinned ? "Unpin Sidebar" : "Pin Sidebar") {
                isSidebarPinned.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            // Enabled on any page, not just detected ones: the classifier is
            // advice for the pill, and extraction itself is the better judge —
            // its failure mode is a message, not a mangled page.
            Button(session.selectedTab.isFocusActive ? "Leave Focus" : "Enter Focus") {
                session.selectedTab.toggleFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(session.selectedTab.mode != .browsing)

            Divider()

            Button("Reload") { session.selectedTab.reload() }
                .keyboardShortcut("r", modifiers: .command)

            Button("Reload Ignoring Cache") { session.selectedTab.reloadIgnoringCache() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Stop") { session.selectedTab.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!session.selectedTab.isLoading)

            Divider()

            // Zoom is per-tab, so these read against whatever is on screen.
            // Bound to "=" rather than "+": + is a shifted key on most layouts,
            // so binding it literally means ⌘= — what people actually press —
            // never arrives. AppKit draws it as ⌘+ regardless.
            Button("Zoom In") { session.selectedTab.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)

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
        }
    }

    // MARK: - History

    /// Back and forward are the whole reason this menu exists: they are what a
    /// browser's users reach here for, and a tab's own back/forward list is the
    /// only history Surf keeps by default.
    ///
    /// There is deliberately no list of visited pages. `HistoryStore` lives in
    /// memory so that typing "git" can offer github, and it dies with the
    /// process unless the user turns persistence on — so a menu that browsed it
    /// would contradict the promise the app is built around.
    private var historyCommands: some Commands {
        CommandMenu("History") {
            Button("Back") { session.selectedTab.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!session.selectedTab.canGoBackOrClose)

            Button("Forward") { session.selectedTab.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!session.selectedTab.canGoForward)

            Button("Home") { session.selectedTab.goHome() }
                .disabled(session.selectedTab.mode == .home)

            Divider()

            Button("Reopen Closed Tab") { session.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!session.canReopenClosedTab)
        }
    }

    // MARK: - Window

    /// Tab switching and the split live here rather than in a Tabs menu of
    /// their own, which is both where Safari puts them and what keeps the menu
    /// bar at the nine menus a browser is expected to have.
    ///
    /// Grouping is absent on purpose: it is a drag-and-right-click gesture in
    /// the sidebar, and the sidebar's own context menu already carries it.
    private var windowCommands: some Commands {
        CommandGroup(after: .windowSize) {
            Button("Show Previous Tab") { session.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Button("Show Next Tab") { session.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Divider()

            // One key for both halves of the same state, in the house style of
            // Enter/Leave Focus and Show/Hide Developer Tools. The split was on
            // ⌘D, which every other browser spends on bookmarking, and swapping
            // sides was on ⌘⌥D — the system's Dock-hiding shortcut, which never
            // reaches the app at all. Swapping is rare enough to live without
            // one rather than be given some third awkward chord.
            if session.isSplit {
                Button("Close Split") { session.closeSplit() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Swap Split Sides") { session.swapSplitSides() }
            } else {
                Button("Split With Next Tab") { session.splitWithNextTab() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(session.tabs.count < 2)
            }

            Divider()

            // The tabs that are actually open, by name. This was nine fixed
            // "Show Tab N" items, seven of which usually pointed at nothing and
            // did nothing when picked — enabled, silently inert.
            ForEach(Array(session.tabs.enumerated()), id: \.element.id) { entry in
                tabMenuItem(entry.element, at: entry.offset, of: session.tabs.count)
            }
        }
    }

    @ViewBuilder
    private func tabMenuItem(_ tab: Tab, at index: Int, of count: Int) -> some View {
        let item = Toggle(
            isOn: Binding(
                get: { session.selectedTab.id == tab.id },
                set: { _ in session.select(tab) }
            )
        ) {
            Text(tab.displayTitle)
        }

        if let position = Self.shortcutPosition(at: index, of: count) {
            item.keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
        } else {
            item
        }
    }

    /// ⌘1–⌘8 by position, and ⌘9 for the last one — but only once there are
    /// more than eight, because below that the last tab already has a number of
    /// its own and a second key aimed at it would just be a duplicate the menu
    /// has no way to draw.
    private static func shortcutPosition(at index: Int, of count: Int) -> Int? {
        if index < 8 { return index + 1 }
        if index == count - 1 { return 9 }
        return nil
    }

    // MARK: - Islands

    private var islandCommands: some Commands {
        CommandMenu("Islands") {
            Button("New Island") {
                // Straight into the editor: the moment you make an island is
                // the moment you know what it's for.
                session.createIslandAndEdit()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Edit Island…") {
                session.beginEditing(session.currentIsland)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Divider()

            // ⌥⌘← / ⌥⌘→ rather than anything with ⌘⇧ brackets: those are tabs,
            // and an island is a bigger move than a tab — the arrows read as
            // travelling somewhere.
            Button("Previous Island") { session.cycleIsland(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Island") { session.cycleIsland(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(session.islands.count < 2)

            Divider()

            // ⌥⌘1–⌥⌘9. ⌘1–⌘9 are spoken for by tabs, and ⌃1–⌃9 — the obvious
            // second choice — collide with Mission Control's desktop switching,
            // which is on by default once you have more than one desktop and
            // takes the key before any app sees it. So Option-Command is the
            // island modifier throughout, arrows included.
            ForEach(Array(session.islands.enumerated()), id: \.element.id) { entry in
                islandMenuItem(entry.element, at: entry.offset, of: session.islands.count)
            }

            Divider()

            // ⌘D, the key every other browser spends on bookmarking, pointed at
            // Surf's version of the same idea. Stickers belong in this menu
            // rather than one of their own because they are island-scoped — a
            // top-level Bookmarks menu would misrepresent where they live.
            Button("Add Sticker") {
                withAnimation(StickerShelf.slap) {
                    session.pinSticker(for: session.selectedTab)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(session.selectedTab.mode != .browsing)

            Divider()

            // Named for what it does. "Delete Island" reads like closing a
            // window; this throws away every login inside it.
            Button(session.deleteTitle(for: session.currentIsland), role: .destructive) {
                session.requestDeleteIsland(session.currentIsland)
            }
            .disabled(session.currentIsland.isHome)
        }
    }

    @ViewBuilder
    private func islandMenuItem(_ island: Island, at index: Int, of count: Int) -> some View {
        let item = Toggle(
            isOn: Binding(
                get: { session.currentIsland === island },
                set: { _ in session.select(island: island) }
            )
        ) {
            Text(island.name)
        }

        if let position = Self.shortcutPosition(at: index, of: count) {
            item.keyboardShortcut(
                KeyEquivalent(Character("\(position)")),
                modifiers: [.command, .option]
            )
        } else {
            item
        }
    }

    // MARK: - Develop

    private var developCommands: some Commands {
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

        // AppKit's own window tabbing puts a second "Show Previous Tab" and
        // "Show Next Tab" in the Window menu — same names as Surf's, no
        // shortcuts, wired to NSWindow tabs that Surf never creates — and
        // injects them in the middle of ours, splitting the group in two. Surf
        // draws its own tabs in the sidebar and hides the title bar, so there
        // is nothing here to keep.
        NSWindow.allowsAutomaticWindowTabbing = false

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
            // Bounded, because the work now scales with the number of islands
            // and every one of them is a round trip to WebKit. An app that
            // won't quit is a worse failure than one that quits having cleared
            // most of what it promised — and whatever is missed is cleared on
            // the next launch's quit, since the setting is still on.
            let clearing = Task { @MainActor in
                await BrowsingDataCleaner.clear(categories)
            }
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                clearing.cancel()
            }
            await clearing.value
            deadline.cancel()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
