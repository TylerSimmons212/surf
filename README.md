# Glass

A web browser for macOS, built in Swift + SwiftUI.

## Status

Working single-page browser: type a search or an address on the home screen and
it loads, with back/forward/reload/stop and a live progress bar. No tabs yet.

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

- `Sources/GlassCore/URLResolver.swift` — decides address vs. search. No UI
  dependencies, which is what makes it unit-testable.
- `Sources/Glass/GlassApp.swift` — app entry point and `NSApplication` setup
- `Sources/Glass/BrowserEngine.swift` — owns the `WKWebView`, mirrors its state
- `Sources/Glass/ContentView.swift` — switches between home and browsing
- `Sources/Glass/SearchView.swift` — the centered home search bar
- `Sources/Glass/BrowserChrome.swift` — toolbar, address field, progress bar
- `Sources/Glass/VisualEffectBackground.swift` — the transparent blurred window

## Dev

`GLASS_URL=example.com swift run` boots straight to a page and logs load
results to stderr — handy for exercising navigation without clicking.

## Next

- Tabs (needs a `Tab` model before any UI)
- History and a back/forward menu on long-press
- Search engine preference (DuckDuckGo is the default; Google is implemented)
- Downloads, find-in-page, bookmarks
