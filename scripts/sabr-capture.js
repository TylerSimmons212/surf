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

  // --- catch one -----------------------------------------------------------
  let captured = null;
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

  const nativeFetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      const url = (input && typeof input === 'object' && input.url) ? input.url : String(input);
      const method = (init && init.method) || (input && input.method) || 'GET';
      if (!captured && method.toUpperCase() === 'POST' && url.includes('videoplayback')) {
        const body = init && init.body;
        toBytes(body).then((bytes) => {
          if (bytes && !captured) {
            captured = { url, bytes };
            log('caught a request —', bytes.length, 'bytes');
          }
        });
      }
    } catch (e) { /* never break playback to watch it */ }
    return nativeFetch.apply(this, arguments);
  };

  log('watching. NOW SEEK THE VIDEO — drag the scrubber somewhere new.');
  for (let i = 0; i < 60 && !captured; i++) {
    await new Promise((r) => setTimeout(r, 500));
  }
  window.fetch = nativeFetch;

  if (!captured) {
    log('nothing caught in 30s. The player may be using XHR, or may have had');
    log('everything it needed buffered. Try seeking somewhere far away and rerun.');
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
