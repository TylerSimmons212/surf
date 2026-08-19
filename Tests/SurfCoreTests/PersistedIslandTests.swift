import Foundation
import Testing
@testable import SurfCore

@Suite("Island persistence")
struct PersistedIslandTests {

    private func tab(_ url: String?, _ title: String = "t") -> PersistedTab {
        PersistedTab(url: url, title: title)
    }

    /// A minimal island document with the tint written verbatim, so a test can
    /// hand it either shape the decoder has to cope with.
    private func islandJSON(tint: String) -> String {
        let id = UUID().uuidString
        return "{\"id\":\"\(id)\",\"name\":\"Work\",\"symbol\":\"W\","
            + "\"tint\":\(tint),\"tabs\":[],\"selectedIndex\":0}"
    }

    private func island(_ name: String, tabs: [PersistedTab] = [], selected: Int = 0)
        -> PersistedIsland
    {
        PersistedIsland(
            name: name, symbol: "🌊", tint: .kelp, dataStoreID: UUID(),
            tabs: tabs, selectedIndex: selected
        )
    }

    // MARK: - Migration

    /// The upgrade path everyone takes exactly once. It has to be silent: the
    /// home island is *defined* as the one using the default store, which is
    /// the jar those cookies were already in, so nobody is signed out.
    @Test("A session file written before islands existed opens as one home island")
    func legacyFileMigrates() throws {
        let legacy = PersistedSession(
            tabs: [tab("a.com"), tab("b.com")], selectedIndex: 1
        )
        let (islands, selected) = legacy.resolvedIslands

        #expect(islands.count == 1)
        #expect(selected == 0)
        let home = try #require(islands.first)
        #expect(home.isHome)
        #expect(home.dataStoreID == nil)
        #expect(home.tabs.count == 2)
        #expect(home.selectedIndex == 1)
    }

    /// Decoding is where back-compatibility actually has to hold: the new keys
    /// are optional so the synthesized decoder uses `decodeIfPresent` rather
    /// than throwing, and a throw here means launching with no tabs.
    @Test("JSON with no islands key decodes rather than failing")
    func legacyJSONDecodes() throws {
        let json = """
        {"tabs":[{"url":"a.com","title":"A"}],"selectedIndex":0}
        """
        let decoded = try JSONDecoder().decode(
            PersistedSession.self, from: Data(json.utf8)
        )
        #expect(decoded.islands == nil)
        #expect(decoded.resolvedIslands.islands.count == 1)
        #expect(decoded.resolvedIslands.islands[0].isHome)
    }

    @Test("A session round-trips through JSON with its islands intact")
    func roundTrip() throws {
        let session = PersistedSession(
            islands: [.home(tabs: [tab("a.com")]), island("Work", tabs: [tab("w.com")])],
            selectedIslandIndex: 1
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: data)
        #expect(decoded == session)
        #expect(decoded.selectedIslandIndex == 1)
    }

    /// What a downgrade sees. Without the mirror, rolling back to the previous
    /// build — or crash-looping into it — opens an empty browser.
    @Test("The home island is mirrored into the legacy fields on write")
    func legacyMirrorWritten() {
        let session = PersistedSession(
            islands: [
                .home(tabs: [tab("a.com"), tab("b.com")], selectedIndex: 1),
                island("Work", tabs: [tab("w.com")]),
            ],
            selectedIslandIndex: 1
        )
        #expect(session.tabs.map(\.url) == ["a.com", "b.com"])
        #expect(session.selectedIndex == 1)
        #expect(session.schemaVersion == PersistedSession.currentSchemaVersion)
    }

    /// A future build adding a key must not make this one unlaunchable.
    @Test("Unknown keys don't fail the decode")
    func unknownKeysTolerated() throws {
        let json = """
        {"tabs":[],"selectedIndex":0,"somethingFromTheFuture":{"a":1}}
        """
        let decoded = try JSONDecoder().decode(
            PersistedSession.self, from: Data(json.utf8)
        )
        #expect(decoded.tabs.isEmpty)
    }

    // MARK: - Sanitizing

    /// The one that guards against silently losing logins. Dropping an emptied
    /// island would mean closing your last work tab deletes the work island and
    /// orphans its cookie jar — with no undo, and no way to tell it happened.
    @Test("An island whose every tab is unrestorable is kept, with no tabs")
    func emptyIslandSurvives() throws {
        let session = PersistedSession(
            islands: [.home(tabs: [tab("a.com")]), island("Work", tabs: [tab(nil)])],
            selectedIslandIndex: 0
        )
        let result = try #require(session.sanitized())
        let islands = try #require(result.islands)
        #expect(islands.count == 2)
        #expect(islands[1].name == "Work")
        #expect(islands[1].tabs.isEmpty)
        // The store identifier is the point of keeping it.
        #expect(islands[1].dataStoreID != nil)
    }

    /// The pre-Islands behaviour, preserved: a browser with nothing open
    /// shouldn't resurrect old tabs on the next launch.
    @Test("A lone home island with nothing open still sanitizes away")
    func loneEmptyHomeIsNil() {
        let session = PersistedSession(
            islands: [.home(tabs: [tab(nil)])], selectedIslandIndex: 0
        )
        #expect(session.sanitized() == nil)
    }

    /// Same rule as tabs, one level up — and the reason it matters more here is
    /// that landing on the wrong island means browsing as the wrong person.
    @Test("Island tab selection follows its tab when earlier tabs are dropped")
    func islandSelectionFollows() throws {
        let island = PersistedIsland(
            name: "Work", symbol: "🌊", tint: .surf, dataStoreID: UUID(),
            tabs: [tab(nil), tab("keep.com")], selectedIndex: 1
        )
        #expect(island.sanitized().selectedIndex == 0)
        #expect(island.sanitized().tabs.map(\.url) == ["keep.com"])
    }

    /// An island that acquired `dataStoreID == nil` through any path would be
    /// silently reading and writing the user's main cookie jar.
    @Test("Sanitizing never turns an isolated island into the home island")
    func isolationSurvivesSanitizing() throws {
        let session = PersistedSession(
            islands: [.home(), island("Work", tabs: [tab(nil)])],
            selectedIslandIndex: 1
        )
        let islands = try #require(session.sanitized()?.islands)
        #expect(islands.filter(\.isHome).count == 1)
        #expect(islands.first(where: { $0.name == "Work" })?.isHome == false)
    }

    // MARK: - Tints

    /// So the first few islands are told apart at a glance without anyone
    /// having to choose a colour.
    @Test("A new island's tint is the least-used preset")
    func tintsSpread() {
        #expect(IslandTint.next(after: []) == .surf)
        #expect(IslandTint.next(after: [.surf]) == .lagoon)
        #expect(IslandTint.next(after: [.surf, .lagoon]) == .kelp)
        // Once the palette wraps it reuses from the front rather than running
        // out of colours.
        #expect(IslandTint.next(after: IslandTint.presets) == .surf)
    }

    /// A colour the user mixed themselves must not push new islands onto a
    /// preset it happens to sit near — `next` counts presets, not neighbours.
    @Test("A custom colour doesn't consume a preset")
    func customTintDoesNotConsumePreset() {
        let custom = IslandTint(red: 0.11, green: 0.61, blue: 0.86)
        #expect(custom != IslandTint.surf)
        #expect(IslandTint.next(after: [custom]) == .surf)
    }

    /// The upgrade that has to be silent. A session file written before the
    /// colour picker existed says `"tint": "surf"`, and failing to read it
    /// would drop every island's colour on the first launch after updating.
    @Test("A tint stored as a preset name still decodes")
    func legacyTintNameDecodes() throws {
        let island = try JSONDecoder().decode(
            PersistedIsland.self, from: Data(islandJSON(tint: "\"kelp\"").utf8)
        )
        #expect(island.tint == .kelp)
    }

    /// An unknown name has no sensible colour to become, and must fail rather
    /// than silently pick one — the island's identity is what it looks like.
    @Test("An unknown tint name fails to decode rather than guessing")
    func unknownTintNameFails() {
        let json = islandJSON(tint: "\"chartreuse\"")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PersistedIsland.self, from: Data(json.utf8))
        }
    }

    @Test("A custom tint round-trips through JSON")
    func customTintRoundTrips() throws {
        let custom = IslandTint(red: 0.42, green: 0.13, blue: 0.77)
        let island = PersistedIsland(
            name: "Work", symbol: "💼", tint: custom, dataStoreID: UUID()
        )
        let data = try JSONEncoder().encode(island)
        let decoded = try JSONDecoder().decode(PersistedIsland.self, from: data)
        #expect(decoded.tint == custom)
        #expect(decoded.tint.presetName == nil)
    }

    /// A picker on a wide-gamut display can hand back values just past both
    /// ends, and a colour outside 0...1 isn't a colour.
    @Test("Out-of-range components are clamped")
    func componentsClamped() {
        let wild = IslandTint(red: 1.4, green: -0.2, blue: 0.5)
        #expect(wild.red == 1)
        #expect(wild.green == 0)
        #expect(wild.blue == 0.5)
    }
}
