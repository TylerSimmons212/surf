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
    /// has neither. Asserting the split here means a new method can't
    /// quietly pick the wrong one.
    @Test("Worlds are assigned by domain, not case by case")
    func worldsFollowDomain() {
        let pageWorldDomains: Set<Substring> = ["media", "find", "youtube", "amazon"]
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
