import Foundation
import SurfCore

/// How Surf finds out what a page asked for.
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

    static let handlerName = "surfBlock"

    /// Built rather than stored, so the words the sweep matches on come from
    /// `AdSlot` — one list, tested in Swift, rather than two that drift.
    ///
    /// `collapsing` is off when the reader has turned element hiding off, and it
    /// has to reach in here as well as into the rules. Reclaiming a container's
    /// space is a change to the page's layout, which means it is a change a page
    /// can *measure* — and a switch that stopped the filter list hiding things
    /// while leaving this running would leave exactly the same fingerprint, on a
    /// page that has just been told there is nothing to find.
    static func script(collapsing: Bool) -> String {
        """
    (function () {
      if (window.__surfBlockInstalled) { return; }
      window.__surfBlockInstalled = true;

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

      // One wrapper layer per frame, never two.
      //
      // In the main frame the network agent has already replaced fetch, XHR
      // and sendBeacon and installed the one resource observer — it is a
      // document-start script added before this one — so this script taps
      // that wrap instead of wrapping the wrapped functions a second time.
      // The tap's signature is `note`'s own: (url, kind, loaded).
      //
      // In subframes the network agent is not injected at all (its drain and
      // setLive commands only ever run in the main frame, so a subframe copy
      // could never surface anything), and this script keeps its own
      // accounting — a third-party iframe is where much of an ad stack does
      // its work.
      const net = globalThis['\(NetworkAgent.globalName)'];
      if (net && net.state && net.state.networkInstalled) {
        net.state.blockTap = note;
      } else {
        // What loaded. `buffered: true` replays the entries recorded before
        // this observer existed, which at document start is most of a page's
        // CSS and its first scripts.
        try {
          const observer = new PerformanceObserver((list) => {
            const entries = list.getEntries();
            for (let i = 0; i < entries.length; i++) {
              note(entries[i].name, entries[i].initiatorType || 'other', true);
            }
          });
          observer.observe({ type: 'resource', buffered: true });
        } catch (error) { /* no Resource Timing: the loaded half is simply absent */ }

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
      }

      // ------------------------------------------------------------------
      // Standing in for what was blocked: the stub says there are no ads, which
      // every player already handles. README › Blocking.

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
      // Pressing play is not asking for a window. Refused by intent, not by
      // destination, so it works on domains no list carries. README › Blocking.

      const PLAYER_PARTS = \(AntiAdblock.playerSelectorsJS);
      let playerClickUntil = 0, armedBy = null;

      // An embed big enough to be a player.
      function isEmbeddedPlayer(element) {
        if (element.tagName !== 'IFRAME') { return false; }
        const box = element.getBoundingClientRect();
        return box.width >= SMALLEST_PLAYER && box.height >= SMALLEST_PLAYER;
      }

      const CONTROLS = 'a,button,input,select,textarea,label,summary,[role=button],[role=link]';

      // Judged by what is under the pointer, not by what took the click: they
      // differ exactly when a sheet lies over the player. README › Blocking.
      function clickIsOnPlayer(event) {
        const target = event.target;
        if (!target || !target.closest) { return false; }
        try { if (target.closest(PLAYER_PARTS)) { return true; } } catch (error) {}
        let stack, overControl = false;
        try {
          stack = document.elementsFromPoint(event.clientX, event.clientY);
          // A real control over an embed means what it says.
          overControl = !!target.closest(CONTROLS);
        } catch (error) { return false; }
        for (let i = 0; i < stack.length; i++) {
          const element = stack[i];
          if (element === target) { continue; }
          if (element.tagName === 'VIDEO') { return true; }
          if (!overControl && isEmbeddedPlayer(element)) { return true; }
        }
        return false;
      }

      // Armed when the button goes down. The scripts open their window on
      // mousedown, before a click exists, and the new tab takes the mouseup
      // with it. On the window, capturing, so a page's own listener can't stop
      // the event before this sees it.
      function armIfOnPlayer(event) {
        if (clickIsOnPlayer(event)) {
          playerClickUntil = Date.now() + \(Int(AntiAdblock.playerClickWindow * 1000));
          armedBy = event;
        }
      }

      // A refused window proves what took the click was a trap. If it covers
      // the player, let clicks through it, so the next one plays. Never the
      // video, and never a control smaller than the picture, like play itself.
      function disarm() {
        const event = armedBy;
        armedBy = null;
        if (!event || !event.target || !event.target.closest) { return; }
        const trap = event.target.closest('a') || event.target;
        if (trap.tagName === 'VIDEO' || trap.querySelector('video,iframe')) { return; }
        const box = trap.getBoundingClientRect();
        let stack;
        try { stack = document.elementsFromPoint(event.clientX, event.clientY); } catch (error) { return; }
        for (let i = 0; i < stack.length; i++) {
          const under = stack[i];
          if (trap.contains(under)) { continue; }
          if (under.tagName !== 'VIDEO' && !isEmbeddedPlayer(under)) { continue; }
          const player = under.getBoundingClientRect();
          if (box.width * box.height >= player.width * player.height * TRAP_COVERAGE) {
            trap.style.setProperty('pointer-events', 'none', 'important');
            trap.setAttribute('data-surf-untrapped', '');
          }
          return;
        }
      }
      ['pointerdown', 'mousedown', 'click'].forEach(function (type) {
        window.addEventListener(type, armIfOnPlayer, true);
      });

      const nativeOpen = window.open;
      if (typeof nativeOpen === 'function') {
        window.open = function (url) {
          let elsewhere = false;
          try {
            elsewhere = new URL(String(url), location.href).hostname !== location.hostname;
          } catch (error) { elsewhere = false; }

          if (Date.now() < playerClickUntil && elsewhere) {
            note(String(url), 'popup', false);
            disarm();
            // What a popup blocker returns, and what these scripts already
            // handle — they have to, because every browser blocks some of them.
            return null;
          }
          return nativeOpen.apply(window, arguments);
        };
      }

      // ------------------------------------------------------------------
      // The layer over the play button: made transparent to the pointer, not
      // removed, so only who receives the click changes. README › Blocking.

      const TRAP_COVERAGE = \(AntiAdblock.clickTrapCoverage);
      const SMALLEST_PLAYER = \(Int(AntiAdblock.smallestPlayer));

      function isTransparent(style) {
        if (style.backgroundImage !== 'none') { return false; }
        const colour = style.backgroundColor || '';
        return colour === 'transparent' || colour === 'rgba(0, 0, 0, 0)' || colour === '';
      }

      function untrapPlayers() {
        // An embedded player is an iframe out here, and a sheet over it is
        // the same trap.
        let videos;
        try { videos = document.querySelectorAll('video,iframe'); } catch (error) { return; }

        for (let v = 0; v < videos.length; v++) {
          const video = videos[v];
          if (video.tagName === 'IFRAME' && !isEmbeddedPlayer(video)) { continue; }

          // The *outermost* player element, not the nearest one. `closest`
          // stops at the first match, which on a real player is the inner
          // wrapper holding the video — and the sheet is laid one level above
          // that, as a sibling of it, precisely where a search from the inner
          // wrapper can never look.
          let container = null;
          let node = video.parentElement;
          while (node && node !== document.body && node !== document.documentElement) {
            try { if (node.matches(PLAYER_PARTS)) { container = node; } }
            catch (error) { /* a selector this engine dislikes */ }
            node = node.parentElement;
          }
          if (!container) { container = video.parentElement; }
          if (!container) { continue; }

          // Measured against the video rather than against the container. An
          // outer wrapper can be far larger than the picture, and a sheet that
          // covers the picture is covering the player whatever else it does or
          // doesn't reach.
          const player = video.getBoundingClientRect();
          if (player.width < SMALLEST_PLAYER || player.height < SMALLEST_PLAYER) { continue; }
          const area = player.width * player.height;

          let candidates;
          try { candidates = container.querySelectorAll('div,a,span'); } catch (error) { continue; }

          for (let i = 0; i < candidates.length; i++) {
            const element = candidates[i];
            if (element.hasAttribute('data-surf-untrapped')) { continue; }
            // Named elements belong to the player: its own code has to find
            // them again. This one is anonymous because nothing ever will.
            if (element.id) { continue; }
            const className = typeof element.className === 'string' ? element.className : '';
            if (className.trim()) { continue; }
            // Empty. A layer with anything in it is showing something.
            if (element.children.length || (element.textContent || '').trim()) { continue; }

            let style;
            try { style = getComputedStyle(element); } catch (error) { continue; }
            if (style.position !== 'absolute' && style.position !== 'fixed') { continue; }
            if (style.display === 'none' || style.visibility === 'hidden') { continue; }
            if (style.pointerEvents === 'none') { continue; }
            if (!isTransparent(style)) { continue; }

            const box = element.getBoundingClientRect();
            if (box.width * box.height < area * TRAP_COVERAGE) { continue; }

            element.style.setProperty('pointer-events', 'none', 'important');
            element.setAttribute('data-surf-untrapped', '');
          }
        }
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
      // The hole the ad leaves behind. Released rather than hidden, so a slot
      // that fills later grows back. README › Blocking.

      const COLLAPSING = \(collapsing);
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
          if (child.hasAttribute('data-surf-collapsed')) { continue; }
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
        node.setAttribute('data-surf-collapsed', '');
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
        if (!COLLAPSING) { return; }
        if (!element || !element.style || element.hasAttribute('data-surf-collapsed')) { return; }
        const box = element.getBoundingClientRect();
        element.style.setProperty('display', 'none', 'important');
        element.setAttribute('data-surf-collapsed', '');
        if (box.height >= HEIGHT_FLOOR || box.width >= HEIGHT_FLOOR) { releaseAncestors(element); }
      }

      // And the slots nothing was ever requested for. When the script that
      // would have filled a slot is itself blocked, no request is made and
      // nothing fails — the container is simply left holding a height open
      // forever. Three conditions together, never any one alone: it is named
      // as an ad container, it is reserving real height, and it is empty.
      function sweepSlots() {
        if (!COLLAPSING) { return; }
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
          if (element.hasAttribute('data-surf-collapsed')) { continue; }
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
        sweepTimer = setTimeout(() => {
          sweepTimer = null;
          sweepSlots();
          // The trap is laid once the player has built itself, and laid again
          // if it is taken away, so it is looked for on every sweep rather
          // than once at load.
          untrapPlayers();
        }, 400);
      }

      // Before `load`, which is when these checks are wired up, and again after
      // in case the page wrote more of itself in between.
      document.addEventListener('DOMContentLoaded', function () {
        sweepMarkupScripts();
        answerBaitChecks();
        untrapPlayers();
        scheduleSweep();
      }, true);
      window.addEventListener('load', function () {
        answerBaitChecks();
        untrapPlayers();
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
