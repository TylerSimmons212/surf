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

    init() {
        let first = Tab()
        tabs = [first]
        selectedTabID = first.id
        first.session = self
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
            return
        }

        // Only move the selection if the closed tab was the selected one.
        if tab.id == selectedTabID {
            selectedTabID = tabs[nextIndex].id
        }
    }

    func closeSelectedTab() { close(selectedTab) }

    // MARK: - Selection

    func select(_ tab: Tab) { selectedTabID = tab.id }

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
