import Foundation
import Testing
@testable import SurfCore

@Suite("Session persistence")
struct PersistedSessionTests {

    private func tab(_ url: String?, _ title: String = "t") -> PersistedTab {
        PersistedTab(url: url, title: title)
    }

    @Test("Home tabs are not restorable")
    func homeTabsDropped() {
        #expect(tab(nil).isRestorable == false)
        #expect(tab("").isRestorable == false)
        #expect(tab("https://example.com").isRestorable == true)
    }

    @Test("A session of only home tabs restores nothing")
    func allEmpty() {
        let session = PersistedSession(tabs: [tab(nil), tab("")], selectedIndex: 0)
        #expect(session.sanitized() == nil)
    }

    @Test("Selection follows its tab when earlier tabs are dropped")
    func selectionFollows() throws {
        // [home, A, B] selecting B (index 2) -> [A, B], B is now index 1.
        let session = PersistedSession(
            tabs: [tab(nil), tab("https://a.com"), tab("https://b.com")],
            selectedIndex: 2
        )
        let result = try #require(session.sanitized())
        #expect(result.tabs.count == 2)
        #expect(result.selectedIndex == 1)
        #expect(result.tabs[result.selectedIndex].url == "https://b.com")
    }

    @Test("A dropped selection falls back to the first tab")
    func droppedSelection() throws {
        let session = PersistedSession(
            tabs: [tab("https://a.com"), tab(nil)],
            selectedIndex: 1
        )
        let result = try #require(session.sanitized())
        #expect(result.selectedIndex == 0)
        #expect(result.tabs.count == 1)
    }

    @Test("Round-trips through disk unchanged")
    func roundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("surf-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = PersistedSession(
            tabs: [
                PersistedTab(url: "https://a.com", title: "A", interactionState: Data([1, 2, 3])),
                PersistedTab(url: "https://b.com", title: "B"),
            ],
            selectedIndex: 1
        )

        try SessionFile.save(original, to: url)
        let loaded = try #require(SessionFile.load(from: url))
        #expect(loaded == original)
        #expect(loaded.tabs[0].interactionState == Data([1, 2, 3]))
    }

    @Test("A corrupt file yields nil instead of throwing")
    func corruptFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("surf-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("not json at all".utf8).write(to: url)
        #expect(SessionFile.load(from: url) == nil)
    }

    @Test("A missing file yields nil")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/surf/session.json")
        #expect(SessionFile.load(from: url) == nil)
    }

    // MARK: - What a closed tab is called

    /// The closed-tab buffer is the one place a `PersistedTab` is shown to
    /// somebody — the island menu lists it — and a row with no text is a row
    /// nobody can read or aim at.
    @Test("A closed tab's row prefers its title")
    func rowTitlePrefersTitle() {
        let tab = PersistedTab(url: "https://github.com/a/b", title: "Pull #1482")
        #expect(tab.rowTitle == "Pull #1482")
    }

    @Test("With no title, a closed tab's row falls back to the host")
    func rowTitleFallsBackToHost() {
        let tab = PersistedTab(url: "https://github.com/a/b", title: "")
        #expect(tab.rowTitle == "github.com")
    }

    /// A title can be missing because history was redacted along with it, and
    /// an address with no host still beats an empty row.
    @Test("With no host, a closed tab's row falls back to the address")
    func rowTitleFallsBackToAddress() {
        let tab = PersistedTab(url: "about:blank", title: "")
        #expect(tab.rowTitle == "about:blank")
    }

    @Test("With nothing at all, a closed tab's row is still readable")
    func rowTitleNeverBlank() {
        #expect(PersistedTab(url: nil, title: "").rowTitle == "Untitled")
        #expect(PersistedTab(url: "", title: "").rowTitle == "Untitled")
    }
}
