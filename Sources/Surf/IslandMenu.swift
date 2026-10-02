import AppKit
import SurfCore
import SwiftUI

/// The island's face, and the menu behind it.
///
/// An island already is an account — it owns a cookie jar, it can share that
/// jar with another island, and it can fail to get persistent storage and
/// quietly forget every login at quit. None of that had anywhere to live except
/// a tooltip on a chip, which is a strange place to keep the answer to "am I
/// signed in as me or as work right now?".
///
/// It was a SwiftUI popover with three rows and one sentence. A menu instead,
/// for the reason `DownloadMenu` gives and one more of its own. The reason in
/// common: a popover is its own window, so reaching into it reads as leaving
/// the hover-revealed sidebar. The reason of its own is that most of what this
/// control has to say is *lists* — the sites in the jar, the tabs, the closed
/// tabs — and a list you pick one thing out of is a menu, with hover expansion
/// and keyboard navigation already in it.
///
/// There is a third reason that only shows up in the detail. `recentlyClosed`
/// is `@ObservationIgnored`, so SwiftUI cannot observe it at all and a popover
/// listing it would show a stale buffer. A menu is built once per press from a
/// snapshot and then tracks modally, so every list in it is correct by
/// construction rather than by luck.
///
/// Deliberately not a switcher. `IslandDots` sits a few points away in the same
/// bar and already does that job, inside the sidebar's own window; a second,
/// different-looking island picker next to it would be two answers to one
/// question. `New Island` is the only row in both.
struct IslandProfileButton: View {
    let session: BrowserSession
    let hold: SidebarHold

    private static let holdReason = "island-profile"

    /// Somewhere for the menu to hang from, and a guard against a second press
    /// while the first is still reading the jar.
    @State private var anchor = MenuAnchor()
    @State private var isAsking = false

    var body: some View {
        let island = session.currentIsland

        return Button {
            present()
        } label: {
            Text(island.symbol)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .background { Circle().fill(island.tint.color.opacity(0.22)) }
                .overlay { Circle().strokeBorder(island.tint.color.opacity(0.55), lineWidth: 1) }
                .overlay(alignment: .bottomTrailing) { badge(for: island) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .help(island.name)
        .pointerStyle(.link)
    }

    /// Only ever drawn for something that is actually wrong. An island that is
    /// working says so by wearing nothing.
    @ViewBuilder
    private func badge(for island: Island) -> some View {
        if island.isDegraded {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .background { Circle().fill(.background).padding(-1) }
                .offset(x: 2, y: 2)
        }
    }

    /// Reads the jar, then shows the menu.
    ///
    /// In that order, and the whole menu is a snapshot taken at this one
    /// instant. The alternative is `NSMenuDelegate.menuNeedsUpdate`, which is
    /// the native way to fill a submenu on hover and is wrong here: it is
    /// synchronous and `allCookies()` is not, so the rows would have to arrive
    /// on a later turn of the main loop *while the menu is tracking*, which
    /// reads as a submenu that opens empty and then twitches.
    ///
    /// Not read when the footer draws, either. That would touch the jar of
    /// whichever island you are standing in on every redraw of the sidebar, to
    /// fill a menu nobody has asked for.
    private func present() {
        guard !isAsking else { return }
        isAsking = true
        Task { @MainActor in
            let island = session.currentIsland
            // `island.dataStore` is the memoised `IslandStores` instance, so
            // this builds no web view and wakes no sleeping tab.
            let jar = CookieDomains.summary(of: await CookieStore.cookies(in: island.dataStore))
            isAsking = false

            IslandMenu(session: session, island: island, jar: jar)
                .build()
                .popUp(below: anchor, holding: hold, reason: Self.holdReason)
        }
    }
}

// MARK: - The menu

/// Builds one island's menu from a snapshot of it.
///
/// A struct of three lets rather than a method on the button, so each section
/// is a named function and the order of the whole thing is readable in `build`.
@MainActor
private struct IslandMenu {
    let session: BrowserSession
    let island: Island
    let jar: CookieJarSummary

    private static let degradedLine =
        "Storage unavailable — logins are forgotten when Surf quits."

    func build() -> NSMenu {
        let menu = NSMenu()
        addHeader(to: menu)
        menu.addItem(.separator())
        addCookies(to: menu)
        addTabs(to: menu)
        addRecentlyClosed(to: menu)
        menu.addItem(.separator())
        addIdentity(to: menu)
        return menu
    }

    // MARK: Who you are

    /// Identity, and what it shares.
    ///
    /// Three items rather than one, because they are three facts and a single
    /// multi-line attributed title is one row that cannot be addressed as two.
    /// `sectionHeader` gets the system's own header treatment, which tracks
    /// appearance and is skipped by keyboard navigation for free; the sentences
    /// under it are notes for the same reason.
    private func addHeader(to menu: NSMenu) {
        menu.addItem(NSMenuItem.sectionHeader(title: "\(island.symbol)  \(island.name)"))
        let sharing = session.islandsSharingStore(with: island).map(\.name)
        menu.addNote(IslandLayout.sharingLine(with: sharing))
        if island.isDegraded { menu.addNote(Self.degradedLine) }
    }

    // MARK: What you're signed in to

    /// The jar, one row per site.
    ///
    /// Two levels and no deeper. A cookie's value is a 400-character opaque
    /// token, and three hovers to reach one is the dev tools storage pane's
    /// job — which also has search, and is where the tail beyond the dozen rows
    /// here lives.
    ///
    /// A single site's row is not confirmed. It states its own scope and size
    /// before it is clicked, the cost of being wrong is signing into one place
    /// again, and a confirmation on every row would make the menu useless for
    /// the one job it exists to do.
    private func addCookies(to menu: NSMenu) {
        let store = island.dataStore
        let jar = self.jar
        let session = self.session
        let island = self.island

        menu.addSubmenu(jar.isEmpty ? "Cookies" : "Cookies — \(jar.headline)") { sites in
            // The parent stays enabled on an empty jar so this can be read.
            // Disabling it would withhold exactly the answer somebody opened
            // the menu for, and a disabled parent cannot be opened to say it.
            guard !jar.isEmpty else {
                sites.addNote("No cookies in this island")
                return
            }

            for row in jar.domains {
                sites.addAction(row.rowTitle) {
                    Task { @MainActor in
                        // The cookies the row counted, by identity — never
                        // re-derived from its domain, so it cannot widen.
                        await CookieStore.delete(row.cookies, in: store)
                    }
                }
            }
            if jar.hiddenDomainCount > 0 {
                sites.addNote("and \(jar.hiddenDomainCount) more sites")
            }

            sites.addItem(.separator())
            // The ellipsis says a question is coming. Off the tracking loop,
            // because the question is an app-modal alert.
            sites.addAction("Sign Out of Everything…") {
                Task { @MainActor in
                    await session.requestSignOut(
                        of: island, cookies: jar.totalCookies, sites: jar.totalDomains
                    )
                }
            }
        }
    }

    // MARK: What's open

    /// Every tab in the island, pinned ones included.
    ///
    /// From `island.tabs` rather than `session.tabs`, and that is the submenu's
    /// reason to exist: `session.tabs` filters out sticker-owned tabs, which
    /// have no row anywhere in the sidebar and are reachable only by clicking
    /// the sticker. So the pinned section leads. For ordinary tabs this does
    /// duplicate the list directly above it in the same panel, which is worth
    /// being honest about — they are here so the submenu is the whole island
    /// rather than a surprising subset of it.
    private func addTabs(to menu: NSMenu) {
        let tabs = island.tabs
        guard !tabs.isEmpty else { return }
        let pinned = tabs.filter { $0.stickerID != nil }
        let listed = tabs.filter { $0.stickerID == nil }

        menu.addSubmenu("Tabs — \(tabs.count)") { list in
            if !pinned.isEmpty {
                list.addItem(NSMenuItem.sectionHeader(title: "Pinned"))
                for tab in pinned { add(tab, to: list, isPinned: true) }
                if !listed.isEmpty {
                    list.addItem(NSMenuItem.sectionHeader(title: "Tabs"))
                }
            }
            for tab in listed { add(tab, to: list, isPinned: false) }
        }
    }

    /// One tab's row.
    ///
    /// `displayTitle` never returns empty and never reaches for the web view,
    /// which is what stops hovering this submenu waking every sleeping tab in
    /// the island. The star and the Pinned section say the same thing twice on
    /// purpose: the section names the group, and the star keeps a row that was
    /// arrowed down onto in isolation legible.
    ///
    /// One action for both kinds. `session.select` already handles selecting a
    /// tab that deliberately has no row — the media player needed that first.
    private func add(_ tab: Tab, to menu: NSMenu, isPinned: Bool) {
        let session = self.session
        let item = menu.addAction(tab.displayTitle) { session.select(tab) }
        if isPinned {
            item.image = NSImage(
                systemSymbolName: "star.fill", accessibilityDescription: "Pinned"
            )
        }
        // AppKit draws the state marker and the image in separate columns, so a
        // selected pinned tab shows both.
        if tab.id == session.selectedTabID { item.state = .on }
    }

    /// The closed-tab buffer, which until now had exactly one interface: `⌘⇧T`,
    /// which reopens blind. Listing it is new capability rather than a reskin,
    /// and it is per-island, which this menu is already the right place to say.
    private func addRecentlyClosed(to menu: NSMenu) {
        let closed = island.recentlyClosed
        let session = self.session
        let island = self.island

        menu.addSubmenu("Recently Closed") { list in
            guard !closed.isEmpty else {
                list.addNote("Nothing closed yet")
                return
            }
            for (index, tab) in closed.enumerated() {
                list.addAction(tab.rowTitle) { session.reopenClosedTab(at: index) }
            }
            list.addItem(.separator())
            // Not confirmed: nothing is destroyed that was not already closed,
            // and the buffer is the one thing here that only exists in memory.
            list.addAction("Forget These") { session.forgetClosedTabs(in: island) }
        }
    }

    // MARK: The island itself

    private func addIdentity(to menu: NSMenu) {
        let session = self.session
        let island = self.island

        menu.addAction("Rename…") { session.beginEditing(island) }
        menu.addAction("New Island") { _ = session.createIslandAndEdit() }
        if !island.isHome {
            menu.addAction(session.deleteTitle(for: island)) {
                // Off the tracking loop: this one asks too.
                Task { @MainActor in session.requestDeleteIsland(island) }
            }
        }
    }
}

// MARK: - Verification

/// Writes the menu's rows to stderr, for `SURF_ISLAND_MENU=1`.
///
/// The grouping, the prose and the counts are all pure and tested in SurfCore.
/// What no unit test can reach is the *assembly* — whether the rows come out in
/// the right order, whether a sticker's tab is starred and the selected one
/// ticked, whether an empty jar says so instead of offering to sign out of it.
/// That needed a human clicking through three submenus and describing what they
/// saw, which is not a reasonable way to check a list.
///
/// It builds the menu through `IslandMenu.build()` — the same call the button
/// makes — so what it prints is the real thing rather than a description
/// assembled alongside it and free to disagree.
@MainActor
func dumpIslandMenu(for session: BrowserSession) async {
    let island = session.currentIsland
    let jar = CookieDomains.summary(of: await CookieStore.cookies(in: island.dataStore))
    let menu = IslandMenu(session: session, island: island, jar: jar).build()
    debugLog("island menu: \(island.name) — \(menu.items.count) rows")
    describe(menu, depth: 1)
}

private func describe(_ menu: NSMenu, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    for item in menu.items {
        guard !item.isSeparatorItem else {
            debugLog("island menu: \(pad)--")
            continue
        }
        var marks: [String] = []
        if item.submenu != nil { marks.append("submenu") }
        // A row with no action is one the menu states rather than offers: a
        // note or a section header. Both are unclickable, which is the
        // property worth asserting.
        if item.action == nil, item.submenu == nil { marks.append("unclickable") }
        if item.state == .on { marks.append("selected") }
        if item.image != nil { marks.append("starred") }
        let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: " "))]"
        debugLog("island menu: \(pad)\(item.title)\(suffix)")
        if let submenu = item.submenu { describe(submenu, depth: depth + 1) }
    }
}
