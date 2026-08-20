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
    static var script: String {
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
        sweepTimer = setTimeout(() => { sweepTimer = null; sweepSlots(); }, 400);
      }

      document.addEventListener('DOMContentLoaded', scheduleSweep, true);
      window.addEventListener('load', scheduleSweep, true);
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
