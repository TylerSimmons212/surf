import Foundation
import GlassCore

/// The agent itself: a tiny method registry installed into a content world at
/// document start, and the only thing Glass ever adds to a page's globals.
///
/// Everything a feature wants from the page is registered on it as a named
/// method. The alternative — the one this replaces — is handing WebKit a new
/// block of source for every question, which means every feature carries its
/// own conventions for arguments, for errors, and for what "nothing" looks
/// like.
enum PageRuntime {

    /// The property the agent hangs off `window`, chosen once per launch.
    ///
    /// In the isolated world this is invisible to the site and the name
    /// wouldn't matter. In the page world it is visible, and a fixed name —
    /// `__glassMedia`, as it used to be — is a reliable way for a site to
    /// detect which browser it is being read in. Randomising it per launch
    /// leaves nothing stable to test for.
    ///
    /// Per *launch*, not per tab: a popup inherits its opener's content
    /// controller, so two tabs can share one set of user scripts. A single
    /// handle makes a duplicate install idempotent instead of a conflict.
    static let handle: String = {
        let hex = (0..<12).map { _ in "0123456789abcdef".randomElement()! }
        return "__glass" + String(hex)
    }()

    /// The registry, plus the two calls every domain is written against:
    /// `define` to answer a method, `emit` to volunteer something.
    ///
    /// A thrown error becomes a reported failure rather than a rejected
    /// promise WebKit turns into a bare `nil`, which is what lets a call site
    /// tell a broken script from a page with nothing to say.
    static func source(for world: PageProtocol.World) -> String {
        """
        (function () {
          const HANDLE = '\(handle)';
          if (window[HANDLE]) { return; }

          const methods = Object.create(null);

          const agent = {
            define(name, fn) { methods[name] = fn; },

            async dispatch(name, params) {
              const fn = methods[name];
              if (!fn) {
                return JSON.stringify({ ok: false, error: 'no such method: ' + name });
              }
              try {
                const value = await fn(params || {});
                // `undefined` is not JSON, and a method that answers with
                // nothing still succeeded — so it becomes an explicit null and
                // the Swift side reads it as "nothing to report".
                return JSON.stringify({ ok: true, value: value === undefined ? null : value });
              } catch (error) {
                return JSON.stringify({
                  ok: false,
                  error: String((error && error.message) || error)
                });
              }
            },

            emit(domain, event, payload) {
              const handlers = window.webkit && window.webkit.messageHandlers;
              const channel = handlers && handlers['\(world.handlerName)'];
              if (!channel) { return; }
              // A string rather than an object: one decoder on the Swift side
              // for every event, instead of a cast per field.
              channel.postMessage(JSON.stringify({
                domain: domain,
                event: event,
                payload: payload === undefined ? null : payload
              }));
            },

            // Scratch space for domains that need to remember something
            // between calls — the media element the user is listening to,
            // for one. Off `window` proper, so the page sees one property
            // rather than a scattering of them.
            state: Object.create(null)
          };

          // Non-enumerable and non-writable: a script that walks `window` does
          // not list it, and nothing on the page can replace it with its own.
          Object.defineProperty(window, HANDLE, { value: agent });
        })();
        """
    }
}
