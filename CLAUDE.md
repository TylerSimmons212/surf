# Surf

macOS 26 web browser. Swift 6, SwiftUI, WebKit, SwiftPM. [README.md](README.md) is the design record: read the section for the subsystem you're touching before changing it.

## Layout

- `Sources/SurfCore` — pure logic, no AppKit/WebKit. Everything testable lives here; push logic out of `Sources/Surf` into it when you need a test.
- `Sources/Surf` — the app: views, `Tab`, bridges to injected JS (`*Bridge.swift`), dev tools, narration, pop-out.
- `Sources/SherpaTTSABI` — pinned C struct layouts for the dlopen'd TTS runtime. Don't edit without bumping the pinned version.
- `Tests/SurfCoreTests` — swift-testing (`import Testing`), one file per SurfCore type.
- `testpages/` — HTML fixtures for driving the app by hand or via `SURF_URL`.

## Commands

```bash
swift build
swift test --filter <TypeName>Tests
./scripts/check-js.sh        # Swift enum ↔ JS registration contract; needs node
./scripts/bundle.sh          # Surf.app, needed for Reminders and a real bundle id
SURF_URL=<url> swift run     # open straight to a page; enables [surf] stderr logs
```

Other launch drivers: `SURF_FOCUS=1|2`, `SURF_SILENT=1`, `SURF_DEVTOOLS=<pane>`, `SURF_DOWNLOAD=1|2` (with `SURF_DOWNLOAD_PICK=<height>` to take one row of the quality menu), `SURF_DUMP_SCRIPTS=<dir>` (defined in `Sources/Surf/ContentView.swift`), and `SURF_STATE_DIR=<dir>` to keep a run out of your real Application Support (`SupportDirectory` in SurfCore).

## The contract the compiler can't see

Injected JS registers methods by name; Swift declares them as enum cases (`PageProtocol.Method`, `DevToolsMethod`). Two content worlds (isolated, page). Nothing type-checks the pair. After touching either side, run `./scripts/check-js.sh`. `*Wire.swift` files in SurfCore are the JSON shapes those replies decode into; a key renamed on one side fails silently on the other.

## Skills

Project skills in `.claude/skills/`. Reach for them by situation:

- Something is broken, throwing, or slow → `diagnosing-bugs` (build a red loop before hypothesising).
- Small diff you don't fully trust → `blast-radius` (find the one fact it's safe because of; prove it by running code).
- Changing `Sources/Surf` or injected JS → `verify-surf` (drive the real app, isolated, capture evidence).
- Adding behavior test-first → `tdd`; deciding where a seam goes → `codebase-design`.
- Explaining a subsystem → `how`. Sharpening a plan before a big feature → `grill-me`.
- Writing prose (README, commits, PRs) → `unslop`. Writing or editing a skill or this file → `writing-for-agents`.

## Conventions

- Commit messages and README prose are written as explanations, not changelogs. Keep that voice.
- No Surf state escapes the machine; preserve that in any feature that touches the network.
- Verification runs set `SURF_STATE_DIR` to a scratch directory (`verify-surf/scripts/launch.sh`); never drive the user's own Surf instance or state.
