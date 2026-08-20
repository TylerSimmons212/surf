import Foundation
import Testing
@testable import SurfCore

@Suite("Stickers")
struct StickerTests {

    // MARK: - Construction

    @Test("A sticker derives its host from the URL")
    func hostDerivation() {
        let sticker = Sticker(url: "https://mail.google.com/mail/u/0", title: "Inbox")
        #expect(sticker?.host == "mail.google.com")
    }

    @Test("A hostless or empty URL makes no sticker")
    func rejectsHostless() {
        #expect(Sticker(url: "", title: "Nothing") == nil)
        #expect(Sticker(url: "   ", title: "Blank") == nil)
        #expect(Sticker(url: "about:blank", title: "About") == nil)
    }

    @Test("Origin keeps scheme, host and port, and drops the path")
    func origin() {
        #expect(
            Sticker(url: "https://example.com/deep/path?q=1", title: "")?.origin
                == "https://example.com"
        )
        #expect(
            Sticker(url: "http://localhost:8080/admin", title: "")?.origin
                == "http://localhost:8080"
        )
    }

    // MARK: - List logic

    @Test("Pinning the same URL twice is a no-op")
    func dedupes() {
        let first = Sticker(url: "https://example.com/a", title: "A")!
        let duplicate = Sticker(url: "https://example.com/a", title: "A again")!
        let list = Sticker.adding(duplicate, to: Sticker.adding(first, to: []))
        #expect(list == [first])
    }

    @Test("Different URLs on the same host both pin")
    func sameHostDifferentPages() {
        let inbox = Sticker(url: "https://example.com/inbox", title: "Inbox")!
        let docs = Sticker(url: "https://example.com/docs", title: "Docs")!
        let list = Sticker.adding(docs, to: Sticker.adding(inbox, to: []))
        #expect(list.count == 2)
    }

    @Test("Removing by id leaves the rest in order")
    func removal() {
        let a = Sticker(url: "https://a.com", title: "A")!
        let b = Sticker(url: "https://b.com", title: "B")!
        let c = Sticker(url: "https://c.com", title: "C")!
        #expect(Sticker.removing(b.id, from: [a, b, c]) == [a, c])
    }

    // MARK: - Appearance

    @Test("Tilt is deterministic, never zero, and stays small")
    func tilt() {
        let sticker = Sticker(url: "https://example.com", title: "")!
        let tilt = sticker.tiltDegrees
        #expect(tilt == sticker.tiltDegrees)
        #expect(abs(tilt) >= 1.5)
        #expect(abs(tilt) <= 4.0)
    }

    @Test("Shine angle is deterministic and stays near the diagonal")
    func shineAngle() {
        let sticker = Sticker(url: "https://example.com", title: "")!
        #expect(sticker.shineAngleDegrees == sticker.shineAngleDegrees)
        #expect((14.0...38.0).contains(sticker.shineAngleDegrees))
        #expect((0.0...1.0).contains(sticker.shineOffset))
    }

    @Test("Tilt and shine vary independently across a shelf")
    func appearanceVaries() {
        // Salted separately, so neither is a function of the other — a shelf
        // where they moved together would read as one printed sheet.
        let shelf = (0..<40).map { Sticker(url: "https://example.com/\($0)", title: "")! }
        #expect(Set(shelf.map(\.shineAngleDegrees)).count > 8)
        #expect(Set(shelf.map(\.tiltDegrees)).count > 8)

        let byTilt = shelf.sorted { $0.tiltDegrees < $1.tiltDegrees }
        let byShine = shelf.sorted { $0.shineAngleDegrees < $1.shineAngleDegrees }
        #expect(byTilt.map(\.id) != byShine.map(\.id))
    }

    @Test("Fallback hue is stable per host and within range")
    func hue() {
        let one = Sticker(url: "https://example.com/a", title: "")!
        let two = Sticker(url: "https://example.com/b", title: "")!
        #expect(one.fallbackHue == two.fallbackHue)
        #expect((0..<1).contains(one.fallbackHue))
    }

    @Test("Fallback initial strips www. and uppercases")
    func initial() {
        #expect(Sticker(url: "https://www.github.com", title: "")?.fallbackInitial == "G")
        #expect(Sticker(url: "https://news.ycombinator.com", title: "")?.fallbackInitial == "N")
    }

    // MARK: - Persistence

    @Test("An island file written before stickers existed still decodes")
    func decodesLegacyIsland() throws {
        let json = """
            {"id":"00000000-0000-0000-0000-000000000001","name":"Home","symbol":"🏝️",
             "tint":{"red":0.1,"green":0.6,"blue":0.85},"dataStoreID":null,
             "tabs":[],"selectedIndex":0}
            """
        let island = try JSONDecoder().decode(PersistedIsland.self, from: Data(json.utf8))
        #expect(island.stickers == nil)
    }

    @Test("Stickers round-trip through the island's coding")
    func roundTrip() throws {
        let sticker = Sticker(url: "https://example.com", title: "Example")!
        var island = PersistedIsland.home()
        island.stickers = [sticker]
        let data = try JSONEncoder().encode(island)
        let decoded = try JSONDecoder().decode(PersistedIsland.self, from: data)
        #expect(decoded.stickers == [sticker])
    }

    @Test("A lone home island with stickers but no tabs survives sanitizing")
    func stickersKeepTheSession() {
        var home = PersistedIsland.home()
        home.stickers = [Sticker(url: "https://example.com", title: "Example")!]
        let session = PersistedSession(islands: [home], selectedIslandIndex: 0)
        #expect(session.sanitized() != nil)
    }

    @Test("A lone empty home island with no stickers still sanitizes to nil")
    func emptySessionStillDropped() {
        let session = PersistedSession(
            islands: [PersistedIsland.home()], selectedIslandIndex: 0
        )
        #expect(session.sanitized() == nil)
    }
}
