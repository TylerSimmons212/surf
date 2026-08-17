import Foundation
import GlassCore
import WebKit

/// What a tab is currently playing.
struct MediaState: Equatable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var hasVideo: Bool
    var duration: Double
    var currentTime: Double
    /// The resolved media URL, or empty if the element has no source yet.
    var sourceURL: String = ""

    /// What the source actually is, which decides how it gets downloaded.
    var kind: MediaSourceKind { MediaSource.kind(of: sourceURL) }

    /// A plain media file we can fetch, the same as "Download Video" in any
    /// browser's context menu.
    var isDownloadable: Bool { kind == .file }

    /// Segmented: either a `blob:` handle into the page's own buffer, or an
    /// HLS/DASH index whose URL points at a playlist rather than the video.
    /// Neither can be fetched — both need yt-dlp, which starts from the page.
    var needsExtraction: Bool { kind == .streamed || kind == .manifest }

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
          currentTime: current.currentTime || 0,
          // `currentSrc` is the resolved source, including <source> children.
          // A blob: URL means Media Source Extensions — a segmented stream with
          // no single fetchable file behind it.
          src: current.currentSrc || current.src || ''
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

    /// Where the playing video sits in the viewport, in CSS pixels.
    ///
    /// This is the entire site-specific surface of the lens approach: one
    /// rectangle. No styling is injected into the player, so there is no
    /// stacking-context or containing-block fight to lose.
    static let measureScript = """
    const el = window.__glassMedia;
    if (!el || !el.isConnected) { return null; }
    const r = el.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) { return null; }
    return JSON.stringify([r.x, r.y, r.width, r.height]);
    """

    /// Stops wheel events from scrolling the page under the lens, which would
    /// slide the video out of the cropped region.
    static let lockScrollScript = """
    if (!document.getElementById('__glass_lens')) {
      const s = document.createElement('style');
      s.id = '__glass_lens';
      s.textContent = 'html, body { overflow: hidden !important; }';
      document.documentElement.appendChild(s);
    }
    // Native controls don't auto-hide reliably when the pointer never arrives,
    // so switch them off outright. Custom players are handled by the panel
    // swallowing mouse events, which lets their own idle timer hide them.
    const el = window.__glassMedia;
    if (el) {
      el.dataset.glassControls = el.controls ? '1' : '0';
      el.controls = false;
    }
    return true;
    """

    static let unlockScrollScript = """
    document.getElementById('__glass_lens')?.remove();
    const el = window.__glassMedia;
    if (el && el.dataset.glassControls !== undefined) {
      el.controls = el.dataset.glassControls === '1';
      delete el.dataset.glassControls;
    }
    return true;
    """

    static func decode(_ body: Any) -> MediaState? {
        guard let dict = body as? [String: Any] else { return nil }
        return MediaState(
            isPlaying: dict["playing"] as? Bool ?? false,
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            hasVideo: dict["hasVideo"] as? Bool ?? false,
            duration: dict["duration"] as? Double ?? 0,
            currentTime: dict["currentTime"] as? Double ?? 0,
            sourceURL: dict["src"] as? String ?? ""
        )
    }
}
