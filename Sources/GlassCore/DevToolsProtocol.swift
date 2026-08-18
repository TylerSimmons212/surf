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
    case runtimeCompletions = "Runtime.completions"

    case consoleDrain = "Console.drain"
    case consoleSetLive = "Console.setLive"
    case consoleAck = "Console.ack"

    case domGetDocument = "DOM.getDocument"
    case domRequestChildNodes = "DOM.requestChildNodes"
    case domGetBoxModel = "DOM.getBoxModel"
    case domScrollIntoView = "DOM.scrollIntoView"
    case domWatch = "DOM.watch"
    case domPathToNode = "DOM.pathToNode"
    case domAck = "DOM.ack"

    case cssGetMatchedRules = "CSS.getMatchedRulesForNode"
    case cssGetComputed = "CSS.getComputedStyleForNode"

    case overlaySetInspectMode = "Overlay.setInspectMode"
}

/// Which injected script answers a command.
///
/// Stated per method rather than inferred from the domain name, because the
/// split doesn't follow the domains: `Runtime.ping` is a liveness check on the
/// inspection agent, while `Runtime.evaluate` has to run in the page's own
/// globals — the same world that holds the objects it hands back. Guessing
/// from a prefix put evaluation in the wrong world and it failed as an
/// "unknown method", which reads like a missing feature rather than a
/// misrouted call.
public enum DevToolsTarget: Sendable, Equatable {
    /// The isolated world: DOM, styles, overlay.
    case agent
    /// The page's own world: console capture, evaluation, object handles.
    case page
}

extension DevToolsMethod {
    public var target: DevToolsTarget {
        switch self {
        case .runtimePing,
             .domGetDocument, .domRequestChildNodes, .domGetBoxModel,
             .domScrollIntoView, .domWatch, .domPathToNode, .domAck,
             .cssGetMatchedRules, .cssGetComputed,
             .overlaySetInspectMode:
            .agent
        case .runtimeEvaluate, .runtimeGetProperties, .runtimeReleaseObject,
             .runtimeCompletions,
             .consoleDrain, .consoleSetLive, .consoleAck:
            .page
        }
    }
}

/// What the injected scripts push without being asked.
public enum DevToolsEvent: Sendable, Equatable {
    /// A fresh document is live. Carries the generation the page reports so a
    /// reply racing a navigation can be told apart from a current one.
    case bootstrapped(frameURL: String, generation: Int)
    /// The agent gave up keeping pace and dropped work. The only correct
    /// response is a resync — never a replay, which would double-apply.
    case overflowed
    /// Log output, batched. The sequence is what gets acked, which is how the
    /// page knows we're keeping up. `dropped` counts messages the agent had to
    /// discard to stay bounded since the last batch — zero in normal use.
    case consoleBatch(entries: [ConsoleEntry], sequence: Int, dropped: Int)
    /// The page called `console.clear()` itself.
    case consoleCleared
    /// The page's DOM changed under a subtree the panel is mirroring.
    case domMutations(mutations: [DOMMutation], sequence: Int)
    /// The pointer moved over a new element while the picker is armed.
    case inspectHover(nodeId: DOMNodeID, box: BoxModel?)
    case inspectPicked(nodeId: DOMNodeID)
    case inspectCancelled
    /// A watched element moved — scrolled, resized, or animated. Reported from
    /// the page rather than polled, so the highlight tracks without lag.
    case boxChanged(nodeId: DOMNodeID, box: BoxModel?)
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
        case "console":
            guard let batch = ConsoleWire.decodeBatch(dict) else { return nil }
            return .consoleBatch(
                entries: batch.entries,
                sequence: batch.sequence,
                dropped: batch.dropped
            )
        case "cleared":
            return .consoleCleared
        case "dom.mutations":
            return .domMutations(
                mutations: DOMWire.decodeMutations(dict["mutations"]),
                sequence: dict["sequence"] as? Int ?? 0
            )
        case "dom.inspectHover":
            guard let nodeId = dict["nodeId"] as? Int else { return nil }
            return .inspectHover(nodeId: nodeId, box: DOMWire.decodeBox(dict["box"]))
        case "dom.inspectPicked":
            guard let nodeId = dict["nodeId"] as? Int else { return nil }
            return .inspectPicked(nodeId: nodeId)
        case "dom.inspectCancelled":
            return .inspectCancelled
        case "dom.boxChanged":
            guard let nodeId = dict["nodeId"] as? Int else { return nil }
            return .boxChanged(nodeId: nodeId, box: DOMWire.decodeBox(dict["box"]))
        default:
            return nil
        }
    }
}
