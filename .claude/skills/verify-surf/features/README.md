# Surf feature map

One file per user-facing feature. Each says what it is, how a user reaches it, how to drive it with the `verify-surf` scripts, and which observable state proves it. Add a file when a feature ships; fix one when its log lines or fixture change.

| Feature | Driver | Fixture |
|---|---|---|
| [page-load.md](page-load.md) — open pages, several tabs, content blocking | `SURF_URL` | any, `testpages/heavy.html` |
| [focus-article.md](focus-article.md) — the native reader | `SURF_FOCUS=1` | `testpages/focus-demo.html` |
| [focus-recipe.md](focus-recipe.md) — the recipe lens | `SURF_FOCUS=1` | `testpages/recipe-demo.html` |
| [narration.md](narration.md) — read aloud with lyric sync | `SURF_FOCUS=2` | `testpages/focus-demo.html` |
| [devtools.md](devtools.md) — the attached inspector panel | `SURF_DEVTOOLS=<pane>` | `testpages/styles-demo.html`, `console-demo.html` |
| [media-and-popout.md](media-and-popout.md) — now-playing, theater, pop-out | human | `testpages/media-demo.html` |
| [focus-youtube.md](focus-youtube.md) — the YouTube site lens | `SURF_FOCUS=1` | youtube.com (no fixture) |
| [focus-amazon.md](focus-amazon.md) — the Amazon site lens, incl. the cart | `SURF_FOCUS=1` | amazon.com (no fixture) |
| [menu-bar.md](menu-bar.md) — the nine menus, dynamic tab and island lists | Accessibility API | any |
| [mini-window.md](mini-window.md) — the floating panel for uncommitted links | context menu + `CGEvent` | `testpages/context-demo.html` |
| [window-frame.md](window-frame.md) — how big the main window opens, and what it remembers | launch + Accessibility API | any |

Not yet mapped (human-driven, no log hook): downloads, element capture/screenshots, address palette. Split panes and island switching have no log hook either, but both are reachable through the menu bar, which `menu-bar.md` drives. Map them before claiming a proof that touches them.
