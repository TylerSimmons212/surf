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
          runtime.define('stream.tap', () => ({
            manifests: manifests.slice(),
            codecs: codecs.slice(),
            isProtected: encrypted
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
        })();
        """
    }
}
