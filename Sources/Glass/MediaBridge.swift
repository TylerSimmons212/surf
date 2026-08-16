import Foundation
import WebKit

/// What a tab is currently playing.
struct MediaState: Equatable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var hasVideo: Bool
    var duration: Double
    var currentTime: Double

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}

/// Breaks the retain cycle that `add(_:name:)` would otherwise create.
///
/// The user content controller retains its handler strongly, and the tab owns
/// the web view which owns the controller — so handing it the tab directly
/// would keep every tab alive forever.
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

enum MediaBridge {
    static let handlerName = "glassMedia"

    /// Injected in the PAGE world: `navigator.mediaSession.metadata` is set by
    /// the page's own scripts, and an isolated world would have its own
    /// `navigator` with nothing in it.
    ///
    /// Listeners are registered on `document` in the capture phase, so they see
    /// every media element including ones created later.
    static let script = """
    (function () {
      const send = (p) => window.webkit.messageHandlers.\(handlerName).postMessage(p);
      let current = null;

      function describe() {
        if (!current) return { playing: false, title: '', artist: '', hasVideo: false,
                               duration: 0, currentTime: 0 };
        const meta = navigator.mediaSession && navigator.mediaSession.metadata;
        return {
          playing: !current.paused && !current.ended,
          title: (meta && meta.title) || document.title || '',
          artist: (meta && meta.artist) || location.hostname,
          hasVideo: current.tagName === 'VIDEO' && current.videoWidth > 0,
          duration: isFinite(current.duration) ? current.duration : 0,
          currentTime: current.currentTime || 0
        };
      }

      function track(event) {
        const el = event.target;
        if (!(el instanceof HTMLMediaElement)) return;
        // The most recently started element is the one the user means.
        current = el;
        window.__glassMedia = el;
        send(describe());
      }

      document.addEventListener('play', track, true);
      document.addEventListener('pause', (e) => { if (e.target === current) send(describe()); }, true);
      document.addEventListener('ended', (e) => { if (e.target === current) send(describe()); }, true);

      // Position updates for the scrubber. `timeupdate` fires ~4x a second,
      // which is far more traffic than a progress bar needs.
      setInterval(() => { if (current && !current.paused) send(describe()); }, 1000);
    })();
    """

    /// Toggling has to run in the page world, where `__glassMedia` lives.
    static let toggleScript = """
    const el = window.__glassMedia;
    if (!el) { return false; }
    if (el.paused) { el.play(); } else { el.pause(); }
    return true;
    """

    /// Promotes the playing element to fill the viewport.
    ///
    /// Nothing is hidden — the video is pinned over everything at max z-index
    /// instead. Hiding a site's chrome tends to break players that measure
    /// their own layout; covering it doesn't.
    static let focusScript = """
    const el = window.__glassMedia;
    if (!el) { return false; }
    el.setAttribute('data-glass-popout', '1');
    let style = document.getElementById('__glass_popout');
    if (!style) {
      style = document.createElement('style');
      style.id = '__glass_popout';
      style.textContent = `
        html, body { overflow: hidden !important; background: #000 !important; }
        [data-glass-popout] {
          position: fixed !important; inset: 0 !important;
          width: 100vw !important; height: 100vh !important;
          max-width: none !important; max-height: none !important;
          object-fit: contain !important; background: #000 !important;
          z-index: 2147483647 !important;
        }`;
      document.documentElement.appendChild(style);
    }
    return true;
    """

    static let unfocusScript = """
    document.getElementById('__glass_popout')?.remove();
    document.querySelectorAll('[data-glass-popout]')
      .forEach((el) => el.removeAttribute('data-glass-popout'));
    return true;
    """

    /// Natural size of the playing video, for sizing the panel.
    static let dimensionsScript = """
    const el = window.__glassMedia;
    if (!el || !el.videoWidth) { return null; }
    return JSON.stringify([el.videoWidth, el.videoHeight]);
    """

    static func decode(_ body: Any) -> MediaState? {
        guard let dict = body as? [String: Any] else { return nil }
        return MediaState(
            isPlaying: dict["playing"] as? Bool ?? false,
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            hasVideo: dict["hasVideo"] as? Bool ?? false,
            duration: dict["duration"] as? Double ?? 0,
            currentTime: dict["currentTime"] as? Double ?? 0
        )
    }
}
