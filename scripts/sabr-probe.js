// Does YouTube serve media for a request we built ourselves?
//
// Paste the whole thing into the console on any YouTube watch page and press
// return. It prints a short report. Nothing is uploaded anywhere and no
// credential is printed: the signed URL and the ustreamer config stay inside the
// page, and the output is statuses, byte counts and part numbers.
//
// What it does: builds one VideoPlaybackAbrRequest asking for the smallest video
// and audio track from the start of the video, posts it to the streaming URL the
// page already holds, and reports what came back.
//
// The question it answers is whether a request with no proof-of-origin token is
// accepted. If it is, Surf can download YouTube. If the answer is
// STREAM_PROTECTION / attestation required, we know exactly what is missing
// before building the rest.

(async () => {
  const log = (...a) => console.log('%c[sabr]', 'color:#0a0', ...a);

  const player = window.ytInitialPlayerResponse;
  const sd = player && player.streamingData;
  const cfg = player && player.playerConfig && player.playerConfig.mediaCommonConfig
    && player.playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig
    && player.playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig
      .videoPlaybackUstreamerConfig;

  if (!sd || !sd.serverAbrStreamingUrl || !cfg) {
    log('this page has no SABR streaming url or no ustreamer config.');
    log('open a normal watch page (youtube.com/watch?v=...) and try again.');
    return;
  }

  // --- protobuf writing -----------------------------------------------------
  // BigInt throughout. lastModified is a uint64 around 1.7e18, past
  // Number.MAX_SAFE_INTEGER, and encoding it as a double silently drops the low
  // digits — the server then rejects the request for a reason that looks like
  // anything else.
  const pvarint = (n) => {
    n = BigInt(n);
    const out = [];
    do { let b = Number(n & 127n); n >>= 7n; if (n) b |= 128; out.push(b); } while (n);
    return out;
  };
  const ptag = (field, wire) => pvarint(BigInt(field) * 8n + BigInt(wire));
  const pv = (field, value) => [...ptag(field, 0), ...pvarint(value)];
  const pb = (field, bytes) => [...ptag(field, 2), ...pvarint(bytes.length), ...bytes];

  const unb64 = (s) => {
    const raw = atob(s.replace(/-/g, '+').replace(/_/g, '/'));
    return Array.from(raw, (c) => c.charCodeAt(0));
  };

  // --- UMP reading ----------------------------------------------------------
  // Not protobuf's varint. The first byte's leading set bits give the total
  // length; the rest of that byte is the low end of the value. They agree below
  // 128, which is what makes mixing them up survive small test data.
  const umpVarint = (buf, at) => {
    const first = buf[at];
    let size = 0;
    for (let shift = 1; shift <= 5; shift++) {
      if ((first & (128 >> (shift - 1))) === 0) { size = shift; break; }
    }
    if (!size || at + size > buf.length) return null;
    let value;
    if (size === 1) value = first;
    else if (size === 2) value = (first & 0x3f) | (buf[at + 1] << 6);
    else if (size === 3) value = (first & 0x1f) | (buf[at + 1] << 5) | (buf[at + 2] << 13);
    else if (size === 4) {
      value = (first & 0x0f) | (buf[at + 1] << 4) | (buf[at + 2] << 12) | (buf[at + 3] << 20);
    } else {
      // `>>> 0` because JavaScript's bitwise operators work on signed 32-bit
      // integers: without it a top byte of 0xFF makes this -1 instead of
      // 4294967295, and every length in the stream after it is nonsense. The
      // Swift reader does not have this problem — its Int is 64-bit — which is
      // exactly why the two are checked against the same hand-computed values.
      value = (buf[at + 1] | (buf[at + 2] << 8) | (buf[at + 3] << 16)
        | (buf[at + 4] << 24)) >>> 0;
    }
    return { value, next: at + size };
  };

  const NAMES = {
    20: 'MEDIA_HEADER', 21: 'MEDIA', 22: 'MEDIA_END', 31: 'LIVE_METADATA',
    35: 'NEXT_REQUEST_POLICY', 36: 'USTREAMER_VIDEO_AND_FORMAT_METADATA',
    37: 'FORMAT_SELECTION_CONFIG', 42: 'FORMAT_INITIALIZATION_METADATA',
    43: 'SABR_REDIRECT', 44: 'SABR_ERROR', 45: 'SABR_SEEK',
    46: 'RELOAD_PLAYER_RESPONSE', 52: 'REQUEST_IDENTIFIER',
    57: 'SABR_CONTEXT_UPDATE', 58: 'STREAM_PROTECTION_STATUS',
    61: 'SABR_ACK', 66: 'PLAYBACK_DEBUG_INFO',
  };

  // --- pick the smallest tracks, so a success is cheap ----------------------
  const smallest = (prefix) => (sd.adaptiveFormats || [])
    .filter((f) => (f.mimeType || '').startsWith(prefix))
    .sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0))[0];
  const video = smallest('video/mp4') || smallest('video/');
  const audio = smallest('audio/mp4') || smallest('audio/');
  if (!video || !audio) { log('no usable formats on this page'); return; }

  const formatId = (f) => [...pv(1, f.itag), ...pv(2, f.lastModified)];
  // client_abr_state: player_time_ms (28) and the track-type bitfield (40).
  // Audio is 1, video is 2, so 3 asks for both.
  const abrState = [...pv(28, 0), ...pv(40, 3)];

  const body = new Uint8Array([
    ...pb(1, abrState),
    ...pv(4, 0),             // media_start_time_ms — from the beginning
    ...pb(5, unb64(cfg)),    // the opaque config, copied verbatim
    ...pb(16, formatId(audio)),
    ...pb(17, formatId(video)),
  ]);

  log('asking for itag', video.itag, '(' + (video.qualityLabel || '?') + ') and itag',
    audio.itag, '— request is', body.length, 'bytes');

  // --- send it --------------------------------------------------------------
  let res, buf;
  try {
    res = await fetch(sd.serverAbrStreamingUrl, {
      method: 'POST', body, credentials: 'include',
    });
    buf = new Uint8Array(await res.arrayBuffer());
  } catch (e) {
    log('REQUEST FAILED before any answer:', String(e));
    log('if this says CORS, the answer is that a page-side fetch is blocked and');
    log('this has to be tried from the browser itself rather than from script.');
    return;
  }

  log('HTTP', res.status, res.statusText || '', '|', res.headers.get('content-type'),
    '|', buf.length, 'bytes back');

  if (!buf.length) { log('nothing in the body — no media, no parts.'); return; }

  // --- read the parts -------------------------------------------------------
  const parts = [];
  let at = 0;
  let mediaBytes = 0;
  let guard = 0;
  while (at < buf.length && guard++ < 20000) {
    const t = umpVarint(buf, at); if (!t) break;
    const s = umpVarint(buf, t.next); if (!s) break;
    const end = s.next + s.value;
    if (end > buf.length) { parts.push({ type: t.value, size: s.value, cut: true }); break; }
    parts.push({ type: t.value, size: s.value });
    if (t.value === 21) mediaBytes += Math.max(0, s.value - 1);
    at = end;
  }

  const tally = {};
  for (const p of parts) {
    const name = NAMES[p.type] || ('type ' + p.type);
    tally[name] = (tally[name] || 0) + 1;
  }
  log('parts:', parts.length, tally);
  log('media bytes in this response:', mediaBytes);

  // The two answers that decide what happens next.
  const protection = parts.findIndex((p) => p.type === 58);
  const redirect = parts.some((p) => p.type === 43);
  const error = parts.some((p) => p.type === 44);

  if (mediaBytes > 0) {
    log('%cMEDIA CAME BACK. A request with no proof-of-origin token was accepted.',
      'color:#0a0;font-weight:bold');
  } else if (redirect) {
    log('%cREDIRECT ONLY — not a failure. The server wants a different host;',
      'color:#a60;font-weight:bold');
    log('a real client follows it and asks again. Worth rerunning to see if the');
    log('second answer carries media.');
  } else if (error || protection !== -1) {
    log('%cNO MEDIA. An error or a protection status came back instead —',
      'color:#a00;font-weight:bold');
    log('most likely a proof-of-origin token is required.');
  } else {
    log('%cNO MEDIA, and no error either. The request was probably malformed.',
      'color:#a00;font-weight:bold');
  }

  log('paste the lines above back to Claude — none of them contain a credential.');
})();
