# Media, theater, and pop-out

A tab playing media shows a now-playing strip in the sidebar; video can pop out into a floating always-on-top panel, automatically when switching away (`Settings › Media`). Video pages get theater mode inside Focus. `Sources/Surf/MediaBridge.swift`, `PopOutController.swift`, `VideoLensView.swift`, `SurfCore/MediaRanking.swift`.

## Sub-features

- Now-playing strip with play/pause
- Pop-out panel, auto pop-out on tab switch, fold back on return
- Theater: WebKit's native video viewer first; when it refuses, the page's own element pinned fullscreen, restored byte-for-byte on exit
- Theater offered only for a video with sound — never for a page whose only video is a muted advert
- Iframe video pinned within its frame

## How to get to it (user POV)

Open `testpages/media-demo.html`, press play. The strip appears at the bottom of the sidebar; its pop-out button floats the video. Switch tabs to see auto pop-out. On a video page, the Focus pill offers theater.

## Driving it with verify-surf

Theater is drivable: `testpages/theater-ads.html` plays its feature with sound on load, and `SURF_FOCUS=1` enters Focus once the page settles. `?main`, `?paused` and `?ad` are the three cases (feature playing, feature paused beside a playing advert, advert alone):

```bash
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh theater "file://$PWD/testpages/theater-ads.html?paused" "focus: (video|no video)"
grep 'focus:' .verify/theater/stderr.log
.claude/skills/verify-surf/scripts/stop.sh theater
```

The now-playing strip and pop-out still need a click. Launch, then hand the user the sequence:

```bash
.claude/skills/verify-surf/scripts/launch.sh media "file://$PWD/testpages/media-demo.html"
# user: press play; click the pop-out button; open a second tab; return
.claude/skills/verify-surf/scripts/window.sh media popout
.claude/skills/verify-surf/scripts/stop.sh media
```

Use `diagnosing-bugs`' HITL loop template to structure the hand-off if this is a bug hunt.

## What proves it

- `windows.txt` after pop-out shows a second on-screen window for the pid (the panel); `window.sh` records the first wide window only, so run `swift` snippet from it with the filter removed, or have the user confirm the floating panel.
- Theater, native: `focus: video in the native viewer from Focus — feature` names the element WebKit chose (`IFRAME` when the video is in an embed). `?paused` is the case that matters: its `media: chose` lines pick the advert and the viewer still names `feature`. `focus: native viewer closed itself — leaving the theater` when the viewer's own control closed it.
- Theater, refused: `?ad` logs `focus: no video with sound to stage` and nothing opens.
- Theater, fallback: `focus: video staged from Focus — native viewer refused` (a tiny unmuted video triggers it); `focus: staged video gone — leaving the theater` when the element is removed by the page.
- The Swift ranking of which media element wins is unit-tested: `swift test --filter MediaRanking`.

## Gotchas

- `media-demo.html` and `media-ranking.html` are the two fixtures; the second exists for the ranking rules, not for playback.
- Theater survives hostile players by restoring saved inline styles; if a page looks wrong after leaving theater, diff the element's `style` attribute before and after via the page agent, not by eye.
