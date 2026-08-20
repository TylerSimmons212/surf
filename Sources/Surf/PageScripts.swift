import Foundation
import SurfCore
import WebKit

/// The `page` domain: the two readings that belong to no feature in
/// particular. Isolated world, like everything else that only observes.
enum PageDomain {

    static var domainScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent) { return; }

          // The colour actually painted at the top of the viewport.
          //
          // Walks up from the topmost element at a few points along the strip
          // until it finds an opaque background. That handles fixed headers,
          // which is exactly the case the WebKit-provided colours get wrong.
          agent.define('page.metrics', () => {
            const root = document.scrollingElement || document.documentElement;
            return {
              width: root ? root.scrollWidth : innerWidth,
              height: root ? root.scrollHeight : innerHeight
            };
          });

          agent.define('page.topColor', () => {
            function opaqueColor(el) {
              if (!el) { return null; }
              const match = getComputedStyle(el).backgroundColor.match(/^rgba?\\(([^)]+)\\)$/);
              if (!match) { return null; }
              const parts = match[1].split(',').map(Number);
              const alpha = parts.length > 3 ? parts[3] : 1;
              // Near-transparent backgrounds don't determine what's on screen.
              return alpha >= 0.9 ? [parts[0], parts[1], parts[2]] : null;
            }
            // Several x positions: a centred logo or search box can sit on its
            // own background that isn't representative of the whole bar.
            const xs = [Math.floor(innerWidth / 2), 12, Math.max(12, innerWidth - 12)];
            for (const x of xs) {
              let el = document.elementFromPoint(x, 3);
              while (el) {
                const color = opaqueColor(el);
                if (color) { return color; }
                el = el.parentElement;
              }
            }
            return opaqueColor(document.body) || opaqueColor(document.documentElement);
          });

          // `link.href` is already absolute — the DOM resolves it against the
          // document, so relative paths and <base> tags are handled for free.
          agent.define('page.favicons', () =>
            Array.from(document.querySelectorAll('link[rel~="icon" i]'))
              .map((l) => ({ href: l.href || '', sizes: l.getAttribute('sizes') || '' }))
          );
        })();
        """
    }
}

/// The one place that decides what gets injected into a page, and in which
/// world.
///
/// `WKUserContentController` can remove all of its scripts or none of them, so
/// any change means rebuilding the set. That used to be a hazard — the theme's
/// preflight had to be rebuilt whenever the scheme changed, and the media
/// bridge was re-added alongside it by hand, with a comment explaining that
/// forgetting to would drop it silently. Composing the whole set from one
/// declarative list is what makes that impossible rather than merely
/// documented.
enum PageScripts {

    /// - Parameters:
    ///   - themePreflight: the scheme to paint before the page's own styles
    ///     arrive, or nil when Surf isn't restyling this page at all.
    ///   - blocking: whether the content blocker's page-side accounting goes
    ///     in. Off means the panel has nothing to report, not that blocking
    ///     stopped — the rules match in the network process either way.
    ///   - devTools: whether the inspector's own agent goes in. The console and
    ///     network agents are unconditional, so a log fired before you opened
    ///     the panel is already waiting when you do.
    @MainActor
    static func install(
        on controller: WKUserContentController,
        themePreflight: ColorSchemeTarget?,
        blocking: Bool,
        devTools: Bool
    ) {
        controller.removeAllUserScripts()

        // The agent, then that world's domains — every frame, because media
        // and theming both reach into same-origin ones.
        add(
            PageRuntime.source(for: .isolated),
            ThemeBridge.domainScript,
            PageDomain.domainScript,
            to: controller, world: .isolated, mainFrameOnly: false
        )
        add(
            PageRuntime.source(for: .page),
            MediaBridge.domainScript,
            FindBridge.domainScript,
            to: controller, world: .page, mainFrameOnly: false
        )

        // The scripts that predate the agent and still speak for themselves.
        // They belong in this list for one reason: `removeAllUserScripts()`
        // above takes them with it, so anything installed anywhere else is
        // dropped on the next rebuild with no error anywhere.
        // Main frame only, and the choice is measured rather than cautious:
        // dev tools' drain and setLive commands run through
        // `callAsyncJavaScript(..., in: nil)` — the main frame — so a subframe
        // copy of these agents buffered forever and was never asked for any of
        // it. Injecting 50KB of capture into every ad iframe bought nothing
        // the panes could show. Subframe *blocking* accounting still exists;
        // it belongs to BlockBridge below.
        add(ConsoleAgent.script, NetworkAgent.script,
            to: controller, world: .page, mainFrameOnly: true)
        if blocking {
            add(
                BlockBridge.script,
                to: controller, world: .page,
                // Every frame: a third-party iframe is where much of an ad
                // stack does its work, and a panel blind to it would report one
                // request where a page made forty. Added *after* the network
                // agent, which matters: in the main frame this script taps the
                // agent's single fetch/XHR wrap instead of wrapping a second
                // time, and in subframes — where the agent isn't injected —
                // it falls back to wrapping for itself.
                mainFrameOnly: false
            )
        }
        if devTools {
            // Main frame only, so the node id space has exactly one authority.
            addRaw(
                DevToolsAgent.script, to: controller,
                world: DevToolsAgent.world, mainFrameOnly: true
            )
        }

        guard let themePreflight else { return }
        add(
            ThemeBridge.preflightScript(for: themePreflight),
            to: controller, world: .isolated,
            // Main frame only: an iframe is a document we don't theme, and
            // painting a holding colour over one we then leave alone would be
            // a flash of our own making.
            mainFrameOnly: true
        )
    }

    /// For the one script that lives in neither of the agent's worlds: the
    /// inspector keeps its own named world, so its globals can't be reached
    /// from the page or collide with the agent's.
    @MainActor
    private static func addRaw(
        _ source: String,
        to controller: WKUserContentController,
        world: WKContentWorld,
        mainFrameOnly: Bool
    ) {
        controller.addUserScript(
            WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: mainFrameOnly,
                in: world
            )
        )
    }

    @MainActor
    private static func add(
        _ sources: String...,
        to controller: WKUserContentController,
        world: PageProtocol.World,
        mainFrameOnly: Bool
    ) {
        controller.addUserScript(
            WKUserScript(
                source: sources.joined(separator: "\n"),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: mainFrameOnly,
                in: world.contentWorld
            )
        )
    }
}

// MARK: - Checking the contract

extension PageScripts {

    /// Writes every injected script to a directory and exits, when
    /// `SURF_DUMP_SCRIPTS` names one.
    ///
    /// The agent's contract has two halves in two languages: a method Swift
    /// declares and a method JavaScript registers. Nothing compiles the second
    /// half, so nothing catches a name that exists on only one side — the
    /// failure is a feature that silently stops working, months later, in one
    /// world. `scripts/check-js.sh` closes that by asking the real scripts,
    /// with a real JavaScript engine, whether they answer to everything
    /// `PageProtocol.Method` claims.
    static func dumpAndExitIfAsked() {
        guard let directory = ProcessInfo.processInfo.environment["SURF_DUMP_SCRIPTS"]
        else { return }

        let scripts: [String: String] = [
            "runtime-isolated.js": PageRuntime.source(for: .isolated),
            "runtime-page.js": PageRuntime.source(for: .page),
            "theme.js": ThemeBridge.domainScript,
            "page.js": PageDomain.domainScript,
            // Lazily injected on first use — in the dump so the contract
            // check can probe its methods, budgeted separately because it
            // is not a page-load cost.
            "capture.js": CaptureDomain.installScript,
            "media.js": MediaBridge.domainScript,
            "find.js": FindBridge.domainScript,
            "preflight.js": ThemeBridge.preflightScript(for: .dark),
            // Not agent domains, but `install` owns them too — and a dump that
            // showed only half of what goes into a page would be worse than none.
            "block.js": BlockBridge.script,
            "console.js": ConsoleAgent.script,
            "network.js": NetworkAgent.script,
            "devtools.js": DevToolsAgent.script,
        ]

        // The method table itself, so the checker compares against the enum
        // rather than against a copy of it that can drift.
        let pageAgent: [String: Any] = [
            // Dumped rather than left for the checker to grep out of the
            // runtime source — it broke once when the constant was renamed,
            // which is the checker coupling to an implementation detail it has
            // no business knowing.
            "handle": PageRuntime.handle,
            "methods": PageProtocol.Method.allCases.map {
                ["name": $0.rawValue, "world": $0.world.rawValue]
            },
        ]

        // Dev tools is the same contract at four times the size, and its
        // routing is the part that has already gone wrong: `DevToolsTarget`
        // carries a comment about evaluation being sent to the wrong world and
        // failing as "no such method", which reads like a missing feature
        // rather than a misroute. So the dispatch sources go out too, and the
        // checker calls the real ones rather than a re-description of them.
        let devTools: [String: Any] = [
            "methods": DevToolsMethod.allCases.map {
                ["name": $0.rawValue, "target": $0.target.rawValue]
            },
            "dispatch": [
                DevToolsTarget.agent.rawValue: DevToolsAgent.dispatchScript,
                DevToolsTarget.page.rawValue: ConsoleAgent.dispatchScript,
                DevToolsTarget.network.rawValue: NetworkAgent.dispatchScript,
            ],
            // Which dumped file installs each target's dispatcher. The one
            // mapping the checker can't derive, kept beside the table above so
            // the two move together.
            "scripts": [
                DevToolsTarget.agent.rawValue: "devtools.js",
                DevToolsTarget.page.rawValue: "console.js",
                DevToolsTarget.network.rawValue: "network.js",
            ],
        ]

        do {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            for (name, source) in scripts {
                try source.write(
                    to: url.appendingPathComponent(name), atomically: true, encoding: .utf8
                )
            }
            try JSONSerialization.data(withJSONObject: pageAgent)
                .write(to: url.appendingPathComponent("methods.json"))
            try JSONSerialization.data(withJSONObject: devTools)
                .write(to: url.appendingPathComponent("devtools.json"))
        } catch {
            FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

/// The element-pick capture methods — installed on first use, not at load.
///
/// Deliberately not part of `page.js`: that script is parsed at documentStart
/// in every frame of every page, and its size budget exists because that is
/// a per-page-load cost. Capture is armed a handful of times a day, so its
/// listeners pay their parse cost when someone actually reaches for the
/// screenshot pick — one evaluate per document, idempotent thereafter.
enum CaptureDomain {

    static var installScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent) { return; }
          if (agent.state.captureInstalled) { return; }
          agent.state.captureInstalled = true;

          // ---- Element-pick capture --------------------------------------
          //
          // Armed by the screenshot button, not by dev tools. Hover reports
          // the element under the pointer; the native overlay draws the
          // highlight (an injected one would answer elementFromPoint and
          // poison its own hovers). Click chooses — suppressed in the capture
          // phase so a link picked for its screenshot doesn't also navigate.
          agent.define('capture.begin', () => {
            if (agent.state.capturePick) { return true; }
            const onMove = (event) => {
              const el = document.elementFromPoint(event.clientX, event.clientY);
              if (!el) { return; }
              const rect = el.getBoundingClientRect();
              agent.emit('capture', 'hover', {
                x: rect.x, y: rect.y, width: rect.width, height: rect.height
              });
            };
            const onClick = (event) => {
              event.preventDefault();
              event.stopPropagation();
              const el = document.elementFromPoint(event.clientX, event.clientY);
              const rect = el ? el.getBoundingClientRect() : null;
              if (!rect) { return; }
              // The element itself is kept, not just its rect. The full-page
              // capture lays the document out at another viewport size, and
              // the page *reflows* — vh heroes, centred columns, responsive
              // grids all move — so a rect measured now addresses a layout
              // that will not exist when the snapshot is taken. capture.rect
              // asks again, after.
              agent.state.capturePicked = el;
              agent.emit('capture', 'picked', {
                x: rect.x, y: rect.y, width: rect.width, height: rect.height,
                scrollX: window.scrollX || 0, scrollY: window.scrollY || 0
              });
            };
            const onKey = (event) => {
              if (event.key !== 'Escape') { return; }
              event.preventDefault();
              agent.emit('capture', 'cancelled', {});
            };
            window.addEventListener('mousemove', onMove, { capture: true, passive: true });
            window.addEventListener('click', onClick, { capture: true });
            window.addEventListener('keydown', onKey, { capture: true });
            agent.state.capturePick = { onMove: onMove, onClick: onClick, onKey: onKey };
            document.documentElement.style.setProperty('cursor', 'crosshair', 'important');
            return true;
          });

          // The picked element's rect as of *now* — called after the
          // full-page relayout, when the pick-time rect has gone stale.
          agent.define('capture.rect', () => {
            const el = agent.state.capturePicked;
            // One-shot: read and release, so a picked node never outlives
            // its capture just because it was kept for the re-measure.
            agent.state.capturePicked = null;
            if (!el || !el.getBoundingClientRect) { return null; }
            const rect = el.getBoundingClientRect();
            return {
              x: rect.x, y: rect.y, width: rect.width, height: rect.height,
              scrollX: window.scrollX || 0, scrollY: window.scrollY || 0
            };
          });

          agent.define('capture.end', () => {
            const armed = agent.state.capturePick;
            if (!armed) { return true; }
            window.removeEventListener('mousemove', armed.onMove, { capture: true });
            window.removeEventListener('click', armed.onClick, { capture: true });
            window.removeEventListener('keydown', armed.onKey, { capture: true });
            agent.state.capturePick = null;
            document.documentElement.style.removeProperty('cursor');
            return true;
          });

        })();
        """
    }
}
