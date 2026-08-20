import Foundation
import SurfCore
import WebKit

/// Surf's side of the conversation with one content world in one tab.
///
/// There is exactly one resident agent per world, installed at document start
/// and addressed by method name. What this replaces is a habit rather than a
/// class: every feature used to hand WebKit a fresh block of JavaScript
/// source, spelled out at the call site, and unpick the answer by hand. That
/// is what made the browser feel like something wrapped around WebKit instead
/// of something built on it — each feature negotiating its own terms with the
/// page, in its own dialect, with its own way of being quietly wrong.
///
/// The dispatch source below is a constant. Nothing is interpolated into
/// JavaScript at any call site, because `callAsyncJavaScript` binds arguments
/// as real variables — so a method name and its parameters are values, and can
/// never become script.
@MainActor
final class PageAgent: NSObject {

    let world: PageProtocol.World

    /// Weak: the tab owns the web view, and the web view's content controller
    /// holds this agent as a message handler. A strong link back would be a
    /// cycle that keeps every closed tab — and its audio — alive.
    private weak var webView: WKWebView?

    /// Called with each event the page pushes, already routed by header.
    ///
    /// The `Data` is the whole envelope, so the receiver can decode the
    /// payload into whatever type the header says it will be. The frame comes
    /// with it because an event from a page world arrives from whichever frame
    /// sent it, and a reply usually has to go back to that same one — an
    /// embedded player's element does not exist in the main frame.
    var onEvent: ((PageProtocol.EventHeader, Data, WKFrameInfo) -> Void)?

    /// One statement, never rebuilt. `handle`, `method` and `params` arrive as
    /// bound variables rather than as text spliced into the source.
    private static let dispatchSource = """
    return await window[handle].dispatch(method, params);
    """

    init(world: PageProtocol.World, webView: WKWebView) {
        self.world = world
        self.webView = webView
        super.init()
    }

    // MARK: - Calling the page

    /// Runs a method and decodes its answer.
    ///
    /// Throws rather than returning nil, so the three ways a call can come
    /// back empty stay distinguishable: the page reported a failure, the reply
    /// wasn't the promised shape, or there was legitimately nothing to report.
    /// The old call sites were uniformly `try?`, which made a broken script
    /// look exactly like a page with nothing to say.
    /// - Parameter frame: which frame to run in, or nil for the main one.
    ///   A page that hosts its player in an iframe has no media element in the
    ///   main frame at all, so "the page" is the wrong unit for anything that
    ///   addresses one.
    @discardableResult
    func call<Value: Decodable>(
        _ method: PageProtocol.Method,
        _ params: [String: Any] = [:],
        as _: Value.Type,
        in frame: WKFrameInfo? = nil
    ) async throws -> Value {
        precondition(
            method.world == world,
            "\(method.rawValue) belongs to the \(method.world.rawValue) world, not \(world.rawValue)"
        )
        guard let webView else {
            throw PageProtocol.Failure.unreachable(method: method.rawValue)
        }

        let reply: Any?
        do {
            reply = try await webView.callAsyncJavaScript(
                Self.dispatchSource,
                arguments: [
                    "handle": PageRuntime.handle,
                    "method": method.rawValue,
                    "params": params,
                ],
                in: frame,
                contentWorld: world.contentWorld
            )
        } catch {
            // WebKit itself refused: the frame has navigated or been removed.
            throw PageProtocol.Failure.unreachable(method: method.rawValue)
        }
        guard let json = reply as? String else {
            // The dispatcher's own null — no runtime in this document at all.
            throw PageProtocol.Failure.unreachable(method: method.rawValue)
        }
        return try PageProtocol.decode(json, as: Value.self, method: method.rawValue)
    }

    /// Runs a method and hands back the raw reply envelope, undecoded.
    ///
    /// For the callers whose replies are heavy — a theme survey is thousands
    /// of colour observations and a handful of base64 pixel buffers — so the
    /// JSON decode can happen off the main actor, where `call` cannot put it.
    /// Nil folds together the frame being gone and the runtime never having
    /// installed, exactly as `value` does for its callers.
    func rawReply(
        _ method: PageProtocol.Method,
        _ params: [String: Any] = [:],
        in frame: WKFrameInfo? = nil
    ) async -> String? {
        precondition(
            method.world == world,
            "\(method.rawValue) belongs to the \(method.world.rawValue) world, not \(world.rawValue)"
        )
        guard let webView else { return nil }
        let reply = try? await webView.callAsyncJavaScript(
            Self.dispatchSource,
            arguments: [
                "handle": PageRuntime.handle,
                "method": method.rawValue,
                "params": params,
            ],
            in: frame,
            contentWorld: world.contentWorld
        )
        return reply as? String
    }

    /// Runs a method whose answer is only whether it worked.
    ///
    /// Failures are logged rather than thrown: these are all fire-and-forget
    /// side effects — pause the video, drop the selection — and there is no
    /// caller in a position to do anything about one.
    func send(
        _ method: PageProtocol.Method,
        _ params: [String: Any] = [:],
        in frame: WKFrameInfo? = nil
    ) {
        Task { @MainActor in
            do {
                try await call(method, params, as: PageProtocol.Empty.self, in: frame)
            } catch PageProtocol.Failure.noValue, PageProtocol.Failure.unreachable {
                // Ordinary: nothing there to act on.
            } catch {
                pageAgentLog("\(method.rawValue) failed — \(error)")
            }
        }
    }

    /// Like `call`, but folds "nothing to report" back into `nil` for the call
    /// sites where absence is the expected answer most of the time — no video
    /// on the page, no colour painted yet.
    func value<Value: Decodable>(
        _ method: PageProtocol.Method,
        _ params: [String: Any] = [:],
        as type: Value.Type,
        in frame: WKFrameInfo? = nil
    ) async -> Value? {
        do {
            return try await call(method, params, as: type, in: frame)
        } catch PageProtocol.Failure.noValue, PageProtocol.Failure.unreachable {
            return nil
        } catch {
            pageAgentLog("\(method.rawValue) failed — \(error)")
            return nil
        }
    }

    // MARK: - Registration

    /// Claims this world's channel on the given controller.
    ///
    /// Removing first is not defensive tidying: a popup tab inherits WebKit's
    /// own configuration, whose controller may already carry the name, and
    /// adding a duplicate throws.
    func register(on controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: world.handlerName, contentWorld: world.contentWorld
        )
        controller.add(
            WeakScriptMessageProxy(target: self),
            contentWorld: world.contentWorld,
            name: world.handlerName
        )
    }

    func unregister(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: world.handlerName, contentWorld: world.contentWorld
        )
    }
}

// MARK: - Events from the page

extension PageAgent: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            // The agent posts a JSON string rather than an object, so one
            // decoder handles every event and no payload is picked apart with
            // a chain of `as?` casts.
            guard let json = message.body as? String else { return }
            let data = Data(json.utf8)
            guard let header = try? JSONDecoder().decode(
                PageProtocol.EventHeader.self, from: data
            ) else { return }
            onEvent?(header, data, message.frameInfo)
        }
    }
}

extension PageProtocol.World {
    /// `.defaultClient` is WebKit's per-client isolated world: the page keeps
    /// its own `window`, and nothing we define can collide with, or be reached
    /// by, the site's own scripts.
    @MainActor
    var contentWorld: WKContentWorld {
        switch self {
        case .isolated: return .defaultClient
        case .page: return .page
        }
    }
}

/// stderr, so it survives output redirection unbuffered. Gated on the dev
/// switch, like the rest of Surf's logging.
func pageAgentLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["SURF_URL"] != nil else { return }
    FileHandle.standardError.write(Data("agent: \(message)\n".utf8))
}
