import Foundation
import GlassCore
import WebKit

/// The transport between one tab and one dev tools session.
///
/// Owns script installation, handler registration, and their symmetric removal.
/// Deliberately knows nothing about what any message *means* — that's the
/// session's job. Keeping the WebKit plumbing in one object with no domain
/// knowledge is what lets the model layer live in `GlassCore` and be tested
/// without a browser at all.
@MainActor
final class DevToolsBridge {

    enum BridgeError: LocalizedError {
        case notAttached
        case noAgent
        case agent(String)

        var errorDescription: String? {
            switch self {
            case .notAttached: "Developer tools are not attached to this tab."
            case .noAgent: "This page can't be inspected."
            case .agent(let message): message
            }
        }
    }

    private weak var tab: Tab?

    /// Pushed messages from the page. The session sets this.
    var onEvent: ((DevToolsEvent) -> Void)?

    private(set) var isAttached = false

    init(tab: Tab) {
        self.tab = tab
        // The tab has to know about us before `attach()` runs:
        // `reinstallUserScripts()` asks the bridge whether to include the agent.
        tab.attachDevTools(self)
    }

    // MARK: - Lifecycle

    /// Installs the agent and confirms it's answering.
    ///
    /// Idempotent: attaching twice is a no-op rather than a duplicate handler,
    /// which WebKit would throw on.
    func attach() async throws {
        guard !isAttached, let tab else { return }
        isAttached = true

        let controller = tab.webView.configuration.userContentController
        // Popup tabs inherit WebKit's configuration, which may already carry a
        // handler under this name; adding a duplicate throws. The same defence
        // the media bridge has needed since day one.
        controller.removeScriptMessageHandler(
            forName: DevToolsAgent.eventHandlerName,
            contentWorld: DevToolsAgent.world
        )
        // Note the `contentWorld:` overload. The plain `add(_:name:)` that the
        // media bridge uses registers into the *page* world only, which would
        // leave `messageHandlers` undefined for an agent running in ours.
        controller.add(
            WeakScriptMessageProxy(target: tab),
            contentWorld: DevToolsAgent.world,
            name: DevToolsAgent.eventHandlerName
        )

        // The console agent is already resident and has been buffering since
        // document-start; this is the first moment it has anywhere to post to.
        controller.removeScriptMessageHandler(
            forName: ConsoleAgent.eventHandlerName,
            contentWorld: .page
        )
        controller.add(
            WeakScriptMessageProxy(target: tab),
            contentWorld: .page,
            name: ConsoleAgent.eventHandlerName
        )

        // Network capture has been recording since document-start for exactly
        // the same reason the console has: the request worth looking at is
        // usually the one that already failed.
        controller.removeScriptMessageHandler(
            forName: NetworkAgent.eventHandlerName,
            contentWorld: .page
        )
        controller.add(
            WeakScriptMessageProxy(target: tab),
            contentWorld: .page,
            name: NetworkAgent.eventHandlerName
        )

        // Adds the agent to the document-start set, so it survives navigation.
        tab.reinstallUserScripts()

        // The document already on screen never ran that script — user scripts
        // only apply to loads that come after. Bootstrap this one by hand.
        _ = try? await tab.webView.callAsyncJavaScript(
            DevToolsAgent.script,
            arguments: [:],
            in: nil,
            contentWorld: DevToolsAgent.world
        )

        // Proves the whole path end to end before the UI claims to be connected.
        _ = try await call(.runtimePing)
    }

    /// The exact inverse of `attach()`, and safe to call twice.
    func detach() {
        guard isAttached, let tab else {
            isAttached = false
            self.tab?.detachDevTools()
            return
        }
        isAttached = false
        defer { tab.detachDevTools() }

        // Back to buffering-only: with no handler its `post` throws, which the
        // agent catches by flipping itself out of live mode.
        Task { @MainActor [weak tab] in
            _ = try? await tab?.webView.callAsyncJavaScript(
                ConsoleAgent.dispatchScript,
                arguments: ["method": DevToolsMethod.consoleSetLive.rawValue,
                            "params": ["live": false]],
                in: nil,
                contentWorld: .page
            )
        }

        let controller = tab.webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: DevToolsAgent.eventHandlerName,
            contentWorld: DevToolsAgent.world
        )
        controller.removeScriptMessageHandler(
            forName: ConsoleAgent.eventHandlerName,
            contentWorld: .page
        )
        controller.removeScriptMessageHandler(
            forName: NetworkAgent.eventHandlerName,
            contentWorld: .page
        )
        // Drops the agent from the document-start set. The copy in the *current*
        // document stays resident until navigation, but with its handler gone it
        // can no longer speak, and its `post` swallows the resulting throw.
        tab.reinstallUserScripts()
    }

    // MARK: - Commands

    /// Glass → page, with a reply.
    ///
    /// Correlation is `async`/`await` itself: one Swift continuation per call in
    /// flight, so there's no request-id table, no pending map and no timeout
    /// bookkeeping. That's the single biggest simplification over speaking a
    /// CDP-style socket protocol, and it's why `DevToolsMethod` carries method
    /// names but no envelope.
    /// `Sendable` values rather than `Any`: parameters cross an await boundary,
    /// and the compiler is right to insist they be safe to carry.
    @discardableResult
    func call(
        _ method: DevToolsMethod,
        _ params: [String: any Sendable] = [:]
    ) async throws -> [String: Any] {
        guard isAttached, let tab else { throw BridgeError.notAttached }

        // Three injected scripts, so three dispatchers. Console and network
        // both live in the page's world but are separate objects with separate
        // lifetimes, and routing a network command through the console's
        // dispatcher fails as "unknown method" — which reads like a missing
        // feature rather than a misroute.
        let (dispatch, world): (String, WKContentWorld) = switch method.target {
        case .agent: (DevToolsAgent.dispatchScript, DevToolsAgent.world)
        case .page: (ConsoleAgent.dispatchScript, .page)
        case .network: (NetworkAgent.dispatchScript, .page)
        }

        let raw = try await tab.webView.callAsyncJavaScript(
            dispatch,
            arguments: ["method": method.rawValue, "params": params],
            in: nil,
            contentWorld: world
        )

        // Null means the agent isn't present — an `about:blank`, a PDF view, or
        // a page whose load raced the injection.
        guard let json = raw as? String else { throw BridgeError.noAgent }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dict = object as? [String: Any]
        else { throw BridgeError.noAgent }

        if let message = dict["error"] as? String { throw BridgeError.agent(message) }
        return dict
    }

    /// Fire and forget, for commands whose reply carries nothing — acks and
    /// object releases. Keeping the untyped reply inside the bridge means it
    /// never has to cross a task boundary at the call site.
    func send(_ method: DevToolsMethod, _ params: [String: any Sendable] = [:]) {
        Task { @MainActor in
            _ = try? await call(method, params)
        }
    }

    // MARK: - Events

    /// Called by `Tab`'s dispatcher. The bridge never registers itself as the
    /// handler, so a tab still has exactly one `WKScriptMessageHandler` and the
    /// existing retain-cycle reasoning is untouched.
    func receive(name: String, body: Any) {
        guard name == DevToolsAgent.eventHandlerName
                || name == ConsoleAgent.eventHandlerName
                || name == NetworkAgent.eventHandlerName
        else { return }
        guard let event = DevToolsProtocol.decodeEvent(body) else { return }
        onEvent?(event)
    }
}
