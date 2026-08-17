import WebKit

/// The inspection agent: the half of dev tools that lives inside the page.
///
/// Injected into a *private content world*, not the page world. Isolated worlds
/// share the DOM but not the JS globals, which buys two things at once: the
/// page can't detect that it's being inspected, and it can't break the agent by
/// overwriting `Array.prototype.map` or anything else the agent leans on. The
/// console bridge has to live in the page world — it exists to replace page
/// globals — but nothing else does.
///
/// Injected only while a dev tools window is actually open. Unlike console
/// capture, this needs no history: the DOM is a live structure, readable
/// whenever we arrive, so there's nothing to be gained by paying for it on
/// every page the user merely browses past.
enum DevToolsAgent {

    /// The world the agent runs in. A single source so it can't drift between
    /// script injection and handler registration — registering a handler in a
    /// *different* world than the script leaves `messageHandlers.x` undefined
    /// and the agent fails completely silently.
    static let worldName = "glass.devtools"
    static var world: WKContentWorld { .world(name: worldName) }

    /// One-way, agent → Glass.
    static let eventHandlerName = "glassDevToolsEvents"

    /// What `callAsyncJavaScript` runs for every command. `method` and `params`
    /// arrive as call arguments, never interpolated into the source — page
    /// content must never be able to become script.
    static let dispatchScript = """
    if (!globalThis.__glassAgent) { return null; }
    return globalThis.__glassAgent.dispatch(method, params);
    """

    static let script = """
    (function () {
      if (globalThis.__glassAgent) { return; }

      const post = (payload) => {
        try {
          window.webkit.messageHandlers.\(eventHandlerName).postMessage(payload);
        } catch (e) {
          // The handler is removed on detach while this document stays alive.
          // Nothing to do, and certainly nothing worth throwing over.
        }
      };

      const agent = {
        // Replies are JSON strings rather than object graphs. Letting WebKit
        // build a deep NSDictionary across the process boundary is markedly
        // slower than handing over one string and decoding it on our side.
        dispatch(method, params) {
          try {
            switch (method) {
              case 'Runtime.ping':
                return JSON.stringify({
                  ok: true,
                  url: location.href,
                  title: document.title,
                  nodeCount: document.getElementsByTagName('*').length
                });
              default:
                return JSON.stringify({ error: 'unknown method: ' + method });
            }
          } catch (e) {
            // A throw here would surface as an opaque WebKit error with none of
            // the page's own message, so carry it across as data.
            return JSON.stringify({ error: String((e && e.message) || e) });
          }
        }
      };

      globalThis.__glassAgent = agent;
      post({ event: 'bootstrapped', url: location.href, generation: 0 });
    })();
    """
}
