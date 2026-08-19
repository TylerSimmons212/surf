import Foundation
import SurfCore

/// The agent itself: a tiny method registry installed into a content world at
/// document start, and the only thing Surf ever adds to a page's globals.
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
    /// `__surfMedia`, as it used to be — is a reliable way for a site to
    /// detect which browser it is being read in. Randomising it per launch
    /// leaves nothing stable to test for.
    ///
    /// Per *launch*, not per tab: a popup inherits its opener's content
    /// controller, so two tabs can share one set of user scripts. A single
    /// handle makes a duplicate install idempotent instead of a conflict.
    static let handle: String = {
        let hex = (0..<12).map { _ in "0123456789abcdef".randomElement()! }
        return "__surf" + String(hex)
    }()

    /// The registry, plus the calls every domain is written against: `define`
    /// to answer a method, `emit` or `post` to volunteer something.
    ///
    /// One implementation, installed wherever a script needs to be addressable
    /// — the always-resident page agent in two worlds, and each of the three
    /// scripts dev tools installs while it is attached. Before this was shared
    /// there were four hand-written dispatchers with four copies of the same
    /// `switch`/`try`/unknown-method logic, and two different ideas of what a
    /// reply looks like.
    ///
    /// A thrown error becomes a reported failure rather than a rejected
    /// promise WebKit turns into a bare `nil`, which is what lets a call site
    /// tell a broken script from a page with nothing to say.
    ///
    /// - Parameters:
    ///   - global: the property to install under. The page agent randomises
    ///     this per launch; dev tools uses fixed names, which is acceptable
    ///     only because those scripts exist solely while a panel is attached.
    ///   - eventHandler: the `messageHandlers` channel `post` writes to.
    static func source(global: String, eventHandler: String) -> String {
        """
        (function () {
          const GLOBAL = '\(global)';
          if (globalThis[GLOBAL]) { return; }

          const methods = Object.create(null);

          const runtime = {
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
                // A throw would otherwise surface as an opaque WebKit error
                // with none of the page's own message, so carry it as data.
                return JSON.stringify({
                  ok: false,
                  error: String((error && error.message) || error)
                });
              }
            },

            /// The raw channel. Domains whose event shape predates the runtime
            /// use this directly; new ones should prefer `emit`.
            post(payload) {
              const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
              const channel = handlers && handlers['\(eventHandler)'];
              // Absent between detach and document teardown, when the handler
              // is gone but this script is still alive.
              if (!channel) { return; }
              channel.postMessage(payload);
            },

            /// A string rather than an object: one decoder on the Swift side
            /// for every event, instead of a cast per field.
            emit(domain, event, payload) {
              runtime.post(JSON.stringify({
                domain: domain,
                event: event,
                payload: payload === undefined ? null : payload
              }));
            },

            // Scratch space for domains that need to remember something
            // between calls — the media element the user is listening to,
            // for one. Off the global proper, so the page sees one property
            // rather than a scattering of them.
            state: Object.create(null)
          };

          // Non-enumerable and non-writable: a script that walks the globals
          // does not list it, and nothing on the page can replace it.
          Object.defineProperty(globalThis, GLOBAL, { value: runtime });
        })();
        """
    }

    /// What `callAsyncJavaScript` runs for every command, for every script.
    ///
    /// `method` and `params` arrive as call arguments, never interpolated into
    /// the source — page content must never be able to become script. A `null`
    /// reply means the runtime isn't there: an `about:blank`, a PDF view, or a
    /// load that raced the injection.
    static func dispatchSource(global: String) -> String {
        """
        if (!globalThis['\(global)']) { return null; }
        return globalThis['\(global)'].dispatch(method, params);
        """
    }

    /// The always-resident page agent's instance, one per content world.
    static func source(for world: PageProtocol.World) -> String {
        source(global: handle, eventHandler: world.handlerName)
    }
}
