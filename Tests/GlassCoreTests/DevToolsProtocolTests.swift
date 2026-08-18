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

@Suite("Developer tools routing")
struct DevToolsRoutingTests {

    /// Evaluation has to run in the page's own globals — the same world that
    /// holds the object handles it hands back. Routing it to the isolated
    /// agent made it fail as an "unknown method", which reads like a missing
    /// feature rather than a misrouted call.
    @Test("Evaluation and object handles belong to the page world")
    func evaluationRunsInThePage() {
        #expect(DevToolsMethod.runtimeEvaluate.target == .page)
        #expect(DevToolsMethod.runtimeGetProperties.target == .page)
        #expect(DevToolsMethod.runtimeReleaseObject.target == .page)
    }

    /// The console patches page globals, so it cannot live anywhere else.
    @Test("Console commands belong to the page world")
    func consoleRunsInThePage() {
        #expect(DevToolsMethod.consoleDrain.target == .page)
        #expect(DevToolsMethod.consoleAck.target == .page)
        #expect(DevToolsMethod.consoleSetLive.target == .page)
    }

    /// Inspection runs isolated so the page can neither detect it nor break it
    /// by overwriting a prototype the agent relies on.
    @Test("Inspection belongs to the isolated agent")
    func inspectionRunsIsolated() {
        #expect(DevToolsMethod.runtimePing.target == .agent)
        #expect(DevToolsMethod.domGetDocument.target == .agent)
        #expect(DevToolsMethod.cssGetMatchedStyles.target == .agent)
        #expect(DevToolsMethod.overlaySetInspectMode.target == .agent)
    }

    /// The split does not follow the domain prefix — `Runtime` spans both —
    /// which is exactly why the target is stated per method.
    @Test("Routing is not inferable from the domain prefix")
    func routingIsNotPrefixBased() {
        #expect(DevToolsMethod.runtimePing.target != DevToolsMethod.runtimeEvaluate.target)
    }
}
