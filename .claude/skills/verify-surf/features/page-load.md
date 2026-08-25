# Page load

Opening a page in a tab: navigation, the content blocker priming and applying, the title reaching the window.

## Sub-features

- Single page load, title in the window
- Several tabs at once (`SURF_URL=a,b`)
- Content blocking: filter lists ready before the first page, blocked counts per page

## How to get to it (user POV)

`⌘L` opens the address palette; type a URL or search and press return. Each tab shows its page title in the sidebar and the window title.

## Driving it with verify-surf

```bash
.claude/skills/verify-surf/scripts/launch.sh load "file://$PWD/testpages/heavy.html"
.claude/skills/verify-surf/scripts/window.sh load
.claude/skills/verify-surf/scripts/stop.sh load
```

Several tabs: pass `"file://$PWD/testpages/heavy.html,https://example.com"` and wait for the second `loaded` line (`launch.sh load <urls> 'loaded https://example.com'`).

Tabs a page opens for itself: `testpages/popup-demo.html` has a `target="_blank"`
link, the same pointed at a host that answers in three seconds, and a
`window.open()` button. All three go through `createWebViewWith`, so proving one
proves the path — but the slow one is the only one that makes the timing visible.
Such a tab must never show the home screen: it is selected the moment it exists
and nothing calls `submit` on it, so any window where `mode` is `.home` is a
window where the water animation is on screen. Log `tab.mode` at creation to
check; it should already read `browsing`.

## What proves it

- `stderr.log`: `[surf] rules ready — N lists, M blocked domains` before `[surf] loaded <url>` (the blocker is applied before the first page, `Sources/Surf/ContentBlocker.swift`). In a fresh state directory this reads `0 lists`, followed later by `EasyList: … rules converted` and `EasyList installed` once the download lands; a second run in the same directory primes from that cache.
- `[surf] loaded file:///…/heavy.html` for each URL.
- `windows.txt`: a window over 300 px wide is on screen; with Screen Recording permission its title equals the page's `<title>`.
- For a real site: `[surf] blocked N from M, K contacted` (`Tab.swift:555`).

## Gotchas

- A scratch state directory has no cached filter lists, so the first page of a run is unblocked; to test blocking, wait for `EasyList installed` before navigating, or point `SURF_STATE_DIR` at a directory from a previous run.
- `closed a window whose only load failed` means the URL was unreachable, not a Surf bug. Check the fixture path.
