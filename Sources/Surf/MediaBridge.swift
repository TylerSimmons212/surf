import Foundation
import SurfCore
import WebKit

/// One media element a page is holding, as the player presents it.
struct MediaState: Equatable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var hasVideo: Bool
    var duration: Double
    var currentTime: Double
    /// The resolved media URL, or empty if the element has no source yet.
    var sourceURL: String = ""

    /// Addresses this exact element inside its frame, so a command lands on the
    /// thing the player is showing rather than on whatever played most
    /// recently. Empty only for states built in tests.
    var elementID: String = ""

    /// The evidence used to decide whether this is the element worth showing.
    var signals = MediaSignals()

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

/// Everything one frame is playing, in one message.
///
/// A frame reports its whole set rather than just its newest element, because
/// choosing between them is a judgement (see `MediaRanking`) and judgements
/// belong in Swift where they can be tested. The frame's only job is to say
/// what's there.
struct MediaReport {
    var frameID: String
    var items: [MediaState]
}

enum MediaBridge {
    static let handlerName = "surfMedia"

    /// Injected in the PAGE world: `navigator.mediaSession.metadata` is set by
    /// the page's own scripts, and an isolated world would have its own
    /// `navigator` with nothing in it.
    ///
    /// Listeners are registered on `document` in the capture phase, so they see
    /// every media element including ones created later.
    static let script = """
    (function () {
      const send = (p) => window.webkit.messageHandlers.\(handlerName).postMessage(p);
      const frameId = 'f' + Math.random().toString(36).slice(2);
      const isTop = window === window.top;

      // Every element that has ever started in this frame, and a way to address
      // one from Swift. A page with adverts has several at once, and the player
      // needs to be able to command a specific one rather than "the last".
      const seen = new Set();
      const registry = new Map();
      let counter = 0;

      function idFor(el) {
        if (!el.__surfId) {
          el.__surfId = frameId + ':' + (++counter);
          registry.set(el.__surfId, el);
        }
        return el.__surfId;
      }

      window.__surfMediaById = function (id) {
        const el = registry.get(id);
        return el && el.isConnected ? el : null;
      };

      function describe(el) {
        const meta = navigator.mediaSession && navigator.mediaSession.metadata;
        const r = el.getBoundingClientRect();
        // A player in an iframe knows the embed's title and hostname, not the
        // page's — 'hgcloud.to' rather than the show you're watching. Better to
        // say nothing and let the tab's own title stand in.
        const named = !!meta || isTop;
        return {
          id: idFor(el),
          playing: !el.paused && !el.ended,
          title: (meta && meta.title) || (isTop ? document.title : '') || '',
          artist: (meta && meta.artist) || (isTop ? location.hostname : '') || '',
          hasVideo: el.tagName === 'VIDEO' && el.videoWidth > 0,
          duration: isFinite(el.duration) ? el.duration : 0,
          currentTime: el.currentTime || 0,
          // `currentSrc` is the resolved source, including <source> children.
          // A blob: URL means Media Source Extensions — a segmented stream with
          // no single fetchable file behind it.
          src: el.currentSrc || el.src || '',
          // Ranking evidence. Volume of zero counts as muted: it's the same
          // thing to a listener, and some ad tags use it instead.
          muted: !!el.muted || el.volume === 0,
          loop: !!el.loop,
          width: r.width,
          height: r.height,
          hasMetadata: named,
          startedAt: el.__surfStartedAt || 0
        };
      }

      function report() {
        const items = [];
        for (const el of Array.from(seen)) {
          // An advert whose iframe content was torn out shouldn't keep a seat.
          if (!el.isConnected) {
            seen.delete(el);
            registry.delete(el.__surfId);
            continue;
          }
          items.push(describe(el));
        }
        send({ frame: frameId, items: items });
      }

      function anyPlaying() {
        for (const el of seen) { if (el.isConnected && !el.paused && !el.ended) { return true; } }
        return false;
      }

      // Position updates for the scrubber. `timeupdate` fires ~4x a second,
      // which is far more traffic than a progress bar needs — so it's a timer,
      // but one that only exists while something is actually playing.
      //
      // This script is injected into every frame of every tab, so an
      // unconditional interval meant every tab you had open owned a timer per
      // frame, waking its content process once a second to discover there was
      // nothing to report. The overwhelming majority of tabs never play
      // anything at all.
      //
      // The beat doubles as a heartbeat: Swift drops a frame that claims to be
      // playing and then goes quiet, which is how an advert that was removed
      // mid-play stops holding the player for ever.
      let ticker = null;
      function startTicker() {
        if (ticker) { return; }
        ticker = setInterval(() => {
          if (anyPlaying()) { report(); } else { stopTicker(); }
        }, 1000);
      }
      function stopTicker() {
        if (ticker) { clearInterval(ticker); ticker = null; }
      }

      document.addEventListener('play', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLMediaElement)) { return; }
        el.__surfStartedAt = performance.now();
        seen.add(el);
        idFor(el);
        report();
        startTicker();
      }, true);

      document.addEventListener('pause', (e) => {
        if (seen.has(e.target)) { report(); }
      }, true);

      document.addEventListener('ended', (e) => {
        if (seen.has(e.target)) { report(); }
      }, true);

      // `videoWidth` is still 0 until metadata arrives, so a video that starts
      // playing before it has loaded reports `hasVideo: false` — which hides
      // the Pop Out button on exactly the videos that are slowest to start.
      // The same is true of its size, which the ranking leans on heavily.
      document.addEventListener('loadedmetadata', (e) => {
        if (seen.has(e.target)) { report(); }
      }, true);

      // Where this frame's viewport sits inside the top document.
      //
      // The pop-out lens crops the tab's web view, so it works in top-document
      // coordinates — but an embedded player measures itself against its own
      // iframe, and those two agree only when there is no iframe. Everything
      // below exists to turn the second into the first.
      //
      // The trick is that `frame.contentWindow === event.source` is a legal
      // comparison across origins even though almost nothing else is: a parent
      // can't read into a cross-origin child, but it can recognise it. So the
      // child asks upward and the parent, which *can* measure the iframe
      // element, answers — recursing until it reaches a frame that knows it is
      // the top and can answer 0,0 outright.
      window.__surfFrameOffset = function () {
        if (isTop) { return Promise.resolve({ x: 0, y: 0 }); }
        return new Promise((resolve) => {
          const token = 's' + Math.random().toString(36).slice(2);
          let settled = false;
          const finish = (value) => {
            if (settled) { return; }
            settled = true;
            window.removeEventListener('message', onReply);
            resolve(value);
          };
          const onReply = (e) => {
            const d = e.data;
            if (!d || d.__surf !== 'frameAt' || d.token !== token) { return; }
            finish(d.offset || null);
          };
          window.addEventListener('message', onReply);
          try { parent.postMessage({ __surf: 'whereAmI', token: token }, '*'); }
          catch (err) { finish(null); }
          // A parent that isn't running this script never answers. Give up
          // rather than leaving Pop Out spinning on a promise that can't settle.
          setTimeout(() => finish(null), 250);
        });
      };

      window.addEventListener('message', (e) => {
        const d = e.data;
        if (!d || d.__surf !== 'whereAmI' || !e.source) { return; }
        let rect = null;
        for (const f of document.querySelectorAll('iframe, frame')) {
          if (f.contentWindow === e.source) { rect = f.getBoundingClientRect(); break; }
        }
        // Not ours to answer — some other frame's child. Staying quiet is
        // correct: its own parent will reply.
        if (!rect) { return; }
        window.__surfFrameOffset().then((base) => {
          const offset = base ? { x: base.x + rect.x, y: base.y + rect.y } : null;
          try { e.source.postMessage({ __surf: 'frameAt', token: d.token, offset: offset }, '*'); }
          catch (err) { /* the child went away mid-question */ }
        });
      });
    })();
    """

    /// Every command below addresses one element by id rather than reaching for
    /// a "current" global. The player's choice and the command's target are
    /// then the same thing by construction, which is what stops a command
    /// landing on an advert that started since the row was drawn.
    static let toggleScript = """
    const el = window.__surfMediaById(id);
    if (!el) { return false; }
    if (el.paused) { el.play(); } else { el.pause(); }
    return true;
    """

    /// Seeks to an absolute position. `time` arrives as a call argument rather
    /// than interpolated into the source, so page content can never become script.
    static let seekScript = """
    const el = window.__surfMediaById(id);
    if (!el) { return false; }
    const limit = isFinite(el.duration) ? el.duration : time;
    el.currentTime = Math.max(0, Math.min(limit, time));
    return true;
    """

    /// Jumps relative to the current position, clamped to the media's bounds.
    static let skipScript = """
    const el = window.__surfMediaById(id);
    if (!el) { return false; }
    const target = el.currentTime + delta;
    el.currentTime = isFinite(el.duration)
      ? Math.max(0, Math.min(el.duration, target))
      : Math.max(0, target);
    return true;
    """

    /// Where the playing video sits, in the *top* document's viewport and in
    /// CSS pixels (== points) — which is the coordinate space the lens crops in.
    ///
    /// This is the entire site-specific surface of the lens approach: one
    /// rectangle. No styling is injected into the player, so there is no
    /// stacking-context or containing-block fight to lose.
    ///
    /// A frame that can't establish where it sits returns null rather than its
    /// own local rectangle — cropping the wrong part of the page looks like a
    /// bug in the video, not in the measurement.
    static let measureScript = """
    const el = window.__surfMediaById(id);
    if (!el) { return null; }
    const r = el.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) { return null; }
    const offset = await window.__surfFrameOffset();
    if (!offset) { return null; }
    return JSON.stringify([r.x + offset.x, r.y + offset.y, r.width, r.height]);
    """

    /// Stops wheel events from scrolling the page under the lens, which would
    /// slide the video out of the cropped region.
    static let lockScrollScript = """
    if (!document.getElementById('__surf_lens')) {
      const s = document.createElement('style');
      s.id = '__surf_lens';
      // `pointer-events` is inherited, but sites set it explicitly on their
      // own overlays, so the universal selector and !important are both doing
      // work here. This is what actually keeps the pointer off the page:
      // covering a view with another one doesn't stop it, because tracking
      // areas fire on geometry and know nothing about what's drawn on top.
      s.textContent = 'html, body { overflow: hidden !important; }' +
        'html, html * { pointer-events: none !important; }';
      document.documentElement.appendChild(s);
    }
    // Native controls don't auto-hide reliably when the pointer never arrives,
    // so switch them off outright. Custom players hide themselves once the
    // page stops seeing hover at all.
    const el = window.__surfMediaById(id);
    if (el) {
      el.dataset.surfControls = el.controls ? '1' : '0';
      el.controls = false;
    }
    return true;
    """

    static let unlockScrollScript = """
    document.getElementById('__surf_lens')?.remove();
    const el = window.__surfMediaById(id);
    if (el && el.dataset.surfControls !== undefined) {
      el.controls = el.dataset.surfControls === '1';
      delete el.dataset.surfControls;
    }
    return true;
    """

    static func decode(_ body: Any) -> MediaReport? {
        guard let dict = body as? [String: Any],
            let frameID = dict["frame"] as? String
        else { return nil }
        let raw = dict["items"] as? [[String: Any]] ?? []
        return MediaReport(frameID: frameID, items: raw.compactMap(decodeItem))
    }

    private static func decodeItem(_ dict: [String: Any]) -> MediaState? {
        guard let id = dict["id"] as? String else { return nil }
        let isPlaying = dict["playing"] as? Bool ?? false
        return MediaState(
            isPlaying: isPlaying,
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            hasVideo: dict["hasVideo"] as? Bool ?? false,
            duration: dict["duration"] as? Double ?? 0,
            currentTime: dict["currentTime"] as? Double ?? 0,
            sourceURL: dict["src"] as? String ?? "",
            elementID: id,
            signals: MediaSignals(
                isPlaying: isPlaying,
                isMuted: dict["muted"] as? Bool ?? false,
                loops: dict["loop"] as? Bool ?? false,
                width: dict["width"] as? Double ?? 0,
                height: dict["height"] as? Double ?? 0,
                duration: dict["duration"] as? Double ?? 0,
                hasMetadata: dict["hasMetadata"] as? Bool ?? false,
                startedAt: dict["startedAt"] as? Double ?? 0
            )
        )
    }
}
