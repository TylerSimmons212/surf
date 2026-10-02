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

/// The video viewer Safari opens from its address bar: the page's main video
/// filling the tab, the page dimmed away behind it, WebKit's own controls.
///
/// It lives in this file because it is the same kind of door — private
/// selectors on `WKWebView`, checked with `responds(to:)` before every use —
/// and the promise above is that every one of those lives in one place.
///
/// **Why it, rather than Surf's own stage.** Which video to show is the hard
/// part, and WebKit already answers it for its media controls with knowledge
/// a page script doesn't have: what is visible, what has audio, what the
/// person has interacted with. Measured on a page with a muted autoplay advert
/// and a playing feature, it opens on the feature; on a page whose only video
/// is the advert, it refuses outright. Surf's stage has to guess both.
///
/// **What it doesn't tell you.** `_canToggleInWindow` answered false on every
/// page tried, including ones where entering then worked — so entering is
/// attempted and then confirmed with `_isInWindowActive`, the same
/// ask-afterwards shape as Picture-in-Picture's read-back.
@MainActor
enum NativeVideoViewer {

    private static let enterSelector = NSSelectorFromString("_enterInWindow")
    private static let exitSelector = NSSelectorFromString("_exitInWindow")
    private static let activeSelector = NSSelectorFromString("_isInWindowActive")

    static var isAvailable: Bool {
        [enterSelector, exitSelector, activeSelector].allSatisfy {
            WKWebView.instancesRespond(to: $0)
        }
    }

    /// Opens the viewer and reports whether it took.
    ///
    /// Polled rather than read once: the request goes to the web process and
    /// the answer comes back on a later turn, so the property read straight
    /// after the call is still false.
    static func enter(on webView: WKWebView) async -> Bool {
        guard isAvailable else { return false }
        send(enterSelector, to: webView)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if isActive(on: webView) { return true }
        }
        return false
    }

    static func exit(on webView: WKWebView) {
        guard isAvailable, isActive(on: webView) else { return }
        send(exitSelector, to: webView)
    }

    static func isActive(on webView: WKWebView) -> Bool {
        guard webView.responds(to: activeSelector) else { return false }
        typealias GetBool = @convention(c) (AnyObject, Selector) -> ObjCBool
        let imp = webView.method(for: activeSelector)
        return unsafeBitCast(imp, to: GetBool.self)(webView, activeSelector).boolValue
    }

    private static func send(_ selector: Selector, to webView: WKWebView) {
        guard webView.responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(webView.method(for: selector), to: Call.self)(webView, selector)
    }
}
