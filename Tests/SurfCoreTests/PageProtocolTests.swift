import Foundation
import Testing
@testable import SurfCore

@Suite("Page agent protocol")
struct PageProtocolTests {

    struct Rect: Decodable, Equatable {
        var x: Double
        var y: Double
    }

    // MARK: - Replies

    @Test("A successful reply yields its value")
    func decodesValue() throws {
        let value = try PageProtocol.decode(
            #"{"ok":true,"value":{"x":1,"y":2}}"#, as: Rect.self, method: "media.frame"
        )
        #expect(value == Rect(x: 1, y: 2))
    }

    @Test("A reported failure carries the page's own message")
    func carriesPageError() {
        #expect(throws: PageProtocol.Failure.page(method: "theme.apply", message: "boom")) {
            try PageProtocol.decode(
                #"{"ok":false,"error":"boom"}"#, as: PageProtocol.Empty.self,
                method: "theme.apply"
            )
        }
    }

    /// The distinction the old `try?` call sites couldn't make: a page with
    /// nothing to report is ordinary, a reply that isn't the shape we asked
    /// for is a bug.
    @Test("Nothing to report is distinguished from a broken reply")
    func separatesEmptyFromBroken() {
        #expect(throws: PageProtocol.Failure.noValue(method: "media.frame")) {
            try PageProtocol.decode(
                #"{"ok":true,"value":null}"#, as: Rect.self, method: "media.frame"
            )
        }
        #expect(throws: PageProtocol.Failure.malformed(method: "media.frame")) {
            try PageProtocol.decode(
                #"{"ok":true,"value":{"x":"not a number"}}"#, as: Rect.self,
                method: "media.frame"
            )
        }
        #expect(throws: PageProtocol.Failure.malformed(method: "media.frame")) {
            try PageProtocol.decode("<html>", as: Rect.self, method: "media.frame")
        }
    }

    @Test("A method returning nothing still reports success")
    func decodesEmpty() throws {
        _ = try PageProtocol.decode(
            #"{"ok":true,"value":true}"#, as: PageProtocol.Empty.self, method: "theme.revert"
        )
    }

    // MARK: - Events

    @Test("An event is routable before its payload is known")
    func readsEventHeader() throws {
        let json = #"{"domain":"media","event":"state","payload":{"x":3,"y":4}}"#
        let header = try JSONDecoder().decode(
            PageProtocol.EventHeader.self, from: Data(json.utf8)
        )
        #expect(header == PageProtocol.EventHeader(domain: "media", event: "state"))

        let full = try JSONDecoder().decode(
            PageProtocol.Event<Rect>.self, from: Data(json.utf8)
        )
        #expect(full.payload == Rect(x: 3, y: 4))
    }

    // MARK: - Method table

    /// The reason the enum exists: one spelling of each name, and one place
    /// that decides which world it runs in.
    @Test("Every method has a distinct name")
    func methodNamesAreUnique() {
        let names = PageProtocol.Method.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    @Test("A method's name is namespaced by its domain")
    func methodNamesAreNamespaced() {
        for method in PageProtocol.Method.allCases {
            #expect(method.rawValue.contains("."), "\(method.rawValue) has no domain")
        }
    }

    /// Media and find both need the site's own `navigator` and selection, so
    /// they cannot run anywhere but the page world; the theme cannot run in
    /// it. YouTube joins them for the same reason: `ytInitialData` and the
    /// player's own methods are the site's globals, and an isolated world
    /// has neither. The stream tap joins them too: it wraps `MediaSource` and
    /// `navigator.requestMediaKeySystemAccess`, and an isolated world has its
    /// own copies of both with nothing in them — so a tap installed there would
    /// record nothing and report it as an absence of DRM, which is the one wrong
    /// answer that matters. Asserting the split here means a new method can't
    /// quietly pick the wrong one.
    @Test("Worlds are assigned by domain, not case by case")
    func worldsFollowDomain() {
        let pageWorldDomains: Set<Substring> = [
            "media", "stream", "find", "youtube", "amazon",
        ]
        for method in PageProtocol.Method.allCases {
            let domain = method.rawValue.split(separator: ".")[0]
            let expected: PageProtocol.World =
                pageWorldDomains.contains(domain) ? .page : .isolated
            #expect(method.world == expected, "\(method.rawValue) is in the wrong world")
        }
    }

    @Test("The two worlds cannot be confused for one another")
    func handlerNamesDiffer() {
        #expect(PageProtocol.World.isolated.handlerName != PageProtocol.World.page.handlerName)
    }
}

/// The seam that keeps a verification run out of the preferences of the Surf
/// you have open. See `SurfDefaults`.
@Suite("Scratch defaults")
struct SurfDefaultsTests {

    @Test("A state directory names a suite of its own")
    func derivesASuite() {
        let name = SurfDefaults.suiteName(forStateDirectory: "/tmp/surf-verify-state.abc")
        #expect(name.hasPrefix("surf.scratch."))
        // A defaults domain is a filename, and a path is full of characters a
        // filename should not carry.
        #expect(name.contains("/") == false)
        #expect(name.contains(" ") == false)
    }

    /// Derived rather than random, so a run that restarts finds what it left
    /// behind rather than starting over with a fresh domain.
    @Test("The same directory always names the same suite")
    func isStable() {
        #expect(SurfDefaults.suiteName(forStateDirectory: "/tmp/one")
            == SurfDefaults.suiteName(forStateDirectory: "/tmp/one"))
    }

    @Test("Different directories name different suites")
    func separatesRuns() {
        let a = SurfDefaults.suiteName(forStateDirectory: "/tmp/surf-verify-state.aaa")
        let b = SurfDefaults.suiteName(forStateDirectory: "/tmp/surf-verify-state.bbb")
        #expect(a != b)
    }

    /// It only has to not collide between two scratch directories on one
    /// machine, but a hash that maps everything to one bucket would do
    /// exactly that.
    @Test("Similar paths do not collide")
    func spreads() {
        let names = Set((0..<200).map {
            SurfDefaults.suiteName(forStateDirectory: "/tmp/surf-verify-state.\($0)")
        })
        #expect(names.count == 200)
    }

    // MARK: - The cookie jar

    /// The same seam, for the hole that mattered more. A scratch run's home
    /// island used to be WebKit's default store, which is the user's own jar —
    /// `SURF_STATE_DIR` cannot redirect it, because it is WebKit's container
    /// rather than one of our files.
    @Test("Different directories name different cookie jars")
    func separatesJars() {
        let a = SurfDefaults.dataStoreID(forStateDirectory: "/tmp/surf-verify-state.aaa")
        let b = SurfDefaults.dataStoreID(forStateDirectory: "/tmp/surf-verify-state.bbb")
        #expect(a != b)
    }

    /// A run that restarts against the same directory has to find the jar it
    /// left behind, or nothing can sign in and then check it stayed signed in.
    @Test("The same directory always names the same jar")
    func jarIsStable() {
        #expect(
            SurfDefaults.dataStoreID(forStateDirectory: "/tmp/one")
                == SurfDefaults.dataStoreID(forStateDirectory: "/tmp/one")
        )
    }

    /// Two ways the derivation could fail quietly, both pinned here.
    ///
    /// Falling through to the sentinel would make every scratch directory share
    /// one jar. And an all-zero identifier makes `WKWebsiteDataStore` raise
    /// rather than return nil, so it is refused upstream and the run degrades
    /// to a non-persistent store — still isolated, but forgetting every cookie
    /// at quit, which is a confusing way to discover a hash bug.
    @Test("A jar is derived from the path, whatever the path looks like")
    func jarIsAlwaysDerived() {
        let awkward = [
            "/tmp/a", "", "/", "/Users/x/.verify/run",
            String(repeating: "z", count: 300), "/tmp/ünïcode/path",
        ]
        for path in awkward {
            let id = SurfDefaults.dataStoreID(forStateDirectory: path)
            #expect(id != SurfDefaults.zeroStoreID)
            #expect(id != SurfDefaults.fallbackStoreID)
        }
    }

    @Test("Similar paths do not collide on a jar either")
    func jarsSpread() {
        let ids = Set((0..<200).map {
            SurfDefaults.dataStoreID(forStateDirectory: "/tmp/surf-verify-state.\($0)")
        })
        #expect(ids.count == 200)
    }
}
