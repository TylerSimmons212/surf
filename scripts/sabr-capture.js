// What does the player send that we don't?
//
// The first probe built a request from scratch and got 403 with an empty body:
// the right endpoint, refused before the protocol layer. So rather than guess at
// what is missing, this reads a real request the player makes and answers three
// questions in order.
//
//   1. Replayed byte for byte, does the player's own request work from here?
//      If not, it is bound to something we cannot reuse — a nonce, a sequence
//      number, timing — and the whole approach needs rethinking.
//   2. What fields does it carry that ours did not?
//   3. Does ours work once it carries the one we suspect?
//
// Paste into the console on a YouTube watch page, then SEEK THE VIDEO — drag the
// scrubber somewhere new. The player only makes these requests when it needs
// media, and this has to catch one being made.
//
// Field numbers and byte counts are printed. Contents are not: the captured
// request carries a session token.

(async () => {
  const log = (...a) => console.log('%c[sabr]', 'color:#0a0', ...a);

  // Printed first, and here because it has already cost a round trip: four
  // revisions of this went out in a row, the console remembers the last paste,
  // and an old copy produces output that looks like a new result. If the line
  // below is not the version being discussed, nothing after it means anything.
  log('%cprobe v3 — reads the body off a Request object', 'font-weight:bold');

  // --- catch one -----------------------------------------------------------
  // Both `fetch` and `XMLHttpRequest`, because the first attempt watched only
  // `fetch` and caught nothing — and a dev-tools network list on the same page
  // showed no googlevideo requests either. Two observations pointing the same
  // way: the media is not being fetched where we were looking.
  //
  // So this also counts what it *does* see, and whether media is reaching the
  // decoder at all. If bytes are arriving while neither hook fires, the fetching
  // happens somewhere this cannot reach from the main thread — a worker — and
  // that is the answer rather than a failure.
  let captured = null;
  const seen = { fetch: 0, xhr: 0, appends: 0, workers: 0, posts: 0,
    bodyFrom: null, bodyError: null };
  const interesting = new Set();

  const note = (method, url) => {
    try {
      if (!/googlevideo|videoplayback/.test(url)) return;
      // Host and path only. The query carries the session token.
      const u = new URL(url, location.href);
      interesting.add(method + ' ' + u.host.replace(/^rr\d+---/, 'rrN---') + u.pathname);
    } catch (e) { /* not a url we can parse */ }
  };

  const toBytes = async (body) => {
    if (!body) return null;
    if (body instanceof Uint8Array) return body;
    if (body instanceof ArrayBuffer) return new Uint8Array(body);
    if (body instanceof Blob) return new Uint8Array(await body.arrayBuffer());
    if (ArrayBuffer.isView(body)) {
      return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
    }
    return null;
  };

  const keep = async (url, body) => {
    if (captured) return;
    const bytes = await toBytes(body);
    if (bytes && bytes.length && !captured) {
      captured = { url, bytes };
      log('caught a request —', bytes.length, 'bytes');
    }
  };

  const nativeFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      const isRequest = !!(input && typeof input === 'object'
        && typeof input.clone === 'function' && input.url);
      const url = isRequest ? input.url : String(input);
      const method = String((init && init.method)
        || (isRequest && input.method) || 'GET').toUpperCase();
      seen.fetch++;
      note(method, url);
      if (method === 'POST' && url.includes('videoplayback')) {
        seen.posts++;
        if (init && init.body) {
          seen.bodyFrom = 'init.body:' + (init.body.constructor
            && init.body.constructor.name);
          keep(url, init.body);
        } else if (isRequest) {
          // The body is on the Request, not in `init` — which is how the first
          // attempt saw the POST go past and captured nothing from it.
          //
          // Cloned before reading. A Request body is a stream and reading it
          // consumes it, so touching the original would make the player's own
          // request arrive empty: the probe would break the thing it is
          // watching, which is the one outcome worse than not catching it.
          seen.bodyFrom = 'Request.clone()';
          input.clone().arrayBuffer()
            .then((b) => keep(url, new Uint8Array(b)))
            .catch((e) => { seen.bodyError = String(e).slice(0, 80); });
        } else {
          seen.bodyFrom = 'nowhere we could see';
        }
      }
    } catch (e) { /* never break playback to watch it */ }
    return nativeFetch.apply(this, arguments);
  };

  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    try { this.__sabrMethod = String(method || 'GET').toUpperCase(); this.__sabrURL = String(url); }
    catch (e) { /* a sealed subclass */ }
    return nativeOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    try {
      seen.xhr++;
      note(this.__sabrMethod || 'GET', this.__sabrURL || '');
      if (this.__sabrMethod === 'POST' && (this.__sabrURL || '').includes('videoplayback')) {
        keep(this.__sabrURL, body);
      }
    } catch (e) { /* never break playback */ }
    return nativeSend.apply(this, arguments);
  };

  // Is media reaching the decoder at all? If it is, and neither hook fired, the
  // request was made somewhere the main thread cannot see.
  let nativeAppend = null;
  try {
    nativeAppend = SourceBuffer.prototype.appendBuffer;
    SourceBuffer.prototype.appendBuffer = function (data) {
      try { seen.appends++; } catch (e) { /* ignore */ }
      return nativeAppend.apply(this, arguments);
    };
  } catch (e) { /* no MSE */ }

  const nativeWorker = window.Worker;
  try {
    window.Worker = function (...args) { seen.workers++; return new nativeWorker(...args); };
    window.Worker.prototype = nativeWorker.prototype;
  } catch (e) { /* ignore */ }

  log('watching fetch, XHR and the decoder.');
  log('NOW SEEK THE VIDEO — drag the scrubber somewhere it has not played yet.');
  for (let i = 0; i < 60 && !captured; i++) {
    await new Promise((r) => setTimeout(r, 500));
  }
  window.fetch = nativeFetch;
  XMLHttpRequest.prototype.open = nativeOpen;
  XMLHttpRequest.prototype.send = nativeSend;
  if (nativeAppend) { SourceBuffer.prototype.appendBuffer = nativeAppend; }
  try { window.Worker = nativeWorker; } catch (e) { /* ignore */ }

  if (!captured) {
    log('nothing caught. What happened while watching:');
    log('   fetch calls:', seen.fetch, '| XHR sends:', seen.xhr,
      '| appendBuffer calls:', seen.appends, '| workers made:', seen.workers);
    log('   videoplayback POSTs seen:', seen.posts,
      '| body found at:', seen.bodyFrom || '(none seen)',
      seen.bodyError ? '| read failed: ' + seen.bodyError : '');
    log('   media-ish requests seen:',
      interesting.size ? Array.from(interesting).join(', ') : 'none');
    if (seen.appends > 0 && !interesting.size) {
      log('   >> media IS reaching the decoder while neither hook saw a request.');
      log('   >> so the fetching happens off the main thread. That is the finding.');
    } else if (!seen.appends) {
      log('   >> no media reached the decoder either, so the player never needed');
      log('   >> any. Seek somewhere it has not buffered and run it again.');
    }
    log('paste these lines back — they contain no token.');
    return;
  }

  // --- read its shape ------------------------------------------------------
  // Protobuf's varint here, not UMP's: this is a request body.
  const pvar = (b, at) => {
    let v = 0n, shift = 0n, i = at;
    while (i < b.length) {
      const byte = b[i++];
      v |= BigInt(byte & 0x7f) << shift;
      if (!(byte & 0x80)) return { value: v, next: i };
      shift += 7n;
      if (shift > 63n) return null;
    }
    return null;
  };
  const fields = (b) => {
    const out = [];
    let at = 0, guard = 0;
    while (at < b.length && guard++ < 5000) {
      const t = pvar(b, at); if (!t) break;
      const number = Number(t.value >> 3n), wire = Number(t.value & 7n);
      if (!number) break;
      if (wire === 0) { const v = pvar(b, t.next); if (!v) break; out.push({ number, wire, value: v.value }); at = v.next; }
      else if (wire === 2) { const l = pvar(b, t.next); if (!l) break; const len = Number(l.value); const end = l.next + len; if (end > b.length) break; out.push({ number, wire, len, at: l.next }); at = end; }
      else if (wire === 5) { out.push({ number, wire }); at = t.next + 4; }
      else if (wire === 1) { out.push({ number, wire }); at = t.next + 8; }
      else break;
    }
    return out;
  };

  const NAMES = {
    1: 'client_abr_state', 2: 'initialization_format_ids', 3: 'buffered_ranges',
    4: 'media_start_time_ms', 5: 'video_playback_ustreamer_config',
    16: 'selected_audio_format_ids', 17: 'selected_video_format_ids',
    19: 'streamer_context', 21: 'server_stitched_dai_info',
    22: 'last_video_itag', 23: 'last_audio_itag', 25: 'unused_bloat_size_bytes',
    1000: 'field1000',
  };

  const theirs = fields(captured.bytes);
  log('the player sends these fields:');
  for (const f of theirs) {
    const name = NAMES[f.number] || ('field ' + f.number);
    log('   ' + String(f.number).padStart(4) + '  ' + name
      + (f.wire === 2 ? '  (' + f.len + ' bytes)' : '  = ' + f.value));
  }

  const ours = new Set([1, 4, 5, 16, 17]);
  const missing = theirs.filter((f) => !ours.has(f.number)).map((f) => f.number);
  log('we were not sending:', missing.length ? missing.join(', ') : '(nothing)');

  // Inside client_abr_state, since ours carried only two of its fields.
  const abr = theirs.find((f) => f.number === 1 && f.wire === 2);
  if (abr) {
    const inner = fields(captured.bytes.slice(abr.at, abr.at + abr.len));
    log('client_abr_state fields:', inner.map((f) => f.number).join(', '));
  }

  // --- 1. does their own request work from here? ---------------------------
  const send = async (label, url, body) => {
    try {
      const res = await fetch(url, { method: 'POST', body, credentials: 'include' });
      const buf = new Uint8Array(await res.arrayBuffer());
      log(label + ':', 'HTTP', res.status, '|', res.headers.get('content-type'),
        '|', buf.length, 'bytes');
      return { status: res.status, length: buf.length };
    } catch (e) {
      log(label + ': FAILED —', String(e).slice(0, 120));
      return null;
    }
  };

  log("--- 1. replaying the player own request, byte for byte ---");
  const replay = await send('replay', captured.url, captured.bytes);

  // --- 2. ours, but carrying their streamer_context ------------------------
  const context = theirs.find((f) => f.number === 19 && f.wire === 2);
  if (!context) {
    log('--- 2. skipped: the player sent no streamer_context either ---');
  } else {
    // Rebuild ours: keep our client_abr_state and format choices, but splice in
    // their field 19 verbatim. The point of the whole approach is that it can be
    // copied without being understood.
    const pv = (n) => { n = BigInt(n); const o = []; do { let b = Number(n & 127n); n >>= 7n; if (n) b |= 128; o.push(b); } while (n); return o; };
    const tag = (f, w) => pv(BigInt(f) * 8n + BigInt(w));
    const vf = (f, v) => [...tag(f, 0), ...pv(v)];
    const bf = (f, b) => [...tag(f, 2), ...pv(b.length), ...b];

    // Take our fields straight from theirs where we can, so only field 19 and
    // the choice of format differ.
    const take = (number) => {
      const f = theirs.find((x) => x.number === number && x.wire === 2);
      return f ? Array.from(captured.bytes.slice(f.at, f.at + f.len)) : null;
    };
    const cfg = take(5), ctx = take(19);
    const audio = theirs.filter((f) => f.number === 16 && f.wire === 2)
      .map((f) => Array.from(captured.bytes.slice(f.at, f.at + f.len)));
    const video = theirs.filter((f) => f.number === 17 && f.wire === 2)
      .map((f) => Array.from(captured.bytes.slice(f.at, f.at + f.len)));

    if (!cfg || !ctx) {
      log('--- 2. skipped: could not read the config or context out of it ---');
    } else {
      const body = new Uint8Array([
        ...bf(1, [...vf(28, 0), ...vf(40, 3)]),   // our minimal client_abr_state
        ...vf(4, 0),
        ...bf(5, cfg),
        ...audio.flatMap((f) => bf(16, f)),
        ...video.flatMap((f) => bf(17, f)),
        ...bf(19, ctx),                            // theirs, copied opaquely
      ]);
      log('--- 2. ours, from the start, with their context (' + body.length + ' bytes) ---');
      await send('ours+context', captured.url, body);
    }
  }

  log('paste the lines above back to Claude — none contain a token.');
})();
