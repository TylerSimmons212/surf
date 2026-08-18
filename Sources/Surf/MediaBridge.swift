import Foundation
import SurfCore

/// What a tab is currently playing.
///
/// Decoded straight off the wire rather than picked out of a dictionary a
/// field at a time: a renamed key is then a decoding failure that says so,
/// instead of a silent fall back to `false` that shows an empty player.
struct MediaState: Equatable, Decodable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var hasVideo: Bool
    var duration: Double
    var currentTime: Double
    /// The resolved media URL, or empty if the element has no source yet.
    var sourceURL: String

    private enum CodingKeys: String, CodingKey {
        case isPlaying = "playing"
        case title, artist, hasVideo, duration, currentTime
        case sourceURL = "src"
    }

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

/// Where the playing video sits in the viewport, in CSS pixels (== points).
struct MediaFrame: Decodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The media domain of the page agent.
///
/// Registered in the PAGE world: `navigator.mediaSession.metadata` is set by
/// the site's own scripts, and an isolated world would have its own
/// `navigator` with nothing in it.
///
/// Listeners are registered on `document` in the capture phase, so they see
/// every media element including ones created later.
enum MediaBridge {

    static var domainScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent) { return; }

          function describe() {
            const el = agent.state.media;
            if (!el) {
              return { playing: false, title: '', artist: '', hasVideo: false,
                       duration: 0, currentTime: 0, src: '' };
            }
            const meta = navigator.mediaSession && navigator.mediaSession.metadata;
            return {
              playing: !el.paused && !el.ended,
              title: (meta && meta.title) || document.title || '',
              artist: (meta && meta.artist) || location.hostname,
              hasVideo: el.tagName === 'VIDEO' && el.videoWidth > 0,
              duration: isFinite(el.duration) ? el.duration : 0,
              currentTime: el.currentTime || 0,
              // `currentSrc` is the resolved source, including <source>
              // children. A blob: URL means Media Source Extensions — a
              // segmented stream with no single fetchable file behind it.
              src: el.currentSrc || el.src || ''
            };
          }

          const report = () => agent.emit('media', 'state', describe());

          function track(event) {
            const el = event.target;
            if (!(el instanceof HTMLMediaElement)) { return false; }
            // The most recently started element is the one the user means.
            agent.state.media = el;
            report();
            return true;
          }

          // Position updates for the scrubber. `timeupdate` fires ~4x a
          // second, which is far more traffic than a progress bar needs — so
          // it's a timer, but one that only exists while something is actually
          // playing.
          //
          // This script is injected into every frame of every tab, so an
          // unconditional interval meant every tab you had open owned a timer
          // per frame, waking its content process once a second to discover
          // there was nothing to report. The overwhelming majority of tabs
          // never play anything at all.
          let ticker = null;
          function startTicker() {
            if (ticker) { return; }
            ticker = setInterval(() => {
              const el = agent.state.media;
              if (el && !el.paused) { report(); } else { stopTicker(); }
            }, 1000);
          }
          function stopTicker() {
            if (ticker) { clearInterval(ticker); ticker = null; }
          }

          document.addEventListener('play', (e) => { if (track(e)) { startTicker(); } }, true);
          document.addEventListener('pause', (e) => {
            if (e.target === agent.state.media) { stopTicker(); report(); }
          }, true);
          document.addEventListener('ended', (e) => {
            if (e.target === agent.state.media) { stopTicker(); report(); }
          }, true);

          // A method that needs the element and hasn't got one has nothing to
          // report — which is not the same as having failed.
          const withElement = (fn) => (params) => {
            const el = agent.state.media;
            if (!el) { return null; }
            return fn(el, params);
          };

          agent.define('media.toggle', withElement((el) => {
            if (el.paused) { el.play(); } else { el.pause(); }
            return true;
          }));

          agent.define('media.seek', withElement((el, { time }) => {
            const limit = isFinite(el.duration) ? el.duration : time;
            el.currentTime = Math.max(0, Math.min(limit, time));
            return true;
          }));

          agent.define('media.skip', withElement((el, { delta }) => {
            const target = el.currentTime + delta;
            el.currentTime = isFinite(el.duration)
              ? Math.max(0, Math.min(el.duration, target))
              : Math.max(0, target);
            return true;
          }));

          // The entire site-specific surface of the lens approach: one
          // rectangle. No styling is injected into the player, so there is no
          // stacking-context or containing-block fight to lose.
          agent.define('media.frame', withElement((el) => {
            if (!el.isConnected) { return null; }
            const r = el.getBoundingClientRect();
            if (r.width < 10 || r.height < 10) { return null; }
            return { x: r.x, y: r.y, width: r.width, height: r.height };
          }));

          // Stops wheel events from scrolling the page under the lens, which
          // would slide the video out of the cropped region.
          agent.define('media.lockScroll', () => {
            if (!document.getElementById('__surf_lens')) {
              const s = document.createElement('style');
              s.id = '__surf_lens';
              // `pointer-events` is inherited, but sites set it explicitly on
              // their own overlays, so the universal selector and !important
              // are both doing work here. This is what actually keeps the
              // pointer off the page: covering a view with another one doesn't
              // stop it, because tracking areas fire on geometry and know
              // nothing about what's drawn on top.
              s.textContent = 'html, body { overflow: hidden !important; }' +
                'html, html * { pointer-events: none !important; }';
              document.documentElement.appendChild(s);
            }
            // Native controls don't auto-hide reliably when the pointer never
            // arrives, so switch them off outright. Custom players hide
            // themselves once the page stops seeing hover at all.
            const el = agent.state.media;
            if (el) {
              el.dataset.surfControls = el.controls ? '1' : '0';
              el.controls = false;
            }
            return true;
          });

          agent.define('media.unlockScroll', () => {
            document.getElementById('__surf_lens')?.remove();
            const el = agent.state.media;
            if (el && el.dataset.surfControls !== undefined) {
              el.controls = el.dataset.surfControls === '1';
              delete el.dataset.surfControls;
            }
            return true;
          });
        })();
        """
    }
}

/// The find domain — also the page world, because the selection it clears is
/// the document's own.
enum FindBridge {

    static var domainScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent) { return; }

          // `innerText` rather than the DOM: it already excludes hidden
          // elements and flattens across element boundaries, so a phrase split
          // by markup still counts once. WebKit's find API reports only
          // whether it landed on something, so the tally has to come from
          // somewhere.
          agent.define('find.count', ({ query }) => {
            const needle = (query || '').toLowerCase();
            if (!needle) { return 0; }
            const text = (document.body?.innerText ?? '').toLowerCase();
            let total = 0;
            let index = text.indexOf(needle);
            while (index !== -1) {
              total += 1;
              index = text.indexOf(needle, index + needle.length);
            }
            return total;
          });

          agent.define('find.clearSelection', () => {
            window.getSelection()?.removeAllRanges();
            return true;
          });
        })();
        """
    }
}
