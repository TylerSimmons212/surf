import Foundation
import SurfCore

/// The `youtube` domain: what the site lens asks YouTube.
///
/// Page world, and on demand. Both halves of that are deliberate. The data
/// this reads — `ytInitialData`, `ytInitialPlayerResponse` — and the player
/// it drives are the site's own globals, invisible from an isolated world.
/// And nothing here is resident: `Tab` evaluates this script when the lens
/// opens, so a tab that never focuses YouTube never parses a byte of it, the
/// same arrangement `FocusBridge.extractorScript` uses.
///
/// The script copies keys and pushes buttons. It classifies nothing, parses
/// nothing, and decides nothing — every judgement about what YouTube's
/// payloads mean lives in `YouTubeModel`, in Swift, under test against
/// payloads captured from the real site.
enum YouTubeBridge {

    /// Registers the domain. Idempotent through the agent's scratch state,
    /// so re-evaluating it on every load while the lens is up is a re-entry
    /// guard rather than a leak.
    static var installScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent || agent.state.youtubeInstalled) { return; }
          agent.state.youtubeInstalled = true;

          const STAGE = 'data-surf-yt-stage';
          const UP = 'data-surf-yt-up';

          // The player is the element, not a global: YouTube hangs its API
          // methods directly on #movie_player. Checked for one of them rather
          // than merely for the id, because the div exists in the document
          // before the player has booted into it.
          function player() {
            const el = document.getElementById('movie_player');
            return el && typeof el.getPlayerState === 'function' ? el : null;
          }

          // ---- Reading the page -------------------------------------------
          //
          // Only the keys the Swift parser reads are copied over. A whole
          // videoRenderer is 11-74KB of tracking parameters and service
          // endpoints; a results page of them is a third of a megabyte
          // across the bridge for the ~2KB per result that says what the
          // video is.
          const RESULT_KEYS = ['videoId', 'title', 'ownerText', 'longBylineText',
            'lengthText', 'viewCountText', 'publishedTimeText', 'thumbnail',
            'badges', 'ownerBadges'];
          const CHAPTER_KEYS = ['title', 'timeRangeStartMillis'];
          const CAPTION_KEYS = ['languageCode', 'name', 'kind'];
          const DETAIL_KEYS = ['videoId', 'title', 'author', 'channelId',
            'lengthSeconds', 'viewCount', 'isLiveContent'];

          function prune(node, keys) {
            const out = {};
            for (const key of keys) {
              if (node[key] !== undefined) { out[key] = node[key]; }
            }
            return JSON.stringify(out);
          }

          // Every object in the payload carrying `key`, which is how YouTube
          // marks what a node is. Depth-capped and count-capped: the blob is
          // megabytes and deeply recursive, and past a page of results the
          // grid has nothing more to show.
          function collect(root, key, limit) {
            const found = [];
            (function walk(node, depth) {
              if (!node || depth > 14 || found.length >= limit) { return; }
              if (Array.isArray(node)) {
                for (const item of node) { walk(item, depth + 1); }
                return;
              }
              if (typeof node !== 'object') { return; }
              const hit = node[key];
              // A hit is not walked into: a renderer's own children hold
              // nothing this is looking for, and stopping here is most of
              // why the walk is cheap.
              if (hit && typeof hit === 'object') { found.push(hit); return; }
              for (const name of Object.keys(node)) { walk(node[name], depth + 1); }
            })(root, 0);
            return found;
          }

          agent.define('youtube.page', () => {
            const data = window.ytInitialData || null;
            const response = window.ytInitialPlayerResponse || null;
            const live = player();

            const renderers = data
              ? collect(data, 'videoRenderer', 40).map((v) => prune(v, RESULT_KEYS))
              : [];
            const chapters = data
              ? collect(data, 'chapterRenderer', 200).map((c) => prune(c, CHAPTER_KEYS))
              : [];

            // The tracklist is an array rather than a renderer, so it is
            // collected by the key that holds it and then walked itself.
            let captionTracks = [];
            if (response) {
              const lists = collect(response, 'captionTracks', 1);
              const tracks = lists.length && Array.isArray(lists[0]) ? lists[0] : [];
              captionTracks = tracks.slice(0, 40)
                .filter((t) => t && typeof t === 'object')
                .map((t) => prune(t, CAPTION_KEYS));
            }

            let details = '';
            const declared = response && response.videoDetails;
            if (declared && typeof declared === 'object') {
              details = prune(declared, DETAIL_KEYS);
            }

            let rates = [];
            if (live && typeof live.getAvailablePlaybackRates === 'function') {
              try {
                const offered = live.getAvailablePlaybackRates();
                if (Array.isArray(offered)) { rates = offered.slice(0, 16); }
              } catch (error) { /* the player is booting; the ladder stands in */ }
            }

            return {
              renderers: renderers,
              details: details,
              chapters: chapters,
              captionTracks: captionTracks,
              rates: rates,
              hasPlayer: !!live
            };
          });

          // ---- The stage ---------------------------------------------------

          // #movie_player is pinned, not the <video> inside it — and that is
          // the whole difference between this and the generic theater.
          // YouTube draws its subtitles into a sibling of the video's parent
          // rather than into a <track>, so a stage that promotes the video
          // alone lights the captions out along with everything else. Pin the
          // player and the captions ride along, positioned by the player's own
          // layout, which is the only code that knows where they go.
          function ensureSheet() {
            if (document.getElementById('__surf_yt')) { return; }
            const sheet = document.createElement('style');
            sheet.id = '__surf_yt';
            sheet.textContent =
              '[' + STAGE + ']{visibility:visible!important;' +
              'position:fixed!important;inset:0!important;' +
              'width:100vw!important;height:100vh!important;' +
              'max-width:none!important;max-height:none!important;' +
              'min-width:0!important;min-height:0!important;' +
              'margin:0!important;padding:0!important;border:0!important;' +
              'transform:none!important;z-index:2147483646!important;' +
              'background:#000!important}' +
              // The wrapper between the player and the video, which has to be
              // given a size before the video can have one. It is
              // position:relative with no dimensions of its own and its only
              // child is absolutely positioned, so its height collapses to
              // zero — and a video sized height:100% against zero is the
              // black screen with the subtitles still playing over it,
              // because the captions hang off the player instead and never
              // needed this box at all.
              '[' + STAGE + '] .html5-video-container{position:absolute!important;' +
              'inset:0!important;width:100%!important;height:100%!important;' +
              'margin:0!important;padding:0!important}' +
              // The video letterboxes itself inside that box. Forced rather
              // than left to YouTube's own resize handling, which is not
              // guaranteed to run for a size we imposed from outside.
              '[' + STAGE + '] video.html5-main-video{' +
              'width:100%!important;height:100%!important;' +
              'left:0!important;top:0!important;object-fit:contain!important}' +
              // Every containing block and stacking context between the player
              // and the document is dissolved, or "fixed" re-anchors to a div
              // and the z-index caps under the masthead.
              '[' + UP + ']{transform:none!important;translate:none!important;' +
              'rotate:none!important;scale:none!important;filter:none!important;' +
              'backdrop-filter:none!important;perspective:none!important;' +
              'clip-path:none!important;mask:none!important;' +
              'isolation:auto!important;mix-blend-mode:normal!important;' +
              'opacity:1!important;contain:none!important;' +
              'content-visibility:visible!important;' +
              'will-change:auto!important;z-index:auto!important}' +
              // Lights out: everything off the path to the player. visibility
              // rather than display, so layout holds and the player keeps
              // measuring the world it expects.
              '[' + UP + ']>:not([' + UP + ']):not([' + STAGE + '])' +
              '{visibility:hidden!important}' +
              // YouTube's own chrome, inside the element we just promoted.
              // display:none here rather than visibility:hidden — these are
              // overlays, and a hidden one still eats the pointer.
              '[' + STAGE + '] .ytp-chrome-bottom,[' + STAGE + '] .ytp-chrome-top,' +
              '[' + STAGE + '] .ytp-gradient-bottom,[' + STAGE + '] .ytp-gradient-top,' +
              '[' + STAGE + '] .ytp-ce-element,[' + STAGE + '] .html5-endscreen,' +
              '[' + STAGE + '] .ytp-suggested-action,[' + STAGE + '] .ytp-popup,' +
              '[' + STAGE + '] .ytp-autonav-endscreen-countdown-overlay,' +
              '[' + STAGE + '] .ytp-miniplayer-ui,[' + STAGE + '] .ytp-pause-overlay,' +
              '[' + STAGE + '] .ytp-watermark,[' + STAGE + '] .ytp-cued-thumbnail-overlay,' +
              '[' + STAGE + '] .ytp-paid-content-overlay,[' + STAGE + '] .iv-branding,' +
              '[' + STAGE + '] .ytp-speedmaster-overlay,[' + STAGE + '] .ytp-gated-actions-overlay' +
              '{display:none!important}' +
              // Surf's transport sits at the bottom of the screen; the
              // captions have to clear it. The container is what the caption
              // windows position themselves inside, so lifting it lifts them.
              '[' + STAGE + '] .ytp-caption-window-container' +
              '{bottom:104px!important}';
            document.documentElement.appendChild(sheet);
          }

          function tag(el) {
            ensureSheet();
            el.setAttribute(STAGE, '');
            let up = el.parentElement;
            while (up && up !== document.documentElement) {
              up.setAttribute(UP, '');
              up = up.parentElement;
            }
          }

          agent.define('youtube.stage', () => {
            const live = player();
            if (!live) { return null; }
            tag(live);
            // The box changed underneath the player and nothing told it.
            // YouTube sizes the video, places its captions and picks its
            // quality ladder from dimensions it measured before the stage
            // went up — 427x240 on the page this was found on. The
            // stylesheet above makes the picture right; this makes the
            // player's own idea of the picture right, which is what the
            // parts we don't draw ourselves are still reading.
            // Only when the box actually changed. Staging is re-run every
            // second by the watchdog — YouTube re-parents its player and the
            // tags have to follow — and setSize drives the player's entire
            // resize path, so calling it on every beat would relayout the
            // video once a second for nothing.
            const width = window.innerWidth || 0;
            const height = window.innerHeight || 0;
            const last = agent.state.youtubeStageSize;
            if (typeof live.setSize === 'function'
                && (!last || last.w !== width || last.h !== height)) {
              agent.state.youtubeStageSize = { w: width, h: height };
              try { live.setSize(width, height); }
              catch (error) { /* an older player build */ }
            }
            return true;
          });

          agent.define('youtube.unstage', () => {
            const marked = document.querySelectorAll('[' + STAGE + '], [' + UP + ']');
            for (const el of marked) {
              el.removeAttribute(STAGE);
              el.removeAttribute(UP);
            }
            const sheet = document.getElementById('__surf_yt');
            if (sheet) { sheet.remove(); }
            // So the next stage re-sizes rather than trusting a box the page
            // no longer has.
            agent.state.youtubeStageSize = null;
            return true;
          });

          // ---- Driving the player ------------------------------------------

          agent.define('youtube.rate', ({ rate }) => {
            const live = player();
            if (!live || !(rate > 0)) { return null; }
            try { live.setPlaybackRate(rate); } catch (error) { /* refused */ }
            // And on the element itself: the API object and the media element
            // can disagree, and the element is the one that actually plays.
            const video = document.querySelector('video.html5-main-video');
            if (video) { video.playbackRate = rate; }
            return true;
          });

          // An empty language turns them off. YouTube spells that as a track
          // with nothing in it rather than as a separate call.
          agent.define('youtube.captions', ({ language }) => {
            const live = player();
            if (!live || typeof live.setOption !== 'function') { return null; }
            // The captions module is not loaded on a video that has never
            // shown one, and setOption against an absent module does nothing.
            if (typeof live.loadModule === 'function') {
              try { live.loadModule('captions'); } catch (error) { /* already on */ }
            }
            try {
              live.setOption('captions', 'track', language ? { languageCode: language } : {});
            } catch (error) {
              return null;
            }
            return true;
          });
        })();
        """
    }
}
