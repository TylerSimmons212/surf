import WebKit

/// Breaks the retain cycle that `add(_:name:)` would otherwise create.
///
/// The user content controller retains its handler strongly, and the tab owns
/// the web view which owns the controller — so handing it the tab directly
/// would keep every tab alive forever.
///
/// Lives here rather than beside the media bridge because it isn't a media
/// concern: every bridge a tab installs routes through one of these.
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(controller, didReceive: message)
    }
}
