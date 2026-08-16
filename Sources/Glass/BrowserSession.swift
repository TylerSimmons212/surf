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

    /// Incremented to ask the focused view to open the address bar (⌘L).
    /// A token rather than a Bool, so repeat presses each register.
    private(set) var focusAddressToken: Int = 0

    /// Whether the pending address-bar request came from creating a tab. Only
    /// then does cancelling discard the tab — someone who opens the address bar
    /// on a tab that already exists and changes their mind should keep it.
    private(set) var addressFocusIsForNewTab = false

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

    func requestAddressFocus(forNewTab: Bool = false) {
        addressFocusIsForNewTab = forNewTab
        focusAddressToken += 1
    }

    /// The whole new-tab flow: make the tab, then ask where to go.
    func openNewTabAndPrompt() {
        addTab()
        requestAddressFocus(forNewTab: true)
    }

    /// Discards a tab that was created and then abandoned.
    func discardIfBlank(_ tab: Tab) {
        // Closing the last tab just recreates an identical empty one, so
        // there's nothing to gain and a visible flicker to lose.
        guard tabs.count > 1, tab.isBlank else { return }
        close(tab)
    }
}
