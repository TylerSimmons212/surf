import Foundation

/// The wire vocabulary between Glass and the scripts it injects into a page.
///
/// Deliberately CDP-shaped — `Domain.method` — so Network, Storage and the rest
/// slot in later without reshaping the envelope. The names are ours, not
/// Chrome's protocol; the borrowing is of the *grouping*, which has survived a
/// decade of devtools features and is the right seam to cut along.
public enum DevToolsMethod: String, Sendable, CaseIterable {
    /// Liveness. Cheap enough to use as the attach handshake.
    case runtimePing = "Runtime.ping"
    case runtimeEvaluate = "Runtime.evaluate"
    case runtimeGetProperties = "Runtime.getProperties"
    case runtimeReleaseObject = "Runtime.releaseObject"

    case consoleDrain = "Console.drain"
    case consoleSetLive = "Console.setLive"
    case consoleAck = "Console.ack"

    case domGetDocument = "DOM.getDocument"
    case domRequestChildNodes = "DOM.requestChildNodes"
    case domGetBoxModel = "DOM.getBoxModel"

    case cssGetMatchedRules = "CSS.getMatchedRulesForNode"
    case cssGetComputed = "CSS.getComputedStyleForNode"

    case overlaySetInspectMode = "Overlay.setInspectMode"
}

/// What the injected scripts push without being asked.
public enum DevToolsEvent: Sendable, Equatable {
    /// A fresh document is live. Carries the generation the page reports so a
    /// reply racing a navigation can be told apart from a current one.
    case bootstrapped(frameURL: String, generation: Int)
    /// The agent gave up keeping pace and dropped work. The only correct
    /// response is a resync — never a replay, which would double-apply.
    case overflowed
}

public enum DevToolsProtocol {

    /// Every message the page sends is `{ "event": "...", ... }`. Anything else
    /// is either a version skew or something that isn't ours, and is dropped
    /// rather than guessed at.
    public static func decodeEvent(_ body: Any) -> DevToolsEvent? {
        guard let dict = body as? [String: Any],
              let event = dict["event"] as? String
        else { return nil }

        switch event {
        case "bootstrapped":
            return .bootstrapped(
                frameURL: dict["url"] as? String ?? "",
                generation: dict["generation"] as? Int ?? 0
            )
        case "overflowed":
            return .overflowed
        default:
            return nil
        }
    }
}
