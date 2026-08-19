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

    /// Invariant: never empty, and `selectedTabID` always names a live tab.
    /// Every view can therefore render a selected tab without a nil branch.
    private(set) var tabs: [Tab] = []
    private(set) var selectedTabID: Tab.ID

    /// Recently closed tabs, newest first, so ⌘⇧T can undo a misclick.
    ///
    /// Memory only, and never written to the session file: this is an undo
    /// buffer for the current run, not a history. Quitting loses it, which is
    /// the point.
    @ObservationIgnored private var recentlyClosed: [PersistedTab] = []
    /// Deep enough to cover a run of accidental closes, shallow enough that it
    /// isn't quietly accumulating everywhere you've been.
    private static let closedTabMemory = 12

    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

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
        if let restored, !restored.tabs.isEmpty {
            isRestoring = true
            let tabs = restored.tabs.map { persisted -> Tab in
                let tab = Tab(dataStore: Self.defaultStore)
                tab.prepareRestore(from: persisted)
                return tab
            }
            let selected = tabs[min(restored.selectedIndex, tabs.count - 1)]
            self.tabs = tabs
            self.selectedTab = selected
            self.selectedTabID = selected.id
            tabs.forEach { $0.session = self }
            isRestoring = false
            // The one selection that doesn't go through `adoptSelection`, so
            // the starting tab is told it's on screen by hand.
            selected.didBecomeVisible()
        } else {
            let first = Tab(dataStore: Self.defaultStore)
            self.tabs = [first]
            self.selectedTab = first
            self.selectedTabID = first.id
            first.session = self
            first.didBecomeVisible()
        }

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

        let snapshot = PersistedSession(
            tabs: tabs.map { $0.snapshot(refreshingState: blocking) },
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID } ?? 0
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
    var nowPlayingTab: Tab? {
        tabs.first { $0.media?.isPlaying == true } ?? tabs.first { $0.media != nil }
    }

    /// Every tab holding media, with the active one first — that's the row the
    /// stack shows when collapsed.
    var mediaTabs: [Tab] {
        let holding = tabs.filter { $0.media != nil }
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
        if outgoing !== tab { outgoing.didResignVisible() }
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
        let candidates = tabs.map { tab in
            TabHibernation.Candidate(
                id: tab.id,
                lastViewedAt: tab.lastViewedAt,
                isLive: tab.isLive,
                isProtected: tab.id == selectedTabID
                    || tab.media?.isPlaying == true
                    || PopOutController.shared.isPoppedOut(tab)
                    || DevToolsController.shared.isOpen(for: tab)
            )
        }

        let doomed = Set(TabHibernation.tabsToSleep(among: candidates, now: now))
        guard !doomed.isEmpty else { return }
        for tab in tabs where doomed.contains(tab.id) {
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

    // MARK: - Lifecycle

    /// The storage every tab in this session gets.
    ///
    /// One island for now, and deliberately the *default* store: those are the
    /// cookies the browser has been accumulating since before islands existed,
    /// and there is no supported way to move them into an identified store. So
    /// the first island is defined as the one that doesn't have an identifier,
    /// and nobody gets signed out of anything.
    ///
    /// Static rather than a stored property because `init` builds tabs before
    /// the session is far enough along to touch `self`.
    private static var defaultStore: WKWebsiteDataStore {
        IslandStores.shared.store(forIdentifier: nil)
    }

    /// The only place a `Tab` is constructed.
    ///
    /// A tab without a data store isn't a tab that browses badly, it's a tab
    /// that browses as the wrong person — so the one thing worth guaranteeing
    /// structurally is that there is no way to make one without saying whose
    /// storage it uses.
    private func makeTab(configuration: WKWebViewConfiguration? = nil) -> Tab {
        Tab(dataStore: Self.defaultStore, configuration: configuration)
    }

    @discardableResult
    func addTab(configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> Tab {
        let tab = makeTab(configuration: configuration)
        // WebKit's configuration for a popup carries the opener's store, which
        // in a one-island browser must be the store we'd have handed it anyway.
        // Worth saying out loud rather than assuming: if WebKit ever stops
        // doing that, popups quietly browse as somebody else, and nothing else
        // in the app would notice.
        if let configuration, configuration.websiteDataStore !== Self.defaultStore {
            debugLog("popup arrived with a data store that isn't its island's")
        }
        tab.session = self
        // Insert next to the current tab, like Safari, rather than at the end —
        // a tab opened from a link belongs beside its opener.
        let insertAt = (tabs.firstIndex { $0.id == selectedTabID }).map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: insertAt)
        if select { setSelection(to: tab.id) }
        scheduleSave()
        return tab
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        // A popped-out tab still owns its panel; tearing it down first would
        // leave a floating window with a dead web view inside.
        if PopOutController.shared.isPoppedOut(tab) {
            PopOutController.shared.restore()
        }

        // Before teardown, or the panel would be left showing a dead page.
        DevToolsController.shared.close(for: tab)

        rememberClosedTab(tab)

        // Explicit teardown, not just dropping the reference: a web view with
        // audio playing keeps its content process alive, so a closed tab would
        // otherwise keep playing.
        tab.teardown()
        let nextIndex = TabSelection.indexAfterClosing(
            closedIndex: index,
            originalCount: tabs.count
        )
        tabs.remove(at: index)

        guard let nextIndex else {
            // Last tab closed: keep the window alive with a fresh home tab
            // rather than tearing the window down.
            let fresh = makeTab()
            fresh.session = self
            tabs = [fresh]
            adoptSelection(fresh)
            scheduleSave()
            return
        }

        // Only move the selection if the closed tab was the selected one.
        if tab.id == selectedTabID {
            adoptSelection(tabs[nextIndex])
        }
        scheduleSave()
    }

    func closeSelectedTab() { close(selectedTab) }

    /// Puts back the most recently closed tab, with its history if it had any.
    func reopenClosedTab() {
        guard !recentlyClosed.isEmpty else { return }
        let persisted = recentlyClosed.removeFirst()
        let tab = makeTab()
        tab.session = self
        tab.prepareRestore(from: persisted)
        let insertAt = (tabs.firstIndex { $0.id == selectedTabID }).map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: insertAt)
        setSelection(to: tab.id)
        scheduleSave()
    }

    // MARK: - Selection

    func select(_ tab: Tab) {
        setSelection(to: tab.id)
    }

    /// Every selection change funnels through here, so the pop-out rules live
    /// in exactly one place instead of at each call site.
    private func setSelection(to id: Tab.ID) {
        guard id != selectedTabID else { return }

        let outgoing = selectedTab
        guard let incoming = tabs.first(where: { $0.id == id }) else { return }

        // Coming back to a popped-out tab folds it back into the window.
        if PopOutController.shared.isPoppedOut(incoming) {
            PopOutController.shared.restore()
        }

        // Leaving a tab mid-video pops it out so it stays watchable. Measured
        // before the selection changes, while the web view is still laid out.
        if shouldAutoPopOut(outgoing) {
            PopOutController.shared.popOut(outgoing)
        }

        adoptSelection(incoming)
        scheduleSave()
    }

    /// Keeps enough to restore the tab, run through the same redaction the
    /// session file gets — with history off, the back/forward blob is stripped
    /// and reopening returns the page, not the trail that led to it.
    private func rememberClosedTab(_ tab: Tab) {
        let snapshot = tab.snapshot()
        guard snapshot.isRestorable else { return }
        let redacted = PrivacyPolicy.redact(
            PersistedSession(tabs: [snapshot], selectedIndex: 0),
            for: .current
        )
        guard let kept = redacted.tabs.first else { return }
        recentlyClosed.insert(kept, at: 0)
        if recentlyClosed.count > Self.closedTabMemory {
            recentlyClosed.removeLast(recentlyClosed.count - Self.closedTabMemory)
        }
    }

    private func shouldAutoPopOut(_ tab: Tab) -> Bool {
        guard MediaPreferences.autoPopOut else { return false }
        // A tab being closed is already torn down — nothing to pop out.
        guard tabs.contains(where: { $0.id == tab.id }) else { return false }
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
