# Focus (YouTube site lens)

The first site lens: `⌘⇧F` on youtube.com replaces the site with a search field, a search with Surf's own grid, and a card with YouTube's player pinned under Surf's transport. Models and URL routing in `SurfCore` (`YouTubeModel.swift`, `SiteFocus.swift`, tested); injected domain in `Sources/Surf/YouTubeBridge.swift`; state in `YouTubeLens.swift`; views in `YouTubeLensView.swift` and `YouTubeStageChrome.swift`.

## Sub-features

- The pill offers the site by address, not by classification; the classifier is skipped entirely on hosts that have a lens
- Results parsed from `ytInitialData`, not the rendered DOM
- The lens survives its own navigations and drops when the address leaves the site
- The stage pins `#movie_player`, so YouTube's own caption layer survives it
- Chapters (millisecond starts), subtitle tracks, playback speed
- Arrow keys scrub five seconds (shared with the generic theater, `TransportKeys.swift`)

## How to get to it (user POV)

Open any youtube.com page; the pill in the corner says YouTube; enter it. Type a search and press return for the grid, click a card for the player. The close button in the player's corner goes back to the grid without re-searching.

## Driving it with verify-surf

```bash
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh yt "https://www.youtube.com/results?search_query=swift+concurrency"
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh yt-watch "https://www.youtube.com/watch?v=u2rYp8AMuSg"
.claude/skills/verify-surf/scripts/stop.sh yt
```

## What proves it

- `focus: YouTube lens` on entry.
- `youtube: N results for "..."` with N matching the site's own first page (15 for the query above).
- `youtube: staged "<title>" — N chapters, N caption tracks` on a watch page.
- No `focus: article`/`focus: video` line anywhere in the run: the classifier is skipped on lens hosts, and a line means that skip regressed.
- Scrubbing, chapter seeks, captions and speed are click-driven; hand the user the steps.

## Gotchas

- Needs the network and a real YouTube page. There is no fixture: the payloads are the site's own, and a captured one would rot. Parser edge cases belong in `swift test --filter YouTube`, where captures from the real site are pinned.
- The injected script is not resident. It is evaluated when the lens opens, so a page loaded without entering the lens answers no `youtube.*` method; `youtube.js` is in the `SURF_DUMP_SCRIPTS` dump anyway so `check-js.sh` can see its registrations.
- `hasPlayer` is true on a *results* page too — YouTube keeps a player around for hover previews. It means "addressable", never "this is a watch page"; the address decides that.
- Arrow keys need the overlay to hold keyboard focus. Clicking the video hands focus back to the page; moving the pointer takes it back. A "keys do nothing" report is usually that.
