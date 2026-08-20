import AppKit
import Foundation
import SurfCore
import Observation
import WebKit

/// Owns the tab collection and the selection. All tab lifecycle goes through
/// here so the invariant below holds in one place.
@Observable
@MainActor
final class BrowserSession {

    /// Every island, in sidebar order. Never empty, and exactly one of them is
    /// the home island — the one on WebKit's default store.
    private(set) var islands: [Island]

    /// The island being looked at. Its tabs are the ones the sidebar lists.
    private(set) var currentIsland: Island

    /// Invariant: the current island is never empty, and `selectedTabID`
    /// always names a live tab **in it**. Every view can therefore render a
    /// selected tab without a nil branch.
    ///
    /// Background islands are allowed to be empty, and that asymmetry is
    /// deliberate: forcing every island to hold a tab means a phantom "New
    /// Tab" row and a `Tab` object apiece for islands nobody has opened in a
    /// month. The cost is one rule — switching to an empty island creates its
    /// home tab first — and in exchange `selectedTab` stays non-optional.
    /// The tabs the sidebar lists, which is every tab in the island except the
    /// ones stickers own — those already have a place on screen.
    ///
    /// The listed tabs, not all of them, because that is what every consumer of
    /// this means: the rows to draw, the run to cycle through, the thing ⌘1
    /// counts from. The handful of places that genuinely need every tab —
    /// resolving a selection, deciding whether to pop out — reach through
    /// `currentIsland.tabs` instead, and say why.
    var tabs: [Tab] { currentIsland.tabs.filter { $0.stickerID == nil } }
    private(set) var selectedTabID: Tab.ID

    /// Every tab in every island. For the things that genuinely span them:
    /// hibernation, and whatever is playing audio.
    var allTabs: [Tab] { islands.flatMap(\.tabs) }

    /// The two tabs on screen side by side, or nil when one page fills the
    /// window.
    ///
    /// Ordered by *position*, not by focus, and that separation is the whole
    /// design. Focus is still `selectedTabID` — so all the chrome that follows
    /// the selected tab keeps working untouched — but clicking the right-hand
    /// page must not make it jump to the left. Storing the sides here and the
    /// focus there is what lets focus move without anything sliding around.
    ///
    /// Invariant, upheld by `setSplit`: when this is non-nil both tabs are live
    /// and in the current island, they are distinct, and `selectedTabID` is one
    /// of them.
    private(set) var split: SplitPanes?

    /// Which tabs are showing right now — one, or two when split.
    var visibleTabIDs: Set<Tab.ID> {
        guard let split else { return [selectedTabID] }
        return [split.leading, split.trailing]
    }

    func isVisible(_ tab: Tab) -> Bool { visibleTabIDs.contains(tab.id) }

    /// The live tab for an id, in the island on screen.
    func tab(_ id: Tab.ID) -> Tab? { currentIsland.tabs.first { $0.id == id } }

    /// Deep enough to cover a run of accidental closes, shallow enough that it
    /// isn't quietly accumulating everywhere you've been.
    ///
    /// The buffer itself lives on the island, so ⌘⇧T can't reopen a work tab
    /// into a personal island.
    static let closedTabMemory = 12

    var canReopenClosedTab: Bool { !currentIsland.recentlyClosed.isEmpty }

    /// Incremented to ask the focused view to open the address bar (⌘L).
    /// A token rather than a Bool, so repeat presses each register.
    private(set) var focusAddressToken: Int = 0

    /// Same token idiom for the find bar: ⌘F opens or re-focuses it, and ⌘G
    /// steps through matches without the menu needing a handle on the view.
    private(set) var findToken: Int = 0
    private(set) var findStepToken: Int = 0
    private(set) var findStepsForward = true

    /// Whether the pending address-bar request should land in a *new* tab.
    /// The tab isn't created until something is submitted, so backing out of
    /// "New Tab" leaves the session exactly as it was.
    private(set) var addressFocusCreatesTab = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var reclaimTimer: Task<Void, Never>?
    /// Suppresses saves while restoring, so a half-built session can't
    /// overwrite the file we're still reading from.
    @ObservationIgnored private var isRestoring = false

    init(restoring restored: PersistedSession? = BrowserSession.restorableSession()) {
        isRestoring = true

        // `resolvedIslands` migrates a pre-Islands file to a single home
        // island carrying its tabs, so there is one shape to handle here.
        let (persisted, selectedIndex) = (restored ?? PersistedSession(tabs: [], selectedIndex: 0))
            .resolvedIslands

        let built = persisted.map { stored -> Island in
            let island = Island(stored)
            island.replaceTabs(with: stored.tabs.map { tab in
                let live = island.makeTab()
                live.prepareRestore(from: tab)
                return live
            })
            island.rememberedSelection = island.tabs.indices.contains(stored.selectedIndex)
                ? island.tabs[stored.selectedIndex].id
                : island.tabs.first?.id
            // A file can name a group no tab is in, or scatter one that was
            // whole when it was written — an older build, a hand edit, or tabs
            // dropped by the privacy filter on the way out. Repaired on the way
            // in, so nothing downstream has to cope with a section in two
            // pieces.
            island.pruneEmptyGroups()
            island.normalizeGroups()
            return island
        }

        self.islands = built
        let current = built[min(selectedIndex, built.count - 1)]
        self.currentIsland = current

        // The current island is the one place the never-empty rule applies, so
        // it's the one place a tab is conjured to satisfy it.
        let selected: Tab
        if let remembered = current.tabs.first(where: { $0.id == current.rememberedSelection }) {
            selected = remembered
        } else if let first = current.tabs.first {
            selected = first
        } else {
            let fresh = current.makeTab()
            current.append(fresh)
            selected = fresh
        }
        self.selectedTab = selected
        self.selectedTabID = selected.id

        for island in built {
            for tab in island.tabs { tab.session = self }
        }
        isRestoring = false
        // The one selection that doesn't go through `adoptSelection`, so the
        // starting tab is told it's on screen by hand.
        selected.didBecomeVisible()

        // Deletions a previous run couldn't finish, retried now — before any
        // island has built a web view, which is the one moment nothing is
        // holding a store.
        Task { @MainActor in await IslandStores.shared.collectTombstones() }

        startReclaimTimer()

        // Quitting doesn't give the debounced save time to fire, so flush.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Blocking, and with fresh interaction state: this is the last
            // chance to write, so it must finish before the process goes, and
            // it's the one save where an exact scroll position is worth paying
            // for.
            MainActor.assumeIsolated { self.saveNow(blocking: true) }
        }
    }

    /// Honours "Reopen tabs on launch" — with it off, the file isn't even read.
    private static func restorableSession() -> PersistedSession? {
        guard PrivacyPolicy.shouldPersistSession(.current) else { return nil }
        return SessionFile.load()
    }

    // MARK: - Persistence

    /// Coalesces the many save triggers (every title change, every navigation)
    /// into one write.
    ///
    /// A throttle rather than a debounce, deliberately. Restarting the timer on
    /// each trigger sounds equivalent, and isn't: pages that rewrite their own
    /// title on a loop — unread counts, a playing video's countdown — retrigger
    /// faster than the delay, so the save was pushed back forever and the
    /// session was never written at all while such a tab was open. Letting an
    /// already-scheduled save run bounds the work to one write per interval and
    /// removes the starvation.
    func scheduleSave() {
        guard !isRestoring else { return }
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            saveTask = nil
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// `blocking` writes on this thread instead of handing off — for quitting,
    /// where there's no later turn of the run loop to finish the job on.
    func saveNow(blocking: Bool = false) {
        let settings = PrivacySettings.current

        // Tab restore turned off: leave nothing behind, and delete anything a
        // previous run wrote. Turning the setting off has to erase the trail,
        // not merely stop adding to it.
        guard PrivacyPolicy.shouldPersistSession(settings) else {
            try? FileManager.default.removeItem(at: SessionFile.url)
            return
        }

        // Every island, not just the one on screen: a background island's
        // tabs are no less the user's for not being visible right now.
        let snapshot = PersistedSession(
            islands: islands.map { island in
                island.snapshot(
                    refreshingState: blocking,
                    selected: island === currentIsland ? selectedTabID : nil
                )
            },
            selectedIslandIndex: islands.firstIndex { $0 === currentIsland } ?? 0
        )
        // Strips each tab's back/forward blob when history is off.
        let redacted = PrivacyPolicy.redact(snapshot, for: settings)

        // A session of only home tabs sanitizes to nil — write it as empty so
        // closing everything and quitting doesn't resurrect old tabs.
        let toWrite = redacted.sanitized() ?? PersistedSession(tabs: [], selectedIndex: 0)

        // Reading the tabs has to happen here, on the main actor. Encoding and
        // writing do not — and they're the expensive half, since every
        // interaction-state blob is base64'd on the way into JSON. Handing them
        // to the writer keeps a save off the frame that triggered it.
        guard !blocking else {
            SessionWriter.writeSynchronously(toWrite)
            return
        }
        Task.detached(priority: .utility) {
            await SessionWriter.shared.write(toWrite)
        }
    }

    /// The tab to show in the media player: whatever is playing, else the most
    /// recent thing that was.
    /// Across every island, deliberately. Switching islands is not a request
    /// to stop the music, and a player that vanished when you did would be
    /// worse than one showing a tab you can't see in the list.
    var nowPlayingTab: Tab? {
        allTabs.first { $0.media?.isPlaying == true } ?? allTabs.first { $0.media != nil }
    }

    /// Every tab holding media, with the active one first — that's the row the
    /// stack shows when collapsed.
    var mediaTabs: [Tab] {
        let holding = allTabs.filter { $0.media != nil }
        guard let primary = nowPlayingTab else { return holding }
        return [primary] + holding.filter { $0.id != primary.id }
    }

    /// The selected tab, held rather than searched for.
    ///
    /// This was `tabs.first { $0.id == selectedTabID }`, which is correct but
    /// reads the whole `tabs` array — so under `@Observable` every view that
    /// asked for the selected tab became an observer of the array itself, and
    /// adding or closing any tab invalidated the window chrome, the sidebar,
    /// and the entire menu-bar command tree together. The menu commands alone
    /// ask fifteen times per evaluation.
    ///
    /// Kept honest by `setSelection`, which is the one path selection changes
    /// through, and by `close`/`reopenClosedTab` for the cases that replace the
    /// array wholesale.
    private(set) var selectedTab: Tab

    /// Restores the invariant after a mutation, and is the only writer of the
    /// selection pair — the two must never disagree.
    ///
    /// Also the one place tabs are told whether they're being looked at. A tab
    /// that isn't on screen has no business restyling itself or sampling its
    /// own colours, and telling it here means the rule can't be forgotten at a
    /// call site.
    private func adoptSelection(_ tab: Tab) {
        let outgoing = selectedTab
        selectedTab = tab
        selectedTabID = tab.id
        // Kept in step as we go rather than written on the way out of an
        // island: switching away is not the only way to leave one — quitting
        // is too, and the remembered tab is what the next launch opens.
        currentIsland.rememberedSelection = tab.id

        // Selecting a tab that isn't part of the split ends it: the new page
        // fills the window, and a pair that outlived the selection would leave
        // a pane on screen belonging to neither.
        if let split, !split.contains(tab.id) { setSplit(nil) }

        // Arriving inside a collapsed section opens it. Selection can come from
        // outside the list — command-1, control-tab, a link opening a tab — and
        // landing on a page whose row is folded away leaves the sidebar showing
        // nothing selected at all. Collapsing a section that already holds the
        // current tab is left alone: that one is deliberate, and the header
        // says so.
        if let groupID = tab.groupID, let group = currentIsland.group(groupID), group.isCollapsed {
            group.isCollapsed = false
        }

        // Losing focus is not the same as leaving the screen. The other pane of
        // a split is still right there, and telling it otherwise stops its
        // restyling and starts its hibernation clock while it's still visible.
        if outgoing !== tab, !isVisible(outgoing) { outgoing.didResignVisible() }
        tab.didBecomeVisible()
        reclaimIdleTabs()
    }

    // MARK: - Reclaiming

    /// Puts idle background tabs to sleep, returning their web content
    /// processes.
    ///
    /// The decision itself is `TabHibernation`, which is pure and tested; this
    /// only gathers the facts and carries out the verdict. What counts as
    /// untouchable is decided here because only the session knows it: the tab
    /// on screen, anything playing, anything popped out, and anything being
    /// inspected.
    ///
    /// Dev tools has to be on that list precisely because its panels are
    /// per-tab: inspecting one page while looking at another is the normal way
    /// to use them, so an inspected tab is in use even when it isn't visible.
    /// Reclaiming it takes the web view out from under the panel, and every
    /// injected agent with it — the console stops, the tree freezes, and
    /// nothing says why.
    private func reclaimIdleTabs() {
        let now = Date()
        let candidates = allTabs.map { tab in
            TabHibernation.Candidate(
                id: tab.id,
                lastViewedAt: tab.lastViewedAt,
                isLive: tab.isLive,
                // Only the tab actually on screen. A background island's
                // remembered selection is exactly the kind of tab worth
                // reclaiming — nobody has looked at it since they switched
                // away, which is the whole memory case for islands.
                isProtected: visibleTabIDs.contains(tab.id)
                    || tab.media?.isPlaying == true
                    || PopOutController.shared.isPoppedOut(tab)
                    || DevToolsController.shared.isOpen(for: tab)
            )
        }

        let doomed = Set(TabHibernation.tabsToSleep(among: candidates, now: now))
        guard !doomed.isEmpty else { return }
        for tab in allTabs where doomed.contains(tab.id) {
            tab.sleep()
        }
    }

    /// Idle tabs go stale on the clock, not on interaction, so something has to
    /// look while nothing is happening — otherwise a session left open all
    /// afternoon holds every process until the next time you touch a tab.
    private func startReclaimTimer() {
        reclaimTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.reclaimIdleTabs()
            }
        }
    }

    /// The island whose editor sheet is open, if any.
    ///
    /// On the session rather than in the sidebar's own state because the sheet
    /// is presented from the window, not the strip: the sidebar can be a
    /// floating panel that hides when the pointer leaves it, and a sheet
    /// anchored to something that disappears goes with it.
    var islandBeingEdited: Island?

    /// Whether that editor opened as part of creating the island, rather than
    /// revisiting one. Cancelling means different things in the two cases.
    private(set) var islandEditorIsForNewIsland = false

    /// Opens the editor for an island.
    func beginEditing(_ island: Island, isNew: Bool = false) {
        islandEditorIsForNewIsland = isNew
        islandBeingEdited = island
    }

    /// Makes an island, shows it, and opens its editor — the whole of what
    /// "New Island" means, in one place rather than at each call site.
    @discardableResult
    func createIslandAndEdit() -> Island {
        let island = createIsland()
        select(island: island)
        beginEditing(island, isNew: true)
        return island
    }

    /// The island a tab belongs to.
    ///
    /// A search rather than a back-pointer on `Tab`: islands hold few enough
    /// tabs that this is free, and a stale pointer here would file a tab under
    /// the wrong cookie jar, which is the one error worth designing out.
    func island(holding tab: Tab) -> Island? {
        islands.first { $0.contains(tab) }
    }

    // MARK: - Islands

    /// A new island, with its own cookie jar.
    ///
    /// The identifier is minted here and never reused: a store is the island's
    /// identity as far as WebKit is concerned, and handing a new island an old
    /// one would hand it someone else's logins.
    @discardableResult
    func createIsland(
        name: String? = nil,
        symbol: String = IslandSymbols.fallback,
        tint: IslandTint? = nil
    ) -> Island {
        let island = Island(
            id: UUID(),
            name: name ?? IslandLayout.defaultName(existing: islands.map(\.name)),
            symbol: symbol,
            tint: tint ?? IslandTint.next(after: islands.map(\.tint)),
            dataStoreID: UUID()
        )
        islands.append(island)
        scheduleSave()
        return island
    }

    /// Brings an island on screen.
    ///
    /// The one place the never-empty rule is paid for: a background island may
    /// hold nothing, so arriving at one has to give it a tab before the
    /// selection is adopted — otherwise `selectedTab` would have to be optional
    /// and every view would grow a nil branch to serve a case that lasts
    /// microseconds.
    func select(island: Island) {
        guard island !== currentIsland, islands.contains(where: { $0 === island }) else { return }

        // Same courtesy as switching tabs: don't take a video off screen
        // without leaving it somewhere watchable.
        if shouldAutoPopOut(selectedTab) {
            PopOutController.shared.popOut(selectedTab)
        }
        currentIsland.rememberedSelection = selectedTabID
        currentIsland = island

        let target: Tab
        if let remembered = island.tabs.first(where: { $0.id == island.rememberedSelection }) {
            target = remembered
        } else if let first = island.tabs.first {
            target = first
        } else {
            let fresh = island.makeTab()
            fresh.session = self
            island.append(fresh)
            target = fresh
        }

        // Arriving at a tab that's floating in its own window folds it back in,
        // exactly as selecting it from the list would.
        if PopOutController.shared.isPoppedOut(target) {
            PopOutController.shared.restore()
        }

        adoptSelection(target)
        scheduleSave()
    }

    func selectIsland(atOneBasedIndex index: Int) {
        guard let target = TabSelection.index(forOneBased: index, count: islands.count) else {
            return
        }
        select(island: islands[target])
    }

    func cycleIsland(by offset: Int) {
        guard let current = islands.firstIndex(where: { $0 === currentIsland }),
              let next = TabSelection.cycled(from: current, by: offset, count: islands.count)
        else { return }
        select(island: islands[next])
    }

    func rename(_ island: Island, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        island.name = trimmed
        scheduleSave()
    }

    /// Asks first, because this cannot be undone.
    ///
    /// A confirmation on a destructive menu item is ordinary caution; here it
    /// is also load-bearing. SwiftUI rebuilds this menu whenever the island
    /// list changes, and a click arriving during that rebuild can be dispatched
    /// to a neighbouring item — observed, not theorised, while testing this
    /// very menu. Every other item in it is harmless to trigger by accident.
    /// This one throws away every login in an island.
    func requestDeleteIsland(_ island: Island) {
        guard !island.isHome, islands.count > 1 else { return }

        let alert = NSAlert()
        alert.messageText = "Delete “\(island.name)”?"
        alert.informativeText = """
            Its tabs will close, and every cookie, login and site setting that \
            belongs to this island will be erased. This cannot be undone.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Island and Its Data")
        alert.addButton(withTitle: "Cancel")
        // So Return cancels and the destructive button has to be aimed at.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteIsland(island)
    }

    /// Deletes an island and everything it knows about you.
    ///
    /// The order is the whole method. Each step exists because the one before
    /// it can fail:
    ///
    /// 1. The home island stays. Its store is WebKit's default one, which isn't
    ///    ours to delete, and it holds every cookie from before islands existed.
    /// 2. Switch away first, so the "current island is never empty" invariant
    ///    is never briefly false while tabs are being torn down under it.
    /// 3. Tear down every tab before touching the store — `remove(forIdentifier:)`
    ///    fails while anything still references it, and a live web view is a
    ///    reference even when its tab is asleep.
    /// 4. Persist *before* removing data. A crash after removal but before the
    ///    save leaves an island pointing at a store that's gone, which is worse
    ///    than a store no island claims: the second is collectable, the first
    ///    just fails to load forever.
    func deleteIsland(_ island: Island) {
        guard !island.isHome, islands.count > 1 else { return }
        guard let index = islands.firstIndex(where: { $0 === island }) else { return }

        if island === currentIsland {
            let fallback = IslandLayout.indexAfterDeleting(
                islandAt: index, count: islands.count
            ) ?? 0
            let destination = islands[fallback == index ? max(0, index - 1) : fallback]
            select(island: destination)
        }

        for tab in island.tabs {
            if PopOutController.shared.isPoppedOut(tab) { PopOutController.shared.restore() }
            DevToolsController.shared.close(for: tab)
            tab.teardown()
        }
        island.replaceTabs(with: [])
        island.recentlyClosed.removeAll()
        islands.remove(at: index)
        saveNow()

        guard let storeID = island.dataStoreID else { return }
        Task { @MainActor in
            // Tombstoned first, then retried with a backoff. Tearing down the
            // tabs above is asynchronous, so WebKit is usually still holding
            // the store when we first ask — and if it holds on past the retries
            // the next launch finishes the job.
            await IslandStores.shared.removeData(for: storeID)
        }
    }

    // MARK: - Stickers

    /// Pins a tab's current page to its island's sticker shelf.
    ///
    /// Filed under the island *holding* the tab, not the current one — the two
    /// can differ when pinning from the media player, and a sticker that jumped
    /// islands would open the site in the wrong cookie jar.
    func pinSticker(for tab: Tab) {
        guard let island = island(holding: tab),
              let url = tab.currentURL,
              let sticker = Sticker(url: url, title: tab.displayTitle)
        else { return }

        island.addSticker(sticker)

        // The tab *becomes* the sticker's tab rather than being copied by it.
        // Pinning is a promotion, not a duplication: leaving the row behind
        // would mean the page you just pinned is open twice the moment you
        // click the sticker, and neither copy is more real than the other.
        //
        // Only when the shelf actually took it — pinning a URL already pinned
        // is a no-op, and quietly unlisting this tab into a sticker owned by
        // another one would leave it unreachable.
        guard let pinned = island.stickers.last, pinned.url == sticker.url else { return }

        // A split draws its pair from the listed tabs, so half of one going
        // unlisted would leave the sidebar unable to show the pairing it is
        // still in.
        if split?.contains(tab.id) == true { closeSplit() }
        // It is leaving the list, and a group is a run of tabs *in* the list.
        removeFromGroup(tab)
        tab.stickerID = pinned.id
        scheduleSave()
    }

    /// Peels a sticker off its island's shelf. The sites themselves are
    /// untouched — a sticker is only a pointer.
    func removeSticker(_ sticker: Sticker, from island: Island) {
        // Its tab is handed back to the list rather than closed — the exact
        // inverse of pinning, which took it out of one. Peeling a sticker off
        // says the site no longer deserves a permanent place, not that the
        // page open on it should be thrown away mid-read. Left as it was it
        // would be worse than either: a tab with no row and no sticker,
        // holding a web content process nothing in the interface can reach.
        if let tab = island.tabs.first(where: { $0.stickerID == sticker.id }) {
            tab.stickerID = nil
        }
        island.removeSticker(id: sticker.id)
        scheduleSave()
    }

    /// The live tab a sticker owns, if it has opened one.
    func tab(for sticker: Sticker) -> Tab? {
        currentIsland.tabs.first { $0.stickerID == sticker.id }
    }

    /// The stickers whose tabs are on screen right now, so the shelf can show
    /// which one you are looking at.
    ///
    /// Written to avoid reading the tab array in the common case. Unsplit, the
    /// answer is one property on the one held selected tab — so switching tabs
    /// redraws the shelf, but opening or closing an unrelated tab does not.
    /// Only a split has to go looking, and only while one is up.
    var showingStickerIDs: Set<UUID> {
        guard split != nil else {
            guard let id = selectedTab.stickerID else { return [] }
            return [id]
        }
        let visible = visibleTabIDs
        return Set(
            currentIsland.tabs
                .filter { visible.contains($0.id) }
                .compactMap(\.stickerID)
        )
    }

    /// Opens a sticker — which is to say, selects it. A sticker *is* a tab.
    ///
    /// The tab it owns is made once, on the first click, and selected on every
    /// click after. It is never listed in the sidebar, because the sticker is
    /// already there: a row as well would be one tab in two places, and closing
    /// the row would leave a sticker that looks pinned and is pointing at
    /// nothing. Matched by `stickerID` rather than by URL, so a page the user
    /// opened separately in an ordinary tab stays theirs and doesn't get
    /// silently annexed by the shelf.
    func open(_ sticker: Sticker) {
        if let existing = tab(for: sticker) {
            select(existing)
            return
        }

        let island = currentIsland
        let tab = island.makeTab()
        tab.session = self
        tab.stickerID = sticker.id
        // Appended rather than slotted in beside the selection: position is
        // what orders the sidebar's list, and this tab isn't in it.
        island.append(tab)
        setSelection(to: tab.id)
        tab.submit(sticker.url)
        scheduleSave()
    }

    // MARK: - Lifecycle

    @discardableResult
    func addTab(configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> Tab {
        let island = currentIsland
        let tab = island.makeTab(configuration: configuration)
        // WebKit's configuration for a popup carries the opener's store, which
        // must be the store we'd have handed it anyway. Worth saying out loud
        // rather than assuming: if WebKit ever stops doing that, popups quietly
        // browse as somebody else, and nothing else in the app would notice.
        if let configuration, configuration.websiteDataStore !== island.dataStore {
            debugLog("popup arrived with a data store that isn't its island's")
        }
        tab.session = self
        // Insert next to the current tab, like Safari, rather than at the end —
        // a tab opened from a link belongs beside its opener.
        let insertAt = (island.index(of: selectedTab)).map { $0 + 1 } ?? island.tabs.count
        island.insert(tab, at: insertAt)
        if select { setSelection(to: tab.id) }
        scheduleSave()
        return tab
    }

    func close(_ tab: Tab) {
        guard let island = island(holding: tab), let index = island.index(of: tab) else { return }

        // A popped-out tab still owns its panel; tearing it down first would
        // leave a floating window with a dead web view inside.
        if PopOutController.shared.isPoppedOut(tab) {
            PopOutController.shared.restore()
        }

        // Before teardown, or the panel would be left showing a dead page.
        DevToolsController.shared.close(for: tab)

        // Closing half a split doesn't shrink the split, it ends it: the other
        // page goes back to filling the window. Done up front, while the tab is
        // still live, so `setSplit` can hand visibility to the survivor before
        // anything is torn down.
        if let split, split.contains(tab.id) {
            let survivor = split.collapsing(after: tab.id)
            setSplit(nil)
            // Closing the unfocused half leaves focus where it was; closing the
            // focused half moves it to the survivor rather than letting the
            // usual next-tab rule pick a third page nobody asked for.
            if tab.id == selectedTabID, let survivor,
               let next = island.tabs.first(where: { $0.id == survivor }) {
                adoptSelection(next)
            }
        }

        // A sticker's tab is not remembered for ⌘⇧T. The sticker is still on
        // the shelf and still reopens the page, so there is nothing to restore
        // — and putting one back would make a second tab claiming the same
        // sticker, with only one of them reachable by clicking it.
        if tab.stickerID == nil { rememberClosedTab(tab, in: island) }
        // Read before teardown, so the group is pruned against the list as it
        // will be, not as it was.
        defer { island.pruneEmptyGroups() }

        // Explicit teardown, not just dropping the reference: a web view with
        // audio playing keeps its content process alive, so a closed tab would
        // otherwise keep playing.
        tab.teardown()
        let nextIndex = TabSelection.indexAfterClosing(
            closedIndex: index,
            originalCount: island.tabs.count
        )
        island.remove(at: index)

        guard let nextIndex else {
            // The island just emptied. Only the one on screen has to be
            // refilled — a background island is allowed to sit empty, and
            // conjuring a tab in it would spend a web content process on
            // something nobody is looking at.
            guard island === currentIsland else {
                island.rememberedSelection = nil
                scheduleSave()
                return
            }
            // Last tab closed: keep the window alive with a fresh home tab
            // rather than tearing the window down.
            let fresh = island.makeTab()
            fresh.session = self
            island.replaceTabs(with: [fresh])
            adoptSelection(fresh)
            scheduleSave()
            return
        }

        // Only move the selection if the closed tab was the selected one — and
        // only when it was the *visible* one, since closing a background
        // island's tab must not pull the window over to it.
        if tab.id == selectedTabID, island === currentIsland {
            adoptSelection(island.tabs[nextIndex])
        } else if island.rememberedSelection == tab.id {
            island.rememberedSelection = island.tabs[nextIndex].id
        }
        scheduleSave()
    }

    func closeSelectedTab() { close(selectedTab) }

    /// Puts back the most recently closed tab, with its history if it had any.
    func reopenClosedTab() {
        let island = currentIsland
        guard !island.recentlyClosed.isEmpty else { return }
        let persisted = island.recentlyClosed.removeFirst()
        let tab = island.makeTab()
        tab.session = self
        tab.prepareRestore(from: persisted)
        let insertAt = (island.index(of: selectedTab)).map { $0 + 1 } ?? island.tabs.count
        island.insert(tab, at: insertAt)
        setSelection(to: tab.id)
        scheduleSave()
    }

    // MARK: - Split

    /// Shows `tab` beside the current page, on the given side.
    ///
    /// Focus follows the drop: you just put this tab there, so the address bar,
    /// find bar and title should be about it rather than about the page it
    /// landed next to.
    func openSplit(with tab: Tab, on side: SplitPanes.Side) {
        // Same island only. The pair is drawn from the list the sidebar is
        // showing, and a pane holding a tab from another island would be a page
        // on screen with no row anywhere to close it from — plus two cookie
        // jars side by side with nothing saying which is which.
        guard currentIsland.contains(tab) else { return }

        let other = split.map { $0.tab(on: side == .leading ? .trailing : .leading) }
            ?? selectedTabID
        guard tab.id != other else { return }

        let panes = side == .leading
            ? SplitPanes(leading: tab.id, trailing: other)
            : SplitPanes(leading: other, trailing: tab.id)
        guard let panes else { return }

        setSplit(panes)
        setSelection(to: tab.id)
    }

    /// Splits with the tab after the current one — the keyboard route to a
    /// split, for when dragging isn't to hand.
    func splitWithNextTab() {
        guard !isSplit, tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == selectedTabID }),
              let next = TabSelection.cycled(from: current, by: 1, count: tabs.count)
        else { return }
        openSplit(with: tabs[next], on: .trailing)
    }

    /// Ends the split, keeping whichever pane had focus.
    func closeSplit() {
        guard split != nil else { return }
        setSplit(nil)
        scheduleSave()
    }

    /// Ends the split, keeping the pane that *didn't* have focus — how you
    /// close the half you're looking at.
    func closeFocusedPane() {
        guard let split, let survivor = split.collapsing(after: selectedTabID) else { return }
        setSplit(nil)
        setSelection(to: survivor)
        scheduleSave()
    }

    func swapSplitSides() {
        guard let split else { return }
        setSplit(split.swapped())
        scheduleSave()
    }

    var isSplit: Bool { split != nil }

    /// The one writer of `split`, so the "both panes visible" bookkeeping can't
    /// be forgotten at a call site.
    ///
    /// A tab in a pane is on screen even when it isn't the focused one, and
    /// `didBecomeVisible`/`didResignVisible` is how a tab learns that — it
    /// drives restyling, colour sampling, and its hibernation clock. Getting it
    /// wrong doesn't merely look untidy: a pane that was never told it became
    /// visible sits there with a stale last-viewed time and is eventually put
    /// to sleep while the user is looking straight at it.
    private func setSplit(_ new: SplitPanes?) {
        let before = visibleTabIDs
        split = new
        let after = visibleTabIDs

        // The sidebar draws the pair as one grouped row, so the two have to
        // actually *be* a pair in the list. Left where they were, the group is a
        // drawing that disagrees with the list it comes from: reorder anything
        // between them and it appears to teleport, and there is no coherent
        // answer to where the group should land when it's dragged. Pulling the
        // trailing tab up to its partner is also what makes swapping the panes
        // swap the halves in the list.
        if let new {
            // Pulling the trailing tab to sit beside its partner moves it
            // across whatever section boundary is in the way, so it has to be
            // refiled to match — otherwise it ends up drawn inside a section it
            // doesn't belong to, and the run it left behind is broken in two.
            // Put beside a tab is put with it.
            if let leading = tab(new.leading), let trailing = tab(new.trailing) {
                trailing.groupID = leading.groupID
            }
            if let order = TabOrder.placing(
                new.trailing,
                immediatelyAfter: new.leading,
                in: currentIsland.tabs.map(\.id)
            ) {
                currentIsland.reorder(to: order)
            }
            currentIsland.pruneEmptyGroups()
        }

        for id in before.subtracting(after) {
            allTabs.first { $0.id == id }?.didResignVisible()
        }
        for id in after.subtracting(before) {
            allTabs.first { $0.id == id }?.didBecomeVisible()
        }
    }

    // MARK: - Groups

    var groups: [TabGroup] { currentIsland.groups }

    func group(_ id: UUID) -> TabGroup? { currentIsland.group(id) }

    /// The tabs in a group, in list order.
    func tabs(in groupID: UUID) -> [Tab] {
        currentIsland.tabs.filter { $0.groupID == groupID }
    }

    /// Files `tab` into a new group of its own, and hands it back so the caller
    /// can put the sidebar straight into renaming it.
    @discardableResult
    func createGroup(with tab: Tab) -> TabGroup? {
        guard currentIsland.contains(tab) else { return nil }
        let group = TabGroup(name: TabGroup.defaultName(existing: currentIsland.groups))
        currentIsland.addGroup(group)
        tab.groupID = group.id
        currentIsland.pruneEmptyGroups()
        currentIsland.normalizeGroups()
        scheduleSave()
        return group
    }

    /// A new group with a new tab in it — what "New Group" means when it's asked
    /// for from empty space rather than from a tab.
    ///
    /// A group has to start with a tab. Groups are defined by their members, so
    /// an empty one has no position in the list and nothing to draw; making one
    /// would put a section on screen that the next redraw would have to remove.
    @discardableResult
    func createGroupWithNewTab() -> TabGroup? {
        let tab = addTab()
        return createGroup(with: tab)
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = currentIsland.group(id), !trimmed.isEmpty else { return }
        group.name = trimmed
        scheduleSave()
    }

    func setGroup(_ id: UUID, collapsed: Bool) {
        guard let group = currentIsland.group(id), group.isCollapsed != collapsed else { return }
        group.isCollapsed = collapsed
        scheduleSave()
    }

    func toggleGroup(_ id: UUID) {
        guard let group = currentIsland.group(id) else { return }
        setGroup(id, collapsed: !group.isCollapsed)
    }

    /// Dissolves the group, leaving its tabs where they are.
    func ungroup(_ id: UUID) {
        guard currentIsland.group(id) != nil else { return }
        currentIsland.removeGroup(id)
        scheduleSave()
    }

    /// Files `tab` at the end of a group's run.
    func addTab(_ tab: Tab, to groupID: UUID) {
        guard currentIsland.contains(tab),
              let group = currentIsland.group(groupID),
              tab.groupID != group.id
        else { return }

        let members = TabGrouping.members(of: group.id, in: currentIsland.slots)
        tab.groupID = group.id
        // Placed by hand rather than left to `normalizeGroups`, which anchors a
        // group at its first member — a tab joining from above would otherwise
        // pull the whole section up to meet it.
        if let last = members.last,
           let order = TabOrder.placing(tab.id, immediatelyAfter: last, in: currentIsland.tabs.map(\.id)) {
            currentIsland.reorder(to: order)
        }
        currentIsland.pruneEmptyGroups()
        currentIsland.normalizeGroups()
        scheduleSave()
    }

    func removeFromGroup(_ tab: Tab) {
        guard tab.groupID != nil else { return }
        tab.groupID = nil
        currentIsland.pruneEmptyGroups()
        currentIsland.normalizeGroups()
        scheduleSave()
    }

    /// Closes every tab in the group. The group goes with them.
    func closeGroup(_ id: UUID) {
        for tab in tabs(in: id) { close(tab) }
        currentIsland.pruneEmptyGroups()
        scheduleSave()
    }

    /// Moves a whole group, the way the split's grip moves a pair.
    @discardableResult
    func moveGroup(_ id: UUID, before targetID: Tab.ID) -> Bool {
        let members = TabGrouping.members(of: id, in: currentIsland.slots)
        guard !members.isEmpty else { return false }

        // Landing on a row inside *another* section would file this one into
        // the middle of that one, which is a section cut in half rather than
        // the nesting it looks like. Sections don't nest, so the drop is read
        // as "before that section" — aim anywhere in it and the whole thing
        // moves ahead of the whole thing.
        var target = targetID
        if let host = tab(targetID)?.groupID, host != id,
           let first = TabGrouping.members(of: host, in: currentIsland.slots).first {
            target = first
        }

        guard let order = TabOrder.moving(members, before: target, in: currentIsland.tabs.map(\.id))
        else { return false }
        currentIsland.reorder(to: order)
        return true
    }

    @discardableResult
    func moveGroupToEnd(_ id: UUID) -> Bool {
        let members = TabGrouping.members(of: id, in: currentIsland.slots)
        guard !members.isEmpty,
              let order = TabOrder.movingToEnd(members, in: currentIsland.tabs.map(\.id))
        else { return false }
        currentIsland.reorder(to: order)
        return true
    }

    // MARK: - Reordering

    /// Moves the dragged tab into the slot the target row currently occupies.
    ///
    /// Both ends are looked up by identity at call time, because during a live
    /// drag this fires once per row crossed and the indices from the previous
    /// call are already stale.
    ///
    /// Deliberately *doesn't* save. A drag down a long list calls this once per
    /// row crossed, and each save snapshots every tab in every island — work
    /// thrown away by the next crossing a moment later. `commitTabReorder`
    /// pays it once, when the drag is over.
    @discardableResult
    func moveTab(_ movedID: Tab.ID, before targetID: Tab.ID) -> Bool {
        let island = currentIsland
        guard let from = island.tabs.firstIndex(where: { $0.id == movedID }),
              let to = island.tabs.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return false }
        island.move(fromIndex: from, toIndex: to)
        // Where a tab lands is what decides whether it's in a group. Dropping it
        // among a section's rows files it there; dropping it outside takes it
        // out. Anything else would mean a tab sitting visibly inside a section
        // it isn't part of.
        island.tabs[to].groupID = island.tabs.first { $0.id == targetID }?.groupID
        island.pruneEmptyGroups()
        return true
    }

    /// Dropping past the last row files the tab at the end of the list.
    @discardableResult
    func moveTabToEnd(_ movedID: Tab.ID) -> Bool {
        let island = currentIsland
        guard let from = island.tabs.firstIndex(where: { $0.id == movedID }),
              from != island.tabs.count - 1
        else { return false }
        island.move(fromIndex: from, toIndex: island.tabs.count - 1)
        // Past the last row is past every section, so the tab lands unfiled.
        island.tabs[island.tabs.count - 1].groupID = nil
        island.pruneEmptyGroups()
        return true
    }

    /// Moves both halves of the split together, keeping their order.
    ///
    /// The pair is one row in the sidebar, so it has to be one thing to drag as
    /// well — otherwise the only way to reposition a split in the list is to
    /// break it, move the tabs, and build it again.
    @discardableResult
    func moveSplitPair(before targetID: Tab.ID) -> Bool {
        guard let split else { return false }
        guard let order = TabOrder.moving(
            [split.leading, split.trailing],
            before: targetID,
            in: currentIsland.tabs.map(\.id)
        ) else { return false }
        currentIsland.reorder(to: order)
        return true
    }

    @discardableResult
    func moveSplitPairToEnd() -> Bool {
        guard let split else { return false }
        guard let order = TabOrder.movingToEnd(
            [split.leading, split.trailing],
            in: currentIsland.tabs.map(\.id)
        ) else { return false }
        currentIsland.reorder(to: order)
        return true
    }

    /// Persists an order arrived at by dragging. Called once the drag ends —
    /// including when it's cancelled, since the rows have already moved.
    func commitTabReorder() {
        scheduleSave()
    }

    // MARK: - Selection

    func select(_ tab: Tab) {
        // A tab can be reached from outside the island it lives in. The media
        // player deliberately lists whatever is playing *anywhere* — switching
        // islands is not a request to stop the music — so its rows are the one
        // place you can click a tab the sidebar isn't showing. Without this,
        // `setSelection` searched only the current island, found nothing, and
        // returned: the row simply didn't respond, with no way to tell why.
        guard let owner = island(holding: tab) else { return }
        if owner !== currentIsland {
            currentIsland.rememberedSelection = selectedTabID
            currentIsland = owner
        }
        setSelection(to: tab.id)
    }

    /// Every selection change funnels through here, so the pop-out rules live
    /// in exactly one place instead of at each call site.
    private func setSelection(to id: Tab.ID) {
        guard id != selectedTabID else { return }

        let outgoing = selectedTab
        // Every tab in the island, not just the listed ones: clicking a sticker
        // selects a tab that deliberately has no row.
        guard let incoming = currentIsland.tabs.first(where: { $0.id == id }) else { return }

        // Coming back to a popped-out tab folds it back into the window.
        if PopOutController.shared.isPoppedOut(incoming) {
            PopOutController.shared.restore()
        }

        // Leaving a tab mid-video pops it out so it stays watchable. Measured
        // before the selection changes, while the web view is still laid out.
        //
        // "Leaving" has to mean leaving the *screen*, not losing focus, and the
        // two came apart when panes arrived. Moving focus between the halves of
        // a split keeps both pages up, so the outgoing one isn't going
        // anywhere; selecting a third tab collapses the split, so it is.
        let outgoingStaysVisible = split.map {
            $0.contains(outgoing.id) && $0.contains(id)
        } ?? false
        if !outgoingStaysVisible, shouldAutoPopOut(outgoing) {
            PopOutController.shared.popOut(outgoing)
        }

        adoptSelection(incoming)
        scheduleSave()
    }

    /// Keeps enough to restore the tab, run through the same redaction the
    /// session file gets — with history off, the back/forward blob is stripped
    /// and reopening returns the page, not the trail that led to it.
    private func rememberClosedTab(_ tab: Tab, in island: Island) {
        let snapshot = tab.snapshot()
        guard snapshot.isRestorable else { return }
        let redacted = PrivacyPolicy.redact(
            PersistedSession(tabs: [snapshot], selectedIndex: 0),
            for: .current
        )
        guard let kept = redacted.tabs.first else { return }
        island.recentlyClosed.insert(kept, at: 0)
        if island.recentlyClosed.count > Self.closedTabMemory {
            island.recentlyClosed.removeLast(
                island.recentlyClosed.count - Self.closedTabMemory
            )
        }
    }

    private func shouldAutoPopOut(_ tab: Tab) -> Bool {
        guard MediaPreferences.autoPopOut else { return false }
        // A tab being closed is already torn down — nothing to pop out.
        guard currentIsland.tabs.contains(where: { $0.id == tab.id }) else { return false }
        guard !PopOutController.shared.isPoppedOut(tab) else { return false }
        // Audio-only playback has no rectangle to crop to.
        guard let media = tab.media, media.isPlaying, media.hasVideo else { return false }
        return true
    }

    func selectNextTab() { cycleSelection(by: 1) }
    func selectPreviousTab() { cycleSelection(by: -1) }

    /// Wraps around at both ends, matching every other tabbed app.
    private func cycleSelection(by offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }),
              let next = TabSelection.cycled(from: current, by: offset, count: tabs.count)
        else { return }
        setSelection(to: tabs[next].id)
    }

    /// ⌘1–⌘8 pick by position; ⌘9 is last, again matching convention.
    func selectTab(atOneBasedIndex index: Int) {
        guard let target = TabSelection.index(forOneBased: index, count: tabs.count) else { return }
        setSelection(to: tabs[target].id)
    }

    func requestFind() { findToken += 1 }

    func stepFind(forward: Bool) {
        findStepsForward = forward
        findStepToken += 1
    }

    func requestAddressFocus(creatingTab: Bool = false) {
        addressFocusCreatesTab = creatingTab
        focusAddressToken += 1
    }

    /// The whole new-tab flow: ask where to go, and only then make the tab.
    ///
    /// Creating the tab up front meant a blank tab appearing in the list, the
    /// page going empty behind the palette, and an abandoned tab to clean up
    /// afterwards. Asking first makes all three go away — the palette simply
    /// floats over whatever you were already looking at.
    func openNewTabAndPrompt() {
        requestAddressFocus(creatingTab: true)
    }

    /// Where a palette submission lands: a tab created on the spot, or the one
    /// already on screen.
    @discardableResult
    func submitFromPalette(_ text: String, creatingTab: Bool) -> Tab {
        let target = creatingTab ? addTab() : selectedTab
        target.submit(text)
        return target
    }
}
