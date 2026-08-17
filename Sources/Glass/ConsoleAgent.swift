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

    static let eventHandlerName = "glassDevToolsConsole"

    /// Runs in the page world, where `__glassConsole` lives.
    static let dispatchScript = """
    if (!globalThis.__glassConsole) { return null; }
    return globalThis.__glassConsole.dispatch(method, params);
    """

    static let script = """
    (function () {
      if (globalThis.__glassConsole) { return; }

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
            return { type: 'function', className: 'Function', description: prefix + name };
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
            className: classNameOf(value), description: nodeDescription(value)
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
          if (!shallow) { out.preview = mapPreview(value); }
          return out;
        }
        if (typeof Set !== 'undefined' && value instanceof Set) {
          const out = { type: 'object', subtype: 'set', className: 'Set',
                        description: 'Set(' + value.size + ')' };
          if (!shallow) { out.preview = setPreview(value); }
          return out;
        }
        if (Array.isArray(value)) {
          const out = { type: 'object', subtype: 'array', className: 'Array',
                        description: 'Array(' + value.length + ')' };
          if (!shallow) { out.preview = arrayPreview(value); }
          return out;
        }
        const name = classNameOf(value);
        const out = { type: 'object', className: name, description: name };
        if (!shallow) { out.preview = objectPreview(value); }
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
      function __glassSource(url, line, column) {
        if (!url || typeof url !== 'string') { return false; }
        if (!/^[a-z]+:/i.test(url)) { return false; }
        if (url.indexOf('user-script') === 0) { return false; }
        return { url: url, line: line || 0, column: column || 0 };
      }

      function __glassCaller() {
        try {
          const lines = (new Error().stack || '').split('\\n');
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line) { continue; }
            // Every function of ours on the stack is named __glass* so it can
            // be skipped here.
            if (line.indexOf('__glass') !== -1) { continue; }
            const match = /^(?:(.*?)@)?(.+?):(\\d+):(\\d+)$/.exec(line);
            if (!match) { continue; }
            const source = __glassSource(match[2], +match[3], +match[4]);
            if (source) { return source; }
          }
        } catch (e) {}
        return null;
      }

      // ---- Recording -------------------------------------------------------

      function __glassRecord(level, args, source) {
        const entry = {
          level: level,
          args: Array.prototype.map.call(args, function (a) { return describe(a, false); }),
          // `false` means the caller genuinely has no useful location — a
          // failed image, a rejected promise — as distinct from not having
          // looked yet. Walking the stack there would only find our own
          // listener.
          source: (source === false) ? null : (source || __glassCaller()),
          groupDepth: groupDepth,
          timestamp: Date.now(),
          frame: frame
        };

        if (live) {
          __glassEnqueue(entry);
          return;
        }
        backlog.push(entry);
        if (backlog.length > BACKLOG_CAP) { backlog.shift(); }
      }

      function __glassEnqueue(entry) {
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
        console[name] = function __glassLog() {
          try { __glassRecord(level, arguments); } catch (e) {}
          // Always forwarded: Safari's Web Inspector can attach to this page
          // too, and swallowing the call would blind it.
          return native[name].apply(console, arguments);
        };
      });

      console.group = function __glassLog() {
        try { __glassRecord('log', arguments); groupDepth++; } catch (e) {}
        return native.group.apply(console, arguments);
      };
      console.groupCollapsed = function __glassLog() {
        try { __glassRecord('log', arguments); groupDepth++; } catch (e) {}
        return native.groupCollapsed.apply(console, arguments);
      };
      console.groupEnd = function __glassLog() {
        // Clamped: an unmatched groupEnd must not indent the rest of the log
        // backwards off the left edge.
        groupDepth = Math.max(0, groupDepth - 1);
        return native.groupEnd.apply(console, arguments);
      };

      console.assert = function __glassLog(condition) {
        try {
          if (!condition) {
            const rest = Array.prototype.slice.call(arguments, 1);
            __glassRecord('error', rest.length ? rest : ['Assertion failed']);
          }
        } catch (e) {}
        return native.assert.apply(console, arguments);
      };

      console.clear = function __glassLog() {
        backlog = [];
        pending = [];
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
            __glassRecord('error', ['Failed to load ' + target.tagName.toLowerCase() + ': ' + url], false);
            return;
          }
          // Prefer the error object (its stack is the useful part), but fall
          // back when it serializes to nothing — a script from an opaque
          // origin yields an Error whose stack is empty.
          let reported = event.error;
          if (!reported || !String(describe(reported, true).description || '').trim()) {
            reported = event.message || 'Script error';
          }
          __glassRecord(
            'error',
            [reported],
            __glassSource(event.filename, event.lineno, event.colno)
          );
        } catch (e) {}
      }, true);

      window.addEventListener('unhandledrejection', function (event) {
        try { __glassRecord('error', ['Unhandled promise rejection:', event.reason], false); } catch (e) {}
      });

      window.addEventListener('securitypolicyviolation', function (event) {
        try {
          __glassRecord('error', [
            'Content Security Policy blocked ' + (event.blockedURI || 'a resource') +
            ' (' + event.violatedDirective + ')'
          ], __glassSource(event.sourceFile, event.lineNumber, event.columnNumber));
        } catch (e) {}
      });

      globalThis.__glassConsole = {
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
                if (!live) { pending = []; }
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
