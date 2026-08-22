---
name: blast-radius
description: "Find what a change could break beyond the diff, then prove the one fact it's safe because of by running real code. Use for 'blast radius of X', 'what could this break', or reviewing a small diff you don't trust."
disable-model-invocation: true
---

# Blast radius

Adapted from cursor/plugins pstack.

Find what a change breaks somewhere else, before it ships. Companion to `how` (what the code does). Blast radius is what it breaks elsewhere.

Listing the callers is not the job. Grep does that in a second. The job is the breakage grep won't show you.

## Don't trust your own writeup

A blast-radius writeup that sounds right is worthless. It reads as convincing whether or not it's true. So don't hand back the writeup. Find the one or two facts the whole thing depends on and prove them by running code.

### How sure are you

For each fact the change's safety depends on, get it as far down this list as is cheap, and say where it stopped.

1. You said so. Worthless on its own.
2. You pointed at the line. A real `file:line`, or the library's own source.
3. You showed the bad case can't happen. You walked the failure step by step and it doesn't reach.
4. You ran it. A script or test that calls the real code and fails loud if you're wrong.
5. You reproduced it in the running app.

Any safety fact you can't get to step 4, say so out loud. Don't write it up as settled.

## Steps

1. Read the change. The diff, the symbols it adds, changes, and deletes, and what it now does differently, including the part the diff doesn't spell out. Pull the PR description and `git log` for the touched files.
2. Find the one fact it's safe because of. Most scary-looking changes are safe because of a single fact, like "this call only drops already-dead cache entries". Find it. If it holds, most of the scary cases die at once. Spend your time here, not on a long list of maybes.
3. Look where grep stops (see the Surf list below). Read the source of the library you call and check its pinned version. Work out when things run: main actor hops, teardown, async tasks outliving their view. Follow what a symbol search misses: a JSON shape, a wire format, another language reading the same bytes, code three hops downstream.
4. Be honest about each risk. Give it a real chance of happening and a real cost if it does. Keep the ones you confirmed; list the ones you checked and cleared separately. Cite a real `file:line`. A search that finds nothing is still an answer. Never invent a caller or an API.
5. Prove the one fact. Write a script or test that runs the real code, run it, paste what happened. If you can't prove it cheaply, mark it unproven. Don't round up.

## Where grep stops in Surf

These are the seams where a symbol search returns nothing and the break is real anyway.

- **The Swift/JS contract.** A method is declared twice in two languages: a case in `PageProtocol.Method` (`Sources/SurfCore/PageProtocol.swift`) and an `agent.define('focus.extract', ...)` registration in a script under `Sources/Surf/*Bridge.swift` / `*Domain` / `PageRuntime.swift`. The compiler sees only the Swift half. There are also two content worlds, `.isolated` and `.page` (`PageProtocol.swift:79`), and a method registered in the wrong one answers nothing. Proof: `scripts/check-js.sh` dumps the real scripts via `SURF_DUMP_SCRIPTS` and runs them in node against the enum.
- **Wire formats.** `Sources/SurfCore/{CSS,Console,DOM,Network,Performance}Wire.swift` decode JSON that JavaScript builds by hand. Renaming a key on one side compiles fine. Proof: `swift test --filter <WireTests>` with a fixture payload, and check the JS that emits it.
- **Resident vs lazily injected scripts.** `PageScripts.swift:226` marks `capture.js` as injected on first use and `focus-extract.js` as evaluated on demand, not resident. A method that works in the dump can still be missing at the moment Swift calls it, if the injection hasn't happened yet or the page navigated in between.
- **WKWebView lifecycle.** Script message handlers, `deinit` ordering, and navigation mid-call (`Sources/Surf/PageAgent.swift`, `Tab.swift`). A reply that arrives after the tab is gone, or an `evaluateJavaScript` on a torn-down view, shows up as `PageProtocol.Failure.unreachable`, not as a compile error.
- **The dlopen'd Sherpa ABI.** `Sources/SherpaTTSABI/include/sherpa_tts_abi.h` reproduces sherpa-onnx struct layouts pinned to v1.13.6, loaded via `dlopen` in `Sources/Surf/KokoroEngine.swift` and `VoiceInstaller.swift`. Nothing type-checks across that boundary. Bumping the library or reordering a field is a silent memory-layout bug. Proof is step 5 only: run the engine on a real voice.

### Proof tools

- `swift test --filter <Name>` for anything in `SurfCore`.
- `scripts/check-js.sh` for the JS contract in both worlds.
- `SURF_URL=testpages/<fixture>.html swift run` (see `testpages/`) to reproduce in the running app. Add `SURF_FOCUS=1` to enter Focus automatically.

## What to hand back

- **What it does.** What changed, including the part that isn't obvious.
- **The one fact it's safe because of.** State it, say which step you got it to, show the proof. If you couldn't prove it, write unproven.
- **Risks.** Only the real ones. Each names how it breaks, the `file:line`, how likely and how bad, and how to check.
- **Cleared.** What you checked and why it's fine.
- **Before you merge.** The cheapest test or repro that catches the real bug, including the script you wrote.

Write it through `unslop` and cite real code.
