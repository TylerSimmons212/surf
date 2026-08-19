import Foundation
import Testing
@testable import SurfCore

@Suite("Island layout")
struct IslandLayoutTests {

    /// The all-zeros UUID doesn't make `WKWebsiteDataStore(forIdentifier:)`
    /// return nil, it makes it raise — so this check is the difference between
    /// an island that fails to isolate and an app that terminates.
    @Test("The all-zeros identifier is rejected")
    func zeroIdentifierRejected() {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(IslandLayout.isValidDataStoreIdentifier(zero) == false)
    }

    /// The check has to be narrow. Rejecting anything else would send a
    /// perfectly good island down the degraded, non-persistent path and lose
    /// the user's logins on every quit.
    @Test("Freshly minted identifiers are accepted")
    func freshIdentifiersAccepted() {
        for _ in 0..<100 {
            #expect(IslandLayout.isValidDataStoreIdentifier(UUID()))
        }
    }
}
