import AppKit
import ObjectiveC
import WebKit

/// macOS's own Picture-in-Picture, through the two doors WebKit leaves unmarked.
///
/// Every private selector Surf uses for this lives here, so the blast radius of
/// Apple closing one is a single file with one honest answer in it.
///
/// **Why it needs private API at all.** On iOS the switch is public —
/// `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback`. On macOS that
/// property is declared `API_AVAILABLE(ios(9.0))` and does not exist at
/// runtime; checked, not assumed. Safari has Picture-in-Picture because Safari
/// is not a `WKWebView` embedder. Everyone else gets `_setAllows…` or nothing.
///
/// **What it fixes, beyond a feature.** Without the preference,
/// `document.pictureInPictureEnabled` reports `true` while
/// `video.requestPictureInPicture()` throws `NotSupportedError`. Surf tells
/// every page it can do this and then refuses — so every site's own
/// Picture-in-Picture button is dead, and no page can feature-detect its way
/// out because the detection property lies. Turning the preference on repairs
/// a standard web API rather than adding a proprietary one.
///
/// **Why a granted gesture rather than a faked click.** Picture-in-Picture
/// requires user activation, and a tab switch has none. A synthesised
/// `NSEvent` would satisfy it, and would also be a real click landing at real
/// coordinates: toggling playback, following whatever is underneath, firing
/// the page's own handlers. `_evaluateJavaScript:…withUserGesture:` lies only
/// to the activation check. Nothing reaches the page.
///
/// **How it fails.** Both doors are checked with `responds(to:)` before use. If
/// a macOS release takes one away, `isAvailable` goes false, the caller falls
/// back to Surf's own pop-out panel, and nothing crashes — the feature gets
/// quieter, not broken. That is the whole reason the panel stays.
@MainActor
enum NativePictureInPicture {

    private static let enableSelector =
        NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")

    /// The *async* variant, deliberately. The page agent's `dispatch` is an
    /// async function returning a JSON envelope, so the plain evaluate hands
    /// back an unawaited Promise — which read as "the player refused" and
    /// opened Surf's panel on top of a Picture-in-Picture window that had
    /// started perfectly well. This one awaits.
    private static let evaluateSelector = NSSelectorFromString(
        "_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:"
    )

    /// Whether WebKit still has the door open.
    static var isAvailable: Bool {
        WKPreferences.instancesRespond(to: enableSelector)
            && WKWebView.instancesRespond(to: evaluateSelector)
    }

    /// Turns Picture-in-Picture on for every page in this configuration.
    ///
    /// Must be set before the web view is built: the configuration is copied at
    /// construction, so assigning afterwards has no effect and says nothing.
    static func enable(on preferences: WKPreferences) {
        guard preferences.responds(to: enableSelector) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let imp = preferences.method(for: enableSelector)
        unsafeBitCast(imp, to: SetBool.self)(preferences, enableSelector, true)
    }

    /// Runs `body` as though a person had just clicked, and reads one string
    /// out of the page agent's reply.
    ///
    /// Reading happens inside the completion rather than after it. The result
    /// is an untyped `Any?`, which is not `Sendable`, and carrying one across
    /// the continuation is a data race the compiler is right to refuse — so
    /// only the string crosses.
    static func runAsUser(
        _ body: String, in frame: WKFrameInfo?, on webView: WKWebView,
        reading key: String
    ) async -> String? {
        guard webView.responds(to: evaluateSelector) else { return nil }

        typealias CallAsync = @convention(c) (
            AnyObject, Selector, NSString, NSDictionary?, AnyObject?, WKContentWorld, ObjCBool,
            @convention(block) (Any?, (any Error)?) -> Void
        ) -> Void
        let fn = unsafeBitCast(webView.method(for: evaluateSelector), to: CallAsync.self)

        return await withCheckedContinuation { continuation in
            // A real block, bound to a variable. Passed as a trailing closure
            // it is a literal, which Swift treats as non-escaping — and WebKit
            // holds onto this one past the call, which traps at runtime with
            // "closure argument passed as @noescape to Objective-C has
            // escaped". Found the hard way.
            let handler: @convention(block) (Any?, (any Error)?) -> Void = { value, _ in
                continuation.resume(returning: reply(value, reading: key))
            }
            fn(webView, evaluateSelector, body as NSString, nil, frame, .page, true, handler)
        }
    }

    /// The page agent answers with `{ ok, value }` as a JSON string, so one
    /// decoder serves every call rather than a cast per field.
    private static func reply(_ value: Any?, reading key: String) -> String? {
        guard let text = value as? String,
              let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = envelope["value"] as? [String: Any]
        else { return nil }
        return payload[key] as? String
    }
}
