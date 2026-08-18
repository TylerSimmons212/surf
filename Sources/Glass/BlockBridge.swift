import Foundation
import GlassCore

/// How Glass finds out what a page asked for.
///
/// WebKit blocks the requests and then says nothing about it. The `notify`
/// action that would report a match is private API, and `decidePolicyFor` is
/// only ever called for frame navigations — it never sees an image, a script, or
/// a beacon, which between them are the whole subject. So the list in the panel
/// can't be a readout of WebKit's decisions and has to be assembled from the
/// page's own account of what it tried to load.
///
/// Two sources, deliberately non-overlapping. Resource Timing reports everything
/// that *completed*, including requests started by CSS that no wrapper here
/// would ever see. The failure handlers report what *didn't*. A request cannot
/// appear in both, so nothing has to be reconciled afterwards, and the
/// difference between the two is exactly the shape of what blocking did.
///
/// Runs in the page world, because that is where the page's own `fetch` lives:
/// an isolated world has a `fetch` of its own that the site never calls.
enum BlockBridge {

    static let handlerName = "glassBlock"

    /// Built rather than stored, so the words the sweep matches on come from
    /// `AdSlot` — one list, tested in Swift, rather than two that drift.
    static var script: String {
        """
    (function () {
      if (window.__glassBlockInstalled) { return; }
      window.__glassBlockInstalled = true;

      const post = (batch) => {
        try {
          window.webkit.messageHandlers.\(handlerName).postMessage(batch);
        } catch (error) { /* handler gone: the tab is being torn down */ }
      };

      const seen = new Set();
      let pending = [];
      let timer = null;

      // A page can fire hundreds of these while loading. Batched on a short
      // timer so the bridge costs one message per frame's worth of activity
      // rather than one per request.
      function flush() {
        timer = null;
        if (pending.length) { post(pending); pending = []; }
      }

      function note(url, kind, loaded) {
        if (typeof url !== 'string' || !url) { return; }
        // Only requests that go to somebody. data:, blob:, and about: are the
        // page talking to itself.
        if (url.lastIndexOf('http', 0) !== 0) { return; }

        const key = kind + '|' + url;
        if (seen.has(key)) { return; }
        // A page that has produced this many distinct requests has already told
        // us everything the panel can show.
        if (seen.size > 1500) { return; }
        seen.add(key);

        pending.push({ u: url, k: kind, l: loaded ? 1 : 0 });
        if (!timer) { timer = setTimeout(flush, 250); }
      }

      // What loaded. `buffered: true` replays the entries recorded before this
      // observer existed, which at document start is most of a page's CSS and
      // its first scripts.
      try {
        const observer = new PerformanceObserver((list) => {
          const entries = list.getEntries();
          for (let i = 0; i < entries.length; i++) {
            note(entries[i].name, entries[i].initiatorType || 'other', true);
          }
        });
        observer.observe({ type: 'resource', buffered: true });
      } catch (error) { /* no Resource Timing: the loaded half is simply absent */ }

      // What didn't. A blocked subresource fails the same way a missing one
      // does, and fires this on the element that asked for it.
      document.addEventListener('error', (event) => {
        const element = event.target;
        if (!element || !element.tagName) { return; }
        const url = element.src || element.href || element.currentSrc || '';
        note(url, element.tagName, false);
        // Only third parties. A broken image on the site's own server is the
        // site being broken, and collapsing it would hide the evidence.
        try {
          if (new URL(url, location.href).hostname !== location.hostname) {
            collapseFailed(element);
          }
        } catch (error) { /* not a URL we can compare */ }
      }, true);

      // fetch and XHR report their own failures; nothing else can see them.
      const nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function (input, init) {
          const url = (input && typeof input === 'object' && input.url)
            ? input.url
            : String(input);
          let result;
          try {
            result = nativeFetch.apply(this, arguments);
          } catch (error) {
            note(url, 'fetch', false);
            throw error;
          }
          // A rejected fetch is a request that never arrived. An HTTP error is
          // not — it resolves, and the server answered.
          return result.catch((error) => { note(url, 'fetch', false); throw error; });
        };
      }

      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try {
          this.addEventListener('error', () => { note(String(url), 'xhr', false); });
        } catch (error) { /* a subclass with a sealed prototype */ }
        return open.apply(this, arguments);
      };

      // sendBeacon is how trackers report on their way out of a page, and it
      // returns false when the request was refused rather than queued.
      const beacon = navigator.sendBeacon;
      if (typeof beacon === 'function') {
        navigator.sendBeacon = function (url) {
          const queued = beacon.apply(navigator, arguments);
          if (!queued) { note(String(url), 'beacon', false); }
          return queued;
        };
      }

      // ------------------------------------------------------------------
      // Standing in for what was blocked.
      //
      // A player loads Google's ad SDK, waits for the global to appear, and
      // hands the viewer to it. Refuse the script and the global never arrives,
      // so the player waits for a callback that cannot come and the viewer, who
      // pressed play, watches nothing happen.
      //
      // So a script we have a stand-in for is answered rather than silenced:
      // the stub is installed, nothing is fetched, and the element reports the
      // load the player is waiting on. What the stub then says is that there
      // are no ads — a state every player already handles, because it is what
      // an unfilled ad slot looks like to them.

      const SURROGATES = \(Surrogate.javaScriptTable);
      const installed = new Set();

      function surrogateFor(url) {
        for (let i = 0; i < SURROGATES.length; i++) {
          if (SURROGATES[i].pattern.test(url)) { return SURROGATES[i]; }
        }
        return null;
      }

      function installSurrogate(surrogate) {
        if (installed.has(surrogate)) { return; }
        installed.add(surrogate);
        try { surrogate.install(); } catch (error) { /* never break the page */ }
      }

      // Intercepting the property rather than the network, because the request
      // is already refused by the time anything here could see it — and it is
      // the element's `load` event, not the response, that the player is
      // actually waiting for.
      const nativeSrc = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
      if (nativeSrc && nativeSrc.set) {
        Object.defineProperty(HTMLScriptElement.prototype, 'src', {
          configurable: true,
          enumerable: nativeSrc.enumerable,
          get: function () { return nativeSrc.get.call(this); },
          set: function (value) {
            const surrogate = surrogateFor(String(value));
            if (!surrogate) { return nativeSrc.set.call(this, value); }
            installSurrogate(surrogate);
            // Asynchronously, so a handler attached on the next line still sees
            // it — the same reason the stub answers asynchronously itself.
            const element = this;
            setTimeout(function () {
              try { element.dispatchEvent(new Event('load')); } catch (error) {}
            }, 0);
          }
        });
      }

      // `setAttribute('src', …)` is the same act by another name, and players
      // use both.
      const nativeSetAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLScriptElement && String(name).toLowerCase() === 'src') {
          this.src = value;
          return;
        }
        return nativeSetAttribute.apply(this, arguments);
      };

      // A script written into the markup is fetched by the parser before any of
      // the above can see it. Its `load` will never fire, but a player that
      // polls for the global — most do — still finds one.
      function sweepMarkupScripts() {
        let scripts;
        try { scripts = document.querySelectorAll('script[src]'); } catch (error) { return; }
        for (let i = 0; i < scripts.length; i++) {
          const surrogate = surrogateFor(scripts[i].getAttribute('src') || '');
          if (surrogate) { installSurrogate(surrogate); }
        }
      }

      // ------------------------------------------------------------------
      // Pressing play is not asking for a window.
      //
      // A player can be configured to open one when clicked — the config sits
      // in the page, next to the video's own settings — so the click that plays
      // the video is the click that opens the tab. Every defence that reasons
      // about gestures is defeated by design there: the gesture is real, and it
      // is the one the viewer made. Checking the destination doesn't help
      // either, because these land on throwaway affiliate domains no list
      // carries.
      //
      // What is constant is the intent. Pressing play is a request to play, not
      // to open a window, and no legitimate player has ever needed one. That is
      // what gets refused — which is why it works on a domain nobody has seen
      // before.

      const PLAYER_PARTS = \(AntiAdblock.playerSelectorsJS);
      let playerClickUntil = 0;

      document.addEventListener('click', function (event) {
        const target = event.target;
        if (!target || !target.closest) { return; }
        try {
          if (target.closest(PLAYER_PARTS)) {
            playerClickUntil = Date.now() + \(Int(AntiAdblock.playerClickWindow * 1000));
          }
        } catch (error) { /* a selector this engine dislikes */ }
      }, true);

      const nativeOpen = window.open;
      if (typeof nativeOpen === 'function') {
        window.open = function (url) {
          let elsewhere = false;
          try {
            elsewhere = new URL(String(url), location.href).hostname !== location.hostname;
          } catch (error) { elsewhere = false; }

          if (Date.now() < playerClickUntil && elsewhere) {
            note(String(url), 'popup', false);
            // What a popup blocker returns, and what these scripts already
            // handle — they have to, because every browser blocks some of them.
            return null;
          }
          return nativeOpen.apply(window, arguments);
        };
      }

      // ------------------------------------------------------------------
      // The variable a page checks for instead of asking.
      //
      // A page cannot ask whether a request was blocked, so it loads a script
      // whose only job is to set a variable and then checks whether the
      // variable is there. The name is random per site, so no list can carry it
      // and no stub can be written for it in advance — but the check itself is
      // in the page, in plain text, and can be read.

      const BAIT_PREFIXES = \(AntiAdblock.baitPrefixesJSArray);

      function namesBait(identifier) {
        const lowered = identifier.toLowerCase();
        for (let i = 0; i < BAIT_PREFIXES.length; i++) {
          const prefix = BAIT_PREFIXES[i];
          if (lowered.indexOf(prefix) !== 0) { continue; }
          const tail = lowered.slice(prefix.length);
          // A word that merely starts with "bait" is a word.
          if (!tail) { return true; }
          return tail[0] === '_' || tail[0] === '$' || (tail[0] >= '0' && tail[0] <= '9');
        }
        return false;
      }

      function answerBaitChecks() {
        let scripts;
        try { scripts = document.querySelectorAll('script:not([src])'); }
        catch (error) { return; }

        const patterns = [
          /\(AntiAdblock.baitCheckPattern)/g,
          /\(AntiAdblock.baitCheckPatternReversed)/g
        ];

        for (let i = 0; i < scripts.length; i++) {
          const source = scripts[i].textContent || '';
          for (let p = 0; p < patterns.length; p++) {
            patterns[p].lastIndex = 0;
            let match;
            while ((match = patterns[p].exec(source)) !== null) {
              const name = match[1];
              if (!namesBait(name) || name in window) { continue; }
              // Never when the page assigns it itself — then it is a variable
              // the page owns and the check is about its own state, not ours.
              if (new RegExp('(var|let|const)\\s+' + name + '\\b|\\b' + name + '\\s*=[^=]')
                  .test(source)) { continue; }
              try {
                Object.defineProperty(window, name, {
                  value: true, writable: true, configurable: true
                });
              } catch (error) { /* the page got there first */ }
            }
          }
        }
      }

      // ------------------------------------------------------------------
      // The hole the ad leaves behind.
      //
      // Refusing the request doesn't reclaim the space: a slot is a container
      // given a height before anyone knows what will fill it, so a blocked ad
      // leaves the reservation standing and the reader gets a blank band.
      //
      // What happens here is a release of the reservation, not a hiding of the
      // element. `display: none` is a decision that can't be walked back if the
      // site fills the slot a second later; a container no longer holding a
      // height open collapses while it is empty and grows again if something
      // real arrives.

      const SLOT_NAMES = new Set(\(AdSlot.slotNamesJSArray));
      const HEIGHT_FLOOR = \(Int(AdSlot.reservedHeightFloor));
      const MAX_SWEEPS = 12;
      let sweeps = 0;

      // Whole tokens, never substrings — a class called `download` contains
      // "ad" and names nothing of the sort. Mirrors AdSlot.tokens.
      function namesASlot(element) {
        const source = (element.id || '') + ' ' + (element.className || '');
        if (typeof source !== 'string' || !source.trim()) { return false; }
        const tokens = source.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/);
        for (let i = 0; i < tokens.length; i++) {
          if (tokens[i] && SLOT_NAMES.has(tokens[i])) { return true; }
        }
        return false;
      }

      function hasVisibleContent(node) {
        const children = node.children;
        for (let i = 0; i < children.length; i++) {
          const child = children[i];
          if (child.hasAttribute('data-glass-collapsed')) { continue; }
          let style;
          try { style = getComputedStyle(child); } catch (error) { continue; }
          if (style.display === 'none' || style.visibility === 'hidden') { continue; }
          const box = child.getBoundingClientRect();
          if (box.width > 2 && box.height > 2) { return true; }
        }
        for (let node2 = node.firstChild; node2; node2 = node2.nextSibling) {
          if (node2.nodeType === 3 && node2.nodeValue.trim()) { return true; }
        }
        return false;
      }

      // Every way a slot is given a size before it has contents. Height and
      // min-height are the common two; the padding pair is the aspect-ratio
      // hack, where the box is held open by percentage padding and setting the
      // height alone changes nothing at all.
      function release(node) {
        node.style.setProperty('min-height', '0', 'important');
        node.style.setProperty('height', 'auto', 'important');
        node.style.setProperty('padding-top', '0', 'important');
        node.style.setProperty('padding-bottom', '0', 'important');
        node.style.setProperty('aspect-ratio', 'auto', 'important');
        node.setAttribute('data-glass-collapsed', '');
      }

      // Up from a hole, for as long as the ancestors are holding space open for
      // it and nothing else. Bounded, because past a few levels the container
      // belongs to the page's layout rather than to the ad.
      function releaseAncestors(element) {
        let node = element.parentElement;
        let depth = 0;
        while (node && depth < 4 && node !== document.body && node !== document.documentElement) {
          if (hasVisibleContent(node)) { break; }
          if (node.getBoundingClientRect().height < HEIGHT_FLOOR) { break; }
          release(node);
          node = node.parentElement;
          depth++;
        }
      }

      // A subresource that failed is a box that will never be filled. Hiding
      // *this* element is safe in a way that hiding a slot is not: there is
      // nothing in it and nothing coming.
      function collapseFailed(element) {
        if (!element || !element.style || element.hasAttribute('data-glass-collapsed')) { return; }
        const box = element.getBoundingClientRect();
        element.style.setProperty('display', 'none', 'important');
        element.setAttribute('data-glass-collapsed', '');
        if (box.height >= HEIGHT_FLOOR || box.width >= HEIGHT_FLOOR) { releaseAncestors(element); }
      }

      // And the slots nothing was ever requested for. When the script that
      // would have filled a slot is itself blocked, no request is made and
      // nothing fails — the container is simply left holding a height open
      // forever. Three conditions together, never any one alone: it is named
      // as an ad container, it is reserving real height, and it is empty.
      function sweepSlots() {
        if (sweeps++ > MAX_SWEEPS) { return; }
        let candidates;
        try {
          candidates = document.querySelectorAll(
            '[id*="ad" i],[class*="ad" i],[id*="dfp" i],[class*="dfp" i],' +
            '[id*="gpt" i],[class*="gpt" i],[id*="sponsor" i],[class*="sponsor" i],' +
            '[class*="leaderboard" i],[class*="taboola" i],[class*="outbrain" i]'
          );
        } catch (error) { return; }

        for (let i = 0; i < candidates.length; i++) {
          const element = candidates[i];
          if (element.hasAttribute('data-glass-collapsed')) { continue; }
          if (!namesASlot(element)) { continue; }
          if (element.getBoundingClientRect().height < HEIGHT_FLOOR) { continue; }
          if (hasVisibleContent(element)) { continue; }
          release(element);
          releaseAncestors(element);
        }
      }

      // Slots are filled late and lazily, so one pass at load would miss most
      // of them. Throttled, and capped, for the same reason the theme sweep is:
      // a page that rewrites itself on a timer would otherwise buy a sweep
      // every time it did.
      let sweepTimer = null;
      function scheduleSweep() {
        if (sweepTimer) { return; }
        sweepTimer = setTimeout(() => { sweepTimer = null; sweepSlots(); }, 400);
      }

      // Before `load`, which is when these checks are wired up, and again after
      // in case the page wrote more of itself in between.
      document.addEventListener('DOMContentLoaded', function () {
        sweepMarkupScripts();
        answerBaitChecks();
        scheduleSweep();
      }, true);
      window.addEventListener('load', function () {
        answerBaitChecks();
        scheduleSweep();
      }, true);
      try {
        new MutationObserver(scheduleSweep)
          .observe(document.documentElement, { childList: true, subtree: true });
      } catch (error) { /* no document element yet: the load events still fire */ }

      // The last batch of a page that navigates away mid-flush.
      window.addEventListener('pagehide', flush, true);
    })();
    """
    }

    /// Decodes one batch. Anything malformed is dropped rather than defaulted:
    /// this is the page's word, and the page is not trusted to be well-behaved.
    static func decode(_ body: Any) -> [RequestRecord] {
        guard let batch = body as? [[String: Any]] else { return [] }
        return batch.compactMap { entry in
            guard let url = entry["u"] as? String, !url.isEmpty else { return nil }
            let reported = entry["k"] as? String ?? ""
            let loaded = (entry["l"] as? Int ?? 0) == 1
            return RequestRecord(url: url, kind: ResourceKind(reported: reported), didLoad: loaded)
        }
    }
}
