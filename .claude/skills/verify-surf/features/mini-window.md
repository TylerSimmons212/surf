# Mini windows

A floating panel holding one page nobody has committed to, with **Open in Surf**
to keep it. `MiniWindowController` owns the panel; the tab inside is a real
`Tab` that its island does not list, so promoting is `append` and dismissing is
`teardown`.

## Driving it

No environment driver — it opens from the page context menu. Use
`testpages/context-demo.html`, whose link sits at page y≈140:

1. Right-click the link (`CGEvent`, see [menu-bar.md](menu-bar.md)).
2. `key code 125` ×3, then `key code 36` — "Open Link in Mini Window" is the
   third item for a link hit. **Count the items before trusting that number**;
   the list is built per hit kind.

## What proves it

`[surf] mini:` lines in stderr — `opened <url> in <island>`, `promoted into
<island>`, `dismissed` — plus:

| Check | Oracle |
|---|---|
| the panel exists | process window count goes 1 → 2 |
| Escape dismisses | count back to 1, one `dismissed` line |
| promotion keeps the page | the Window menu's tab list gains the page's title |

The panel's own controls are not readable — like every other window here it is
one opaque `AXGroup` — so click them by coordinate. The panel is 1000x680; find
it by size rather than assuming it is `window 1`, because the ordering changes
and the main window answers happily in its place.

Measured, relative to the panel's frame:

| Control | Where | Oracle |
|---|---|---|
| Close | (left+34, top+34) | window count drops, `mini: dismissed` |
| Copy link | (right-150, top+34) — (right-184) with a caret | `pbpaste` — prime a sentinel first |
| Open in Surf / Open in <island> | (right-60, top+34); **(right-103) once a caret appears** | `mini: promoted`, tab list grows |
| Island caret | (right-24, top+34), only with 2+ islands | menu opens; Down/Return picks |
| Drag strip | anywhere in the top 52pt clear of the buttons | panel `position` moves by the drag delta |

**Sweeping for a button can destroy its own subject.** Open in Surf is wide; a
sweep that starts near the right edge promotes on its first step and every later
click lands on a panel that is no longer there, reading as "nothing happened" all
the way across. Check the window count between steps and stop when it drops.

Drag with stepped `leftMouseDragged` events, not one jump: `performDrag(with:)`
runs its own event loop and follows dragged events, so a single teleport can be
missed entirely.

Escape dismisses, and focus should return to the opener — check with
`get size of (value of attribute "AXFocusedWindow")`, which goes from the
panel's 1000x680 to the main window's size.

## A second island

Needed for anything about island choice, and cheap to make: click **Islands >
New Island**, `keystroke "Work"`, then `key code 36` — the editor's Done button
carries `.defaultAction`, so Return commits it. The Islands menu then lists both,
with `AXMenuItemMarkChar` marking the current one.

Both island paths are proven. Opening in Home, switching the main window to Work
with `⌥⌘2`, then promoting files the tab into **Home** and switches back to it —
never into whatever island is current. Picking Work from the caret instead logs
`promoted into Work` and the page arrives in Work's list, freshly fetched rather
than carried over.

## Links from other apps

Needs a real bundle — `swift run` cannot be registered with Launch Services — and
does **not** need Surf to be the default browser: `open -a` targets an app
directly, which exercises the same `application(_:open:)` path without changing
a system-wide setting. Never set the default browser to test this.

```bash
./scripts/bundle.sh
STATE=$(mktemp -d)
SURF_STATE_DIR="$STATE" SURF_URL="file://$PWD/testpages/context-demo.html" SURF_SILENT=1 \
  ./Surf.app/Contents/MacOS/Surf 2>/tmp/surf-ext.log &
open -a "$PWD/Surf.app" "https://example.com/from-another-app"
grep -E "external:|mini:" /tmp/surf-ext.log
```

Launch the binary *inside* the bundle by hand so `SURF_STATE_DIR` and `SURF_URL`
are set, then use `open -a` to deliver links to that running instance. Going
through `open` for the launch itself sends stderr to the system log, where the
`[surf]` lines are effectively unreadable.

The bundle reads its defaults from the real `com.surf.browser` domain, not from
`SURF_STATE_DIR`. To exercise the tab branch, `defaults write com.surf.browser
externalLinksInMiniWindow -bool false` — and `defaults delete` it afterwards.

## Not yet proven

A link arriving *before* the session exists, which `ExternalLinks` queues for.
`SurfApp.init` builds the session very early, so this may be unreachable in
practice; the `link(s) queued` log line is how you would know it ever fired.

Nothing about how any of it *looks* — the glass, the hover growth, the copy
tick — has been seen. `screencapture` needs Screen Recording granted to the
terminal, and without it every check here is geometry and behaviour only.
