import WebKit

/// The inspection agent: the half of dev tools that lives inside the page.
///
/// Injected into a *private content world*, not the page world. Isolated worlds
/// share the DOM but not the JS globals, which buys two things at once: the
/// page can't detect that it's being inspected, and it can't break the agent by
/// overwriting `Array.prototype.map` or anything else the agent leans on. The
/// console bridge has to live in the page world — it exists to replace page
/// globals — but nothing else does.
///
/// Injected only while a dev tools window is actually open. Unlike console
/// capture, this needs no history: the DOM is a live structure, readable
/// whenever we arrive, so there's nothing to be gained by paying for it on
/// every page the user merely browses past.
enum DevToolsAgent {

    /// The world the agent runs in. A single source so it can't drift between
    /// script injection and handler registration — registering a handler in a
    /// *different* world than the script leaves `messageHandlers.x` undefined
    /// and the agent fails completely silently.
    static let worldName = "glass.devtools"
    static var world: WKContentWorld { .world(name: worldName) }

    /// One-way, agent → Glass.
    static let eventHandlerName = "glassDevToolsEvents"

    /// What `callAsyncJavaScript` runs for every command. `method` and `params`
    /// arrive as call arguments, never interpolated into the source — page
    /// content must never be able to become script.
    static let dispatchScript = """
    if (!globalThis.__glassAgent) { return null; }
    return globalThis.__glassAgent.dispatch(method, params);
    """

    static let script = """
    (function () {
      if (globalThis.__glassAgent) { return; }

      const HANDLER = '\(eventHandlerName)';
      // Text longer than this is truncated for the tree; the node itself still
      // holds the whole thing.
      const MAX_TEXT = 400;
      const MUTATION_CAP = 500;

      const post = (payload) => {
        try {
          window.webkit.messageHandlers[HANDLER].postMessage(payload);
        } catch (e) {
          // The handler is removed on detach while this document stays alive.
        }
      };

      // ---- Node identity --------------------------------------------------

      // Two maps, both weak in the direction that matters. `ids` lets a node
      // find its number again; `nodes` holds only weak references, so keeping
      // the tree open can never pin a detached subtree in memory — the panel
      // would otherwise be a leak you cause by looking.
      const ids = new WeakMap();
      const nodes = new Map();
      let nextId = 1;

      function idFor(node) {
        let id = ids.get(node);
        if (id === undefined) {
          id = nextId++;
          ids.set(node, id);
          nodes.set(id, new WeakRef(node));
        }
        return id;
      }

      function nodeFor(id) {
        const ref = nodes.get(id);
        if (!ref) { return null; }
        const node = ref.deref();
        if (!node) { nodes.delete(id); return null; }
        return node;
      }

      // ---- Serialization --------------------------------------------------

      function typeName(node) {
        switch (node.nodeType) {
          case 1: return 'element';
          case 3: return 'text';
          case 8: return 'comment';
          case 9: return 'document';
          case 10: return 'doctype';
          case 11: return node.host ? 'shadowRoot' : 'fragment';
          default: return 'element';
        }
      }

      /// Whitespace between tags is formatting, not content. Every devtools
      /// hides it, because a pretty-printed document is otherwise more blank
      /// rows than real ones.
      function isIgnorable(node) {
        return node.nodeType === 3 && !(node.nodeValue || '').trim();
      }

      function childrenOf(node) {
        const out = [];
        // An open shadow root is shown as the element's first child, which is
        // where it renders. A closed one is unreachable by design and the
        // panel says so rather than pretending the element is empty.
        if (node.nodeType === 1 && node.shadowRoot) { out.push(node.shadowRoot); }
        const kids = node.childNodes || [];
        for (let i = 0; i < kids.length; i++) {
          if (!isIgnorable(kids[i])) { out.push(kids[i]); }
        }
        return out;
      }

      function serialize(node, depth) {
        const out = {
          id: idFor(node),
          nodeType: typeName(node),
          nodeName: node.nodeName,
          attributes: [],
          childCount: 0,
          value: ''
        };

        if (node.nodeType === 1) {
          const attrs = node.attributes || [];
          for (let i = 0; i < attrs.length; i++) {
            out.attributes.push({ name: attrs[i].name, value: attrs[i].value });
          }
        }
        if (node.nodeType === 3 || node.nodeType === 8) {
          const text = node.nodeValue || '';
          out.value = text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) + '…' : text;
        }

        const children = childrenOf(node);
        out.childCount = children.length;
        if (depth > 0) {
          out.children = children.map(function (child) { return serialize(child, depth - 1); });
        }
        return out;
      }

      // ---- Box model ------------------------------------------------------

      function sides(style, prefix, suffix) {
        const read = (edge) => parseFloat(style.getPropertyValue(prefix + edge + suffix)) || 0;
        return [read('top'), read('right'), read('bottom'), read('left')];
      }

      function boxModel(node) {
        if (!node || node.nodeType !== 1 || !node.getBoundingClientRect) { return null; }
        const rect = node.getBoundingClientRect();
        if (!rect.width && !rect.height) { return null; }
        const style = getComputedStyle(node);
        return {
          // The border box, in CSS pixels relative to the viewport.
          x: rect.x, y: rect.y, width: rect.width, height: rect.height,
          margin: sides(style, 'margin-', ''),
          border: sides(style, 'border-', '-width'),
          padding: sides(style, 'padding-', ''),
          // Shown in the panel's header: what the element actually measures.
          tagName: node.nodeName.toLowerCase()
        };
      }

      // ---- Mutations ------------------------------------------------------

      let observer = null;
      let queued = [];
      let scheduled = false;
      let sequence = 0;
      let lastAck = 0;

      function flushMutations() {
        scheduled = false;
        if (!queued.length) { return; }
        // Beyond the window the client is not keeping up. Say so once and let
        // it resync — replaying would double-apply what already landed.
        if (sequence - lastAck >= 8 || queued.length > MUTATION_CAP) {
          queued = [];
          post({ event: 'overflowed' });
          return;
        }
        const batch = queued;
        queued = [];
        sequence += 1;
        post({ event: 'dom.mutations', mutations: batch, sequence: sequence });
      }

      function scheduleFlush() {
        if (scheduled) { return; }
        scheduled = true;
        if (typeof requestAnimationFrame === 'function' && !document.hidden) {
          requestAnimationFrame(flushMutations);
        } else {
          setTimeout(flushMutations, 16);
        }
      }

      function queueMutation(mutation) {
        queued.push(mutation);
        scheduleFlush();
      }

      function startObserving() {
        if (observer || !document.documentElement) { return; }
        observer = new MutationObserver(function (records) {
          for (let i = 0; i < records.length; i++) {
            const record = records[i];
            // Only nodes the panel has actually seen are worth reporting. The
            // page is far bigger than the mirror, and a mutation about a node
            // that was never fetched is noise the client would only discard.
            const known = ids.get(record.target);
            if (known === undefined) { continue; }

            if (record.type === 'attributes') {
              const name = record.attributeName;
              queueMutation({
                kind: 'attribute', id: known, name: name,
                value: record.target.getAttribute ? record.target.getAttribute(name) : null
              });
            } else if (record.type === 'characterData') {
              const text = record.target.nodeValue || '';
              queueMutation({
                kind: 'text', id: known,
                value: text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) + '…' : text
              });
            } else if (record.type === 'childList') {
              queueMutation({
                kind: 'children', id: known,
                childCount: childrenOf(record.target).length
              });
            }
          }
        });
        observer.observe(document.documentElement, {
          subtree: true, childList: true, attributes: true, characterData: true
        });
      }

      // ---- Element picker -------------------------------------------------

      let picking = false;
      let lastHovered = -1;
      // The last event, measured once per frame rather than once per move.
      // `getComputedStyle` on every mousemove is a lot of work to throw away
      // milliseconds later, and the pointer generates far more events than the
      // screen can show.
      let pendingHover = null;
      let hoverScheduled = false;

      function pickTarget(event) {
        // `composedPath` sees through open shadow roots, so picking works on
        // a component's internals rather than stopping at its host.
        const path = event.composedPath ? event.composedPath() : [];
        for (let i = 0; i < path.length; i++) {
          if (path[i] && path[i].nodeType === 1) { return path[i]; }
        }
        return event.target;
      }

      function flushHover() {
        hoverScheduled = false;
        const target = pendingHover;
        pendingHover = null;
        if (!picking || !target || !target.isConnected) { return; }
        const id = idFor(target);
        if (id === lastHovered) { return; }
        lastHovered = id;
        post({ event: 'dom.inspectHover', nodeId: id, box: boxModel(target) });
      }

      function onPickMove(event) {
        if (!picking) { return; }
        const target = pickTarget(event);
        if (!target || target.nodeType !== 1) { return; }
        pendingHover = target;
        if (hoverScheduled) { return; }
        hoverScheduled = true;
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(flushHover);
        } else {
          setTimeout(flushHover, 16);
        }
      }

      function onPickClick(event) {
        if (!picking) { return; }
        // Swallowed in the capture phase: clicking to inspect a link must not
        // also navigate away from the page being inspected.
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        const target = pickTarget(event);
        setPicking(false);
        post({ event: 'dom.inspectPicked', nodeId: idFor(target) });
      }

      function onPickKey(event) {
        if (picking && event.key === 'Escape') {
          event.preventDefault();
          event.stopPropagation();
          setPicking(false);
          post({ event: 'dom.inspectCancelled' });
        }
      }

      function setPicking(enabled) {
        if (picking === enabled) { return; }
        picking = enabled;
        lastHovered = -1;
        const options = { capture: true, passive: false };
        if (enabled) {
          document.addEventListener('mousemove', onPickMove, options);
          document.addEventListener('click', onPickClick, options);
          document.addEventListener('keydown', onPickKey, options);
        } else {
          document.removeEventListener('mousemove', onPickMove, options);
          document.removeEventListener('click', onPickClick, options);
          document.removeEventListener('keydown', onPickKey, options);
        }
      }

      // ---- Following a selected element -----------------------------------

      // Scrolling, resizing and the page's own animations all move an element
      // without changing it. Reporting from here — where the events actually
      // are — is both instant and cheaper than the panel asking on a timer and
      // being wrong in between.
      let watched = -1;
      let watchScheduled = false;
      let lastBoxKey = '';

      function reportWatchedBox() {
        watchScheduled = false;
        if (watched < 0) { return; }
        const node = nodeFor(watched);
        if (!node) { return; }
        const box = boxModel(node);
        if (!box) { return; }
        // Only when it actually moved: a scroll that doesn't affect this
        // element should cost nothing.
        const key = box.x + ',' + box.y + ',' + box.width + ',' + box.height;
        if (key === lastBoxKey) { return; }
        lastBoxKey = key;
        post({ event: 'dom.boxChanged', nodeId: watched, box: box });
      }

      function scheduleWatch() {
        if (watchScheduled || watched < 0) { return; }
        watchScheduled = true;
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(reportWatchedBox);
        } else {
          setTimeout(reportWatchedBox, 16);
        }
      }

      window.addEventListener('scroll', scheduleWatch, { capture: true, passive: true });
      window.addEventListener('resize', scheduleWatch, { passive: true });

      // ---- Commands -------------------------------------------------------

      const agent = {
        // Replies are JSON strings rather than object graphs. Letting WebKit
        // build a deep NSDictionary across the process boundary is markedly
        // slower than handing over one string and decoding it on our side.
        dispatch(method, params) {
          try {
            switch (method) {
              case 'Runtime.ping':
                return JSON.stringify({
                  ok: true,
                  url: location.href,
                  title: document.title,
                  nodeCount: document.getElementsByTagName('*').length
                });

              case 'DOM.getDocument': {
                const root = document.documentElement;
                if (!root) { return JSON.stringify({ error: 'no document' }); }
                startObserving();
                // One level only. Two sounds harmless and isn't: the second
                // level of a real page is <body>'s children, so a document
                // with four thousand elements serialised all four thousand
                // into the very first payload. <html> and its two children is
                // all the first screen needs; everything below is fetched when
                // it is actually opened.
                return JSON.stringify({ root: serialize(root, 1) });
              }

              case 'DOM.requestChildNodes': {
                const node = nodeFor(params && params.nodeId);
                if (!node) { return JSON.stringify({ children: [] }); }
                return JSON.stringify({
                  children: childrenOf(node).map(function (child) { return serialize(child, 0); })
                });
              }

              case 'DOM.watch': {
                watched = (params && params.nodeId) !== undefined ? params.nodeId : -1;
                lastBoxKey = '';
                reportWatchedBox();
                return JSON.stringify({ ok: true });
              }

              case 'DOM.getBoxModel': {
                const node = nodeFor(params && params.nodeId);
                return JSON.stringify({ box: boxModel(node) });
              }

              case 'DOM.scrollIntoView': {
                const node = nodeFor(params && params.nodeId);
                if (node && node.scrollIntoView) {
                  node.scrollIntoView({ block: 'center', inline: 'nearest' });
                }
                return JSON.stringify({ ok: true });
              }

              case 'DOM.ack': {
                lastAck = Math.max(lastAck, (params && params.sequence) || 0);
                return JSON.stringify({ ok: true });
              }

              case 'Overlay.setInspectMode': {
                setPicking(!!(params && params.enabled));
                return JSON.stringify({ ok: true });
              }

              default:
                return JSON.stringify({ error: 'unknown method: ' + method });
            }
          } catch (e) {
            // A throw here would surface as an opaque WebKit error with none of
            // the page's own message, so carry it across as data.
            return JSON.stringify({ error: String((e && e.message) || e) });
          }
        }
      };

      globalThis.__glassAgent = agent;
      post({ event: 'bootstrapped', url: location.href, generation: 0 });
    })();
    """
}
