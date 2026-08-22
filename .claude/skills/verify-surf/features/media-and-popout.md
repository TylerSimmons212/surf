# Media, theater, and pop-out

A tab playing media shows a now-playing strip in the sidebar; video can pop out into a floating always-on-top panel, automatically when switching away (`Settings › Media`). Video pages get theater mode inside Focus. `Sources/Surf/MediaBridge.swift`, `PopOutController.swift`, `VideoLensView.swift`, `SurfCore/MediaRanking.swift`.

## Sub-features

- Now-playing strip with play/pause
- Pop-out panel, auto pop-out on tab switch, fold back on return
- Theater: the page's own element pinned fullscreen, restored byte-for-byte on exit
- Iframe video pinned within its frame

## How to get to it (user POV)

Open `testpages/media-demo.html`, press play. The strip appears at the bottom of the sidebar; its pop-out button floats the video. Switch tabs to see auto pop-out. On a video page, the Focus pill offers theater.

## Driving it with verify-surf

No env driver starts playback (autoplay with sound is blocked by WebKit). Launch, then hand the user the sequence:

```bash
.claude/skills/verify-surf/scripts/launch.sh media "file://$PWD/testpages/media-demo.html"
# user: press play; click the pop-out button; open a second tab; return
.claude/skills/verify-surf/scripts/window.sh media popout
.claude/skills/verify-surf/scripts/stop.sh media
```

Use `diagnosing-bugs`' HITL loop template to structure the hand-off if this is a bug hunt.

## What proves it

- `windows.txt` after pop-out shows a second on-screen window for the pid (the panel); `window.sh` records the first wide window only, so run `swift` snippet from it with the filter removed, or have the user confirm the floating panel.
- Theater: `focus: video staged` on entering the theater; `focus: staged video gone — leaving the theater` when the element is removed by the page.
- The Swift ranking of which media element wins is unit-tested: `swift test --filter MediaRanking`.

## Gotchas

- `media-demo.html` and `media-ranking.html` are the two fixtures; the second exists for the ranking rules, not for playback.
- Theater survives hostile players by restoring saved inline styles; if a page looks wrong after leaving theater, diff the element's `style` attribute before and after via the page agent, not by eye.
