# Dev tools

An inspector panel attached to a tab: Elements, Styles, Network, Storage, Tags, Speed, Console. The injected half (`console.js`, `network.js`, `devtools.js`) exists only while a panel is attached. `Sources/Surf/DevToolsController.swift`, `DevToolsBridge.swift`, protocol in `SurfCore/DevToolsProtocol.swift`.

## Sub-features

- Attach and the initial DOM snapshot
- Per-pane behavior (element editing, style cascade, console REPL, request replay)
- Method routing across the three injected scripts

## How to get to it (user POV)

Open a page, then the dev tools control on the pane rail (or the View menu). Panes switch along the rail.

## Driving it with verify-surf

```bash
SURF_DEVTOOLS=console .claude/skills/verify-surf/scripts/launch.sh devtools "file://$PWD/testpages/console-demo.html" 'devtools: attached' 30
.claude/skills/verify-surf/scripts/window.sh devtools
.claude/skills/verify-surf/scripts/stop.sh devtools
```

Any pane name from `DevToolsSession.Pane` works: `elements`, `styles`, `network`, `storage`, `tags`, `performance`, `console`. Pair with the matching fixture (`styles-demo.html`, `layout-overlay.html`, `force-state.html`).

## What proves it

- `devtools: attached — N nodes at <url>` with N > 0: the agent installed, the bridge round-tripped, and the DOM was walked.
- No `devtools: <method> failed — …` lines during attach. One of these naming `unknown method` is the routing failure described in the README; run `./scripts/check-js.sh` to pin which world it was sent to.
- Pane interactions (editing a rule, replaying a request) are click-driven; the Swift models behind them are covered by `swift test --filter CSS`, `Console`, `Network`, `DOMTree`.

## Gotchas

- Attach waits 2 s after launch for the first document to commit; attaching to `about:blank` and navigating is a different path. Don't shorten the wait.
- The contract between `DevToolsMethod` and the scripts is checked offline by `scripts/check-js.sh` (needs `node`). Run it first when a pane is blank; it is faster than launching.

## Trusted Types

`testpages/trusted-types.html` sends `require-trusted-types-for 'script'`, which
is what YouTube sends. Every string handed to a code sink throws there, and the
console prompt is a sink — so evaluation went through a Trusted Types policy
rather than a bare string.

Drive it, and read three things off the log:

```bash
SURF_DEVTOOLS=console SURF_CONSOLE=$'var ttX = 1\nttX + 41\nwindow.surfFixture.where' \
  .claude/skills/verify-surf/scripts/launch.sh tt "file://$PWD/testpages/trusted-types.html"
```

- `result log — 42` on the second line: the policy worked **and** global scope
  survived, which is the part a function body injected from outside would lose.
- `result log — trusted-types`: page state is visible, so evaluation really is
  in the page's own world.
- Exactly **one** `CSP blocked trusted-types-sink` line, against the first entry
  only. A bare string is tried once per document and the refusal remembered; one
  violation is true and informative, one per keystroke is noise.

The control is any ordinary page: `var` persists, nothing is logged about CSP,
and no policy is registered, because the policy is only ever created after a
refusal.
