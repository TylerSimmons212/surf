import Testing

@testable import GlassCore

@Suite("Developer tools protocol")
struct DevToolsProtocolTests {

    @Test("A bootstrap event carries the document it belongs to")
    func decodesBootstrap() {
        let event = DevToolsProtocol.decodeEvent([
            "event": "bootstrapped",
            "url": "https://example.com/",
            "generation": 3,
        ])
        #expect(event == .bootstrapped(frameURL: "https://example.com/", generation: 3))
    }

    /// The page is not a trusted peer. A malformed or half-written message must
    /// degrade to a usable default rather than crash the browser it's inside.
    @Test("A bootstrap event missing its fields still decodes")
    func toleratesMissingFields() {
        let event = DevToolsProtocol.decodeEvent(["event": "bootstrapped"])
        #expect(event == .bootstrapped(frameURL: "", generation: 0))
    }

    @Test("Unknown and malformed messages are dropped, not guessed at")
    func rejectsUnknown() {
        #expect(DevToolsProtocol.decodeEvent(["event": "somethingElse"]) == nil)
        #expect(DevToolsProtocol.decodeEvent(["url": "https://example.com/"]) == nil)
        #expect(DevToolsProtocol.decodeEvent("not a dictionary") == nil)
        #expect(DevToolsProtocol.decodeEvent(42) == nil)
    }

    @Test("Overflow decodes, because ignoring it would silently desync the tree")
    func decodesOverflow() {
        #expect(DevToolsProtocol.decodeEvent(["event": "overflowed"]) == .overflowed)
    }

    /// Two methods sharing a wire name would route to whichever the switch
    /// happened to test first — a bug that only shows up under load.
    @Test("Every method has a distinct wire name")
    func methodNamesAreUnique() {
        let names = Set(DevToolsMethod.allCases.map(\.rawValue))
        #expect(names.count == DevToolsMethod.allCases.count)
    }

    @Test("Every method is namespaced by domain")
    func methodNamesAreNamespaced() {
        for method in DevToolsMethod.allCases {
            #expect(method.rawValue.contains("."), "\(method.rawValue) has no domain")
        }
    }
}
