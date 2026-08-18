# Glass

A web browser for macOS, built in Swift + SwiftUI.

Requires macOS 26 or later — the chrome uses the current SF Symbols effects
(`rotate`, `drawOn`) with no fallbacks.

## Status

Working tabbed browser: type a search or an address on the home screen and it
loads, with back/forward/reload/stop, a live progress bar, and tabs. Links with
`target="_blank"` open in a new tab; scripted popups are blocked.

The window is nothing but the page, under a slim title strip that tints itself
from the current page's `theme-color` (or its background colour). Navigation controls and tabs live in an
Arc-style sidebar that reveals on hover near the left window edge, and can be
pinned open with `⌘S`. The address bar is a floating palette (`⌘L`, or the
search button in the sidebar) rather than a permanent toolbar — and it's the
only place to type an address, including on a new tab. Each tab row has a link
button that copies its URL.

A tab that's playing media shows a now-playing strip at the bottom of the
sidebar, with play/pause and a button to pop video out into a floating
always-on-top panel. Switching away from a tab that's playing video pops it out
automatically, and returning to the tab folds it back in — toggle it off under
Media in Settings.

Downloads land in `~/Downloads` and appear in a list behind the sidebar's
download button, with progress, cancel, retry, and Show in Finder. The list is
kept in memory only and is empty again on relaunch.

A plain media file is saved by WebKit itself, so it inherits the page's session
and referrer. Video that's streamed in segments — a `blob:` source from Media
Source Extensions, or an HLS/DASH manifest — has no single file to fetch, and is
reassembled from the page instead. Only the cookies for the site being
downloaded from are handed to the reassembler, in a temp file deleted when the
run ends.

Typing in the address bar autocompletes from history, which is held in memory
only unless you turn on "Remember browsing history". Tabs, window size, and window position
all restore on relaunch — including each tab's back/forward history and scroll
position.

### Appearance

Settings (`⌘,`) and the View menu carry one three-way choice: System, Light,
Dark. System follows the Mac, including when it switches at sunset; the other
two stay put, which is the whole point of an override.

There is no colour-scheme API on `WKWebView` — nothing in `WKWebView.h`,
`WKWebViewConfiguration.h`, or `WKWebpagePreferences.h`. What WebKit reads is
the view's `effectiveAppearance`, which it maps onto the `prefers-color-scheme`
media query and re-evaluates live. So the setting writes one property on
`NSApplication` and lets AppKit inheritance carry it to every window, the
chrome, and every tab's web view — including tabs opened later, since a
`WKWebView` sets no appearance of its own. The per-tab lever is the same
property one level down, which is where per-site exceptions will hook in.

That much is free and exact: a site with a dark mode of its own renders in the
design its authors drew, not an approximation of it. A site without one is
currently left alone — Glass doesn't yet invent a dark theme for it.

"Restyle sites that don't offer it" builds one for the rest. It is off by
default, because restyling a page is a far larger intervention than telling it
which scheme you want.

The transform works in OKLCH, where lightness is the theme axis and hue and
chroma are the identity axis. Surfaces and text invert along lightness. A
site's brand colours keep their hue *exactly* and move only as far as
legibility demands — a red button becomes a lighter red, never an orange one —
so a page comes back recognisably itself rather than recognisably processed.
Scale decides the rest: the same blue is preserved on a badge and calmed on a
masthead, because a saturated wall is fatiguing at that size and inverting its
hue would be worse.

Every colour meant to be read is then re-seated against the thing immediately
behind it, not against the page — a label on a brand-coloured button is judged
on that button. Both WCAG's ratio and a perceptual floor have to be satisfied;
the second exists because the ratio flatters equiluminant chromatic pairs, and
a theme that preserves brand colours produces those on purpose.

Borders are judged on separation rather than on colour. What a rule means is
how far it stands from what it sits on, so that gap is measured against the old
background and re-established against the new one — a deliberate heavy divider
stays heavy, a decorative hairline stays faint, and neither is dragged to a
uniform minimum that would make them the same line.

Gradients move as one body rather than stop by stop: transforming each stop
alone reverses the direction the light falls from, which reads as broken rather
than as dark.

Images are left alone, with one exception narrow enough to be safe: a mark
carrying **no colour at all** is inverted, so a black wordmark drawn for a white
page comes back white rather than invisible. There is no hue to shift and no
brand to mangle, and a filter touches only the pixels already being drawn — so
transparency stays transparent and no box appears around the artwork. Anything
with real colour in it is left exactly as it was, even where that leaves it
dim: Wikipedia's wordmark carries a blue badge beside its black letters, and
inverting that would turn the badge orange.

Colourlessness is judged per pixel and weighted by alpha. A logo of a red
circle beside a green one averages to grey and would fool any test of its mean;
and sampled pixels arrive unpremultiplied, so the soft edge of a black wordmark
reads as scattered navy unless the faint pixels are given proportionally little
say.

An inline `<svg>` is a different thing wearing the same clothes. It is DOM
rather than pixels, and it is how most sites now ship their icons, so its paint
is remapped like any other colour and by the same rules: a neutral mark inverts
as text does, and a chromatic one is brand and keeps its hue exactly. A black
chevron comes back light; a green logotype comes back the same green.

A holding colour is painted at document start, before the page's own styles
arrive, so there is no flash of the light version on the way to the dark one —
the flash is a frame the page was always going to draw, and the only cure is to
have an answer in place before it draws one. It works by removing colour rather
than imposing it: backgrounds go transparent so everything shows the one dark
ground beneath, which leaves overlays overlaying instead of turning them into
opaque blocks.

The walk crosses the two boundaries `querySelectorAll` stops at: an open shadow
root, and a same-origin iframe. Between them they hold most of the web's
design-system components and embedded widgets. Shadow DOM needs more than
reaching, because encapsulation runs both ways — a sheet injected into the
document never applies inside one, so marking those elements alone would change
nothing. Each root adopts a single constructed stylesheet carrying the same
rules instead. A cross-origin frame is a document nothing in the page can reach
into, and is left exactly as it is.

Pages don't hold still, so the theme is swept again whenever one changes under
it — a section revealed on scroll, a lazily loaded list, a subtree re-rendered
with our properties torn off, a sticky header that turns opaque. Each sweep
switches our own styles off before reading, so what it sees is always the
site's palette rather than the last answer we gave: that is what lets an
element whose colour changed *in place* be noticed at all, and it means a sweep
can be repeated safely rather than having to skip whatever it already touched.

Which sites need this is measured rather than asked. A page is examined after
it paints, and one already showing the requested scheme is left alone. Declared
signals — a meta tag, a `prefers-color-scheme` rule — say what a site claims;
reading what it painted says what it did, and cross-origin stylesheets can't
hide it.

### Privacy

Glass is private by default and keeps no browsing history. Settings (`⌘,`) has
four switches:

| Setting | Default | Effect |
|---|---|---|
| Remember browsing history | Off | When on, each tab's back/forward list is saved to disk |
| Keep me signed in | On | Retains cookies across quits |
| Reopen tabs on launch | On | Writes open tab addresses to disk — the one setting that stores where you went |
| Clear caches when quitting | On | Wipes WebKit caches and per-site storage, never cookies |

The guarantee is that caches and cookies are independent: clearing where you
went never signs you out. `PrivacyPolicy` encodes that rule and the tests
enforce it.

### Helpers

Stream downloads are done by two binaries Glass runs but doesn't build: yt-dlp
resolves a page to its media, and ffmpeg merges separate video and audio
streams. Neither is a user-visible feature. Settings shows one number — the
Glass version — and nothing about what's inside it, because a version the user
can't act on is noise, and "Glass is current" has to mean everything in it is
current or the number means nothing.

`UpdateManager` keeps them that way: a weekly check at launch, SHA-256 verified
against the publisher's own checksums, installed atomically into
`~/Library/Application Support/Glass/Components`, never prompting and never
reporting. A failed update leaves the previous copy alone and tries again next
week. Resolution runs newest-first — managed copy, then the copy bundled in the
app, then `PATH`, so `swift run` works without a bundle.

The two are handled differently, and the difference is licensing:

| | yt-dlp | ffmpeg |
|---|---|---|
| Licence | Unlicense | GPLv3 — every prebuilt static macOS build |
| Bundled in `Glass.app` | Yes, pinned + checksummed by `bundle.sh` | **No** |
| Source | GitHub releases + `SHA2-256SUMS` | [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de) + `.sha256` sidecar |
| Extra verification | — | Developer ID team pin (`KU3N25YGLU`) |

Bundling an ffmpeg build would put Glass under GPLv3 along with it. Fetching it
at runtime makes the user the recipient rather than Glass the redistributor,
which is the same arrangement yt-dlp itself and HandBrake use. If that ever
needs to change, it means compiling an LGPL ffmpeg (`--disable-gpl
--disable-version3`, minus the GPL codecs) — which would also cost the
publisher signature.

ffmpeg's build IDs are timestamped with no "latest" alias, so the current one is
read off their history page. That scrape is the fragile link, and
`FFmpegRelease.fallback` holds a hand-verified build ID and hash per
architecture so a redesign there costs a slightly older ffmpeg rather than the
feature — and never an unverified download.

### Shortcuts

| | |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab (the last one is replaced by a fresh tab) |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`–`⌘8` | Select tab by position |
| `⌘9` | Select last tab |
| `⌘L` | Open the floating address bar |
| `⌘[` / `⌘]` | Back / forward |
| `⌘R` | Reload |
| `⌘S` | Pin / unpin the sidebar |
| `⌘,` | Settings |

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
- `Sources/GlassCore/PrivacyPolicy.swift` — what gets cleared, what gets stored
- `Sources/GlassCore/HistorySearch.swift` — autocomplete ranking
- `Sources/GlassCore/AppearanceMode.swift` — the three-way scheme setting and
  what it resolves to against the OS
- `Sources/GlassCore/SRGB.swift` — sRGB colour, hex parsing, alpha compositing
- `Sources/GlassCore/OKLCH.swift` — the perceptual colour space and hue-preserving
  gamut mapping
- `Sources/GlassCore/Contrast.swift` — WCAG ratio, plus the perceptual floor that
  catches the pairs it flatters
- `Sources/GlassCore/CSSColor.swift` — the colour syntaxes stylesheets actually use
- `Sources/GlassCore/CSSGradient.swift` — gradient parsing and whole-value rewriting
- `Sources/GlassCore/ThemeTransform.swift` — surface, text, and accent remapping
- `Sources/GlassCore/ContrastRepair.swift` — re-seats a colour against its new background
- `Sources/GlassCore/ThemePlan.swift` — classifies each colour's role and builds
  the page's substitutions
- `Sources/GlassCore/ImageAnalysis.swift` — decides which artwork would vanish,
  and what to back it with
- `Sources/Glass/GlassApp.swift` — app entry, `NSApplication` setup, ⌘-shortcuts
- `Sources/Glass/BrowserSession.swift` — owns the tabs and the selection
- `Sources/Glass/Tab.swift` — one tab: its `WKWebView` and observed state
- `Sources/Glass/ContentView.swift` — tab bar + selected tab's content
- `Sources/Glass/Sidebar.swift` — the vertical tab list
- `Sources/Glass/HoverZone.swift` — click-through edge hover detection
- `Sources/Glass/IconButton.swift` — shared icon button; hover/press feedback and
  SF Symbols effects (spin, bounce, pulse, draw-in)
- `Sources/Glass/FaviconStore.swift` — favicon fetch, memory + disk cache
- `Sources/Glass/URLPalette.swift` — the floating address bar
- `Sources/Glass/SuggestionList.swift` — autocomplete dropdown and keyboard state
- `Sources/Glass/HistoryStore.swift` — in-memory visit history
- `Sources/Glass/SettingsView.swift` — the Settings window
- `Sources/Glass/Preferences.swift` — defaults keys and WebKit data clearing
- `Sources/Glass/Appearance.swift` — maps the setting onto `NSAppearance`
- `Sources/Glass/ThemeBridge.swift` — measures a page's colours and writes the
  plan back onto it
- `Sources/Glass/EmptyTabView.swift` — the new-tab backdrop
- `Sources/Glass/MediaBridge.swift` — media detection script and JS↔Swift bridge
- `Sources/Glass/MediaPlayerStack.swift` — now-playing card stack at the sidebar's foot
- `Sources/Glass/DownloadManager.swift` — download history, progress, and disk writes;
  routes each source to WebKit or to yt-dlp
- `Sources/Glass/DownloadsPanel.swift` — toolbar button and downloads list
- `Sources/Glass/MediaExtractor.swift` — resolves the helper, exports one site's
  cookies, and runs the process
- `Sources/Glass/UpdateManager.swift` — weekly check, checksum + signature
  verification, atomic install
- `Sources/GlassCore/MediaSource.swift` — file vs manifest vs `blob:` classification
- `Sources/GlassCore/YTDLP.swift` — its arguments, progress parsing, and cookie file
- `Sources/GlassCore/ComponentUpdate.swift` — version comparison, scheduling, and
  release discovery for both helpers
- `Sources/Glass/PopOutChrome.swift` — the pop-out's hover controls and rounded frame
- `Sources/Glass/PopOutController.swift` — lens panel: crops the live web view
  to the video's rectangle instead of restyling the page
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
- Bookmarks
- Cross-origin iframes, which are a separate document nothing in the page can
  reach into — theming one means running the whole pass inside it
