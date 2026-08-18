import WebKit

/// Network capture, in the page's own world.
///
/// It has to be the page world: the only route to request headers, request
/// bodies and response bodies is replacing `fetch` and `XMLHttpRequest`, and
/// you cannot replace a page's globals from an isolated one. The DOM agent
/// stays isolated; this one cannot.
///
/// Three sources feed it, and each is authoritative about something the others
/// can't see:
///
/// * **The fetch/XHR patch** knows status, headers and method — and it is the
///   *only* source of a status code, because WebKit does not implement
///   `PerformanceResourceTiming.responseStatus`. Measured, not assumed.
/// * **Resource Timing** sees everything else — images, stylesheets, fonts,
///   scripts — with sizes and phase timings, but never a status.
/// * **The navigation delegate**, natively, owns the document row.
///
/// Installed at document-start and always running, like console capture, for
/// the same reason: the request you want to look at is usually the one that
/// already failed. It costs nothing until a panel attaches — the ring buffer
/// fills and `postMessage` is called zero times.
enum NetworkAgent {

    static let eventHandlerName = "glassNetworkEvents"

    static let dispatchScript = """
    if (!globalThis.__glassNetwork) { return null; }
    return globalThis.__glassNetwork.dispatch(method, params);
    """

    static let script = """
    (function () {
      if (globalThis.__glassNetwork) { return; }

      const HANDLER = '\(eventHandlerName)';
      const MAX_RECORDS = 400;
      const ACK_WINDOW = 8;

      let live = false;
      let sequence = 0;
      let lastAck = 0;
      let nextId = 1;
      let dropped = 0;

      // Everything seen this document, by id. Bounded, because a page polling
      // in a loop must not be able to grow this without limit just because a
      // panel might open later.
      const records = new Map();
      let pending = [];
      let scheduled = false;

      const post = (payload) => {
        try {
          window.webkit.messageHandlers[HANDLER].postMessage(payload);
        } catch (e) {
          // No handler means no panel; fall back to buffering.
          live = false;
        }
      };

      function remember(record) {
        if (!records.has(record.id) && records.size >= MAX_RECORDS) {
          // Drop the oldest, and say so rather than quietly showing a partial
          // list as though it were the whole story.
          const oldest = records.keys().next().value;
          records.delete(oldest);
          dropped += 1;
        }
        records.set(record.id, record);
      }

      function note(record) {
        remember(record);
        if (!live) { return; }
        pending.push(record);
        if (scheduled) { return; }
        scheduled = true;
        // A timer rather than rAF: network activity continues in a background
        // tab, and rAF would stop reporting exactly when a long fetch is most
        // interesting.
        setTimeout(flush, 100);
      }

      function flush() {
        scheduled = false;
        if (!pending.length) { return; }
        if (sequence - lastAck >= ACK_WINDOW) {
          // The client is not keeping up. Records are still in the map, so a
          // resync recovers everything — replaying would double-count.
          pending = [];
          post({ event: 'network.overflowed' });
          return;
        }
        const batch = pending;
        pending = [];
        sequence += 1;
        post({
          event: 'network.batch', requests: batch, sequence: sequence, dropped: dropped
        });
        dropped = 0;
      }

      function absolute(url) {
        try { return new URL(url, location.href).href; } catch (e) { return String(url); }
      }

      function headerObject(headers) {
        const out = {};
        try {
          if (!headers) { return out; }
          if (typeof headers.forEach === 'function') {
            headers.forEach(function (value, key) { out[key] = value; });
          } else if (Array.isArray(headers)) {
            for (const pair of headers) { out[pair[0]] = pair[1]; }
          } else {
            for (const key in headers) { out[key] = String(headers[key]); }
          }
        } catch (e) { /* a header list we can't read is not worth throwing over */ }
        return out;
      }

      function parseRawHeaders(raw) {
        const out = {};
        (raw || '').split('\\r\\n').forEach(function (line) {
          const colon = line.indexOf(':');
          if (colon > 0) { out[line.slice(0, colon).trim()] = line.slice(colon + 1).trim(); }
        });
        return out;
      }

      // ---- fetch ----------------------------------------------------------

      const nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function (input, init) {
          let url = '';
          let method = 'GET';
          let requestHeaders = {};
          try {
            if (typeof input === 'string') { url = input; }
            else if (input && input.url) {
              url = input.url;
              method = input.method || method;
              requestHeaders = headerObject(input.headers);
            } else { url = String(input); }
            if (init) {
              if (init.method) { method = init.method; }
              if (init.headers) { requestHeaders = headerObject(init.headers); }
            }
          } catch (e) { /* fall through with whatever was read */ }

          const started = performance.now();
          const record = {
            id: 'f' + (nextId++), url: absolute(url), method: String(method).toUpperCase(),
            initiator: 'fetch', startedAt: started, detailed: true,
            requestHeaders: requestHeaders
          };
          note(record);

          return nativeFetch.apply(this, arguments).then(function (response) {
            record.status = response.status;
            record.statusText = response.statusText || '';
            record.duration = performance.now() - started;
            record.responseHeaders = headerObject(response.headers);
            // An opaque response is one we are not allowed to see into at all;
            // its status reads as 0, which is not a status.
            record.isOpaque = response.type === 'opaque' || response.type === 'opaqueredirect';
            if (record.isOpaque) { record.status = undefined; }
            note(record);
            return response;
          }, function (error) {
            record.failure = String((error && error.message) || error);
            record.duration = performance.now() - started;
            note(record);
            throw error;
          });
        };
      }

      // ---- XMLHttpRequest -------------------------------------------------

      // The prototype's methods rather than the constructor: replacing the
      // constructor breaks `instanceof` for any page that checks it.
      try {
        const proto = XMLHttpRequest.prototype;
        const nativeOpen = proto.open;
        const nativeSend = proto.send;
        const nativeSetHeader = proto.setRequestHeader;

        proto.open = function (method, url) {
          this.__glassInfo = {
            method: String(method || 'GET').toUpperCase(),
            url: absolute(url), headers: {}
          };
          return nativeOpen.apply(this, arguments);
        };

        proto.setRequestHeader = function (name, value) {
          if (this.__glassInfo) { this.__glassInfo.headers[name] = value; }
          return nativeSetHeader.apply(this, arguments);
        };

        proto.send = function () {
          const info = this.__glassInfo;
          if (info) {
            const started = performance.now();
            const record = {
              id: 'x' + (nextId++), url: info.url, method: info.method,
              initiator: 'xmlhttprequest', startedAt: started, detailed: true,
              requestHeaders: info.headers
            };
            note(record);
            const request = this;
            this.addEventListener('loadend', function () {
              record.duration = performance.now() - started;
              // Status zero is not a status — it is how XHR reports a network
              // failure, a CORS rejection, or an abort.
              if (request.status > 0) {
                record.status = request.status;
                record.statusText = request.statusText || '';
                record.responseHeaders = parseRawHeaders(request.getAllResponseHeaders());
              } else {
                record.failure = 'Request failed, was blocked, or was aborted';
              }
              note(record);
            });
          }
          return nativeSend.apply(this, arguments);
        };
      } catch (e) { /* a page that froze the prototype keeps its own behaviour */ }

      // ---- sendBeacon -----------------------------------------------------

      try {
        const nativeBeacon = navigator.sendBeacon;
        if (typeof nativeBeacon === 'function') {
          navigator.sendBeacon = function (url) {
            note({
              id: 'b' + (nextId++), url: absolute(url), method: 'POST',
              initiator: 'beacon', startedAt: performance.now(), duration: 0,
              detailed: true
            });
            return nativeBeacon.apply(navigator, arguments);
          };
        }
      } catch (e) { /* not fatal */ }

      // ---- Resource Timing ------------------------------------------------

      // Everything the patch can't see: images, stylesheets, fonts, scripts.
      // No status is available for any of them — WebKit does not implement
      // `responseStatus` — so these records are deliberately statusless rather
      // than being assumed to have succeeded.
      function sameOrigin(url) {
        try { return new URL(url, location.href).origin === location.origin; }
        catch (e) { return true; }
      }

      function fromTiming(entry) {
        // A cross-origin response served without `Timing-Allow-Origin`
        // withholds every size and phase. Reporting zero would read as an empty
        // response, which is a different fact from "we're not allowed to know".
        const opaque = !sameOrigin(entry.name)
          && entry.requestStart === 0 && entry.transferSize === 0;

        const record = {
          id: 't' + (nextId++), url: entry.name, method: 'GET',
          initiator: entry.initiatorType || '', startedAt: entry.startTime,
          duration: entry.duration, detailed: false, isOpaque: opaque,
          protocolName: entry.nextHopProtocol || ''
        };
        if (!opaque) {
          record.transferSize = entry.transferSize;
          record.bodySize = entry.encodedBodySize;
          // Zero bytes transferred means it never went to the network: a real
          // response costs at least its headers. Reporting "0 B" instead reads
          // as an empty file, which is a different and wronger claim.
          record.isFromCache = entry.deliveryType === 'cache' || entry.transferSize === 0;
        }
        return record;
      }

      try {
        if (typeof performance.setResourceTimingBufferSize === 'function') {
          performance.setResourceTimingBufferSize(MAX_RECORDS);
        }
        const observer = new PerformanceObserver(function (list) {
          const entries = list.getEntries();
          for (let i = 0; i < entries.length; i++) {
            post_timing(fromTiming(entries[i]));
          }
        });
        // `buffered` replays what already happened, which is the whole point of
        // capturing from document-start.
        observer.observe({ type: 'resource', buffered: true });
      } catch (e) { /* older engines simply contribute no timing */ }

      // Timing records are marked so the client folds them into a patched
      // record rather than listing the same request twice.
      function post_timing(record) {
        record.timing = true;
        note(record);
      }

      // ---- Commands -------------------------------------------------------

      globalThis.__glassNetwork = {
        dispatch(method, params) {
          try {
            switch (method) {
              case 'Network.drain': {
                const all = [];
                records.forEach(function (record) { all.push(record); });
                const count = dropped;
                dropped = 0;
                return JSON.stringify({ requests: all, dropped: count });
              }
              case 'Network.setLive': {
                live = !!(params && params.live);
                return JSON.stringify({ ok: true });
              }
              case 'Network.ack': {
                lastAck = Math.max(lastAck, (params && params.sequence) || 0);
                return JSON.stringify({ ok: true });
              }
              case 'Network.clear': {
                records.clear();
                pending = [];
                dropped = 0;
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
