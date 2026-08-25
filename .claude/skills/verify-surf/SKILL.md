---
name: verify-surf
description: "Drive the real Surf app (macOS browser, Sources/Surf) the way a user does and capture proof: launch an isolated instance, exercise a feature, collect stderr and window evidence, tear down. Use after changing anything in Sources/Surf or the injected JS, when a unit test can't reach the behavior, or when asked to prove a feature works."
---

# Verify Surf

Surf is a SwiftUI + WebKit app. Unit tests cover `SurfCore`; everything in `Sources/Surf` (tabs, Focus, narration, dev tools, pop-out, downloads) is only provable by running the app. This skill is the scripted way to do that. Generated with the pstack `create-verification-skill` recipe, then executed once against this checkout.

Read [features/README.md](features/README.md) for the feature map before driving anything: a proof that exercises one convenient entry point is incomplete when the map lists others.

## Launch

```bash
swift build                                   # once; launch.sh reuses the binary
.claude/skills/verify-surf/scripts/launch.sh <run> <url> [wait-regex] [timeout]
```

`launch.sh` starts one instance with `SURF_STATE_DIR` pointed at a scratch directory, so the run never reads or writes `~/Library/Application Support/Surf` (session, history, favicons, filter lists, voices). Overriding `HOME` does not achieve this — `FileManager` resolves Application Support from the account — which is why the override exists (`SupportDirectory` in `Sources/SurfCore/PersistedSession.swift`).

Two things are keyed by application domain rather than by directory, and so
needed their own seams — a directory override alone does not reach them:

- **User defaults.** `SurfDefaults.store` (`Sources/SurfCore/SurfDefaults.swift`)
  hands a scratch run its own suite, named after the state directory. Nothing
  in `Sources/` may say `UserDefaults.standard`; that is the whole point of
  the seam. The suite's name is written to `<state>/defaults-suite` so
  `stop.sh` can remove both the domain and its plist.

  One deliberate exception, in `MainWindowFrame.sweepOrphanedFrames`, which
  *deletes* from the standard domain and never reads or writes state there.
  SwiftUI saves the main window's frame under a key of its own choosing every
  launch, to the standard domain, where no seam can redirect it; the sweep
  takes it back out. Removing it is the only way the promise above stays true
  for the window's own geometry.
- **Compiled blocking rules.** `WKContentRuleListStore.surf`
  (`Sources/Surf/ContentBlocker.swift`) compiles into `<state>/ContentRules`
  rather than WebKit's shared store, which sits beside the app's own data.
  Expect ~116MB per run; `stop.sh` takes it with the state directory.

- **The main window's frame.** Kept by `MainWindowFrame` under
  `mainWindowFrame` in the suite above, rather than by AppKit's
  `setFrameAutosaveName`, which always writes to the standard domain. See
  [features/window-frame.md](features/window-frame.md) for how to prove both
  the placement and the isolation.

Before these existed a run shared `blockListIdentifiers`, the `blockAds`
preference and the compiled rule sets with whatever Surf you had open — and
`discardStaleLists` would remove the ones it did not recognise. Nothing broke,
because both sides recompile. It was still not what this file says. It waits for the stderr pattern (default `[surf] loaded `) and prints the evidence directory `.verify/<run>/`. Exit 1 means the pattern never came; the log says why.

Drivers are environment variables read at launch (`Sources/Surf/ContentView.swift`, `applyLaunchEnvironment`):

| Var | Effect |
|---|---|
| `SURF_URL` | page(s) to open; comma-separate for several tabs |
| `SURF_FOCUS=1` | enter Focus once the page settles; `2` also starts narration |
| `SURF_SILENT=1` | mute narration (launch.sh sets this by default) |
| `SURF_DEVTOOLS=<pane>` | open dev tools on `elements/styles/network/storage/tags/performance/console` |
| `SURF_STATE_DIR=<dir>` | replace `~/Library/Application Support/Surf` (launch.sh sets this) |

Fixtures live in `testpages/`; pass them as `file://$PWD/testpages/<name>.html`.

Tear down with `scripts/stop.sh <run>`. It kills only the pid it started and removes the scratch state directory; evidence stays.

## Doctor

Before driving, confirm the instance is worth driving:

```bash
kill -0 "$(cat .verify/<run>/pid)" && head -3 .verify/<run>/stderr.log
```

Healthy: process alive, first lines are `[surf] rules …` then `[surf] loaded <url>`. A log with `closed a window whose only load failed` or no `loaded` line is a broken launch; fix that before reading anything else as a result. Check `pgrep -fl '/Surf$'` if you suspect a stale instance from an earlier run; stop it by its `.verify/<run>/pid`, never by name, because the user's own Surf may be open.

## Drive

Everything reachable by environment is driven at launch; there is no IPC into a running instance. A feature that needs a click (pop-out, downloads, split panes, capture) is driven by a human: hand them the exact sequence from the feature file and the log line that proves it, using `diagnosing-bugs`' HITL loop if it's a bug hunt.

`scripts/window.sh <run> [shot]` records the main window's id, size, and (with permission) title to `windows.txt` and tries a screenshot. Both the title and the screenshot need Screen Recording permission for the terminal or host app running the script; when refused, the window record is still evidence and the script says so.

## Evidence

Proof for a run is the directory `.verify/<run>/`:

- `stderr.log` — every `[surf]`, `agent:`, `devtools:`, `narrate:`, `focus:` line the app wrote. Assert on specific lines, not "no crash".
- `windows.txt` — window id and bounds per snapshot, proving a window is on screen. The title column fills in only when Screen Recording permission is granted (macOS hides other apps' window names without it).
- `<shot>.png` — when permission allows.

Standards: drive the real user path (the env drivers go through the same `Tab` methods a click does); capture the action and the resulting state; check side effects where the feature has them (files in the scratch state directory `.verify/<run>/state`, e.g. `session.json` after a clean quit); no mocks. `.verify/` is gitignored; quote the relevant lines in your report rather than committing the directory.

## Cleanup

```bash
.claude/skills/verify-surf/scripts/stop.sh <run>
```

Run it after every attempt, failed ones included. It never deletes `.verify/<run>/`; delete that yourself only once the report is written.

## Maintenance

When a feature changes, update its file in `features/`; when a new env driver or log line is added in `Sources/Surf`, add it to the tables above. The map drifts silently otherwise.
