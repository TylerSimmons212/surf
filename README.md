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

Images are left alone unless a mark on transparency would be lost on the new
background — a logo drawn for a white page, invisible on a dark one. Then it is
inverted, which touches only the pixels already being drawn: transparency stays
transparent, and no box appears around the artwork.

Colourless marks flip outright, since there is no hue to lose. Marks carrying
colour flip their lightness while *holding* their hue, through a colour matrix
rather than the usual `invert(1) hue-rotate(180deg)` — that shorthand is a
linear approximation which drifts, and light blue reliably comes out brown. So
Wikipedia's wordmark comes back with white letters beside a lighter blue badge,
where plain inversion would have made the badge orange. Anything already
legible is left untouched: a logo that reads is not improved by being turned
inside out.

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

### Blocking

Ads and trackers are blocked by default. The rules are WebKit's own content
blockers — the same mechanism Safari extensions use — which match in the network
process, so a blocked request is never made rather than made and discarded, and
no script on the page can be first past the post.

The lists are EasyList, EasyPrivacy and the Adblock Warning Removal List — the
first is about advertising, the second about tracking, since a page can be free
of ads while still reporting everything you do on it to a dozen people, and the
third is about the sites that notice and put up a wall about it. That last one
removes the wall rather than hiding from the thing that raised it, and Glass
could only take it on once it converted lists itself: nobody publishes a WebKit
build of it. Both are published in Adblock Plus
filter syntax and converted here, which is the part Glass used to borrow.
EasyList's publisher does build a WebKit version of that one list, and taking it
worked until the second list made it untenable: EasyPrivacy is published in
filter syntax only, and carrying one list through a converter and the other
around it would mean two sets of rules behaving differently for reasons nobody
could see. Converting also fixed what borrowing had cost — their rules are
host-exact, so `||adnxs.com^` came out matching `adnxs.com` and not the
`ib.adnxs.com` the ads actually come from.

Between them the three lists convert to about 135,000 rules naming 89,000
domains, with 1.5% of EasyList, 0.3% of EasyPrivacy and 0.2% of the warning list
left behind as unconvertible. Each carries its own floor for what counts as a
real download, because they are not the same size and one figure for all three
would either wave a truncated EasyList through or refuse a healthy small list.
Copies are bundled so a fresh install blocks on its first page, and they refresh
weekly into Application Support from then on.

There is no checksum to verify a list against — the publisher issues none — so
the guarantee comes from what the payload *is*. It is filter syntax, never code:
it is parsed into declarative rules that WebKit compiles and matches URLs
against, and there is no path from it into Glass or into a page. What's left to
guard is a truncated download or a captive portal's sign-in page arriving with a
200 and quietly replacing a working list with nothing, and that is what
converting it and counting what came out catches. A list that produces less than
a real list's worth of rules is refused before it is installed, and the previous
one stays in force.

The two syntaxes don't fully meet, and the gap is handled in one direction only.
A **block** rule that can't be expressed is dropped, and the cost is one ad
getting through — the state the browser was in a moment ago. An **exception** is
the dangerous one, because dropping it leaves a site blocked that the list says
shouldn't be, so an exception is only ever dropped when its whole effect is on
element hiding and never when it would leave a request refused. What's left out
is counted rather than guessed at.

Order matters more than it looks: WebKit applies rules in sequence and
`ignore-previous-rules` cancels only what came *before* it, so every exception in
a list is emitted after every block in it. An exception written above the block
it exists to override does nothing at all.

A few translations carry the weight. `||host^` becomes a filter with a subdomain
group, which is what reaches `ib.adnxs.com` from a rule naming `adnxs.com`, and
it ends at a boundary rather than at the host, or `||example.com^` would also
match `example.community`. A rule with no type option is held away from
top-level documents — Adblock Plus's own default, and the difference between an
ad filter and a list that can block a site the user typed the address of. Regex
literals are refused outright: WebKit's engine is a subset of the one they were
written for, and a rule it rejects fails the entire list's compile, taking every
other rule with it.

`$subdocument` is where the asymmetry is easiest to see. It means a nested
document — an iframe — and WebKit has no type for one; its only near-neighbour
also covers the page the user typed the address of. So a *block* rule carrying
it is dropped, at the cost of an ad iframe getting through, while an *exception*
carrying it is kept and widened, because a broader exception un-blocks more than
the list asked for where a dropped one would leave a request refused that the
list said to allow.

The shield in the sidebar carries the count for the page and opens the list
behind it, in two parts. **Blocked** is what was refused, grouped by site with
what each was doing and which rule caught it. **Also contacted** is every other
third party the page reached, each with a button that blocks it everywhere —
which is the half that makes the panel worth opening twice. A site that breaks
under blocking is fixed by the switch in the panel's header, which pauses that
site alone and leaves it on everywhere else.

Windows a page opens are judged the same way. Glass already refused any window
opened *without* a click — `javaScriptCanOpenWindowsAutomatically` is off, so a
script that opens one unprompted gets nowhere. What that can't cover is the
pop-under, which is opened *by* the click: the gesture is real, WebKit is right
to allow it, and the destination is the only thing that gives it away. So the
destination is what gets asked about, before the tab exists rather than after it
appears — a window that opens and vanishes is still something that happened to
the reader. Nothing is refused on a heuristic, because the cost of being wrong
is a link someone clicked and never got.

A window aimed somewhere unlisted fails in two other ways. The first never gets
off the ground: WebKit hands the window over, the load fails, and the tab has no
address at all. The second is the one that gets seen — the landing page commits,
so there is an address and a document, and then everything it exists to fetch is
refused, leaving a blank tab with no title, no text, and a blocked count
climbing on the shield.

Both close themselves. The emptiness is not incidental in the second case; it is
what a page whose entire contents were blocked looks like, and it is a better
signal than any guess about how the window was opened. All three conditions have
to hold together — no title, nothing readable in the body, and several refused
requests — and only ever on a tab a page opened. A tab you opened stays open
however empty it is, because you opened it.

Some pages check anyway, and two of the ways they check are worth naming because
between them they account for a video that starts and then stops.

The first is a bait variable. A page cannot ask whether a request was blocked,
so it loads a script whose only job is to set a variable and then tests whether
the variable is there — pausing the video and raising a wall if it isn't. The
name is random per site, so no list can carry it and no stub can be written for
it in advance. What is constant is the shape: an identifier tested with `typeof`,
never assigned anywhere in the page, and named after what it is. So Glass reads
the check rather than knowing the name, and answers it. Narrowly: only names that
announce themselves as bait, and only where the page never assigns them, because
`typeof jQuery === 'undefined'` is how a page decides whether to load jQuery and
answering that one would leave it calling methods on nothing.

The second is a window opened by the click that plays the video. A player can be
configured to open one — the destination sits in the page, beside the video's own
settings — so every defence that reasons about gestures is defeated by design:
the gesture is real, and it is the one the viewer made. Checking the destination
doesn't help either, because these land on throwaway affiliate domains no list
carries. What is constant is the intent. Pressing play is a request to play, not
to open a window, and no legitimate player has ever needed one — so that is what
gets refused, which is why it works on a domain nobody has seen before. Scoped as
tightly as the claim: only while a click on a video or its controls is being
handled, and only for somewhere other than the site you are on. A share button
that opens a window still opens it.

A blocked script is invisible to a page that never checks, and a video player is
not that page. It loads Google's ad SDK, waits for `google.ima` to appear, and
hands the viewer to it. Refuse the script and the global never arrives, so the
player waits for a callback that cannot come — and the viewer, who pressed play,
watches nothing happen. The site is then free to call that an ad blocker's
fault, and usually does.

So a script Glass has a stand-in for is answered rather than silenced. The stub
is installed, nothing is fetched, and the script element reports the load the
player is waiting on. What the stub then says is that there are no ads, which is
a state every player already handles — it is what an unfilled ad slot looks like
to them, and they play the video. This is not a way of hiding that blocking
happened: it is the difference between a component that is *absent* and one that
says it has *nothing*, and only the second is something the player was written
to survive. Anything a player reaches for that the stub doesn't define answers as
a harmless no-op, because a stand-in that breaks the page it was meant to rescue
is worse than none.

Blocking the request is only half of a blocked ad. A page reserves the space
before it knows what will fill it — a banner slot is a container given a height
and nothing else — so refusing the ad leaves the reservation standing and the
reader gets a blank band where the ad was. Blocked, but not gone.

So the space is reclaimed too, by two passes that are deliberately timid. A
subresource that failed is a box that will never be filled, and it is hidden
outright along with any wrapper left holding space for it and nothing else. A
slot that never requested anything — which is what happens when the script that
would have filled it was itself blocked — is found by name instead, and only
collapses when all three of a name that marks it as an ad container, a real
height held open, and nothing visible inside are true at once. Names are matched
as whole words, because a class called `download` contains "ad" and names
nothing of the sort.

What that second pass does is stop the container *reserving* space rather than
hide it. `display: none` is a decision that can't be walked back if the site
fills the slot a second later, while a container no longer holding a height open
collapses while it's empty and grows again when something real arrives — which
is what makes a heuristic safe enough to run at all. An ad slot that fills with
something legitimate keeps its space; a heading, a download panel, and anything
else with content in it is never touched.

Assembling that list is the awkward part, because WebKit blocks the requests and
then says nothing about it. The `notify` action that would report a match is
private API, and `decidePolicyFor` is only ever called for frame navigations —
it never sees an image, a script, or a beacon, which between them are the whole
subject. So the panel can't be a readout of WebKit's decisions and is built from
the page's own account instead, out of two sources that can't overlap: Resource
Timing reports everything that completed, and the failure handlers report what
didn't. The difference between them is the shape of what blocking did.

Which rule caught a request is known from the conversion, and only rules that
block a domain outright name one. A rule against one path on a shared host —
`googleapis.com/dfh/`, on a host that also serves half the web's fonts — names a
domain that isn't blocked, and treating it as one would turn every unrelated
failure there into a reported block. Requests caught only by a path rule are
therefore blocked correctly and go unnamed: the panel undercounts rather than
inventing, and what it does name, it names correctly.

One rule settles the disagreements: a request seen to complete was not blocked,
whatever the filters say. The page's evidence outranks ours, which keeps a
cached response from being reported as a block — and means pausing a site needs
no special case anywhere in the panel, since with the rules off those requests
simply load and are reported as contacted.

Third-party is judged against the address in the address bar, not the frame that
reported it, or an ad frame's own tracker would count as the ad's first party.
Your own block rules are third-party only for the same reason in reverse: a rule
that fired on the site you're actually on would take the page down along with
the ad on it.

Two lists are compiled rather than one, and the split is about time. EasyList is
around forty-six thousand rules and compiling it costs seconds; your own rules
are a handful and compile instantly. Sharing a list would mean recompiling
EasyList to add one line, and the Block button would feel broken. The allowlist
has to be in both, because `ignore-previous-rules` only cancels rules earlier in
its own list and can't reach across into another — which is why pausing a site
is the one action that pays the slow compile. Each compiled list is cached under
a hash of the rules it was built from, so a list that hasn't changed since the
last launch is never compiled twice.

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
- `Sources/GlassCore/BlockDomains.swift` — registrable domains, third-party, and
  set matching that can't be fooled by a suffix
- `Sources/GlassCore/FilterList.swift` — which lists are carried, and what makes
  a payload one
- `Sources/GlassCore/FilterConverter.swift` — Adblock Plus filter syntax into
  WebKit's rules, and which way it fails when the two don't meet
- `Sources/GlassCore/UserBlockRules.swift` — the user's two decisions and the
  rules they compile to
- `Sources/GlassCore/BlockLog.swift` — what a page requested, what caught it,
  and how it groups
- `Sources/Glass/ContentBlocker.swift` — compiles the rule lists, keeps the list
  current, applies both to every tab
- `Sources/GlassCore/AdSlots.swift` — what names an ad container, and what has
  to be true before its space is reclaimed
- `Sources/GlassCore/Surrogates.swift` — stand-ins for the scripts blocking
  removes, so a player is told there are no ads rather than left waiting
- `Sources/GlassCore/AntiAdblock.swift` — the bait variable a page checks for,
  and why pressing play is never a request to open a window
- `Sources/Glass/BlockBridge.swift` — the page-side account of what was
  requested, and the two passes that close the hole a blocked ad leaves
- `Sources/Glass/BlockPanel.swift` — the shield and the list behind it
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
