import Foundation
import SurfCore
import WebKit

/// One media element a page is holding, as the player presents it.
struct MediaState: Equatable, Decodable {
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

    private enum CodingKeys: String, CodingKey {
        case isPlaying = "playing"
        case title, artist, hasVideo, duration, currentTime
        case sourceURL = "src"
        case elementID = "id"
        case muted, loop, width, height, hasMetadata, startedAt, audioBytes
    }

    /// The page reports ranking evidence flat, alongside the display fields.
    /// Assembling `MediaSignals` here keeps it a plain value with no wire
    /// format of its own — it is evidence, and evidence shouldn't know how it
    /// travelled.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        currentTime = try c.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        // The one field with no sensible default: a report we can't address an
        // element from is not a report we can act on.
        elementID = try c.decode(String.self, forKey: .elementID)
        signals = MediaSignals(
            isPlaying: isPlaying,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
            loops: try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 0,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 0,
            duration: duration,
            hasMetadata: try c.decodeIfPresent(Bool.self, forKey: .hasMetadata) ?? false,
            startedAt: try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0,
            audioBytes: try c.decodeIfPresent(Double.self, forKey: .audioBytes)
        )
    }

    /// Memberwise, for tests and for the states Swift builds itself.
    init(
        isPlaying: Bool = false, title: String = "", artist: String = "",
        hasVideo: Bool = false, duration: Double = 0, currentTime: Double = 0,
        sourceURL: String = "", elementID: String = "",
        signals: MediaSignals = MediaSignals()
    ) {
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.hasVideo = hasVideo
        self.duration = duration
        self.currentTime = currentTime
        self.sourceURL = sourceURL
        self.elementID = elementID
        self.signals = signals
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

/// Everything one frame is playing, in one message.
///
/// A frame reports its whole set rather than just its newest element, because
/// choosing between them is a judgement (see `MediaRanking`) and judgements
/// belong in Swift where they can be tested. The frame's only job is to say
/// what's there.
struct MediaReport: Decodable {
    var frameID: String
    var items: [MediaState]

    private enum CodingKeys: String, CodingKey {
        case frameID = "frame"
        case items
    }
}

/// Where the playing video sits in the *top* document's viewport, in CSS
/// pixels (== points) — the coordinate space the pop-out lens crops in.
struct MediaFrame: Decodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum MediaBridge {

    /// The media domain, in the PAGE world: `navigator.mediaSession.metadata`
    /// is set by the site's own scripts, and an isolated world would have its
    /// own `navigator` with nothing in it.
    ///
    /// Every command addresses one element by id rather than reaching for a
    /// "current" global. The player's choice and the command's target are then
    /// the same thing by construction, which is what stops a command landing
    /// on an advert that started since the row was drawn.
    static var domainScript: String {
        """
          (function () {
            const runtime = globalThis['\(PageRuntime.handle)'];
            // Guarded on the domain: the runtime is shared, and re-entering here
            // would register a second set of listeners on the same document.
            if (!runtime || runtime.state.mediaInstalled) { return; }
            runtime.state.mediaInstalled = true;

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

        function mediaById(id) {
          const el = registry.get(id);
          return el && el.isConnected ? el : null;
        }

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
            hasMetadata: !!meta,  // not `named`: see MediaSignals
            startedAt: el.__surfStartedAt || 0,
            // Audio actually decoded so far. Copied raw, and null when the
            // engine doesn't report it, because "no sound" and "didn't say"
            // are different answers and only Swift should decide what each is
            // worth. It is what separates an unmuted video with no audio track
            // from one that is genuinely making a noise.
            audioBytes: typeof el.webkitAudioDecodedByteCount === 'number'
              ? el.webkitAudioDecodedByteCount
              : null
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
          runtime.emit('media', 'report', { frame: frameId, items: items });
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
        function frameOffset() {
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
        }

        // Theater mode's cross-frame half. A video inside an iframe can pin
        // itself fullscreen only within that iframe; the iframe element
        // lives in the parent, so the child asks upward and each parent
        // pins its own child frame — the same recognise-by-contentWindow
        // trick the frame-offset protocol above stands on. The chain
        // recurses naturally: a parent that isn't the top asks *its* parent.
        function stageFrameOf(source, wanted) {
          for (const f of document.querySelectorAll('iframe, frame')) {
            if (f.contentWindow !== source) { continue; }
            if (wanted) {
              stageElement(f);
              if (window !== window.top) {
                try { parent.postMessage({ __surf: 'stageMe' }, '*'); } catch (err) {}
              }
            } else {
              unstageAll();
              if (window !== window.top) {
                try { parent.postMessage({ __surf: 'unstageMe' }, '*'); } catch (err) {}
              }
            }
            return;
          }
        }

        window.addEventListener('message', (e) => {
          const d = e.data;
          if (d && (d.__surf === 'stageMe' || d.__surf === 'unstageMe') && e.source) {
            stageFrameOf(e.source, d.__surf === 'stageMe');
            return;
          }
          if (!d || d.__surf !== 'whereAmI' || !e.source) { return; }
          let rect = null;
          for (const f of document.querySelectorAll('iframe, frame')) {
            if (f.contentWindow === e.source) { rect = f.getBoundingClientRect(); break; }
          }
          // Not ours to answer — some other frame's child. Staying quiet is
          // correct: its own parent will reply.
          if (!rect) { return; }
          frameOffset().then((base) => {
            const offset = base ? { x: base.x + rect.x, y: base.y + rect.y } : null;
            try { e.source.postMessage({ __surf: 'frameAt', token: d.token, offset: offset }, '*'); }
            catch (err) { /* the child went away mid-question */ }
          });
        });

        // Theater mode: the page's own element becomes the stage — most
        // video is a blob: URL that exists only in this document, so there
        // is nothing to rehost. Promoted by attribute + stylesheet, not
        // inline style: YouTube rewrites the element's inline style every
        // resize tick, and inline stage styles held for exactly one frame.
        // The ancestor rule is the other half — a transform, filter, or
        // contain on any ancestor makes it the containing block and caps
        // z-index under the site's chrome, so every ancestor is neutralised;
        // the wreckage is invisible behind the stage and untagged on exit.
        // Three rules: pin the video; dissolve every ancestor's containing
        // block and stacking context (transform, contain, isolation and kin
        // — any of them re-anchors "fixed" to a div and caps z-index under
        // the site's chrome); and lights-out — everything off the path to
        // the video goes visibility:hidden, so there is no z-order war with
        // mastheads to win and no suggestion tile left to autoplay a
        // preview over the show. visibility, not display: layout holds, and
        // players keep measuring the world they expect.
        function ensureStageSheet() {
          if (document.getElementById('__surf_stage')) { return; }
          const s = document.createElement('style');
          s.id = '__surf_stage';
          s.textContent =
            // visibility:visible is load-bearing: players (YouTube) re-parent
            // their video between containers, and until the next re-tag its
            // new branch is one lights-out would hide — hiding inherits, and
            // this is the override that keeps the show on through the move.
            '[data-surf-stage]{visibility:visible!important;' +
            'position:fixed!important;inset:0!important;' +
            'width:100vw!important;height:100vh!important;' +
            'max-width:none!important;max-height:none!important;' +
            'min-width:0!important;min-height:0!important;' +
            'margin:0!important;padding:0!important;border:0!important;' +
            'transform:none!important;z-index:2147483646!important;' +
            'background:#000!important;object-fit:contain!important}' +
            '[data-surf-stage-ancestor]{transform:none!important;' +
            'translate:none!important;rotate:none!important;' +
            'scale:none!important;filter:none!important;' +
            'backdrop-filter:none!important;perspective:none!important;' +
            'clip-path:none!important;mask:none!important;' +
            'isolation:auto!important;mix-blend-mode:normal!important;' +
            'opacity:1!important;contain:none!important;' +
            'content-visibility:visible!important;' +
            'will-change:auto!important;z-index:auto!important}' +
            '[data-surf-stage-ancestor]>' +
            ':not([data-surf-stage-ancestor]):not([data-surf-stage])' +
            '{visibility:hidden!important}';
          document.documentElement.appendChild(s);
        }

        function stageElement(el) {
          ensureStageSheet();
          el.setAttribute('data-surf-stage', '');
          let a = el.parentElement;
          while (a && a !== document.documentElement) {
            a.setAttribute('data-surf-stage-ancestor', '');
            a = a.parentElement;
          }
        }

        function unstageAll() {
          for (const marked of document.querySelectorAll(
            '[data-surf-stage], [data-surf-stage-ancestor]'
          )) {
            marked.removeAttribute('data-surf-stage');
            marked.removeAttribute('data-surf-stage-ancestor');
          }
          document.getElementById('__surf_stage')?.remove();
        }

        // Picture-in-Picture. Omitting `on` reports the mode without setting it;
        // the reasoning for both halves is on the Swift side.
        runtime.define('media.pictureInPicture', ({ id, on }) => {
          const el = mediaById(id);
          if (!el || typeof el.webkitSetPresentationMode !== 'function') { return null; }
          if (!el.webkitSupportsPresentationMode('picture-in-picture')) { return null; }
          if (on !== undefined && on !== null) {
            el.webkitSetPresentationMode(on ? 'picture-in-picture' : 'inline');
          }
          return { mode: el.webkitPresentationMode };
        });

        runtime.define('media.stage', ({ id }) => {
          const el = mediaById(id);
          if (!el) { return null; }
          // The transport is Surf's; two sets of controls fight.
          if (el.dataset.surfStageControls === undefined) {
            el.dataset.surfStageControls = el.controls ? '1' : '0';
          }
          el.controls = false;
          stageElement(el);
          if (!isTop) {
            try { parent.postMessage({ __surf: 'stageMe' }, '*'); } catch (err) {}
          }
          return true;
        });

        runtime.define('media.unstage', ({ id }) => {
          const el = mediaById(id);
          if (el && el.dataset.surfStageControls !== undefined) {
            el.controls = el.dataset.surfStageControls === '1';
            delete el.dataset.surfStageControls;
          }
          unstageAll();
          if (!isTop) {
            try { parent.postMessage({ __surf: 'unstageMe' }, '*'); } catch (err) {}
          }
          return true;
        });

        runtime.define('media.toggle', ({ id }) => {
          const el = mediaById(id);
          if (!el) { return null; }
          if (el.paused) { el.play(); } else { el.pause(); }
          return true;
        });

        runtime.define('media.seek', ({ id, time }) => {
          const el = mediaById(id);
          if (!el) { return null; }
          const limit = isFinite(el.duration) ? el.duration : time;
          el.currentTime = Math.max(0, Math.min(limit, time));
          return true;
        });

        runtime.define('media.skip', ({ id, delta }) => {
          const el = mediaById(id);
          if (!el) { return null; }
          const target = el.currentTime + delta;
          el.currentTime = isFinite(el.duration)
            ? Math.max(0, Math.min(el.duration, target))
            : Math.max(0, target);
          return true;
        });

        runtime.define('media.frame', async ({ id }) => {
          const el = mediaById(id);
          if (!el) { return null; }
          const r = el.getBoundingClientRect();
          if (r.width < 10 || r.height < 10) { return null; }
          const offset = await frameOffset();
          if (!offset) { return null; }
          return { x: r.x + offset.x, y: r.y + offset.y, width: r.width, height: r.height };
        });

        runtime.define('media.lockScroll', ({ id, keepInteraction }) => {
          if (!document.getElementById('__surf_lens')) {
            const s = document.createElement('style');
            s.id = '__surf_lens';
            // `pointer-events` is inherited, but sites set it explicitly on their
            // own overlays, so the universal selector and !important are both doing
            // work here. This is what actually keeps the pointer off the page:
            // covering a view with another one doesn't stop it, because tracking
            // areas fire on geometry and know nothing about what's drawn on top.
            //
            // Unless the caller wants the page playable: the video stage
            // locks scroll but leaves the player — and its own controls —
            // alive under the cutout, so only the overflow rule goes in.
            s.textContent = keepInteraction
              ? 'html, body { overflow: hidden !important; }'
              : 'html, body { overflow: hidden !important; }' +
                'html, html * { pointer-events: none !important; }';
            document.documentElement.appendChild(s);
          }
          if (keepInteraction) { return true; }
          // Native controls don't auto-hide reliably when the pointer never arrives,
          // so switch them off outright. Custom players hide themselves once the
          // page stops seeing hover at all.
          const el = mediaById(id);
          if (el) {
            el.dataset.surfControls = el.controls ? '1' : '0';
            el.controls = false;
          }
          return true;
        });

        runtime.define('media.unlockScroll', ({ id }) => {
          document.getElementById('__surf_lens')?.remove();
          const el = mediaById(id);
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
