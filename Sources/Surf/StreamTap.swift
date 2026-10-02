import Foundation
import SurfCore
import WebKit

/// What a page fetched to play the video it is playing.
///
/// The engine can download any manifest it is handed. Until now it could only be
/// handed one the media element admits to: `currentSrc`. That covers native HLS
/// and nothing else, because every DASH site and most HLS ones play through Media
/// Source Extensions, where the element's source is a `blob:` the page assembled
/// in its own buffer and the real manifest URL appears nowhere the element will
/// say.
///
/// So the page is watched instead of asked.
///
/// **It wraps nothing to do it.** Resource Timing already records every request a
/// document made, which includes the ones a `<video>` element issued for itself —
/// the requests a `fetch` wrapper cannot see, because the element does not use
/// `fetch`. `buffered: true` replays what happened before this observer existed,
/// which at document start is the whole page. Two monkey-patches remain, on
/// `addSourceBuffer` and the key-system request, and each exists because the fact
/// it records appears nowhere else at all.
///
/// **Deliberately not the dev tools network agent**, which already wraps `fetch`
/// and `XMLHttpRequest` and could have been tapped the way `BlockBridge` taps it.
/// Two reasons. It is main-frame only, so an embedded player would be invisible.
/// And it captures headers and bodies only while a panel is attached, which would
/// make a debugging tool load-bearing for a download — a coupling that is hard to
/// see and easy to break.
///
/// **URLs only.** No bodies, no headers, nothing read from a response. The engine
/// re-fetches the manifest itself through `SegmentFetcher`, which gets it fresh,
/// with the `HttpOnly` cookies no script can read, and with no CORS to answer to.
/// A body captured in the page would be strictly worse information as well as a
/// much larger thing to carry.
enum StreamTap {

    /// What one frame saw.
    struct Report: Decodable {
        /// Manifest URLs, oldest first, deduplicated.
        var manifests: [String] = []
        /// The mime strings the page handed to `addSourceBuffer`, which is the
        /// only place a codec appears when the source is a blob.
        var codecs: [String] = []
        /// A key system was asked for, or an `encrypted` event fired. Detected,
        /// never defeated: it is here so a protected stream is refused before
        /// anything is fetched rather than producing an unplayable file.
        var isProtected = false
        /// One streaming request the page made, kept whole.
        var abr: ABRRequest?
        /// What the page says is available, so a download can choose rather than
        /// accept whatever the server would have sent.
        var formats: [Format] = []
    }

    /// One rendition the page listed.
    struct Format: Decodable {
        var itag: Int
        /// A string across the bridge and a `UInt64` here. The value is around
        /// 1.7×10¹⁸, past where a JSON number holds integers exactly, and the
        /// server rejects a request carrying a rounded one.
        var lastModified: String
        var mimeType: String
        var height: Int
        var bitrate: Int

        var revision: UInt64? { UInt64(lastModified) }
        var isVideo: Bool { mimeType.hasPrefix("video/") }
        var isAudio: Bool { mimeType.hasPrefix("audio/") }
        /// Whether AVFoundation can read it. WebM and its codecs it cannot, and
        /// asking for one produces a download that finishes and will not mux.
        var isMP4: Bool { mimeType.contains("mp4") }
    }

    /// A `videoplayback` POST the player made, which on YouTube is the only
    /// route to its media: nothing is served by URL any more.
    ///
    /// Base64 because the bridge carries JSON. A couple of kilobytes, once per
    /// page, so the encoding costs nothing worth measuring — unlike the media
    /// itself, which is why that is fetched natively and never crosses here.
    struct ABRRequest: Decodable {
        var url: String
        var body: String

        /// The request as it was sent.
        var bytes: Data? { Data(base64Encoded: body) }
    }

    /// Resident, page world, every frame.
    ///
    /// Page world because `MediaSource` and `navigator.requestMediaKeySystemAccess`
    /// are the site's own globals and an isolated world has its own `navigator`
    /// with nothing on it. Every frame because an embedded player is a separate
    /// document that has to be instrumented on its own terms.
    ///
    /// Resident rather than installed on demand, which breaks from how `capture`
    /// and the site lenses work, and is forced: a key-system wrapper installed
    /// after the page asked for one has observed nothing, and a player fetches
    /// its manifest before `play` ever fires. Armed at document start or useless.
    static var domainScript: String {
        """
        (function () {
          const runtime = globalThis['\(PageRuntime.handle)'];
          // Guarded on the domain: the runtime is shared, and re-entering would
          // install a second observer on the same document.
          if (!runtime || runtime.state.streamInstalled) { return; }
          runtime.state.streamInstalled = true;

          const MAX = 24;
          const manifests = [];
          const codecs = [];
          let encrypted = false;
          let abr = null;

          // Extension on the path, not anywhere in the string: a signed segment
          // URL routinely carries a policy with dots in it, and matching the
          // query would call every one of them a manifest.
          function isManifest(url) {
            const query = url.indexOf('?');
            const path = query === -1 ? url : url.slice(0, query);
            const dot = path.lastIndexOf('.');
            if (dot === -1) { return false; }
            const ext = path.slice(dot + 1).toLowerCase();
            return ext === 'm3u8' || ext === 'm3u' || ext === 'mpd';
          }

          function note(url) {
            if (typeof url !== 'string' || !isManifest(url)) { return; }
            if (manifests.indexOf(url) !== -1) { return; }
            if (manifests.length >= MAX) { manifests.shift(); }
            manifests.push(url);
          }

          // Registered before any of the instrumentation below, and that order
          // is the point. Everything that follows is optional — a document
          // without Resource Timing, without MSE, without EME, or without a
          // working `addEventListener` is a document this still has to answer
          // for, with whatever it managed to see. Defining the method last meant
          // one unguarded line could stop it existing at all, which the contract
          // check found before any page did.
          // What the page says is on offer, read when asked rather than at
          // document start: the player does not exist yet when this installs,
          // and `ytInitialPlayerResponse` goes stale the moment anyone navigates
          // within the site. Asked for only when a download starts, by which
          // time the player is the authority.
          function offered() {
            let response = null;
            try {
              const element = document.getElementById('movie_player');
              if (element && typeof element.getPlayerResponse === 'function') {
                response = element.getPlayerResponse();
              }
            } catch (error) { /* the player is not ready */ }
            if (!response) { response = window.ytInitialPlayerResponse || null; }
            const formats = (response && response.streamingData
              && response.streamingData.adaptiveFormats) || [];
            const out = [];
            for (let i = 0; i < formats.length && out.length < 60; i++) {
              const f = formats[i];
              if (!f || !f.itag || !f.lastModified) { continue; }
              out.push({
                itag: f.itag,
                // A string, deliberately: this is a uint64 around 1.7e18 and a
                // JSON number loses its low digits on the way across.
                lastModified: String(f.lastModified),
                mimeType: f.mimeType || '',
                height: f.height || 0,
                bitrate: f.bitrate || 0
              });
            }
            return out;
          }

          runtime.define('stream.tap', () => ({
            manifests: manifests.slice(),
            codecs: codecs.slice(),
            isProtected: encrypted,
            abr: abr,
            formats: offered()
          }));

          // Every request the document made, including the ones a <video>
          // element issued for itself — which no fetch wrapper can see, because
          // the element does not use fetch. Buffered, so the entries from before
          // this ran are replayed.
          try {
            const observer = new PerformanceObserver((list) => {
              const entries = list.getEntries();
              for (let i = 0; i < entries.length; i++) { note(entries[i].name); }
            });
            observer.observe({ type: 'resource', buffered: true });
          } catch (error) { /* no Resource Timing: the tap simply sees nothing */ }

          // What the page told the decoder it was about to feed it. With a blob
          // source there is no other way to learn the container or the codec.
          try {
            const add = MediaSource.prototype.addSourceBuffer;
            MediaSource.prototype.addSourceBuffer = function (mime) {
              try {
                if (typeof mime === 'string' && codecs.length < 8
                    && codecs.indexOf(mime) === -1) {
                  codecs.push(mime);
                }
              } catch (error) { /* never let the tap break playback */ }
              return add.apply(this, arguments);
            };
          } catch (error) { /* no MSE here */ }

          // Protection, so it can be refused rather than downloaded into an
          // unplayable file.
          try {
            const ask = navigator.requestMediaKeySystemAccess;
            if (typeof ask === 'function') {
              navigator.requestMediaKeySystemAccess = function () {
                encrypted = true;
                return ask.apply(this, arguments);
              };
            }
          } catch (error) { /* no EME here */ }
          // Capture phase, because the event is dispatched at the element and a
          // listener on the document would otherwise have to wait for it to
          // bubble past anything that might stop it.
          try {
            document.addEventListener('encrypted', () => { encrypted = true; }, true);
          } catch (error) { /* no document to listen on */ }

          // One streaming request, kept whole.
          //
          // The only place this file wraps anything, and the only request whose
          // *contents* matter: YouTube serves nothing by URL any more, so the
          // bytes the player posts are the only route to its own media. Gated to
          // YouTube because that is the only site this protocol exists on, which
          // keeps the no-wrapping property everywhere else — this script runs in
          // every frame of every page and a global fetch wrapper is both a cost
          // and a surface.
          // Suffix checks rather than a regular expression: a backslash inside a
          // Swift multi-line literal is an escape before it is ever JavaScript,
          // and the pattern needed for this is nothing but backslashes.
          const host = location.hostname || '';
          const endsWith = (suffix) => host === suffix || host.endsWith('.' + suffix);
          const isYouTube = endsWith('youtube.com') || endsWith('youtube-nocookie.com');
          if (isYouTube) {
            try {
              const native = window.fetch;
              window.fetch = function (input, init) {
                try {
                  const asRequest = (input && typeof input === 'object'
                    && typeof input.clone === 'function' && input.url) ? input : null;
                  const url = asRequest ? asRequest.url : String(input);
                  if (!abr && url.indexOf('videoplayback') !== -1) {
                    const method = String((init && init.method)
                      || (asRequest && asRequest.method) || 'GET').toUpperCase();
                    if (method === 'POST') {
                      const take = (bytes) => {
                        if (abr || !bytes || !bytes.length) { return; }
                        let text = '';
                        for (let i = 0; i < bytes.length; i++) {
                          text += String.fromCharCode(bytes[i]);
                        }
                        abr = { url: url, body: btoa(text) };
                      };
                      if (init && init.body) {
                        const body = init.body;
                        if (body instanceof Uint8Array) { take(body); }
                        else if (body instanceof ArrayBuffer) { take(new Uint8Array(body)); }
                        else if (ArrayBuffer.isView(body)) {
                          take(new Uint8Array(body.buffer, body.byteOffset, body.byteLength));
                        }
                      } else if (asRequest) {
                        // Cloned, never read directly. The body is a stream and
                        // reading it consumes it, so taking the original would
                        // leave the player's own request arriving empty — the tap
                        // breaking the playback it exists to observe.
                        asRequest.clone().arrayBuffer()
                          .then((buffer) => { take(new Uint8Array(buffer)); })
                          .catch(() => { /* gone before we could read it */ });
                      }
                    }
                  }
                } catch (error) { /* never break a page to watch it */ }
                return native.apply(this, arguments);
              };
            } catch (error) { /* fetch is not replaceable here */ }
          }
        })();
        """
    }
}
