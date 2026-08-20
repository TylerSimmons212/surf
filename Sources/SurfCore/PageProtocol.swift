import Foundation

/// The contract between Surf and the agent it installs in every page.
///
/// Before this existed, each feature negotiated with the page on its own
/// terms: its own script string, its own handler name, its own hand-rolled
/// `as? String` decode of whatever came back. Three features meant three
/// dialects and three ways to be silently wrong.
///
/// So there is one wire format, and it lives here rather than beside the
/// WebKit code — a message shape is a data structure, and keeping it in
/// `SurfCore` is what lets its decoding be tested without a web view.
public enum PageProtocol {

    /// Every method the page agent answers to.
    ///
    /// An enum rather than bare strings on both sides: a method that exists in
    /// Swift and not in JavaScript is then a compile-time list to check
    /// against, not a `nil` at runtime six months later.
    public enum Method: String, CaseIterable, Sendable {
        // Isolated world — the theme's own, where nothing the site runs can
        // see or collide with us.
        case themeCollect = "theme.collect"
        case themeApply = "theme.apply"
        case themeRevert = "theme.revert"
        case themeDismissPreflight = "theme.dismissPreflight"
        case pageTopColor = "page.topColor"
        case pageFavicons = "page.favicons"
        // The focus domain observes the document and never needs the site's
        // globals, so it lives with the theme in the isolated world. The two
        // extract methods are registered lazily — see `FocusBridge` — but
        // answer through the same agent once they are.
        case focusSignals = "focus.signals"
        case focusExtract = "focus.extract"
        case focusReveal = "focus.reveal"

        // Page world — where the site's own `navigator` and media elements
        // are. An isolated world has its own `navigator`, with nothing in it.
        case mediaToggle = "media.toggle"
        case mediaSeek = "media.seek"
        case mediaSkip = "media.skip"
        case mediaFrame = "media.frame"
        case mediaLockScroll = "media.lockScroll"
        case mediaUnlockScroll = "media.unlockScroll"
        case mediaStage = "media.stage"
        case mediaUnstage = "media.unstage"
        case findCount = "find.count"
        case findClearSelection = "find.clearSelection"

        /// Which world the method has to run in. Getting this wrong is the
        /// failure that looks like the page simply not answering, so it is
        /// stated once here rather than remembered at each call site.
        public var world: World {
            switch self {
            case .themeCollect, .themeApply, .themeRevert,
                 .themeDismissPreflight, .pageTopColor, .pageFavicons,
                 .focusSignals, .focusExtract, .focusReveal:
                return .isolated
            case .mediaToggle, .mediaSeek, .mediaSkip, .mediaFrame,
                 .mediaLockScroll, .mediaUnlockScroll,
                 .mediaStage, .mediaUnstage,
                 .findCount, .findClearSelection:
                return .page
            }
        }
    }

    /// The two content worlds Surf installs an agent into.
    public enum World: String, CaseIterable, Sendable {
        case isolated
        case page

        /// Handler names are scoped per world, but giving them the same name
        /// in both would make a mis-registration invisible. These differ so a
        /// message arriving in the wrong world is a name that doesn't exist.
        public var handlerName: String {
            switch self {
            case .isolated: return "surfAgentIsolated"
            case .page: return "surfAgentPage"
            }
        }
    }

    /// What a dispatched method sends back.
    ///
    /// A failure is carried rather than thrown away. The old call sites were
    /// all `try?`, which turned a broken script and a page that legitimately
    /// had nothing to say into the same silence — and the first of those is a
    /// bug you want to see in the log.
    public struct Response<Value: Decodable>: Decodable {
        public var ok: Bool
        public var value: Value?
        public var error: String?
    }

    /// A method that answers with nothing but success.
    public struct Empty: Decodable, Equatable {
        public init() {}
        public init(from decoder: any Decoder) throws {}
    }

    /// Read first, to route a message before committing to a payload type.
    public struct EventHeader: Decodable, Equatable {
        public var domain: String
        public var event: String
    }

    /// Read second, once the header says what the payload will be.
    public struct Event<Payload: Decodable>: Decodable {
        public var domain: String
        public var event: String
        public var payload: Payload
    }

    /// Something the page said that Surf cannot act on.
    public enum Failure: Error, Equatable {
        /// The agent ran the method and it reported a failure of its own.
        case page(method: String, message: String)
        /// The reply didn't match the shape the method promised.
        case malformed(method: String)
        /// The method ran, but the page had no answer to give — a video that
        /// isn't there, a colour nothing has painted. Ordinary, not an error
        /// worth logging.
        case noValue(method: String)
        /// There was nothing to run the method against: the frame has
        /// navigated or been torn out, or the document never installed a
        /// runtime — an error page, a PDF view, a load that raced injection.
        ///
        /// Distinct from `noValue` because the two call for opposite
        /// responses. A frame that has gone should stop being addressed; a
        /// method that answered with nothing should be asked again next time.
        case unreachable(method: String)
    }

    /// Decodes one reply, turning both kinds of failure into the same thrown
    /// error so a call site can handle them in one place.
    public static func decode<Value: Decodable>(
        _ json: String,
        as _: Value.Type,
        method: String
    ) throws -> Value {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response<Value>.self, from: data)
        else { throw Failure.malformed(method: method) }

        guard response.ok else {
            throw Failure.page(method: method, message: response.error ?? "unknown")
        }
        guard let value = response.value else {
            throw Failure.noValue(method: method)
        }
        return value
    }
}
