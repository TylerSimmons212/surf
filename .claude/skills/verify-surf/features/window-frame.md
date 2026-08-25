# The main window's size

Surf opens at the size of the display the first time, and at whatever you left
it every time after. `WindowPlacement` (SurfCore) does the arithmetic;
`MainWindowFrame` (Surf) applies it, remembers it, and keeps SwiftUI out of it.

## Driving it

No environment driver. Launching at all exercises the opening path; the
remembering path needs the window moved or resized, which the Accessibility API
can do without a human:

```bash
P=$(cat .verify/<run>/pid)
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to set frontmost to true"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to tell window 1 to set size to {1240, 780}"
```

Restoring needs a second launch against the **same** state directory, which
`launch.sh` will not do — it makes a fresh one each run. Kill the pid by hand
rather than `stop.sh` (which deletes the scratch suite along with the state
directory), then relaunch the binary yourself:

```bash
H=$(cat .verify/<run>/state)
kill "$(cat .verify/<run>/pid)"
SURF_STATE_DIR="$H" SURF_SILENT=1 SURF_URL="file://$PWD/testpages/focus-demo.html" \
  .build/out/Products/Debug/Surf 2>>.verify/<run>/stderr.log &
```

AX resize anchors the top-left corner, so it moves the AppKit origin as well as
the size. That is why it fires `didMove` and gets saved; a resize that only grew
the window to the right would need `didResize`, which is why both are observed.

`AXFullScreen` drives the full-screen guard, and `keystroke "f" using {command
down, control down}` does **not** — Surf binds no such key and System Events
sends it nowhere useful. It reads as a pass if you don't check the bounds:

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to tell window 1 to set value of attribute \"AXFullScreen\" to true"
```

## What proves it

`[surf] window:` in stderr — `opening at <rect>` or `restoring to <rect>` — is
the decision. It is logged twice per launch on purpose: once before SwiftUI's
turn and once after, and the second is the one that survives.

| Check | Oracle |
|---|---|
| opens at screen size | `opening at` matches `NSScreen.main!.visibleFrame`, and `window.sh` records the same width×height |
| the width cap | not reachable on a display narrower than 1800pt — this is a `WindowPlacementTests` case, not a run |
| a resize is remembered | `defaults read "$(cat "$(cat .verify/<run>/state)/defaults-suite")" mainWindowFrame` |
| it comes back | second launch logs `restoring to` with that rect; `window.sh` agrees |
| full screen saves nothing | the key is unchanged across an `AXFullScreen` true/false round trip |

Take the `window.sh` record as well as the log line. The log says what Surf
asked for; only the CoreGraphics bounds say what is on screen, and AppKit is
free to disagree.

## The isolation check

This feature is the reason `SURF_STATE_DIR` covers window frames at all, so
prove that too — the real domain for an unbundled run is `Surf`, and for the
bundle `com.surf.browser`:

```bash
defaults read Surf 2>/dev/null | grep -c "NSWindow Frame SwiftUI.WindowGroup"   # 0
defaults read Surf mainWindowFrame                                              # not found
```

Both must hold *after* a run that resized the window and quit. Zero is not the
resting state of the first one by accident: SwiftUI writes that key every launch
and `MainWindowFrame` sweeps it back out, once 750ms in and again on close.
Seeing 1 there means the sweep's timing has drifted, not that the check is wrong.

## Not yet proven

Anything with a second display attached: which screen a remembered frame returns
to, and a frame saved on a monitor that is then unplugged. Both are covered by
`WindowPlacementTests` as arithmetic; neither has been driven against real
hardware.

The width cap has never been seen, for the same reason — no display here is
wider than 1800 points.
