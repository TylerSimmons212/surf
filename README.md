# Glass

A web browser for macOS, built in Swift + SwiftUI.

## Status

Working tabbed browser: type a search or an address on the home screen and it
loads, with back/forward/reload/stop, a live progress bar, and tabs. Links with
`target="_blank"` open in a new tab; scripted popups are blocked.

Tabs live in an Arc-style sidebar that reveals on hover near the left window
edge, and can be pinned open with `⌘S`. Tabs, window size, and window position
all restore on relaunch — including each tab's back/forward history and scroll
position.

### Shortcuts

| | |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab (the last one is replaced by a fresh tab) |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`–`⌘8` | Select tab by position |
| `⌘9` | Select last tab |
| `⌘L` | Focus the address field |
| `⌘S` | Pin / unpin the sidebar |

## Run

```
swift run
```

Or build a real app bundle (needed if you want to launch it from Finder):

```
./scripts/bundle.sh && open Glass.app
```

Tests:

```
swift test
```

## Layout

Pure logic lives in `GlassCore` with no AppKit or WebKit imports, which is what
makes it unit-testable — the UI targets can't be.

- `Sources/GlassCore/URLResolver.swift` — decides address vs. search
- `Sources/GlassCore/TabSelection.swift` — tab index math (close, cycle, ⌘N)
- `Sources/GlassCore/PersistedSession.swift` — session file model and IO
- `Sources/GlassCore/FaviconPicker.swift` — chooses which declared icon to fetch
- `Sources/Glass/GlassApp.swift` — app entry, `NSApplication` setup, ⌘-shortcuts
- `Sources/Glass/BrowserSession.swift` — owns the tabs and the selection
- `Sources/Glass/Tab.swift` — one tab: its `WKWebView` and observed state
- `Sources/Glass/ContentView.swift` — tab bar + selected tab's content
- `Sources/Glass/Sidebar.swift` — the vertical tab list
- `Sources/Glass/HoverZone.swift` — click-through edge hover detection
- `Sources/Glass/FaviconStore.swift` — favicon fetch, memory + disk cache
- `Sources/Glass/SearchView.swift` — the centered home search bar
- `Sources/Glass/BrowserChrome.swift` — toolbar, address field, progress bar
- `Sources/Glass/VisualEffectBackground.swift` — the transparent blurred window

## Dev

`GLASS_URL=example.com swift run` boots straight to a page and logs load
results to stderr — handy for exercising navigation without clicking.
Comma-separate to open several tabs: `GLASS_URL=example.com,apple.com swift run`.

State lives in `~/Library/Application Support/Glass/session.json`.

## Next

- History and a back/forward menu on long-press
- Search engine preference (DuckDuckGo is the default; Google is implemented)
- Tab reordering by drag, and ⌘⇧T to reopen a closed tab
- Downloads, find-in-page, bookmarks
