import Foundation
import GlassCore
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

    /// - Parameter themePreflight: the scheme to paint before the page's own
    ///   styles arrive, or nil when Glass isn't restyling this page at all.
    @MainActor
    static func install(
        on controller: WKUserContentController,
        themePreflight: ColorSchemeTarget?
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
    /// `GLASS_DUMP_SCRIPTS` names one.
    ///
    /// The agent's contract has two halves in two languages: a method Swift
    /// declares and a method JavaScript registers. Nothing compiles the second
    /// half, so nothing catches a name that exists on only one side — the
    /// failure is a feature that silently stops working, months later, in one
    /// world. `scripts/check-js.sh` closes that by asking the real scripts,
    /// with a real JavaScript engine, whether they answer to everything
    /// `PageProtocol.Method` claims.
    static func dumpAndExitIfAsked() {
        guard let directory = ProcessInfo.processInfo.environment["GLASS_DUMP_SCRIPTS"]
        else { return }

        let scripts: [String: String] = [
            "runtime-isolated.js": PageRuntime.source(for: .isolated),
            "runtime-page.js": PageRuntime.source(for: .page),
            "theme.js": ThemeBridge.domainScript,
            "page.js": PageDomain.domainScript,
            "media.js": MediaBridge.domainScript,
            "find.js": FindBridge.domainScript,
            "preflight.js": ThemeBridge.preflightScript(for: .dark),
        ]

        // The method table itself, so the checker compares against the enum
        // rather than against a copy of it that can drift.
        let methods = PageProtocol.Method.allCases.map {
            ["name": $0.rawValue, "world": $0.world.rawValue]
        }

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
            try JSONSerialization.data(withJSONObject: methods)
                .write(to: url.appendingPathComponent("methods.json"))
        } catch {
            FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
