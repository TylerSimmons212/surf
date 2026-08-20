import Foundation

/// The wire vocabulary between Surf and the scripts it injects into a page.
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
    /// Adds or removes one class on one element.
    case domSetClass = "DOM.setClass"
    /// Sets or removes one attribute on one element.
    case domSetAttribute = "DOM.setAttribute"
    /// Rewrites a text or comment node's contents.
    case domSetText = "DOM.setText"
    /// Simulates :hover and friends on one element, by selector rewriting —
    /// WebKit exposes no engine hook for forcing element state.
    case cssForceState = "CSS.forceState"
    case domAck = "DOM.ack"

    case cssGetMatchedStyles = "CSS.getMatchedStyles"
    case cssGetComputed = "CSS.getComputedStyleForNode"
    /// Replaces a declaration block wholesale — the only CSSOM surface that
    /// preserves authored order, so it covers editing, disabling and adding.
    case cssSetRuleText = "CSS.setRuleText"
    case cssRevert = "CSS.revert"
    /// Hands back a stylesheet the page itself is forbidden to read, refetched
    /// natively. Parsed in the page so its selectors can be matched there.
    case cssAddRecoveredSheet = "CSS.addRecoveredSheet"
    /// Locates rules with no element involved, for replaying edits after a
    /// reload has cleared the selection.
    case cssFindRules = "CSS.findRules"
    /// The engine's own property list, asked of the engine. A bundled list
    /// would drift from the WebKit actually running; enumerating one computed
    /// style declaration answers with exactly the properties this build
    /// understands, which is the only correct completion source.
    case cssPropertyNames = "CSS.propertyNames"
    /// Creates an empty rule in Surf's own stylesheet on the page.
    case cssAddRule = "CSS.addRule"

    case storageRead = "Storage.read"
    case storageWrite = "Storage.write"
    case storageRemove = "Storage.remove"
    case storageListCaches = "Storage.listCaches"
    case storageListDatabases = "Storage.listDatabases"
    case storageEstimate = "Storage.estimate"

    case performanceRead = "Performance.read"
    case performanceWatchLayout = "Performance.watchLayout"

    case overlaySetInspectMode = "Overlay.setInspectMode"

    case networkDrain = "Network.drain"
    case networkSetLive = "Network.setLive"
    case networkAck = "Network.ack"
    case networkClear = "Network.clear"
    /// Fetched for one request at a time. Bodies are held in the page rather
    /// than pushed with every batch — see `NetworkAgent`.
    case networkGetBody = "Network.getBody"
    /// Reads the page's tag globals. Page world, because that is the only place
    /// a page's globals exist.
    case tagsDetect = "Tags.detect"
}

/// Which injected script answers a command.
///
/// Stated per method rather than inferred from the domain name, because the
/// split doesn't follow the domains: `Runtime.ping` is a liveness check on the
/// inspection agent, while `Runtime.evaluate` has to run in the page's own
/// globals — the same world that holds the objects it hands back. Guessing
/// from a prefix put evaluation in the wrong world and it failed as "no such
/// method", which reads like a missing feature rather than a misrouted call.
/// `scripts/check-js.sh` now asks every method of the two targets it does not
/// belong to, so a repeat of that is a failed check rather than a bug report.
public enum DevToolsTarget: String, Sendable, Equatable, CaseIterable {
    /// The isolated world: DOM, styles, overlay.
    case agent
    /// The page's own world: console capture, evaluation, object handles.
    case page
    /// Also the page's world, but a separate script with its own dispatcher.
    /// Network capture has to replace `fetch` and `XMLHttpRequest`, which can
    /// only be done where the page's own globals live — but it is a different
    /// concern from the console and is installed and drained separately.
    case network
}

extension DevToolsMethod {
    public var target: DevToolsTarget {
        switch self {
        case .runtimePing,
             .domGetDocument, .domRequestChildNodes, .domGetBoxModel,
             .domScrollIntoView, .domWatch, .domPathToNode, .domAck, .domSetClass,
             .domSetAttribute, .domSetText,
             .cssGetMatchedStyles, .cssGetComputed, .cssSetRuleText, .cssRevert,
             .cssAddRecoveredSheet, .cssFindRules, .cssPropertyNames, .cssAddRule,
             .cssForceState,
             .storageRead, .storageWrite, .storageRemove,
             .storageListCaches, .storageListDatabases, .storageEstimate,
             .performanceRead, .performanceWatchLayout,
             .overlaySetInspectMode:
            .agent
        case .runtimeEvaluate, .runtimeGetProperties, .runtimeReleaseObject,
             .runtimeCompletions,
             .consoleDrain, .consoleSetLive, .consoleAck:
            .page
        case .networkDrain, .networkSetLive, .networkAck, .networkClear, .networkGetBody,
             .tagsDetect:
            .network
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
    /// Requests observed, batched. `dropped` counts records the agent had to
    /// discard to stay bounded.
    case networkBatch(
        requests: [NetworkRequest], timings: [NetworkRequest], sequence: Int, dropped: Int
    )
    /// The agent stopped reporting to keep up. Everything is still in its map,
    /// so the answer is a resync — a replay would double-count.
    case networkOverflowed
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
        case "network.batch":
            let batch = NetworkWire.decodeBatch(dict["requests"])
            return .networkBatch(
                requests: batch.records,
                timings: batch.timings,
                sequence: dict["sequence"] as? Int ?? 0,
                dropped: dict["dropped"] as? Int ?? 0
            )
        case "network.overflowed":
            return .networkOverflowed
        case "dom.boxChanged":
            guard let nodeId = dict["nodeId"] as? Int else { return nil }
            return .boxChanged(nodeId: nodeId, box: DOMWire.decodeBox(dict["box"]))
        default:
            return nil
        }
    }
}
