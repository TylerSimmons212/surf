import WebKit

/// Console capture: the half that lives in the page.
///
/// Injected into the **page world**, unlike the inspection agent, and for a
/// reason that isn't negotiable — this exists to replace `console.log` and the
/// page's error handlers, which an isolated world's separate globals would
/// leave untouched.
///
/// Installed on **every tab, always**, which is the interesting decision. The
/// alternative — inject on attach — means opening dev tools shows an empty
/// console until you reload, and the log you actually wanted was the one from
/// startup. So capture runs from document-start into a small in-page ring
/// buffer and **posts nothing at all** until dev tools attach: no message
/// handler, no process-boundary crossing, nothing to pay for on the thousands
/// of pages nobody ever inspects.
///
/// The other half of making that safe is that unattached capture serializes
/// each argument immediately and drops the reference. Retaining live objects
/// for a console nobody has opened would turn every page visit into a leak, and
/// would change when the page's own garbage collector runs — a correctness
/// problem, not merely a size one.
enum ConsoleAgent {

    static let eventHandlerName = "surfDevToolsConsole"

    /// Runs in the page world, where `__surfConsole` lives.
    static let dispatchScript = """
    if (!globalThis.__surfConsole) { return null; }
    return globalThis.__surfConsole.dispatch(method, params);
    """

    static let script = """
    (function () {
      if (globalThis.__surfConsole) { return; }

      const HANDLER = '\(eventHandlerName)';
      // Deep enough to hold a page's startup chatter, small enough to be free.
      const BACKLOG_CAP = 200;
      const BATCH_CAP = 50;
      // How many unacknowledged batches may be in flight before the agent stops
      // emitting. Without this, a page logging faster than our main thread can
      // apply batches wins the race and the UI stops responding.
      const ACK_WINDOW = 8;
      const PENDING_CAP = 2000;
      const MAX_STRING = 2000;
      const MAX_PREVIEW = 5;

      let live = false;
      let backlog = [];
      let pending = [];
      let sequence = 0;
      let lastAck = 0;
      let scheduled = false;
      let groupDepth = 0;
      // Counted rather than merely flagged: "some messages were dropped" is a
      // shrug, "4,000 messages were dropped" is a diagnosis.
      let dropped = 0;

      // Empty for the main frame; an iframe's logs are worth attributing.
      const frame = (window === window.top) ? '' : location.href;

      // Handles for values the panel can ask to expand. Only ever populated
      // while attached: retaining page objects for a console nobody opened
      // would be a leak, and would keep alive exactly the objects someone is
      // trying to watch get collected.
      const objects = new Map();
      let nextObjectId = 1;
      // Bounded so a chatty page can't pin unbounded memory. Eviction is
      // oldest-first, and Swift releases ids as rows scroll out anyway.
      const OBJECT_CAP = 5000;

      function retain(value) {
        if (!live) { return undefined; }
        const id = 'o' + (nextObjectId++);
        objects.set(id, value);
        if (objects.size > OBJECT_CAP) {
          const oldest = objects.keys().next();
          if (!oldest.done) { objects.delete(oldest.value); }
        }
        return id;
      }

      function post(payload) {
        try {
          window.webkit.messageHandlers[HANDLER].postMessage(payload);
        } catch (e) {
          // The handler is removed on detach while this document lives on.
          // Falling back to buffering is exactly right.
          live = false;
        }
      }

      // ---- Serialization -------------------------------------------------

      function truncate(text) {
        return text.length > MAX_STRING ? text.slice(0, MAX_STRING) + '…' : text;
      }

      function classNameOf(value) {
        try {
          return (value.constructor && value.constructor.name) || 'Object';
        } catch (e) {
          // A null-prototype object has no constructor to ask.
          return 'Object';
        }
      }

      function nodeDescription(node) {
        try {
          if (node.nodeType === 3) { return '#text "' + (node.nodeValue || '').trim() + '"'; }
          if (node.nodeType === 8) { return '<!-- ' + (node.nodeValue || '') + ' -->'; }
          if (node.nodeType === 9) { return '#document'; }
          let text = '<' + node.nodeName.toLowerCase();
          if (node.id) { text += '#' + node.id; }
          if (node.classList && node.classList.length) {
            text += '.' + Array.prototype.join.call(node.classList, '.');
          }
          return text + '>';
        } catch (e) {
          return '<node>';
        }
      }

      /// `shallow` suppresses the nested preview, so a preview is one level
      /// deep by construction and can't recurse into a cyclic graph.
      function describe(value, shallow) {
        try {
          if (value === null) { return { type: 'object', subtype: 'null', description: 'null' }; }
          const t = typeof value;
          if (t === 'undefined') { return { type: 'undefined', description: 'undefined' }; }
          if (t === 'string') { return { type: 'string', description: truncate(value) }; }
          if (t === 'boolean') { return { type: 'boolean', description: String(value) }; }
          if (t === 'bigint') { return { type: 'bigint', description: String(value) + 'n' }; }
          if (t === 'symbol') { return { type: 'symbol', description: String(value) }; }
          if (t === 'number') {
            // -0 prints as "0" via String(), and the distinction is precisely
            // the sort of thing someone opens a console to chase down.
            return { type: 'number', description: Object.is(value, -0) ? '-0' : String(value) };
          }
          if (t === 'function') {
            const name = value.name || '(anonymous)';
            let prefix = 'ƒ ';
            try {
              if (Function.prototype.toString.call(value).indexOf('class') === 0) {
                prefix = 'class ';
              }
            } catch (e) {}
            return {
              type: 'function', className: 'Function', description: prefix + name,
              objectId: shallow ? undefined : retain(value)
            };
          }
          return describeObject(value, shallow);
        } catch (e) {
          return { type: 'object', description: '<unserializable>' };
        }
      }

      function describeObject(value, shallow) {
        if (typeof Node !== 'undefined' && value instanceof Node) {
          return {
            type: 'object', subtype: 'node',
            className: classNameOf(value), description: nodeDescription(value),
            objectId: shallow ? undefined : retain(value)
          };
        }
        if (value instanceof Error) {
          // WebKit's `stack` — unlike V8's — does not begin with the
          // "TypeError: x is not a function" header, so using it alone drops
          // the single most useful line in the whole log. Compose both.
          let headline = '';
          try {
            headline = (value.name || 'Error') + (value.message ? ': ' + value.message : '');
          } catch (e) {
            headline = 'Error';
          }
          let trace = '';
          try { trace = value.stack || ''; } catch (e) {}
          // Some engines and polyfilled errors *do* include the header; don't
          // print it twice.
          if (trace && trace.indexOf(headline) === 0) { headline = ''; }
          return {
            type: 'object', subtype: 'error', className: classNameOf(value),
            description: truncate(headline && trace ? headline + '\\n' + trace : (headline || trace))
          };
        }
        if (value instanceof Date) {
          return { type: 'object', subtype: 'date', className: 'Date',
                   description: value.toISOString() };
        }
        if (value instanceof RegExp) {
          return { type: 'object', subtype: 'regexp', className: 'RegExp',
                   description: String(value) };
        }
        if (typeof Promise !== 'undefined' && value instanceof Promise) {
          return { type: 'object', subtype: 'promise', className: 'Promise',
                   description: 'Promise' };
        }
        if (typeof Map !== 'undefined' && value instanceof Map) {
          const out = { type: 'object', subtype: 'map', className: 'Map',
                        description: 'Map(' + value.size + ')' };
          if (!shallow) { out.preview = mapPreview(value); out.objectId = retain(value); }
          return out;
        }
        if (typeof Set !== 'undefined' && value instanceof Set) {
          const out = { type: 'object', subtype: 'set', className: 'Set',
                        description: 'Set(' + value.size + ')' };
          if (!shallow) { out.preview = setPreview(value); out.objectId = retain(value); }
          return out;
        }
        if (Array.isArray(value)) {
          const out = { type: 'object', subtype: 'array', className: 'Array',
                        description: 'Array(' + value.length + ')' };
          if (!shallow) { out.preview = arrayPreview(value); out.objectId = retain(value); }
          return out;
        }
        const name = classNameOf(value);
        const out = { type: 'object', className: name, description: name };
        if (!shallow) { out.preview = objectPreview(value); out.objectId = retain(value); }
        return out;
      }

      /// Reads a property *without* invoking an accessor.
      ///
      /// Running a getter would execute page code as a side effect of logging,
      /// which can mutate the very state being inspected. Chrome shows getters
      /// unevaluated for the same reason; so do we.
      function previewValue(target, key) {
        try {
          const descriptor = Object.getOwnPropertyDescriptor(target, key);
          if (descriptor && typeof descriptor.get === 'function') {
            return { type: 'object', description: '(…)' };
          }
          return describe(descriptor ? descriptor.value : target[key], true);
        } catch (e) {
          return { type: 'object', description: '<throws>' };
        }
      }

      function objectPreview(value) {
        let keys = [];
        try { keys = Object.keys(value); } catch (e) {}
        const shown = keys.slice(0, MAX_PREVIEW);
        return {
          entries: shown.map(function (key) {
            return { key: key, value: previewValue(value, key) };
          }),
          overflow: keys.length > shown.length
        };
      }

      function arrayPreview(value) {
        const shown = Math.min(value.length, MAX_PREVIEW);
        const entries = [];
        for (let i = 0; i < shown; i++) { entries.push({ value: previewValue(value, i) }); }
        return { entries: entries, overflow: value.length > shown };
      }

      function mapPreview(value) {
        const entries = [];
        try {
          for (const pair of value) {
            if (entries.length >= MAX_PREVIEW) { break; }
            entries.push({ key: describe(pair[0], true).description, value: describe(pair[1], true) });
          }
        } catch (e) {}
        return { entries: entries, overflow: value.size > entries.length };
      }

      function setPreview(value) {
        const entries = [];
        try {
          for (const item of value) {
            if (entries.length >= MAX_PREVIEW) { break; }
            entries.push({ value: describe(item, true) });
          }
        } catch (e) {}
        return { entries: entries, overflow: value.size > entries.length };
      }

      // ---- Where the log came from ---------------------------------------

      /// A location is only worth showing if its URL is a real one. WebKit
      /// hands out `user-script`, `[native code]` and the literal string
      /// "undefined" in various corners, and a confidently wrong file:line is
      /// worse than an honest blank.
      function __surfSource(url, line, column) {
        if (!url || typeof url !== 'string') { return false; }
        if (!/^[a-z]+:/i.test(url)) { return false; }
        if (url.indexOf('user-script') === 0) { return false; }
        return { url: url, line: line || 0, column: column || 0 };
      }

      function __surfCaller() {
        try {
          const lines = (new Error().stack || '').split('\\n');
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line) { continue; }
            // Every function of ours on the stack is named __surf* so it can
            // be skipped here.
            if (line.indexOf('__surf') !== -1) { continue; }
            const match = /^(?:(.*?)@)?(.+?):(\\d+):(\\d+)$/.exec(line);
            if (!match) { continue; }
            const source = __surfSource(match[2], +match[3], +match[4]);
            if (source) { return source; }
          }
        } catch (e) {}
        return null;
      }

      // ---- Recording -------------------------------------------------------

      function __surfRecord(level, args, source) {
        const entry = {
          level: level,
          args: Array.prototype.map.call(args, function (a) { return describe(a, false); }),
          // `false` means the caller genuinely has no useful location — a
          // failed image, a rejected promise — as distinct from not having
          // looked yet. Walking the stack there would only find our own
          // listener.
          source: (source === false) ? null : (source || __surfCaller()),
          groupDepth: groupDepth,
          timestamp: Date.now(),
          frame: frame
        };

        if (live) {
          __surfEnqueue(entry);
          return;
        }
        backlog.push(entry);
        if (backlog.length > BACKLOG_CAP) { backlog.shift(); }
      }

      function __surfEnqueue(entry) {
        pending.push(entry);
        // A ring rather than a dump. A synchronous loop of ten thousand logs
        // is one JS turn, so nothing can be sent during it and the queue must
        // be bounded somehow — but the newest output is the output someone is
        // looking at, so that is what survives. Discarding the whole queue
        // would throw away the end of the flood along with the start.
        while (pending.length > PENDING_CAP) {
          pending.shift();
          dropped++;
        }
        schedule();
      }

      function schedule() {
        if (scheduled || !pending.length) { return; }
        if (sequence - lastAck >= ACK_WINDOW) { return; }
        scheduled = true;
        const run = function () { scheduled = false; flush(); };
        // rAF coalesces to one batch per frame, which alone handles the common
        // case — but it doesn't fire in a hidden document, and a background tab
        // still logs.
        if (typeof requestAnimationFrame === 'function' && !document.hidden) {
          requestAnimationFrame(run);
        } else {
          setTimeout(run, 16);
        }
      }

      function flush() {
        if (!pending.length || sequence - lastAck >= ACK_WINDOW) { return; }
        const batch = pending.splice(0, BATCH_CAP);
        sequence += 1;
        post({ event: 'console', entries: batch, sequence: sequence, dropped: dropped });
        dropped = 0;
        schedule();
      }

      // ---- Patching --------------------------------------------------------

      const native = {};
      const LEVELS = {
        log: 'log', info: 'info', warn: 'warning', error: 'error',
        debug: 'debug', trace: 'log', dir: 'log', dirxml: 'log', table: 'log'
      };

      Object.keys(LEVELS).concat([
        'group', 'groupCollapsed', 'groupEnd', 'assert', 'clear'
      ]).forEach(function (name) {
        native[name] = (console && typeof console[name] === 'function')
          ? console[name].bind(console)
          : function () {};
      });

      Object.keys(LEVELS).forEach(function (name) {
        const level = LEVELS[name];
        console[name] = function __surfLog() {
          try { __surfRecord(level, arguments); } catch (e) {}
          // Always forwarded: Safari's Web Inspector can attach to this page
          // too, and swallowing the call would blind it.
          return native[name].apply(console, arguments);
        };
      });

      console.group = function __surfLog() {
        try { __surfRecord('log', arguments); groupDepth++; } catch (e) {}
        return native.group.apply(console, arguments);
      };
      console.groupCollapsed = function __surfLog() {
        try { __surfRecord('log', arguments); groupDepth++; } catch (e) {}
        return native.groupCollapsed.apply(console, arguments);
      };
      console.groupEnd = function __surfLog() {
        // Clamped: an unmatched groupEnd must not indent the rest of the log
        // backwards off the left edge.
        groupDepth = Math.max(0, groupDepth - 1);
        return native.groupEnd.apply(console, arguments);
      };

      console.assert = function __surfLog(condition) {
        try {
          if (!condition) {
            const rest = Array.prototype.slice.call(arguments, 1);
            __surfRecord('error', rest.length ? rest : ['Assertion failed']);
          }
        } catch (e) {}
        return native.assert.apply(console, arguments);
      };

      console.clear = function __surfLog() {
        backlog = [];
        pending = [];
        objects.clear();
        try { post({ event: 'cleared' }); } catch (e) {}
        return native.clear.apply(console, arguments);
      };

      // ---- Failures the page doesn't report itself -------------------------

      // Capture phase, because resource load failures (a 404 <img>, a dead
      // <script>) don't bubble and window.onerror never sees them.
      window.addEventListener('error', function (event) {
        try {
          const target = event.target;
          if (target && target !== window && target.tagName) {
            const url = target.src || target.href || '';
            __surfRecord('error', ['Failed to load ' + target.tagName.toLowerCase() + ': ' + url], false);
            return;
          }
          // Prefer the error object (its stack is the useful part), but fall
          // back when it serializes to nothing — a script from an opaque
          // origin yields an Error whose stack is empty.
          let reported = event.error;
          if (!reported || !String(describe(reported, true).description || '').trim()) {
            reported = event.message || 'Script error';
          }
          __surfRecord(
            'error',
            [reported],
            __surfSource(event.filename, event.lineno, event.colno)
          );
        } catch (e) {}
      }, true);

      window.addEventListener('unhandledrejection', function (event) {
        try { __surfRecord('error', ['Unhandled promise rejection:', event.reason], false); } catch (e) {}
      });

      window.addEventListener('securitypolicyviolation', function (event) {
        try {
          __surfRecord('error', [
            'Content Security Policy blocked ' + (event.blockedURI || 'a resource') +
            ' (' + event.violatedDirective + ')'
          ], __surfSource(event.sourceFile, event.lineNumber, event.columnNumber));
        } catch (e) {}
      });

      // ---- Evaluation and expansion ---------------------------------------

      /// Runs what someone typed at the prompt.
      ///
      /// An *indirect* eval — `(0, eval)` rather than `eval` — so the code runs
      /// in global scope rather than in this closure. That is what makes
      /// `var x = 1` still be there on the next line, and it keeps the agent's
      /// own locals out of reach of anything typed.
      function __surfEvaluate(params) {
        const src = (params && params.source) || '';
        const shouldAwait = !!(params && params.usesAwait);
        if (!src) { return JSON.stringify({ value: describe(undefined, false) }); }

        let value;
        try {
          value = (0, eval)(src);
        } catch (e) {
          return JSON.stringify({ thrown: true, value: describe(e, false) });
        }

        if (!shouldAwait || !value || typeof value.then !== 'function') {
          return JSON.stringify({ value: describe(value, false) });
        }
        // A promise is returned to Swift as a promise: `callAsyncJavaScript`
        // awaits it for us, so a rejection still arrives as a value we can
        // describe rather than as an opaque WebKit error.
        return value.then(
          function (resolved) { return JSON.stringify({ value: describe(resolved, false) }); },
          function (reason) { return JSON.stringify({ thrown: true, value: describe(reason, false) }); }
        );
      }

      /// One level of an object, fetched only when someone opens it.
      ///
      /// Sending this eagerly with every log would be ruinous — a single DOM
      /// node has hundreds of properties — which is the whole reason values
      /// travel as handles rather than as trees.
      /// How a property's *value* is described.
      ///
      /// Deliberately not the same as a logged value. Building a full preview
      /// for every property means describing five sub-values each, three
      /// hundred times over — and `innerHTML`, `outerHTML` and `textContent`
      /// each materialise the whole document as a string before it can even be
      /// truncated. On a real page that is the difference between instant and
      /// "Reading…" for several seconds.
      ///
      /// So: no preview, and a short cap. Opening the property shows the rest.
      function describeProperty(value) {
        if (typeof value === 'string') {
          const capped = value.length > 180 ? value.slice(0, 180) + '…' : value;
          return { type: 'string', description: capped };
        }
        const described = describe(value, true);
        // Shallow suppresses the objectId too, but a property still has to be
        // openable — so mint one here for the things worth opening.
        if (described.type === 'object' || described.type === 'function') {
          if (described.subtype !== 'null' && value !== null && value !== undefined) {
            described.objectId = retain(value);
          }
        }
        return described;
      }

      function __surfProperties(objectId, offset, limit) {
        // Returned as `{ items, total }` rather than an array carrying a stray
        // property: `JSON.stringify` serialises an array as an array and drops
        // anything hung off it, so the real count silently became the page
        // size and the "show more" affordance never appeared.
        const target = objects.get(objectId);
        if (target === undefined) { return { items: [], total: 0 }; }
        const start = offset || 0;
        const max = limit || 100;
        let totalNames = 0;

        const out = [];
        try {
          if (typeof Map !== 'undefined' && target instanceof Map) {
            let index = 0;
            for (const pair of target) {
              if (index++ < start) { continue; }
              out.push({
                name: String(describe(pair[0], true).description),
                value: describeProperty(pair[1])
              });
              if (out.length >= max) { break; }
            }
            return { items: out, total: target.size };
          }
          if (typeof Set !== 'undefined' && target instanceof Set) {
            let index = 0;
            for (const item of target) {
              const at = index++;
              if (at < start) { continue; }
              out.push({ name: String(at), value: describeProperty(item) });
              if (out.length >= max) { break; }
            }
            return { items: out, total: target.size };
          }

          // Own properties first, then inherited ones.
          //
          // The prototype walk is not optional: a DOM element has almost no own
          // properties — `id`, `className`, `children` and the rest all live on
          // `HTMLElement.prototype` — so stopping at own properties makes
          // expanding a node show nothing at all.
          // Names are collected first and *then* sliced, so paging is stable
          // and the expensive part — reading values — only happens for the
          // page actually being shown.
          const seen = new Set();
          const names = [];
          let level = target;
          let depth = 0;
          while (level && depth < 4) {
            // Stop at the universal bases. `toString`, `valueOf` and
            // `hasOwnProperty` are on every object in the language and tell you
            // nothing about *this* one — listing them buries the two keys you
            // actually logged under a dozen you didn't.
            if (level === Object.prototype
                || level === Array.prototype
                || level === Function.prototype) { break; }
            const inherited = depth > 0;
            let own = [];
            try { own = Object.getOwnPropertyNames(level); } catch (e) {}

            for (let i = 0; i < own.length; i++) {
              const name = own[i];
              if (seen.has(name)) { continue; }
              seen.add(name);
              // An array's `length` is noise next to its elements, and
              // `constructor` is on everything and tells you nothing.
              if (Array.isArray(target) && name === 'length') { continue; }
              if (inherited && name === 'constructor') { continue; }
              names.push({ name: name, level: level, inherited: inherited });
            }

            try { level = Object.getPrototypeOf(level); } catch (e) { level = null; }
            depth++;
          }

          for (let n = start; n < names.length && out.length < max; n++) {
            {
              const name = names[n].name;
              const level = names[n].level;
              const inherited = names[n].inherited;

              let descriptor;
              try { descriptor = Object.getOwnPropertyDescriptor(level, name); } catch (e) {}

              if (descriptor && typeof descriptor.get === 'function') {
                // A *native* accessor — `element.id`, `node.children` — is the
                // engine reading its own state, with nothing to trigger. An
                // author-written getter is page code, and running it as a side
                // effect of looking at an object can change the very state
                // being inspected, so that one stays unevaluated.
                let isNative = false;
                try {
                  isNative = Function.prototype.toString.call(descriptor.get)
                    .indexOf('[native code]') !== -1;
                } catch (e) {}

                if (!isNative) {
                  out.push({
                    name: name, isAccessor: true, isEnumerable: !inherited,
                    value: { type: 'object', description: '(…)' }
                  });
                  continue;
                }
                let got;
                try { got = descriptor.get.call(target); } catch (e) {
                  out.push({
                    name: name, isEnumerable: false,
                    value: { type: 'object', description: '<throws>' }
                  });
                  continue;
                }
                out.push({ name: name, isEnumerable: !inherited, value: describeProperty(got) });
                continue;
              }

              let raw;
              try { raw = descriptor ? descriptor.value : level[name]; } catch (e) {
                out.push({
                  name: name, isEnumerable: false,
                  value: { type: 'object', description: '<throws>' }
                });
                continue;
              }
              out.push({
                name: name,
                // Inherited members are dimmed: real, but not what you came
                // to look at.
                isEnumerable: inherited ? false : (descriptor ? !!descriptor.enumerable : true),
                value: describeProperty(raw)
              });
            }
          }
          totalNames = names.length;
        } catch (e) {}
        return { items: out, total: Math.max(totalNames, out.length) };
      }

      /// Property names for the completion list.
      ///
      /// The base arrives already restricted to a plain dotted path, so
      /// resolving it cannot call anything. Names only — no values are read,
      /// so no getter runs either.
      function __surfCompletions(params) {
        const base = (params && params.base) || '';
        let target;
        try {
          target = base ? (0, eval)(base) : globalThis;
        } catch (e) {
          return [];
        }
        if (target === null || target === undefined) { return []; }

        const names = [];
        const seen = new Set();
        let level = target;
        // A primitive has no own properties worth listing, but its prototype
        // does — `'abc'.` should still offer `slice`.
        if (typeof level !== 'object' && typeof level !== 'function') {
          try { level = Object.getPrototypeOf(level); } catch (e) { level = null; }
        }
        let depth = 0;
        while (level && depth < 6 && names.length < 500) {
          let own = [];
          try { own = Object.getOwnPropertyNames(level); } catch (e) {}
          for (let i = 0; i < own.length; i++) {
            const name = own[i];
            if (seen.has(name)) { continue; }
            seen.add(name);
            // Only names that can actually be typed after a dot.
            if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) { continue; }
            names.push(name);
          }
          try { level = Object.getPrototypeOf(level); } catch (e) { level = null; }
          depth++;
        }
        return names;
      }

      globalThis.__surfConsole = {
        dispatch: function (method, params) {
          try {
            switch (method) {
              case 'Console.drain': {
                const entries = backlog;
                backlog = [];
                live = true;
                return JSON.stringify({ entries: entries, backlog: true });
              }
              case 'Console.setLive': {
                live = !!(params && params.live);
                if (!live) {
                  pending = [];
                  // Nothing can expand these any more, and holding them would
                  // pin page objects alive for the life of the document.
                  objects.clear();
                }
                return JSON.stringify({ ok: true });
              }
              case 'Runtime.evaluate': {
                return __surfEvaluate(params);
              }
              case 'Runtime.getProperties': {
                const offset = (params && params.offset) || 0;
                const limit = (params && params.limit) || 100;
                const reply = __surfProperties(params && params.objectId, offset, limit);
                // The real size travels with the page, so the panel can say how
                // much it is not showing rather than implying the object is
                // smaller than it is.
                return JSON.stringify({
                  properties: reply.items,
                  offset: offset,
                  total: Math.max(reply.total, offset + reply.items.length)
                });
              }
              case 'Runtime.completions': {
                return JSON.stringify({ names: __surfCompletions(params) });
              }
              case 'Runtime.releaseObject': {
                const ids = (params && params.objectIds) || [];
                for (let i = 0; i < ids.length; i++) { objects.delete(ids[i]); }
                return JSON.stringify({ ok: true });
              }
              case 'Console.ack': {
                lastAck = Math.max(lastAck, (params && params.sequence) || 0);
                schedule();
                return JSON.stringify({ ok: true });
              }
              default:
                return JSON.stringify({ error: 'unknown method: ' + method });
            }
          } catch (e) {
            return JSON.stringify({ error: String((e && e.message) || e) });
          }
        }
      };
    })();
    """
}
