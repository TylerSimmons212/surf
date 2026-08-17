import AppKit
import Foundation
import GlassCore
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
    /// Suppresses saves while restoring, so a half-built session can't
    /// overwrite the file we're still reading from.
    @ObservationIgnored private var isRestoring = false

    init(restoring restored: PersistedSession? = BrowserSession.restorableSession()) {
        if let restored, !restored.tabs.isEmpty {
            isRestoring = true
            let tabs = restored.tabs.map { persisted -> Tab in
                let tab = Tab()
                tab.prepareRestore(from: persisted)
                return tab
            }
            self.tabs = tabs
            self.selectedTabID = tabs[min(restored.selectedIndex, tabs.count - 1)].id
            tabs.forEach { $0.session = self }
            isRestoring = false
        } else {
            let first = Tab()
            self.tabs = [first]
            self.selectedTabID = first.id
            first.session = self
        }

        // Quitting doesn't give the debounced save time to fire, so flush.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.saveNow() }
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
    func scheduleSave() {
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        let settings = PrivacySettings.current

        // Tab restore turned off: leave nothing behind, and delete anything a
        // previous run wrote. Turning the setting off has to erase the trail,
        // not merely stop adding to it.
        guard PrivacyPolicy.shouldPersistSession(settings) else {
            try? FileManager.default.removeItem(at: SessionFile.url)
            return
        }

        let snapshot = PersistedSession(
            tabs: tabs.map { $0.snapshot() },
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID } ?? 0
        )
        // Strips each tab's back/forward blob when history is off.
        let redacted = PrivacyPolicy.redact(snapshot, for: settings)

        // A session of only home tabs sanitizes to nil — write it as empty so
        // closing everything and quitting doesn't resurrect old tabs.
        do {
            try SessionFile.save(redacted.sanitized() ?? PersistedSession(tabs: [], selectedIndex: 0))
        } catch {
            fputs("[glass] session save failed: \(error)\n", stderr)
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

    var selectedTab: Tab {
        // Safe by the invariant; the fallback keeps a corrupted state from
        // crashing the app mid-session.
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    // MARK: - Lifecycle

    @discardableResult
    func addTab(configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> Tab {
        let tab = Tab(configuration: configuration)
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
            let fresh = Tab()
            fresh.session = self
            tabs = [fresh]
            selectedTabID = fresh.id
            scheduleSave()
            return
        }

        // Only move the selection if the closed tab was the selected one.
        if tab.id == selectedTabID {
            selectedTabID = tabs[nextIndex].id
        }
        scheduleSave()
    }

    func closeSelectedTab() { close(selectedTab) }

    /// Puts back the most recently closed tab, with its history if it had any.
    func reopenClosedTab() {
        guard !recentlyClosed.isEmpty else { return }
        let persisted = recentlyClosed.removeFirst()
        let tab = Tab()
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

        let outgoing = tabs.first { $0.id == selectedTabID }
        let incoming = tabs.first { $0.id == id }

        // Coming back to a popped-out tab folds it back into the window.
        if let incoming, PopOutController.shared.isPoppedOut(incoming) {
            PopOutController.shared.restore()
        }

        // Leaving a tab mid-video pops it out so it stays watchable. Measured
        // before the selection changes, while the web view is still laid out.
        if let outgoing, shouldAutoPopOut(outgoing) {
            PopOutController.shared.popOut(outgoing)
        }

        selectedTabID = id
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
