import Foundation
import Testing

@testable import SurfCore

@Suite("Storage model")
struct StorageModelTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func cookie(
        _ name: String = "session", value: String = "abc",
        domain: String = "example.com", expires: Date? = nil, httpOnly: Bool = false
    ) -> StorageCookie {
        StorageCookie(
            name: name, value: value, domain: domain,
            expiresAt: expires, isHTTPOnly: httpOnly
        )
    }

    /// A session cookie has no expiry at all, which is a different thing from
    /// one expiring soon — and it's the distinction that decides whether
    /// closing the browser logs you out.
    @Test("A cookie with no expiry reads as a session cookie")
    func sessionCookie() {
        #expect(cookie().expiryLabel(now: now) == "Session")
        #expect(!cookie().isExpired(now: now))
    }

    @Test("Expiry is described at the scale it happens on")
    func expiryScale() {
        func at(_ offset: TimeInterval) -> String {
            cookie(expires: now.addingTimeInterval(offset)).expiryLabel(now: now)
        }
        #expect(at(-60) == "Expired")
        #expect(at(1800) == "in 30 min")
        #expect(at(7200) == "in 2 h")
        #expect(at(3 * 86_400) == "in 3 d")
        #expect(at(800 * 86_400) == "in 2 y")
    }

    @Test("An expired cookie is identifiable")
    func expired() {
        #expect(cookie(expires: now.addingTimeInterval(-1)).isExpired(now: now))
        #expect(!cookie(expires: now.addingTimeInterval(1)).isExpired(now: now))
    }

    /// Two cookies can share a name and be completely different things — the
    /// triple that identifies one is domain, path and name together. Keying on
    /// the name alone would make deleting one delete the wrong cookie.
    @Test("A cookie is identified by domain, path and name together")
    func identity() {
        let a = StorageCookie(name: "id", value: "1", domain: "example.com", path: "/")
        let b = StorageCookie(name: "id", value: "2", domain: "api.example.com", path: "/")
        let c = StorageCookie(name: "id", value: "3", domain: "example.com", path: "/admin")
        #expect(Set([a.id, b.id, c.id]).count == 3)
    }

    @Test("A cookie's size counts both halves")
    func cookieSize() {
        #expect(cookie(value: "abcd").size == "session".utf8.count + 4)
    }

    // MARK: - Items

    @Test("A stored value is previewed on one line")
    func preview() {
        let item = StorageItem(key: "k", value: "line one\nline two")
        #expect(item.preview == "line one line two")
        let long = StorageItem(key: "k", value: String(repeating: "x", count: 400))
        #expect(long.preview.count == 201)
        #expect(long.preview.hasSuffix("…"))
    }

    /// Almost everything in localStorage is a serialised object, and knowing
    /// that is what lets the detail view offer to format it.
    @Test("JSON-looking values are recognised")
    func jsonDetection() {
        #expect(StorageItem(key: "k", value: #"{"a":1}"#).looksLikeJSON)
        #expect(StorageItem(key: "k", value: "[1,2]").looksLikeJSON)
        #expect(!StorageItem(key: "k", value: "plain").looksLikeJSON)
        // A lone brace is not an object.
        #expect(!StorageItem(key: "k", value: "{").looksLikeJSON)
    }

    // MARK: - Filtering

    @Test("Cookies filter across name, value and domain, and sort by name")
    func cookieFiltering() {
        let jar = [
            cookie("zebra", domain: "a.test"),
            cookie("alpha", value: "needle", domain: "b.test"),
            cookie("middle", domain: "needle.test"),
        ]
        #expect(StorageFilter.cookies(jar, query: "").map(\.name) == ["alpha", "middle", "zebra"])
        #expect(StorageFilter.cookies(jar, query: "needle").count == 2)
        #expect(StorageFilter.cookies(jar, query: "zeb").map(\.name) == ["zebra"])
    }

    @Test("Items filter across key and value, and sort by key")
    func itemFiltering() {
        let items = [
            StorageItem(key: "theme", value: "dark"),
            StorageItem(key: "auth", value: "token-xyz"),
        ]
        #expect(StorageFilter.items(items, query: "").map(\.key) == ["auth", "theme"])
        #expect(StorageFilter.items(items, query: "xyz").map(\.key) == ["auth"])
    }

    /// The reason to open a site-data list is to find what's large, so the
    /// largest origin has to be the one you don't have to scroll for.
    @Test("Site data sorts biggest first")
    func siteDataSorting() {
        let records = [
            SiteDataRecord(origin: "small.test", types: ["Cookies"], size: 10),
            SiteDataRecord(origin: "huge.test", types: ["IndexedDB"], size: 9_000),
            SiteDataRecord(origin: "middle.test", types: ["Cache"], size: 500),
        ]
        #expect(
            StorageFilter.siteData(records, query: "").map(\.origin)
                == ["huge.test", "middle.test", "small.test"]
        )
        #expect(StorageFilter.siteData(records, query: "huge").count == 1)
    }

    @Test("Equal sizes fall back to a stable alphabetical order")
    func siteDataTieBreak() {
        let records = [
            SiteDataRecord(origin: "b.test", types: [], size: 100),
            SiteDataRecord(origin: "a.test", types: [], size: 100),
        ]
        #expect(StorageFilter.siteData(records, query: "").map(\.origin) == ["a.test", "b.test"])
    }

    // MARK: - Sizes

    @Test("Byte counts read in the unit that suits them")
    func byteFormatting() {
        #expect(ByteSize.format(512) == "512 B")
        #expect(ByteSize.format(2048) == "2.0 kB")
        #expect(ByteSize.format(5 * 1024 * 1024) == "5.00 MB")
        #expect(ByteSize.format(3 * 1024 * 1024 * 1024) == "3.00 GB")
    }

    @Test("Only local and session storage can be edited in place")
    func editability() {
        #expect(StorageArea.local.isEditable)
        #expect(StorageArea.session.isEditable)
        #expect(!StorageArea.cookies.isEditable)
        #expect(!StorageArea.siteData.isEditable)
    }
}
