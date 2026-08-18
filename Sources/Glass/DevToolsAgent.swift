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
      // Nodes whose next `style` attribute change was made by us. Without this,
      // editing an inline declaration reports itself back as a page mutation,
      // the panel reloads, and the row being typed into is rebuilt mid-edit.
      const selfStyleEdits = new Set();
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
              if (name === 'style' && selfStyleEdits.has(record.target)) {
                selfStyleEdits.delete(record.target);
                continue;
              }
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

      // ---- Styles ---------------------------------------------------------

      // Pseudo-classes describing a state the element is not in while being
      // inspected. `matches()` answers "no" for all of them, so a rule that
      // only styles the hover state would simply never appear — which is why
      // no inspector shows you what an element looks like on hover without
      // making you hover it. These are stripped so the rule matches, and the
      // rule is then flagged as not currently applying.
      const STATE_PSEUDOS = [
        'hover', 'active', 'focus', 'focus-visible', 'focus-within',
        'target', 'visited'
      ];
      // Pseudo-elements that predate the double colon.
      const LEGACY_ELEMENTS = ['before', 'after', 'first-line', 'first-letter'];
      const MAX_VALUE = 400;
      const MAX_ANCESTORS = 10;
      const MAX_RULES = 500;

      // ---- Recovered stylesheets ------------------------------------------

      // A cross-origin sheet throws on `.cssRules`, so the page cannot read it
      // and neither can any inspector built out of page script. Glass refetches
      // it natively — `URLSession` is not bound by CORS — and hands the text
      // back here.
      //
      // It returns as a *constructable* stylesheet rather than being injected:
      // parsing it gives `.cssRules` to walk and `element.matches()` to test
      // against, while adopting it into the document would apply every rule a
      // second time and change the page being inspected.
      const recoveredSheets = new Map();

      // ---- Editable rule handles ------------------------------------------

      // Rules are addressed by a minted id, never by their index in the sheet.
      // Inserting a rule shifts every index after it, so an index captured
      // during one read edits a *different* rule on the next one — which is a
      // silent, page-corrupting kind of wrong. CSSOM wrapper objects keep their
      // identity, so a WeakMap survives exactly what an index doesn't.
      const ruleIds = new WeakMap();
      const ruleRefs = new Map();
      // The authored text, captured the first time a rule is touched, so any
      // edit can be taken back without reloading the page.
      const ruleOriginals = new Map();
      let nextRuleId = 1;

      function idForRule(rule) {
        let id = ruleIds.get(rule);
        if (id === undefined) {
          id = nextRuleId++;
          ruleIds.set(rule, id);
          ruleRefs.set(id, new WeakRef(rule));
        }
        return id;
      }

      function ruleFor(id) {
        const ref = ruleRefs.get(id);
        if (!ref) { return null; }
        const rule = ref.deref();
        if (!rule) { ruleRefs.delete(id); return null; }
        return rule;
      }

      /// Replaces a declaration block wholesale.
      ///
      /// One operation for editing, disabling, adding and reordering, because
      /// `cssText` is the only CSSOM surface that preserves authored order.
      /// Setting properties one by one moves a re-enabled declaration to the
      /// end of the block, which quietly changes the cascade within the rule.
      function applyStyleText(style, text, owner) {
        const before = new Set();
        for (let i = 0; i < style.length; i++) { before.add(style.item(i)); }
        style.cssText = text;
        // What the engine actually accepted. A value it can't parse is dropped
        // silently, and the panel needs to say so rather than show an edit that
        // didn't happen.
        const applied = [];
        for (let i = 0; i < style.length; i++) { applied.push(style.item(i)); }
        return { ok: true, applied: applied, owner: owner };
      }

      // ---- Colour resolution ----------------------------------------------

      // Asked of the engine rather than parsed by hand.
      //
      // A hand-rolled parser would need the 148 named colours, hex in three
      // lengths, rgb/hsl in two syntaxes each — and would still miss `oklch()`,
      // which Tailwind v4 now emits by default, and `color-mix()`, and
      // `light-dark()`. A 1×1 canvas knows all of them, because it is the same
      // colour parser the page itself uses.
      let colorCanvas = null;
      const colorCache = new Map();

      function colorContext() {
        if (!colorCanvas) {
          colorCanvas = document.createElement('canvas');
          colorCanvas.width = 1;
          colorCanvas.height = 1;
        }
        try {
          return colorCanvas.getContext('2d', { willReadFrequently: true });
        } catch (e) {
          return null;
        }
      }

      function resolveColor(token, node) {
        const cached = colorCache.get(token);
        if (cached !== undefined) { return cached; }

        let result = null;
        const ctx = colorContext();
        let text = token;

        // A custom property is a name, not a colour, until it's resolved.
        if (text.indexOf('var(') === 0 && node) {
          const close = text.indexOf(')');
          const name = text.slice(4, close < 0 ? text.length : close).split(',')[0].trim();
          text = (getComputedStyle(node).getPropertyValue(name) || '').trim();
        }

        if (ctx && text) {
          // Two sentinels. An unparseable value leaves `fillStyle` untouched,
          // so the two answers disagree — which is the only reliable way to
          // ask the engine "is this a colour?" without a table of your own.
          ctx.fillStyle = '#000000';
          ctx.fillStyle = text;
          const black = ctx.fillStyle;
          ctx.fillStyle = '#ffffff';
          ctx.fillStyle = text;
          if (black === ctx.fillStyle) {
            // The pixel rather than the string: exact sRGB bytes come back
            // whatever syntax went in, so nothing here has to know what
            // `oklch(0.7 0.1 200)` means.
            ctx.clearRect(0, 0, 1, 1);
            ctx.fillStyle = text;
            ctx.fillRect(0, 0, 1, 1);
            try {
              const data = ctx.getImageData(0, 0, 1, 1).data;
              result = [data[0], data[1], data[2], data[3]];
            } catch (e) { /* tainted canvas, which this one can't be */ }
          }
        }

        colorCache.set(token, result);
        return result;
      }

      /// Splits a value so each colour in it can be shown next to its swatch.
      ///
      /// Per colour, not per declaration: `border: 1px solid red` has one, and
      /// `linear-gradient(red, blue)` has two, and a single swatch stuck on the
      /// front of either would be answering a different question.
      function colorSegments(value, node, depth) {
        const segments = [];
        let plain = '';
        let i = 0;

        function pushPlain() {
          if (plain) { segments.push({ text: plain }); plain = ''; }
        }

        while (i < value.length) {
          const ch = value[i];
          if (ch !== '#' && !isNameChar(ch)) { plain += ch; i++; continue; }

          let j = ch === '#' ? i + 1 : i;
          while (j < value.length && isNameChar(value[j])) { j++; }
          let token = value.slice(i, j);
          let end = j;

          if (value[j] === '(') {
            let level = 0;
            let k = j;
            for (; k < value.length; k++) {
              if (value[k] === '(') { level++; }
              else if (value[k] === ')') { level--; if (level === 0) { k++; break; } }
            }
            token = value.slice(i, k);
            end = k;
          }

          const rgba = resolveColor(token, node);
          if (rgba) {
            pushPlain();
            segments.push({ text: token, rgba: rgba });
            i = end;
            continue;
          }

          const open = token.indexOf('(');
          if (open > 0 && depth < 4) {
            // Not a colour itself, but its arguments might be — a gradient is
            // the ordinary case, and two swatches is the right answer.
            plain += token.slice(0, open + 1);
            pushPlain();
            const inner = colorSegments(token.slice(open + 1, token.length - 1), node, depth + 1);
            for (let n = 0; n < inner.length; n++) { segments.push(inner[n]); }
            plain = ')';
            i = end;
            continue;
          }

          plain += token;
          i = end;
        }
        pushPlain();
        return segments;
      }

      function isNameChar(ch) {
        return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
          || (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
      }

      /// Splits a selector into something `matches()` can answer, plus what had
      /// to be removed to get there.
      function analyseSelector(selector) {
        let pseudo = null;
        const states = [];
        let out = '';
        let depth = 0;
        let quote = null;
        let i = 0;

        while (i < selector.length) {
          const ch = selector[i];
          if (quote) {
            out += ch;
            if (ch === quote) { quote = null; }
            i++;
            continue;
          }
          if (ch === '"' || ch === "'") { quote = ch; out += ch; i++; continue; }
          if (ch === '(') { depth++; out += ch; i++; continue; }
          if (ch === ')') { depth = Math.max(0, depth - 1); out += ch; i++; continue; }

          // Only at the top level: `:not(:hover)` means something quite
          // different from `:hover`, and stripping inside it would change which
          // elements the selector picks out.
          if (ch === ':' && depth === 0) {
            let j = i + 1;
            let isElement = false;
            if (selector[j] === ':') { isElement = true; j++; }
            let k = j;
            while (k < selector.length && isNameChar(selector[k])) { k++; }
            const name = selector.slice(j, k).toLowerCase();

            let end = k;
            if (selector[k] === '(') {
              let d = 0;
              let m = k;
              for (; m < selector.length; m++) {
                if (selector[m] === '(') { d++; }
                else if (selector[m] === ')') { d--; if (d === 0) { m++; break; } }
              }
              end = m;
            }

            if (isElement || LEGACY_ELEMENTS.indexOf(name) >= 0) {
              pseudo = '::' + name;
              i = end;
              continue;
            }
            if (STATE_PSEUDOS.indexOf(name) >= 0) {
              states.push(':' + name);
              i = end;
              continue;
            }
            out += selector.slice(i, end);
            i = end;
            continue;
          }
          out += ch;
          i++;
        }

        let clean = out.trim();
        // A selector that was nothing but state — `:hover { }` — still applies
        // to something.
        if (!clean) { clean = '*'; }
        const tail = clean[clean.length - 1];
        if (tail === '>' || tail === '+' || tail === '~') { clean += ' *'; }
        return { clean: clean, pseudo: pseudo, states: states };
      }

      function splitDeclarations(text) {
        const out = [];
        let depth = 0;
        let quote = null;
        let current = '';
        for (let i = 0; i < text.length; i++) {
          const ch = text[i];
          if (quote) {
            current += ch;
            if (ch === quote) { quote = null; }
            continue;
          }
          if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
          if (ch === '(') { depth++; }
          else if (ch === ')') { depth = Math.max(0, depth - 1); }
          // A `;` inside `url(data:...)` is not a separator, and splitting on
          // it produces two declarations that are both nonsense.
          else if (ch === ';' && depth === 0) {
            if (current.trim()) { out.push(current.trim()); }
            current = '';
            continue;
          }
          current += ch;
        }
        if (current.trim()) { out.push(current.trim()); }
        return out;
      }

      // What a shorthand actually sets, asked of the engine rather than
      // guessed from a table that would go stale. This is what lets the panel
      // strike through only the sides of a `margin` that lost.
      const longhandCache = new Map();
      let scratch = null;

      function longhandsFor(name, value) {
        if (name.indexOf('--') === 0) { return [name]; }
        const key = name + '|' + value;
        const cached = longhandCache.get(key);
        if (cached) { return cached; }
        // Detached, so it never enters the document and the page's own
        // MutationObserver never sees it.
        if (!scratch) { scratch = document.createElement('div'); }
        scratch.style.cssText = '';
        try { scratch.style.setProperty(name, value); } catch (e) { /* unknown property */ }
        const out = [];
        for (let i = 0; i < scratch.style.length; i++) { out.push(scratch.style.item(i)); }
        const result = out.length ? out : [name];
        longhandCache.set(key, result);
        return result;
      }

      function readDeclarations(style, node) {
        const out = [];
        if (!style) { return out; }
        // The authored names in authored order, taken from `cssText` — walking
        // the indexed list instead would report four `margin-*` longhands for
        // a `margin` nobody wrote.
        const seen = new Set();
        const pieces = splitDeclarations(style.cssText || '');
        for (let i = 0; i < pieces.length; i++) {
          const colon = pieces[i].indexOf(':');
          if (colon < 0) { continue; }
          const name = pieces[i].slice(0, colon).trim();
          if (!name || seen.has(name)) { continue; }
          seen.add(name);
          let value = style.getPropertyValue(name);
          if (value === '' && name.indexOf('--') !== 0) {
            value = pieces[i].slice(colon + 1).replace('!important', '').trim();
          }
          if (value.length > MAX_VALUE) { value = value.slice(0, MAX_VALUE) + '…'; }
          const entry = {
            name: name,
            value: value,
            important: style.getPropertyPriority(name) === 'important',
            longhands: longhandsFor(name, value)
          };
          // Carried only when there is one, so an ordinary declaration costs
          // nothing extra on the wire.
          const segments = colorSegments(value, node, 0);
          if (segments.some(function (s) { return !!s.rgba; })) { entry.segments = segments; }
          out.push(entry);
        }
        return out;
      }

      function sheetLabel(sheet) {
        if (!sheet) { return '<style>'; }
        if (!sheet.href) { return sheet.ownerNode && sheet.ownerNode.nodeName === 'STYLE'
          ? '<style>' : 'inline'; }
        try {
          const url = new URL(sheet.href);
          const parts = url.pathname.split('/');
          return parts[parts.length - 1] || url.hostname;
        } catch (e) {
          return sheet.href;
        }
      }

      /// Resolves a nested rule's selector against its parent, the way the
      /// nesting spec says to. Without this, CSS nesting reads as a pile of
      /// selectors starting with `&` that match nothing at all.
      function resolveNested(selector, parent) {
        if (!parent) { return selector; }
        const scope = ':is(' + parent + ')';
        if (selector.indexOf('&') >= 0) { return selector.split('&').join(scope); }
        return scope + ' ' + selector;
      }

      function matchedStyles(node) {
        if (!node || node.nodeType !== 1) { return { rules: [], layers: [] }; }

        const chain = [node];
        let cursor = node.parentElement;
        while (cursor && chain.length <= MAX_ANCESTORS) {
          chain.push(cursor);
          cursor = cursor.parentElement;
        }

        const rules = [];
        const layers = [];
        const unreadable = [];
        let order = 0;

        function noteLayer(name) {
          if (name && layers.indexOf(name) < 0) { layers.push(name); }
        }

        function visitStyleRule(rule, context) {
          if (rules.length >= MAX_RULES) { return; }
          const declarations = readDeclarations(rule.style, chain[0]);
          const position = order++;
          if (!declarations.length) { return; }

          const selectorText = resolveNested(rule.selectorText || '', context.parent);
          const branches = selectorText.split(',');
          // Reassembled so a `,` inside :is() doesn't produce broken branches.
          const list = [];
          let buffer = '';
          let depth = 0;
          for (let i = 0; i < branches.length; i++) {
            buffer = buffer ? buffer + ',' + branches[i] : branches[i];
            for (let c = 0; c < branches[i].length; c++) {
              const ch = branches[i][c];
              if (ch === '(' || ch === '[') { depth++; }
              else if (ch === ')' || ch === ']') { depth = Math.max(0, depth - 1); }
            }
            if (depth === 0) { list.push(buffer.trim()); buffer = ''; }
          }
          if (buffer.trim()) { list.push(buffer.trim()); }

          for (let d = 0; d < chain.length; d++) {
            const target = chain[d];
            for (let i = 0; i < list.length; i++) {
              const parsed = analyseSelector(list[i]);
              let hit = false;
              try { hit = target.matches(parsed.clean); } catch (e) { hit = false; }
              if (!hit) { continue; }
              rules.push({
                id: idForRule(rule),
                selector: selectorText,
                matched: list[i],
                origin: 'author',
                layer: context.layer || '',
                conditions: context.conditions,
                href: (rule.parentStyleSheet && rule.parentStyleSheet.href) || '',
                label: context.label,
                order: position,
                declarations: declarations,
                pseudo: parsed.pseudo || '',
                states: parsed.states,
                inline: false,
                distance: d,
                from: d > 0 ? describe(target) : '',
                recovered: !!context.recovered
              });
              // One hit per element is enough; the heaviest branch is what
              // decides the fight and `calculate` already takes the maximum.
              break;
            }
          }
        }

        function walk(list, context) {
          for (let i = 0; i < list.length; i++) {
            const rule = list[i];
            const name = (rule.constructor && rule.constructor.name) || '';

            if (rule.selectorText !== undefined && rule.style) {
              visitStyleRule(rule, context);
              // CSS nesting: a style rule can contain more style rules.
              if (rule.cssRules && rule.cssRules.length) {
                const nested = Object.assign({}, context);
                nested.parent = resolveNested(rule.selectorText, context.parent);
                walk(rule.cssRules, nested);
              }
              continue;
            }

            if (name === 'CSSLayerStatementRule') {
              const names = rule.nameList || [];
              for (let n = 0; n < names.length; n++) { noteLayer(names[n]); }
              continue;
            }

            if (!rule.cssRules) { continue; }

            const next = Object.assign({}, context);
            next.conditions = context.conditions.slice();

            if (name === 'CSSLayerBlockRule') {
              const layerName = rule.name || '';
              next.layer = context.layer && layerName
                ? context.layer + '.' + layerName
                : (layerName || context.layer);
              noteLayer(next.layer);
            } else if (rule.media && rule.media.mediaText) {
              next.conditions.push('@media ' + rule.media.mediaText);
            } else if (name === 'CSSContainerRule') {
              next.conditions.push('@container ' + (rule.containerQuery || rule.conditionText || ''));
            } else if (rule.conditionText !== undefined) {
              next.conditions.push('@supports ' + rule.conditionText);
            } else if (name === 'CSSScopeRule') {
              next.conditions.push('@scope');
            }
            walk(rule.cssRules, next);
          }
        }

        const sheets = document.styleSheets || [];
        for (let s = 0; s < sheets.length; s++) {
          const sheet = sheets[s];
          if (sheet.disabled) { continue; }
          let list = null;
          try {
            list = sheet.cssRules;
          } catch (e) {
            // Cross-origin. The page is forbidden to read it, and every
            // JS-based inspector therefore shows nothing — indistinguishable
            // from the sheet having no rules for this element.
            const recovered = sheet.href && recoveredSheets.get(sheet.href);
            if (recovered) {
              // Walked in place, so its rules take the document order they
              // actually have — a recovered sheet appended at the end would
              // cascade as though it were the last stylesheet on the page.
              walk(recovered.cssRules, {
                conditions: [], layer: '', label: sheetLabel(sheet),
                parent: null, recovered: true
              });
              continue;
            }
            if (sheet.href) { unreadable.push(sheet.href); }
            continue;
          }
          if (!list) { continue; }
          walk(list, {
            conditions: [], layer: '', label: sheetLabel(sheet), parent: null, recovered: false
          });
        }

        // The style attribute, which behaves as a final layer of its own.
        const inline = readDeclarations(node.style, node);
        if (inline.length) {
          rules.push({
            // Negative, so an inline block can never collide with a rule id.
            id: -idFor(node),
            selector: 'style attribute', matched: '', origin: 'author',
            layer: '', conditions: [], href: '', label: 'element',
            order: order + 1, declarations: inline,
            pseudo: '', states: [], inline: true, distance: 0, from: '', recovered: false
          });
        }

        // Every custom property the element can see, resolved. Chrome shows a
        // resolved value on hover; none of them tells you where it was set,
        // which is the actual question when a token doesn't take effect.
        const variables = {};
        const computed = getComputedStyle(node);
        for (let i = 0; i < rules.length; i++) {
          const declarations = rules[i].declarations;
          for (let d = 0; d < declarations.length; d++) {
            const name = declarations[d].name;
            if (name.indexOf('--') !== 0 || variables[name] !== undefined) { continue; }
            variables[name] = (computed.getPropertyValue(name) || '').trim();
          }
        }

        return {
          rules: rules, layers: layers, unreadable: unreadable, variables: variables
        };
      }

      function describe(element) {
        let text = element.nodeName.toLowerCase();
        if (element.id) { text += '#' + element.id; }
        else if (element.classList && element.classList.length) {
          text += '.' + element.classList[0];
        }
        return text;
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

              case 'DOM.pathToNode': {
                // Where a node lives, root first, excluding the node itself.
                //
                // Picking hands back an id minted on the spot for whatever was
                // under the pointer, and the panel has very likely never
                // fetched that subtree — so it cannot work out the ancestry on
                // its own. Only the page knows.
                const target = nodeFor(params && params.nodeId);
                if (!target) { return JSON.stringify({ path: [] }); }
                const path = [];
                let cursor = target.parentNode || (target.getRootNode && target.getRootNode().host);
                let depth = 0;
                while (cursor && depth < 500) {
                  if (cursor.nodeType === 9) { break; }
                  path.push(idFor(cursor));
                  cursor = cursor.parentNode
                    || (cursor.getRootNode && cursor.getRootNode() !== cursor
                        ? cursor.getRootNode().host
                        : null);
                  depth++;
                }
                path.reverse();
                return JSON.stringify({ path: path });
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

              case 'CSS.getMatchedStyles': {
                const node = nodeFor(params && params.nodeId);
                return JSON.stringify(matchedStyles(node));
              }

              case 'CSS.addRecoveredSheet': {
                const href = params && params.href;
                const text = (params && params.text) || '';
                if (!href) { return JSON.stringify({ error: 'no href' }); }
                if (typeof CSSStyleSheet !== 'function') {
                  return JSON.stringify({ error: 'constructable stylesheets unavailable' });
                }
                const sheet = new CSSStyleSheet();
                // Synchronous, and deliberately never adopted: this parses the
                // text so its rules can be read, and must not restyle the page.
                sheet.replaceSync(text);
                recoveredSheets.set(href, sheet);
                return JSON.stringify({ ok: true, rules: sheet.cssRules.length });
              }

              case 'CSS.getComputedStyleForNode': {
                const node = nodeFor(params && params.nodeId);
                if (!node || node.nodeType !== 1) { return JSON.stringify({ computed: {} }); }
                const style = getComputedStyle(node);
                const out = {};
                const colors = {};
                for (let i = 0; i < style.length; i++) {
                  const name = style.item(i);
                  const value = style.getPropertyValue(name);
                  out[name] = value;
                  // Computed colours always come back as rgb()/rgba(), so this
                  // prefilter costs nothing and skips the other three hundred.
                  if (value.indexOf('rgb') === 0 || value.indexOf('#') === 0
                      || value.indexOf('color(') === 0) {
                    const rgba = resolveColor(value, node);
                    if (rgba) { colors[name] = rgba; }
                  }
                }
                return JSON.stringify({ computed: out, colors: colors });
              }

              case 'CSS.setRuleText': {
                const text = (params && params.text) || '';
                if (params && params.nodeId !== undefined) {
                  const node = nodeFor(params.nodeId);
                  if (!node || !node.style) { return JSON.stringify({ error: 'no element' }); }
                  const key = 'node:' + params.nodeId;
                  if (!ruleOriginals.has(key)) {
                    ruleOriginals.set(key, node.style.cssText || '');
                  }
                  selfStyleEdits.add(node);
                  return JSON.stringify(applyStyleText(node.style, text, key));
                }
                const rule = ruleFor(params && params.ruleId);
                if (!rule || !rule.style) { return JSON.stringify({ error: 'no rule' }); }
                const key = 'rule:' + params.ruleId;
                if (!ruleOriginals.has(key)) {
                  ruleOriginals.set(key, rule.style.cssText || '');
                }
                return JSON.stringify(applyStyleText(rule.style, text, key));
              }

              case 'CSS.revert': {
                const key = (params && params.nodeId !== undefined)
                  ? 'node:' + params.nodeId
                  : 'rule:' + (params && params.ruleId);
                if (!ruleOriginals.has(key)) { return JSON.stringify({ ok: true }); }
                const original = ruleOriginals.get(key);
                ruleOriginals.delete(key);
                if (params && params.nodeId !== undefined) {
                  const node = nodeFor(params.nodeId);
                  if (!node || !node.style) { return JSON.stringify({ error: 'no element' }); }
                  selfStyleEdits.add(node);
                  return JSON.stringify(applyStyleText(node.style, original, key));
                }
                const rule = ruleFor(params.ruleId);
                if (!rule || !rule.style) { return JSON.stringify({ error: 'no rule' }); }
                return JSON.stringify(applyStyleText(rule.style, original, key));
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
