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

    /// Incremented to ask the focused view to select the address field (⌘L).
    /// A token rather than a Bool, so repeat presses each register.
    private(set) var focusAddressToken: Int = 0

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
        if select { selectedTabID = tab.id }
        scheduleSave()
        return tab
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        // Stop loading before dropping the reference, or the web view can keep
        // running a navigation with no one observing it.
        tab.stop()
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
        selectedTabID = tab.id
        scheduleSave()
    }

    func selectNextTab() { cycleSelection(by: 1) }
    func selectPreviousTab() { cycleSelection(by: -1) }

    /// Wraps around at both ends, matching every other tabbed app.
    private func cycleSelection(by offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }),
              let next = TabSelection.cycled(from: current, by: offset, count: tabs.count)
        else { return }
        selectedTabID = tabs[next].id
    }

    /// ⌘1–⌘8 pick by position; ⌘9 is last, again matching convention.
    func selectTab(atOneBasedIndex index: Int) {
        guard let target = TabSelection.index(forOneBased: index, count: tabs.count) else { return }
        selectedTabID = tabs[target].id
    }

    func requestAddressFocus() { focusAddressToken += 1 }
}
