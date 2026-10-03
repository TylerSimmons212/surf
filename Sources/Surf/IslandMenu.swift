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
                // Upward: this button is the last thing at the foot of the
                // sidebar, so a menu dropping from it has nowhere to go.
                .popUp(above: anchor, holding: hold, reason: Self.holdReason)
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
        addIdentity(to: menu)
        return menu
    }

    // MARK: Who you are

    /// The island, as the thing the menu is about and the way into its
    /// settings.
    ///
    /// A view rather than menu items, which is the one place in this menu that
    /// departs from AppKit's own furniture. An item can only be dimmed grey
    /// text here — no colour, no shape — so the island's name never read as the
    /// subject of its own menu, and the tint that identifies it everywhere else
    /// in the app went unused. The circle is the one on the button that was
    /// just clicked, which is the point: the menu should look like it came out
    /// of that button.
    ///
    /// It is also where Rename went. A menu row called "Rename…" is one of the
    /// three things the island editor does, and listing one of them flat while
    /// the other two are only reachable through it is a worse map than making
    /// the island itself the way in. So the header highlights on hover and
    /// opens the editor — which costs it the thing a header normally gets for
    /// free, since a view item has to draw its own highlight and answer for its
    /// own accessibility. `IslandHeaderView` does both.
    private func addHeader(to menu: NSMenu) {
        let session = self.session
        let island = self.island
        menu.addView(
            IslandHeaderView(island: island) { session.beginEditing(island) }
        )
        // Only ever shown for something that is actually wrong, and the one
        // fact important enough to survive the header losing its second line:
        // an island that cannot keep its storage forgets every login at quit.
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

        menu.addSubmenu("Cookies") { sites in
            // The parent stays enabled on an empty jar so this can be read.
            // Disabling it would withhold exactly the answer somebody opened
            // the menu for, and a disabled parent cannot be opened to say it.
            guard !jar.isEmpty else {
                sites.addNote("No cookies in this island")
                return
            }

            // The scope lives here rather than on the parent row. "Cookies —
            // 9 cookies in 2 sites" said cookies twice and spent the widest
            // row in the menu on a number nobody had asked for yet; a noun
            // and a chevron is what the row is actually offering.
            //
            // It stays somewhere, because this list is capped. A dozen rows
            // that silently stand for forty is the one case where the total
            // is load-bearing.
            sites.addItem(NSMenuItem.sectionHeader(title: jar.headline))

            for row in jar.domains {
                sites.addRow(
                    row.rowTitle,
                    icon: NSMenuItem.menuFavicon(host: row.domain),
                    symbol: "globe",
                    action: "trash"
                ) {
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
            // No ellipsis. It would promise a dialog that asks for something,
            // and the one this opens only asks whether you meant it.
            sites.addRow("Clear Cookies", symbol: "birthday.cake", action: "trash") {
                Task { @MainActor in
                    await session.requestClearCookies(
                        of: island, cookies: jar.totalCookies, sites: jar.totalDomains
                    )
                }
            }
        }
        // The same symbol the dev tools storage pane uses for cookies, so the
        // two places that list a jar agree about what one looks like.
        .symbol("birthday.cake")
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

        menu.addSubmenu("Tabs") { list in
            if !pinned.isEmpty {
                list.addItem(NSMenuItem.sectionHeader(title: "Pinned"))
                for tab in pinned { add(tab, to: list, isPinned: true) }
                if !listed.isEmpty {
                    list.addItem(NSMenuItem.sectionHeader(title: "Tabs"))
                }
            }
            for tab in listed { add(tab, to: list, isPinned: false) }
        }
        // Not `rectangle.on.rectangle`, which already means "pop out" in three
        // other places in this app.
        .symbol("rectangle.stack")
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
        menu.addRow(
            tab.displayTitle,
            // Its own favicon, which is the fastest way to find a tab in a
            // list and the reason this submenu is worth opening at all. The
            // star went with it: one image slot, and the Pinned section above
            // already says which these are.
            icon: tab.favicon ?? NSMenuItem.menuFavicon(
                host: tab.currentURL.flatMap(URL.init(string:))?.host
            ),
            symbol: isPinned ? "star.fill" : "globe",
            action: "arrow.right",
            isChecked: tab.id == session.selectedTabID
        ) {
            session.select(tab)
        }
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
                list.addRow(
                    tab.rowTitle,
                    icon: NSMenuItem.menuFavicon(
                        host: tab.url.flatMap(URL.init(string:))?.host
                    ),
                    symbol: "globe",
                    action: "arrow.uturn.backward"
                ) {
                    session.reopenClosedTab(at: index)
                }
            }
            list.addItem(.separator())
            // Not confirmed: nothing is destroyed that was not already closed,
            // and the buffer is the one thing here that only exists in memory.
            list.addRow("Forget These", symbol: "xmark", action: "trash") {
                session.forgetClosedTabs(in: island)
            }
        }
        .symbol("arrow.uturn.backward")
    }

    // MARK: The island itself

    /// What is left of the island's own affairs once the header has them.
    ///
    /// Rename moved into the header, which is now the way into the editor it
    /// was one third of. New Island went entirely: the dots a few points away
    /// already offer it, and this menu is about *this* island — a row that
    /// makes a different one was the only thing in it that wasn't.
    ///
    /// Deleting stays, behind a separator, because it is the one thing here
    /// that cannot be undone and the editor has nowhere to put it.
    private func addIdentity(to menu: NSMenu) {
        guard !island.isHome else { return }
        let session = self.session
        let island = self.island

        menu.addItem(.separator())
        menu.addAction(session.deleteTitle(for: island)) {
            // Off the tracking loop: this one asks first.
            Task { @MainActor in session.requestDeleteIsland(island) }
        }
        .symbol("trash")
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

@MainActor
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
        if item.action == nil, item.submenu == nil, item.view == nil {
            marks.append("unclickable")
        }
        if item.state == .on { marks.append("selected") }
        // Both the name and the size. `name()` is nil for a symbol image, so
        // on its own it reported "no icon" for every row that had one — and
        // the size is the half that matters, since an image a menu will not
        // draw looks exactly like an image that was never set.
        if let image = item.image {
            let size = "\(Int(image.size.width))x\(Int(image.size.height))"
            marks.append("icon \(image.name() ?? "symbol") \(size)")
        }

        // A view item has no title of its own, so it answers as its view does
        // to VoiceOver — which is the only description of it that exists, and
        // therefore the one worth checking.
        let title = item.view.map { view in
            "<view: \(view.accessibilityLabel() ?? "no accessibility label")>"
        } ?? item.title

        let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: " "))]"
        debugLog("island menu: \(pad)\(title)\(suffix)")
        if let submenu = item.submenu { describe(submenu, depth: depth + 1) }
    }
}

// MARK: - The header

/// The island, drawn the way the sidebar draws it, and the way into its
/// settings.
///
/// A menu item can carry an icon and a title and nothing else — no second
/// colour, no shape, no tint. This island is identified by a coloured circle
/// everywhere else in the app, including on the button this menu hangs from,
/// and a menu that opened out of that button looking like unrelated grey text
/// was the single thing most worth fixing about it.
///
/// A view item pays for that in three ways, and all three have to be paid
/// rather than skipped: AppKit draws no highlight for it, routes no keyboard
/// selection to it, and reports nothing to VoiceOver about it. So it tracks
/// the pointer itself, answers as a button, and performs on a press from
/// either direction.
@MainActor
private final class IslandHeaderView: NSView {

    private let run: () -> Void
    private let tint: NSColor
    private let name: NSTextField
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            name.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            needsDisplay = true
        }
    }

    /// Wide enough to look like a header rather than a row, and tall enough for
    /// the circle the sidebar uses at the size the sidebar uses it.
    init(island: Island, run: @escaping () -> Void) {
        self.run = run
        self.tint = NSColor(
            srgbRed: island.tint.red,
            green: island.tint.green,
            blue: island.tint.blue,
            alpha: 1
        )
        self.name = Self.label(
            island.name, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 44))

        let badge = NSView(frame: NSRect(x: 14, y: 7, width: 30, height: 30))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 15
        badge.layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
        badge.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor
        badge.layer?.borderWidth = 1
        addSubview(badge)

        let symbol = Self.label(
            island.symbol, font: .systemFont(ofSize: 15), color: .labelColor
        )
        symbol.alignment = .center
        symbol.frame = NSRect(x: 0, y: 6, width: 30, height: 20)
        badge.addSubview(symbol)

        name.frame = NSRect(x: 54, y: 13, width: bounds.width - 68, height: 18)
        addSubview(name)

        setAccessibilityRole(.button)
        setAccessibilityLabel("\(island.name), island settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        // The inset and radius a modern menu highlight uses, since AppKit will
        // not draw this one for us and a square full-bleed fill reads as a
        // different control.
        //
        // `selectedContentBackgroundColor` rather than `selectedMenuItemColor`,
        // which names exactly this and has been deprecated since macOS 11. Both
        // are the accent colour and both follow the system; only one of them
        // still exists.
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 5, yRadius: 5
        ).fill()
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    /// Closes the menu *before* acting, and lets the run loop finish unwinding
    /// the tracking session before the sheet goes up. `popUp` is blocking, so
    /// presenting a window from inside it is a window fighting a tracking loop
    /// for events.
    private func press() {
        enclosingMenuItem?.menu?.cancelTracking()
        let run = self.run
        DispatchQueue.main.async { run() }
    }

    private static func label(
        _ text: String, font: NSFont, color: NSColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
