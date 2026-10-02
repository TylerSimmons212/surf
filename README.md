# Surf

A web browser for macOS, built in Swift + SwiftUI.

Requires macOS 27 or later. The chrome uses the current SF Symbols effects
(`rotate`, `drawOn`) with no fallbacks, and the sticker shelf reorders through
SwiftUI's `reorderable` / `reorderContainer`, which are macOS 27 and have no
back-deployment.

## Download

[**Download Surf**](https://github.com/TylerSimmons212/surf/releases/latest) —
open the `.dmg` and drag Surf to Applications.

It is signed and notarized by Apple, so it opens like any other app. No
right-clicking, no quarantine to strip, no trip to System Settings to talk it
into running. macOS 27 or later only; on anything older it will not launch.

To make it your browser: Settings (`⌘,`) has a **Make Surf the Default** button,
or use System Settings › Desktop & Dock › Default web browser. Either way macOS
asks you to confirm, and you can change it back the same way.

Nothing Surf knows about you leaves your Mac. History is off unless you turn it
on, and there is no account, no sync, and no telemetry of any kind.

## Status

Working tabbed browser: type a search or an address on the home screen and it
loads, with back/forward/reload/stop, a live progress bar, and tabs. Links with
`target="_blank"` open in a new tab; scripted popups are blocked.

A tab WebKit opens for itself skips the home screen. Every other new tab starts
there and dives out of it when you submit an address, but a popup is selected
the moment it exists and nothing calls `submit` on it — so it used to sit on the
home screen, water animation running, until its first URL arrived. That wait is
however long WebKit takes to start the navigation, which is what made it look
intermittent: a flicker on a fast host, the whole animation on a slow one.
`Tab.willBeLoadedByPage` is where it starts out browsing instead.

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
and referrer. Video that's streamed in segments has no single file to fetch, and
takes one of two routes.

An HLS manifest is downloaded by Surf. The manifest is the one the page itself
fetched to play the video, so what gets parsed is a specification rather than a
site — there are no per-site extractors here and there is no intention of adding
any. Segments are fetched four at a time with the tab's own cookies, including
the `HttpOnly` ones no script can read, appended in order to a single file, and
where the picture and sound arrive separately they are combined by AVFoundation
with nothing re-encoded. For fragmented MP4, which is most of the modern web,
that combining is the only step that isn't plain concatenation: an
initialisation segment followed by its media segments already *is* a file
AVFoundation reads.

Measured on Apple's 4K reference stream: 295MB at 25.6 MB/s, and the muxing
itself takes 77 milliseconds.

Everything else — a `blob:` source from Media Source Extensions, a transport
stream, a fetchable AES-128 key, a live stream with no end, a manifest Surf
could not parse — is handed to yt-dlp without a word to anyone, because a
download that succeeds by another route is not an error. Only the cookies for
the site being downloaded from are handed over, in a temp file deleted when the
run ends.

Protected video is the one refusal. Widevine and FairPlay encrypt the samples
before they reach the decoder and there is no key to ask for, so it is refused
immediately and said so, rather than handed to a subprocess that will fail
slower and more obscurely.

A finished file is checked against what the page said it was before it is
allowed into `~/Downloads`. A video download that came back with only audio, or
only a third of its length, is discarded while it is still in a temp directory —
so there is nothing left to double-click, be confused by, and delete by hand.
That check exists because a download did exactly that once, and the cause was
never found.

Typing in the address bar autocompletes from history, which is held in memory
only unless you turn on "Remember browsing history". Tabs, window size, and window position
all restore on relaunch — including each tab's back/forward history and scroll
position.

### Focus

`⌘⇧F` replaces an article with a native reader — SwiftUI over the live page,
not re-styled HTML, so the typography, the dark mode, and the chrome are ours
and the page's junk simply isn't drawn. The web view stays mounted underneath:
leaving Focus is a fade, and it lands the page on the passage you were reading
rather than wherever its scroll position happened to be.

A tiny resident script counts what's on the page (words, paragraphs, declared
types) and Swift classifies it; when it's confident there's an article, a quiet
pill offers Focus in the corner. The extractor — a compact Readability that
scores containers by the paragraph text they hold and walks the winner into
headings, paragraphs, quotes, code, lists, and figures — is *not* resident: it
is injected only when Focus is entered, so only pages you focus pay for it.
The menu item works on any page and lets extraction be the judge; when a page
has no article to give, Focus says so instead of rendering the attempt.

Escape leaves Focus, and it cancels an armed screenshot pick first — the thing
started last goes first. The key is caught by the same local `NSEvent` monitor
that handles ⌃⇥, not by a SwiftUI shortcut: Escape is a focus key, so whichever
view is first responder eats it before a menu or a hidden button would see it,
and the web view in particular never passes a plain key down on. The monitor
runs before the responder chain and consumes the key only when it did
something; an Escape aimed at a text field (the address palette, the find bar)
or at a mini window is left alone, so those close themselves and the reader
stays.

A recipe page gets its own lens. Recipe SEO guarantees the page carries
`schema.org/Recipe` JSON-LD, and the lens renders what that data says the
recipe *is* — not the essay above it. Ingredients check off as you gather
them and scale together (½× to 3×, quantities re-written as cook's
fractions, the yield chip scaling with them); steps keep their section names
("For the broth"); and Cook Mode sets the steps large, dims all but the one
you're on, and keeps the screen awake while your hands are wet. The
checkboxes double as a pantry check: "Add to Groceries" sends the *unchecked*
ingredients — at the current scale — to a Groceries list in Reminders (found
or created), each item carrying the recipe's name and address so an item in
the aisle can say why it's there. Reminders access needs the real bundle
(`./scripts/bundle.sh`); a bare `swift run` has no Info.plist to ask with.
Both lenses carry the native share menu, sharing the page's address. The parser
lives in `SurfCore` behind tests, because real recipe JSON-LD is filthy —
`@graph` wrappers, entity-encoded apostrophes, instructions nested two
sections deep, and five spellings of every field. The page's prose stays one
toggle away as the article lens.

A video page gets theater mode. Rehosting the stream in a player of our own
is the obvious spelling and doesn't work — most video is a `blob:` URL that
exists only in its page — so the page's *own* element is promoted where it
stands: pinned fullscreen over everything the page drew, restored
byte-for-byte from its saved inline style on the way out. A video inside an
iframe pins itself within its frame and each parent pins the frame carrying
it, hopping origins by message the same way the pop-out measures them. On
top rides Surf's transport — one set of controls on every site, driven by
the same agent methods as the now-playing strip — with chrome that fades
when the pointer stops. The offer follows the evidence: the classifier for
pages that are plainly a player, and live media state for embed hosts whose
video lives in a frame the detector can't see. In either stage the arrow keys
scrub five seconds, which is what every player on the web does; the cost is
that the overlay holds keyboard focus while a stage is up, so the site's own
shortcuts stop answering until you leave.

A site can also have a lens of its own. The article, recipe and video lenses
read whatever page they are handed; a site lens knows one site's data and one
site's player, and in exchange it can offer what no general reader can.
YouTube is the first. `⌘⇧F` on youtube.com replaces the site with a search
field, a search with a grid of Surf's own cards, and a card with the video —
its chapters listed beside the transport, its subtitle tracks and its speeds
in it. There is no feed, which is the point: the front page of a focused
YouTube is a field and nothing else.

The grid is built from `ytInitialData` rather than from the DOM, because the
DOM does not have it. A fresh results page holds one rendered result and
loads the rest as you scroll, while the page's own payload carries the whole
first page at once. Every judgement about that payload is Swift's, and tested
against captures from the real site, because the shapes are filthy in
specific ways: a live stream has no duration and counts viewers instead of
views, an unaired premiere has neither, and the field that is `simpleText` on
one video is `runs` on the next.

Searching is a page load and so is playing, which makes this the one lens
that expects to navigate. It survives its own loads and drops when the
address leaves the site. Swapping the video in place without a load would be
quicker and is wrong: the payloads are published once per document, so the
second video would wear the first one's chapters.

The stage pins `#movie_player` rather than the `<video>` inside it, and that
is the whole difference between this and the generic theater. YouTube draws
its subtitles into a sibling of the video's parent instead of into a
`<track>`, so a stage that promotes the video alone lights the captions out
along with everything else. Pinning the player keeps them, placed by the only
code that knows where they go. The wrapper between the two has to be given a
size on the way past — it is `position:relative` with no dimensions of its
own and its only child is absolutely positioned, so its height collapses to
zero, and a video sized against zero is a black screen with the subtitles
still playing over it.

The reader can also read aloud. Listen starts a narration with lyric mode:
the sentence being spoken carries a faint wash, the word being spoken is lit
inside it, the passage keeps itself in the upper third of the view, and
tapping any paragraph or heading seeks the voice there. The sentence is the
unit of everything — seeking, skipping, pause position — which is why the
script is split by a real sentence tokenizer rather than on full stops.
Starting a narration pauses a page that is already playing media — two voices
in one room — and the reading survives switching tabs, because it belongs to
the tab rather than to the view. Headings and quotes are read as written;
lists are read item by item; code is skipped, because code read aloud is
noise.

Two voices sit behind one small engine protocol. Out of the box, narration
uses the best voice installed on this Mac (the premium and enhanced system
voices people download rank first) — the system synthesiser is also the only
engine whose word boundaries come free, which is what makes word-level lyric
sync possible at all. Settings › Reader offers the enhanced voice: Kokoro, a
neural model run locally through sherpa-onnx, downloaded on request
(~344 MB, pinned versions, SHA-256 verified, quarantine handled) into
Application Support. The runtime is `dlopen`'d — Surf links none of it — and
its C struct layouts are compiled in from a pinned header (`SherpaTTSABI`),
so the dylib the offsets are checked against is the dylib that ships. A
neural voice reports no word timings, so its lyric is the moving sentence;
the next sentence is synthesised while the current one plays, so the joins
don't wait for the model. Nothing that is read leaves the machine.

`SURF_FOCUS=1` alongside `SURF_URL` enters Focus automatically once the page
loads, which is how the extractor gets exercised from the command line;
`SURF_FOCUS=2` also starts the narration, and `SURF_SILENT=1` mutes it so the
whole speech pipeline — callbacks, highlights, advancement — runs without the
room hearing it.

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
currently left alone — Surf doesn't yet invent a dark theme for it.

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

### Talking to a page

Everything Surf wants from a page — the colours it painted, what it is
playing, which icons it declares — goes through one resident agent per content
world, installed at document start and addressed by method name.

The alternative, and what this replaced, is handing WebKit a fresh block of
JavaScript source for every question. That works, and it is how most of this
started, but it means each feature arrives with its own conventions for
arguments, for errors, and for what "nothing" looks like — which is what makes
a browser feel like something wrapped around WebKit rather than something built
on it.

Two worlds, because the split is forced: media has to run in the page's own,
where `navigator.mediaSession` and the site's media elements are, and the theme
has to run outside it, where nothing it defines can collide with the site's
scripts. `PageProtocol.Method` names every method once and says which world it
belongs to, so a call site can't pick the wrong one.

Dev tools uses the same runtime. It reaches a page through three more instances
— its own isolated world for the DOM, and two in the page world for console
capture and for network capture — because those have different lifetimes and
different reasons to exist, not because they are a different kind of thing.
Five instances of one implementation, then, rather than the four hand-written
dispatchers this replaced. Each of those carried its own copy of the same
`switch`, the same `try`, its own spelling of "unknown method", and — between
the page agent and dev tools — two different ideas of what a reply even looks
like. A domain now says `define('DOM.getDocument', …)` and returns a value; the
runtime owns everything around it.

Nothing is interpolated into JavaScript at a call site. `callAsyncJavaScript`
binds arguments as real variables, so a method name and its parameters are
values and can never become script.

A reply is an envelope rather than a bare result, which is what lets the three
ways a call comes back empty stay apart: the page reported a failure, the reply
wasn't the shape the method promised, or there was legitimately nothing to
report. Only the last is ordinary. Collapsing them — which is what a `try?`
around a raw evaluation does — is how a page that had been failing to answer
for months looked exactly like a page with nothing to say.

The page agent hangs off a property name chosen fresh each launch. In the
isolated world that is invisible either way; in the page world a fixed name is
a reliable way for a site to tell which browser it is being read in. Dev tools'
instances keep fixed names, which is only defensible because they exist solely
while a panel is attached — a page being inspected is already being watched.

### The page's context menu

Right-clicking a page gets WebKit's own menu with Surf's items on the front of
it: open a link in a new tab or a split, copy a link or an image address, pop a
video out, enter Focus, take a screenshot, block the site's domain. WebKit's
half is kept rather than replaced — Look Up, Services, spelling and the editing
verbs are all things Surf would only reimplement worse.

Knowing what was right-clicked is the hard part, and the reason is a process
boundary. The DOM `contextmenu` event is dispatched in the web process; the menu
is built in the UI process, synchronously, inside `willOpenMenu`. There is no
round trip to be had at the moment it is needed, so the page pushes what was
under the pointer on every right-click and Surf holds the answer before the
question. Measured on this machine the push lands 20–60ms ahead of the menu.

It is still a race, so it is arranged to fail safe. The held hit is cleared when
the menu closes, which means a payload can only ever describe the click its menu
belongs to; losing the race costs items, never accuracy. The listener never
calls `preventDefault`, so a lost race is still a working stock menu.

The selection is only reported when the click lands inside it. Without that
check a right-click on an image offers to search for whatever sentence was
highlighted somewhere else on the page, because the selection outlives the click
that made it.

`page.js` is injected into every page and `check-js.sh` budgets it at 3000
bytes for that reason. The listener spends most of what was left, which is why
its reasoning lives in Swift comments around the string rather than in the
string — comments in there ship to every site you visit.

### Mini windows

A link you have not committed to opens in a floating panel with the page in it
and one button that keeps it: **Open in Surf**. Most links are read once and
thrown away, and a browser that turns every one of them into a tab makes you
tidy up after reading. Escape dismisses; the page never reaches the sidebar.

One bar across the top, and the page below it: a close button, the address, copy
and **Open in Surf**. No traffic lights — a mini window has exactly one thing you
can do to it that isn't promoting it, and that is make it go away.

The address is a real field. The panel opens on a link somebody sent, but what it
holds is a real `Tab`, and a page you have followed two links into should not
still claim to be at the address it arrived on. It edits `addressText`, the same
property the main window's palette edits and the same one navigation writes back
to, so nothing has to keep the two in step.

The controls take their hover, focus and press behaviour from the system rather
than from `.onHover` into a flag into a tint, which is what they did before and
which was maintaining an impression of a button rather than having one. Three
things had to be true for that to work, and none of them were obvious:

- The panel is no longer a `.nonactivatingPanel`. That flag stops a click in the
  panel making Surf the active app, and **an inactive app draws every control in
  its inactive state** — a whole row of buttons that do not answer the pointer,
  because as far as AppKit is concerned nobody is looking at them.
- No `GlassEffectContainer` around them. That coordinates `.glassEffect`
  modifiers into one sampling pass; `.buttonStyle(.glass)` brings its own, so the
  container was put in charge of a pass it had no controls to draw.
- `.pointerStyle(.link)`, because a Mac button never changes the cursor. That is
  right on a form and wrong on chrome floating over a web page, where it reads as
  nothing being there at all.

The field is a `SurfTextField` and not SwiftUI's `TextField`, which was tried and
silently does not work: a `TextField` inside an `NSHostingView` mounted as a
*subview* of a borderless panel never takes focus. Clicking does nothing, setting
`@FocusState` by hand does nothing, and typing goes wherever it was already
going. `SurfTextField` makes itself first responder explicitly, which is the step
the plain one is missing.

The bar drags the window. A borderless panel has no title bar to grab, and
`isMovableByWindowBackground` cannot help because the web view covers the
background and takes the drag first, so the grab area is a view behind the bar's
own controls. That used to cost the page its top strip — an AppKit view takes
every click inside its frame — and now costs nothing, because the page starts
below the bar and there is no page up there to deaden.

The size comes from `MiniWindowSizing`: about 55% of the display's usable
rectangle, floored at 820×560 and capped at 1180×800. It was a flat 1000×680,
which is two thirds of a laptop screen and a quarter of a 6K one — the same
window reading as almost the whole desktop in one place and a postage stamp in
the other.

Closing puts you back in the window the link came from. Dismissing a mini window
means "never mind", and never mind means going back rather than landing wherever
AppKit decides to raise next.

With one island the button reads **Open in Surf**, because there is nothing to
choose and the useful thing to say is which app this floating window belongs to.
With more than one it reads **Open in <island>** and grows a caret listing the
others — the same rule as the tab and island menus, where the UI is a map of
what exists rather than a fixed grid.

Choosing a different island is not a re-filing. The tab's cookie jar came from
the island it was browsing in, so carrying the live view across would put a page
that browsed as one identity into another's list; instead the page is fetched
again as the island you picked. That reload is the feature — "open this in Work"
means load it as Work — and it is why the two cases are different code rather
than one `append` with a different argument.

The panel holds a real `Tab` — same cookie jar, same content rules, same theme,
same page agent — that its island simply does not list. That absence is the
whole mechanism. There is no ephemeral-tab flag for the rest of the app to
remember to check: the sidebar draws `island.tabs`, and this is not in it.
Promoting is `append`, dismissing is `teardown`, and neither reloads the page.

It browses in the island that was current when it opened, and says which one in
its chrome, because that is whose logins the page is seeing. Promotion files the
tab back into *that* island rather than whatever is current now — the two come
apart the moment someone switches islands with a panel open, and a page carrying
one island's identity into another island's list is the confusion `openSplit`
already refuses to create.

Links from other applications are the case this is really for. `bundle.sh`
declares `http` and `https` in `CFBundleURLTypes`, which is what puts Surf in the
default-browser list and what makes macOS hand it links at all. They arrive
through `onOpenURL` on the window's content — SwiftUI's spelling of the
delegate callback, and the better one here, because the view that receives
them already holds the session; an app-delegate method would have needed a
static way back to it. Settings › Links has the switch for whether they arrive
as a mini window or straight as a tab, and the button that asks macOS to make
Surf the default — a request, not a change, since the system puts up its own
confirmation. When a link is what launched the app and the choice is a tab, it
goes into the single untouched home tab rather than beside it: one tab from a
click in Mail, not two with one of them empty.

Only a real bundle can be a browser. Run from `swift run` there is nothing for
Launch Services to point at, so Settings says so rather than offering a button
that would fail quietly.

### Blocking

Ads and trackers are blocked by default. The rules are WebKit's own content
blockers — the same mechanism Safari extensions use — which match in the network
process, so a blocked request is never made rather than made and discarded, and
no script on the page can be first past the post.

The lists are EasyList, EasyPrivacy and the Adblock Warning Removal List — the
first is about advertising, the second about tracking, since a page can be free
of ads while still reporting everything you do on it to a dozen people, and the
third is about the sites that notice and put up a wall about it. That last one
removes the wall rather than hiding from the thing that raised it, and Surf
could only take it on once it converted lists itself: nobody publishes a WebKit
build of it. Both are published in Adblock Plus
filter syntax and converted here, which is the part Surf used to borrow.
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
against, and there is no path from it into Surf or into a page. What's left to
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

Windows a page opens are judged the same way. Surf already refused any window
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

There is a third way a page can check, and it is the one Surf can least argue
with: hiding is the only thing a blocker does that a site can *see from the
inside*. A player puts an element on its own page, measures it, finds it hidden,
and stops playing — and it is right, in the sense that the measurement is
correct. So element hiding can be switched off on its own, in Settings, without
giving up a single refused request. The lists are compiled a second way with the
hiding rules left out — and the switch reaches the reclaiming pass too, because
closing a hole is as measurable as hiding one, and a switch that stopped the
list hiding things while leaving that running would leave the same fingerprint
on a page that had just been told there was nothing to find. With it off, the
layout is exactly what the site's authors wrote, holes and all, and every request
is still refused.

Some pages check less directly, and two of those ways are worth naming because
between them they account for a video that starts and then stops.

The first is a bait variable. A page cannot ask whether a request was blocked,
so it loads a script whose only job is to set a variable and then tests whether
the variable is there — pausing the video and raising a wall if it isn't. The
name is random per site, so no list can carry it and no stub can be written for
it in advance. What is constant is the shape: an identifier tested with `typeof`,
never assigned anywhere in the page, and named after what it is. So Surf reads
the check rather than knowing the name, and answers it. Narrowly: only names that
announce themselves as bait, and only where the page never assigns them, because
`typeof jQuery === 'undefined'` is how a page decides whether to load jQuery and
answering that one would leave it calling methods on nothing.

The second is a sheet laid over the player to catch the click meant for it —
unnamed, empty, transparent, and stacked above the player's own controls. The
viewer aims at play, hits that instead, and gets a window; it then gets out of
the way so the second click works, which is exactly why it reads as "I pressed
play and an ad opened". What identifies it is the combination, and above all
the last part: a player has no reason to cover its own controls. Its own layers
are named — `fp-ui`, `fp-ui-block` — because its own code has to find them
again, where this one is anonymous because nothing ever will. It is made
transparent to the pointer rather than removed, because removing an element a
player put there is a guess about someone else's code, while this changes
nothing except who receives the click — and the click was always meant for the
player.

The third is a window opened by the click that plays the video. A player can be
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

So a script Surf has a stand-in for is answered rather than silenced. The stub
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
EasyList to add one line, and the Block button would feel broken. Each compiled
list is cached under a hash of the rules it was built from, so a list that
hasn't changed since the last launch is never compiled twice.

Pausing a site compiles nothing. It used to: the exception lived inside the
compiled lists as `ignore-previous-rules`, so flipping the switch meant
rebuilding EasyList — tens of seconds, during which the page reloaded under the
old rules and the switch appeared to do nothing. Flip it twice and the compiles
queued behind each other. Now the decision is made per tab instead. Rule lists
attach to a tab's content controller, so a paused site is a tab that simply has
none: the lists and the counting script come off, the page reloads plain, and
nothing is looking for anything — which is also why the shield says "off" rather
than "paused", and shows no count. Resuming puts them back and reloads. The tab
re-decides on every main-frame navigation, before the load's first request, so
moving from a paused site to a blocked one in the same tab gets the right lists.
Flipping the switch now reloads in a few milliseconds, and the compiled
exception could not have stayed even in the background: lists already in memory
carried it, so resuming would re-attach lists that didn't block until the next
compile landed.

The one shape this can't express is a window a page opened, which shares its
opener's content controller: if the two sit on different sites and one is
paused, whichever decided last decides for both.

### Privacy

Surf is private by default and keeps no browsing history. Settings (`⌘,`) has a
Privacy pane, with four switches at the heart of it:

| Setting | Default | Effect |
|---|---|---|
| Remember browsing history | Off | When on, each tab's back/forward list is saved to disk |
| Keep me signed in | On | Retains cookies across quits |
| Reopen tabs on launch | On | Writes open tab addresses to disk — the one setting that stores where you went |
| Clear caches when quitting | On | Wipes WebKit caches and per-site storage, never cookies |

The guarantee is that caches and cookies are independent: clearing where you
went never signs you out. `PrivacyPolicy` encodes that rule and the tests
enforce it.

Each switch still explains itself, but behind an ⓘ rather than in a paragraph
underneath. Printed under every row at once — which is how this started — the
window grew taller than the screen and became something to scroll past rather
than read, which is its own way of going unread. Settings is one pane per
subject now: General, Privacy, Links, Reader, AI.

### Helpers

Stream downloads are done by two binaries Surf runs but doesn't build: yt-dlp
resolves a page to its media, and ffmpeg merges separate video and audio
streams. Neither is a user-visible feature. Settings shows one number — the
Surf version — and nothing about what's inside it, because a version the user
can't act on is noise, and "Surf is current" has to mean everything in it is
current or the number means nothing.

`UpdateManager` keeps them that way: a weekly check at launch, SHA-256 verified
against the publisher's own checksums, installed atomically into
`~/Library/Application Support/Surf/Components`, never prompting and never
reporting. A failed update leaves the previous copy alone and tries again next
week. Resolution runs newest-first — managed copy, then `PATH`, so `swift run`
works without a bundle. Neither binary ships inside `Surf.app`: yt-dlp was
dropped from the bundle to keep the app small (it was 37&nbsp;MB of a
54&nbsp;MB app), so stream downloads start working after the first update
check, or immediately with a copy on `PATH`.

The two are handled differently, and the difference is licensing:

| | yt-dlp | ffmpeg |
|---|---|---|
| Licence | Unlicense | GPLv3 — every prebuilt static macOS build |
| Bundled in `Surf.app` | **No** — fetched by `UpdateManager` | **No** |
| Source | GitHub releases + `SHA2-256SUMS` | [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de) + `.sha256` sidecar |
| Extra verification | — | Developer ID team pin (`KU3N25YGLU`) |

Bundling an ffmpeg build would put Surf under GPLv3 along with it. Fetching it
at runtime makes the user the recipient rather than Surf the redistributor,
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

The menu bar is the nine menus a Mac browser is expected to have, with Islands
standing where Bookmarks would be — which is the honest arrangement, since a
sticker belongs to an island rather than to the app.

| | |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab (the last one is replaced by a fresh tab) |
| `⌘⇧T` | Reopen closed tab |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`–`⌘8` | Select tab by position |
| `⌘9` | Select the last tab, once there are more than eight of them |
| `⌘L` | Open the floating address bar |
| `⌘[` / `⌘]` | Back / forward |
| `⌘R` | Reload |
| `⌘⇧D` | Split with the next tab, and close the split again |
| `⌘⇧F` | Enter / leave Focus |
| `←` / `→` | Scrub five seconds, on either video stage |
| `⌘⇧L` | Pin / unpin the sidebar |
| `⌘D` | Add a sticker |
| `⌥⌘←` / `⌥⌘→` | Previous / next island |
| `⌥⌘1`–`⌥⌘9` | Select island |
| `⌘,` | Settings |

Three of these moved off keys they had no business holding. The sidebar was on
`⌘S`, which is Save everywhere else on the Mac; the split was on `⌘D`, which is
bookmarking everywhere else, and now carries Surf's equivalent. Swapping the
split's two sides was on `⌘⌥D` — the system's Dock-hiding shortcut, which never
reaches an app — so it is menu-only rather than given a third awkward chord.

There is no `⌘N`, and no New Window item for it to belong to. Surf is one
window by construction: a single session, and every tab owns one `WKWebView`,
which can live in one view hierarchy at a time. The stock item SwiftUI adds to
a `WindowGroup` would open a second window over the same tabs, and the two
would then steal each page from each other whenever either showed it. Closing
the window quits the app, which is the other half of the same fact.

### How big the window is

The first time Surf opens it takes the full height of the display and as much
width as it can up to 1800 points, centred. Height is what reading a page wants,
and there is no reason to hand back any of it. Width is capped because a browser
stretched across a 6K display puts the sidebar and the far edge of the page a
head-turn apart, and the line lengths go with it — past that point the extra
width is worth more to the desktop than to the page. On a laptop or a 1440p
monitor the cap never bites and the window fills the screen edge to edge. Full
screen stays a thing you choose, not a thing Surf does to you.

After that it is whatever you left it as. `WindowPlacement` in SurfCore settles
the arithmetic: a frame saved on a monitor that has since been unplugged is slid
back onto a screen rather than opened where there are no pixels, and one saved
on a larger display is cut down to fit a smaller one. Leaving the window in full
screen saves nothing, because full screen is a mode and not a size.

`MainWindowFrame` does the remembering, and it does it by hand for a reason
worth writing down. `setFrameAutosaveName` is the one-line AppKit answer to all
of this, and Surf called it for months with no effect at all. A `WindowGroup`'s
window belongs to SwiftUI, which assigns an autosave name of its own a runloop
turn after the hosting view attaches and overwrites whatever anyone else set.
The name it picks is built from the *type* of the scene's content, so it reads
in full as `SwiftUI.WindowGroup<SwiftUI.ModifiedContent<Surf.ContentView, …>>-1-AppWindow-1`
— which means adding a modifier at the root of `ContentView` changes the key,
orphans the old one, and makes the window forget its size, silently, with
nothing in the diff to suggest it. That is what had happened.

So the frame is Surf's to keep, under a short stable key, in `SurfDefaults.store`
rather than the standard domain. That last part closes the hole the scratch
suite could not: AppKit's autosave always writes to the standard domain, so a
`SURF_STATE_DIR` run used to leave a window frame in your real preferences.
SwiftUI still writes its own key about a tenth of a second after the name is
cleared — clearing stops AppKit, not SwiftUI, which keeps its own copy — so the
key is swept back out after that write and again when the window closes.

## Run

```
swift run
```

Or build a real app bundle (needed if you want to launch it from Finder):

```
./scripts/bundle.sh && open Surf.app
```

Tests:

```
swift test
```

### Updating itself

Surf checks one address for one file listing the current version, and installs
what it finds only after the download's signature verifies against a key built
into the app. Nothing about the machine goes with the question: system
profiling is off in the bundle and off on the updater, so the request has no
query string and says nothing except which file it wants.

That is the only dependency in the project. The rule the rest of the code
follows is to write it yourself, and the reason this is the exception is that
replacing a running signed application is a genuinely hard job with a lot of
ways to leave somebody holding a broken app: verify, stage beside the original,
swap a bundle whose code is executing, relaunch, survive losing power halfway.
Sparkle is the implementation the rest of the Mac already trusts with it.

The signing key is not the Developer ID. It is a separate EdDSA pair whose
private half lives in the keychain of whoever cuts releases, which is what
makes a tampered download — or one served by something that isn't us —
refusable by a copy that is already installed.

## Shipping it to someone else

```
scripts/release.sh 0.2.0
```

That produces a signed, notarized `Surf-0.2.0.dmg`, which is the only kind of
download another Mac will open without a fight. All three parts of that matter
and none of them are optional. An ad-hoc signature means nothing off the
machine that made it. The hardened runtime is what notarization requires. And
notarization is what Gatekeeper checks: since Catalina an un-notarized download
is refused, and since Sequoia the right-click-Open escape hatch is gone, so the
person you sent it to would have to walk into System Settings to run it at all.

The hardened runtime takes two things away that Surf needs back, which is what
`scripts/Surf.entitlements` is for. WebKit's JavaScript JIT writes executable
memory, and a signed Surf without `allow-jit` loads pages that never run a
script. The enhanced voice is a dylib downloaded at runtime and signed by
somebody else, and library validation refuses it unless it is switched off, so
Kokoro would install and never load.

Two things are needed once, on the machine that builds releases. A Developer ID
Application certificate, which needs a paid Apple Developer Program membership
(Xcode › Settings › Accounts › Manage Certificates). And a notary credential,
which the release script reads by name from the keychain and never handles
itself:

```
xcrun notarytool store-credentials "surf-notary" --apple-id "you@example.com" --team-id "YOURTEAMID" --password "app-specific-password"
```

The password there is an app-specific one from appleid.apple.com, not the Apple
ID password.

Whoever you send the image to drags Surf to Applications and opens it. Nothing
else: no quarantine to strip, no security pane to visit. Surf declares itself a
handler for `http` and `https`, so it appears in System Settings › Desktop &
Dock › Default web browser, and Settings › Links has a button that asks macOS
the same question. It is `LSMinimumSystemVersion 27.0`, so an older Mac can't
run it at all.

That key is also what keeps an older Mac from being *offered* a build it can't
launch: `generate_appcast` reads it out of the bundle and writes
`sparkle:minimumSystemVersion` into the entry, so Sparkle skips that entry and
offers the newest release the machine can actually run. Which means the last
macOS 26 release has to stay in the feed permanently — it is the only entry a
26 machine can still see, and with it gone the updater finds nothing eligible
and goes quiet with no way to say why.

## Layout

Pure logic lives in `SurfCore` with no AppKit or WebKit imports, which is what
makes it unit-testable — the UI targets can't be.

- `Sources/SurfCore/URLResolver.swift` — decides address vs. search
- `Sources/SurfCore/TabSelection.swift` — tab index math (close, cycle, ⌘N)
- `Sources/SurfCore/PersistedSession.swift` — session file model and IO
- `Sources/SurfCore/FaviconPicker.swift` — chooses which declared icon to fetch
- `Sources/SurfCore/PrivacyPolicy.swift` — what gets cleared, what gets stored
- `Sources/SurfCore/HistorySearch.swift` — autocomplete ranking
- `Sources/SurfCore/AppearanceMode.swift` — the three-way scheme setting and
  what it resolves to against the OS
- `Sources/SurfCore/AICLI.swift` — AI CLI detection: reading each CLI's own
  record of who's signed in, model menus, and which provider runs
- `Sources/SurfCore/AITabNaming.swift` — AI tab renaming: the prompt, the
  per-CLI command line, and how much of the answer to believe
- `Sources/SurfCore/AIDownloadNaming.swift` — AI download renaming. Two things
  are never the model's to decide, and both are decided here instead: the
  extension, which the file keeps whatever the reply says, and the naming
  convention, which follows the *kind* of file. A document gets spaces
  (`Q3 Revenue Report.pdf`); anything that ends up in a terminal gets hyphens
  (`Surf-0.5.0.dmg`), because a space in a name you type means quoting it every
  time and forgetting to means two arguments where one was meant. The prompt
  asks for the right shape and the sanitiser enforces it, so a model that
  ignores the instruction still cannot put a space where one must not be.
  A file whose name somebody already chose on purpose is skipped before the
  CLI is even woken: the renamer is for `dl_88213.pdf`, not for
  `Surf-0.5.0.dmg`
- `Sources/SurfCore/SRGB.swift` — sRGB colour, hex parsing, alpha compositing
- `Sources/SurfCore/OKLCH.swift` — the perceptual colour space and hue-preserving
  gamut mapping
- `Sources/SurfCore/Contrast.swift` — WCAG ratio, plus the perceptual floor that
  catches the pairs it flatters
- `Sources/SurfCore/CSSColor.swift` — the colour syntaxes stylesheets actually use
- `Sources/SurfCore/CSSGradient.swift` — gradient parsing and whole-value rewriting
- `Sources/SurfCore/ThemeTransform.swift` — surface, text, and accent remapping
- `Sources/SurfCore/ContrastRepair.swift` — re-seats a colour against its new background
- `Sources/SurfCore/ThemePlan.swift` — classifies each colour's role and builds
  the page's substitutions
- `Sources/SurfCore/ImageAnalysis.swift` — decides which artwork would vanish,
  and what to back it with
- `Sources/SurfCore/PageProtocol.swift` — the wire format Surf and the page
  agree on: method names, which world each runs in, and the reply envelope
- `Sources/Surf/PageAgent.swift` — Surf's side of one content world: typed
  calls out, decoded events back
- `Sources/Surf/PageRuntime.swift` — the agent itself, and the only property
  Surf adds to a page's globals
- `Sources/Surf/PageScripts.swift` — the one place that decides what is
  injected, and into which world
- `Sources/Surf/SurfApp.swift` — app entry, `NSApplication` setup, ⌘-shortcuts
- `Sources/Surf/BrowserSession.swift` — owns the tabs and the selection
- `Sources/Surf/Tab.swift` — one tab: its `WKWebView` and observed state
- `Sources/Surf/ContentView.swift` — tab bar + selected tab's content
- `Sources/Surf/Sidebar.swift` — the vertical tab list
- `Sources/Surf/HoverZone.swift` — click-through edge hover detection
- `Sources/Surf/IconButton.swift` — shared icon button; hover/press feedback and
  SF Symbols effects (spin, bounce, pulse, draw-in)
- `Sources/Surf/FaviconStore.swift` — favicon fetch, memory + disk cache
- `Sources/Surf/URLPalette.swift` — the floating address bar
- `Sources/Surf/SuggestionList.swift` — autocomplete dropdown and keyboard state
- `Sources/Surf/HistoryStore.swift` — in-memory visit history
- `Sources/Surf/SettingsView.swift` — the Settings window
- `Sources/Surf/Preferences.swift` — defaults keys and WebKit data clearing
- `Sources/Surf/Appearance.swift` — maps the setting onto `NSAppearance`
- `Sources/Surf/ThemeBridge.swift` — the theme domain: measures a page's
  colours and writes the plan back onto it
- `Sources/Surf/EmptyTabView.swift` — the new-tab backdrop
- `Sources/Surf/MediaBridge.swift` — the media and find domains of the agent
- `Sources/Surf/MediaPlayerStack.swift` — now-playing card stack at the sidebar's foot
- `Sources/Surf/DownloadManager.swift` — download history, progress, and disk writes;
  routes each source to WebKit, to the stream engine, or to yt-dlp
- `Sources/Surf/DownloadsPanel.swift` — toolbar button and downloads list
- `Sources/Surf/MediaExtractor.swift` — resolves the helper, exports one site's
  cookies, and runs the process
- `Sources/SurfCore/StreamIndex.swift` — what a manifest offers, with no trace of
  which kind of manifest said it; the one shape both parsers produce
- `Sources/SurfCore/HLSPlaylist.swift` — m3u8 into a `StreamIndex`; master and
  media playlists through one function, because which you have is something you
  find out by reading it
- `Sources/SurfCore/StreamPlan.swift` — which rendition to take and what to
  refuse, decided before anything is requested
- `Sources/SurfCore/SegmentSchedule.swift` — a cursor rather than a worklist, so
  the buffer is bounded, the output is an in-order append, and resuming is seeding
  what is already done
- `Sources/SurfCore/SavedMedia.swift` — whether the finished file is the file that
  was asked for
- `Sources/Surf/SegmentFetcher.swift` — the tab's own session behind each request
- `Sources/Surf/StreamAssembler.swift` — concatenation, and AVFoundation muxing
  with nothing re-encoded
- `Sources/Surf/StreamDownload.swift` — one download start to finish; decides
  nothing itself
- `Sources/Surf/MediaInspector.swift` — the four facts `SavedMedia` judges
- `Sources/Surf/UpdateManager.swift` — weekly check, checksum + signature
  verification, atomic install
- `Sources/SurfCore/BlockDomains.swift` — registrable domains, third-party, and
  set matching that can't be fooled by a suffix
- `Sources/SurfCore/FilterList.swift` — which lists are carried, and what makes
  a payload one
- `Sources/SurfCore/FilterConverter.swift` — Adblock Plus filter syntax into
  WebKit's rules, and which way it fails when the two don't meet
- `Sources/SurfCore/UserBlockRules.swift` — the user's two decisions and the
  rules they compile to
- `Sources/SurfCore/BlockLog.swift` — what a page requested, what caught it,
  and how it groups
- `Sources/Surf/ContentBlocker.swift` — compiles the rule lists, keeps the list
  current, applies both to every tab
- `Sources/SurfCore/AdSlots.swift` — what names an ad container, and what has
  to be true before its space is reclaimed
- `Sources/SurfCore/Surrogates.swift` — stand-ins for the scripts blocking
  removes, so a player is told there are no ads rather than left waiting
- `Sources/SurfCore/AntiAdblock.swift` — the bait variable a page checks for,
  and why pressing play is never a request to open a window
- `Sources/Surf/BlockBridge.swift` — the page-side account of what was
  requested, and the two passes that close the hole a blocked ad leaves
- `Sources/Surf/BlockPanel.swift` — the shield and the list behind it
- `Sources/SurfCore/MediaSource.swift` — file vs manifest vs `blob:` classification
- `Sources/SurfCore/YTDLP.swift` — its arguments, progress parsing, and cookie file
- `Sources/SurfCore/ComponentUpdate.swift` — version comparison, scheduling, and
  release discovery for both helpers
- `Sources/Surf/PopOutChrome.swift` — the pop-out's hover controls and rounded frame
- `Sources/Surf/PopOutController.swift` — lens panel: crops the live web view
  to the video's rectangle instead of restyling the page
- `Sources/Surf/VisualEffectBackground.swift` — the transparent blurred window

## Dev

`SURF_URL=example.com swift run` boots straight to a page and logs load
results to stderr — handy for exercising navigation without clicking.
Comma-separate to open several tabs: `SURF_URL=example.com,apple.com swift run`.

State lives in `~/Library/Application Support/Surf/session.json`.
`SURF_STATE_DIR=<dir>` moves all of Application Support — session, history,
favicons, filter lists, helpers, voice — so a second Surf can run without
touching the first's tabs. Overriding `HOME` doesn't: `FileManager` resolves
Application Support from the account.

`SURF_DEVTOOLS=elements` alongside `SURF_URL` opens the panel on that pane at
launch. The injected half of dev tools exists only while a panel is attached,
so without it there is no way to exercise the largest thing Surf puts into a
page except by hand.

Every web view is inspectable, so Safari's Develop menu opens a full Web
Inspector on any tab. Safari ships with that menu hidden, so it costs nothing
until someone goes looking for it.

An injected contract has two halves in two languages — a case in an enum, and
a registration in a script — and the compiler only sees the first.
`./scripts/check-js.sh` closes that gap: it dumps the real scripts, installs
them in a real JavaScript engine, and asks whether they answer to everything
the enums claim. Needs `node` on `PATH`.

Both contracts are checked: `PageProtocol.Method` against the always-resident
page agent, and `DevToolsMethod` against the three scripts dev tools installs
while attached. Dev tools also gets a routing check, because that is where this
has already gone wrong once — `Runtime.evaluate` sent to the inspection agent
instead of the page fails as "unknown method", which reads like a missing
feature rather than a misroute. So every method is asked of the two targets it
*doesn't* belong to as well, and answering there is a failure. The dispatch
sources are the real ones, dumped from Swift rather than restated in the
checker, so the path exercised is the one `DevToolsBridge` uses.

## Next

- Registering as a browser, so links from other apps arrive — and land in a
  mini window, which is the case that feature exists for
- A back/forward menu on long-press
- Search engine preference (DuckDuckGo is the default; Google is implemented)
- Moving a tab between islands, which nothing can do yet — it is what "Move to
  Island" and "Open Link in New Island" are both waiting on
- Cross-origin iframes, which are a separate document nothing in the page can
  reach into — theming one means running the whole pass inside it
- The tab list on `reorderable` / `reorderContainer`, as the sticker shelf
  already is. It is the better model and not just less code: each section
  becomes a collection, so reordering a tab and filing it into a folder stop
  being separate gestures with separate delegates, and the drop reports which
  folder it meant instead of leaving it to be inferred from whatever row the
  pointer was over.

  It does not work yet. With a `reorderContainer` on the list, lifting a row
  dies inside SwiftUI: `DragContainerStorage.payload(for:)` fails a
  precondition reading *"Expected UUID, got UUID"* — a message that cannot
  distinguish the two types it is comparing. Six configurations of the list
  were tried, including with the collection dimension removed entirely, and
  every one crashes; a standalone harness built to match it, including the
  enum row type, the class-backed model, a conditional `ForEach` body and an
  empty region inside the container, does not crash in any of them. The
  sticker shelf's own container is not involved — removing it changes nothing.
  Whatever the list does that the harness does not has not been found, and a
  radar is probably worth more than another afternoon of bisecting.
