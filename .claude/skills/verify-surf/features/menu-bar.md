# Menu bar

The nine menus — Surf, File, Edit, View, History, Islands, Develop, Window,
Help — declared in `Sources/Surf/SurfApp.swift`, one computed `Commands`
property per menu. Islands stands where a browser's Bookmarks menu would be,
because a sticker belongs to an island rather than to the app.

The tab list in Window and the island list in Islands are built from what is
actually open, not from fixed slots, so the menu is evidence of the app's state
and can be read as such.

## Driving it

No environment driver and no click needed: the Accessibility API reads the menu
bar out of a running instance.

**Target the pid, never the name.** `process "Surf"` matches the first Surf on
the machine, which may be another worktree's build or the user's own — it will
answer happily with the wrong app's menus, and the reply looks entirely valid.

```bash
P=$(cat .verify/<run>/pid)
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to get name of every menu bar item of menu bar 1"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to get name of every menu item of menu 1 of menu bar item \"Window\" of menu bar 1"
```

Per-item attributes, on `every menu item` of a menu:

| Attribute | Proves |
|---|---|
| `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers` | the shortcut actually bound, not the one intended |
| `AXMenuItemMarkChar` | the checkmark on the current tab or island |
| `enabled` | a `.disabled(…)` that fires |

`missing value` in a name list is a separator. Arrow-key shortcuts report an
empty `CmdChar`; that is not a missing binding.

Items can be invoked, which is how a toggling item is proven from both sides:

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to click menu item \"Split With Next Tab\" of menu 1 of menu bar item \"Window\" of menu bar 1"
```

Needs Accessibility permission for the terminal or host app. Without it
`osascript` errors rather than answering wrongly, so a reply is trustworthy.

## What proves it

- Nine menu bar items in the order above.
- Window lists the open tabs by `displayTitle` on ⌘1–⌘8, ⌘9 for the last once
  there are more than eight, and exactly one carries a mark char.
- Islands lists the islands that exist on ⌥⌘1–⌥⌘9, current one marked.
- Window carries one "Show Previous Tab" and one "Show Next Tab", not two:
  AppKit's native window tabbing adds a shortcut-less pair of the same names
  and splits the group in half, which `NSWindow.allowsAutomaticWindowTabbing =
  false` in `AppDelegate` suppresses.
- Clicking "Split With Next Tab" turns that item into "Close Split" and reveals
  "Swap Split Sides"; both halves share ⇧⌘D.

## Context menus do not answer

The menu *bar* is fully readable. The right-click menus are not, and the reason
is worth knowing before spending an afternoon on it: this app's window exposes a
single opaque `AXGroup` with zero children.

```bash
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to get count of (entire contents of window 1)"
# 0
```

So there is no row, chip or tile to find, nothing to send `AXShowMenu` to, and
no `AXMenu` window appears in the process when a context menu is open — a
synthesised right-click via `CGEvent` opens the menu on screen without it ever
becoming readable. SwiftUI publishes no accessibility hierarchy here.

Menu bar items *can* be clicked, and that reaches any state a context menu also
reaches, which is the usable substitute: `click menu item "Pin Sidebar"` flips
the pref and the item's own title changes to "Unpin Sidebar", proving the round
trip. Restore anything toggled this way — `@AppStorage` writes to the real user
defaults domain, not into `SURF_STATE_DIR`.

Context menu contents themselves are human-verified. Hand over the surface, the
right-click target, and the expected items.

## The page context menu

Surf's items are inserted at the front of WebKit's menu (`Tab.willOpenContextMenu`).
The menu is no more readable than any other context menu, but it is verifiable,
because both the driving and the oracle live outside it.

Drive: `SURF_URL=testpages/context-demo.html`, whose targets sit at known page
coordinates (link y≈140, image y≈350, video y≈580, prose y≈760; the page's
origin is the window's). Synthesise a right-click with a `CGEvent` from a Swift
script, then `key code 125` per item down and `key code 36` to activate.

Read `[surf] context:` in stderr — one `hit` line per right-click saying what the
page found, one `menu` line saying how old that hit was when the menu opened. A
`no hit in hand` means the push lost the race and the menu degraded to stock.

Oracles for what an item actually did, neither of which needs the menu:

| Item | Proof |
|---|---|
| Open Link in New Tab | the Window menu's tab list grows, and the new title appears in it |
| Copy Image Address | `pbpaste`. Prime the pasteboard with a sentinel first — and warn whoever owns the machine, this destroys their clipboard |

Check the *order* of the items before counting arrow presses: the list is built
per hit kind, so a link's first item is not an image's first item.
