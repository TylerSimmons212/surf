# Mini windows

A floating panel holding one page nobody has committed to, with **Open in Surf**
to keep it. `MiniWindowController` owns the panel; the tab inside is a real
`Tab` that its island does not list, so promoting is `append` and dismissing is
`teardown`. Its chrome is one bar across the top — close, address, copy, Open in
— with the page starting below it.

## Driving it

No environment driver — it opens from the page context menu. Use
`testpages/context-demo.html`, whose link sits at page (550, 140), i.e. screen
(550, 173) with the window filling a 1512×949 visible frame:

1. Right-click the link (`CGEvent`, see [menu-bar.md](menu-bar.md)).
2. `key code 125` ×3, then `key code 36` — "Open Link in Mini Window" is the
   third item for a link hit. **Count the items before trusting that number**;
   the list is built per hit kind.

**Move the pointer along a path into the link before right-clicking.** The
page's hit report is pushed from pointer movement, so a right-click at a spot
the pointer is already sitting on reports the *previous* hit — which shows up as
`context: hit bare` and a stock WebKit menu with none of Surf's items in it.
Teleporting the pointer straight to the target is not enough either; post a
handful of intermediate `mouseMoved` events. Expect this to be flaky regardless:
in one session every hit came back `bare` including over the image block, with
no change to the page or the window. Confirm `context: hit link=…` in the log
before reading a menu result as anything.

## What proves it

`[surf] mini:` lines in stderr — `opened <url> in <island>`, `promoted into
<island>`, `dismissed` — plus:

| Check | Oracle |
|---|---|
| the panel exists | a second CoreGraphics window for the pid, at layer 3 |
| it opens the right size | `MiniWindowSizing.size(forVisible:)` — 832×560 on a 1512×949 visible frame |
| Escape dismisses | window count back to 1, one `dismissed` line |
| promotion keeps the page | the Window menu's tab list gains the page's title |
| the bar drags the window | the panel's CG origin moves by **exactly** the drag delta |
| the address field works | type an address, `key code 36`, and a `loaded <url>` line follows |

The panel's own controls are not readable — like every other window here it is
one opaque `AXGroup` — so click them by coordinate, measured from the panel's CG
bounds. The bar is 46pt tall at the top of the panel; its controls are 30pt and
centred, which leaves an 8pt strip along the top and bottom of the bar that
belongs to the drag area rather than to any control. That strip is where a drag
test should start.

**Sweeping for a button can destroy its own subject.** Open in Surf is wide; a
sweep that starts near the right edge promotes on its first step and every later
click lands on a panel that is no longer there, reading as "nothing happened" all
the way across. Check the window count between steps and stop when it drops.

Drag with stepped `leftMouseDragged` events, not one jump: `performDrag(with:)`
runs its own event loop and follows dragged events, so a single teleport can be
missed entirely.

Escape dismisses, and focus should return to the opener — check with
`get size of (value of attribute "AXFocusedWindow")`, which goes from the
panel's size to the main window's.

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

Nothing about how any of it *looks* — the glass, the hover and focus states, the
copy tick — has been seen. `screencapture` needs Screen Recording granted to the
terminal, and without it every check here is geometry and behaviour only. This is
not a small gap: the bar's controls once had hover events arriving correctly and
drew no hover at all, because the panel was non-activating and AppKit was
rendering the whole row inactive. Every log line said it was working.
