---
name: diagnosing-bugs
description: Diagnosis loop for hard bugs and performance regressions in Surf. Use when the user says "diagnose" or "debug this", or reports something broken, crashing, failing, or slow.
---

<!-- Adapted from mattpocock/skills (MIT). -->

# Diagnosing Bugs

A discipline for hard bugs. Skip phases only when explicitly justified.

Surf is a macOS 26 browser: Swift 6 + SwiftUI + WebKit, built with SwiftPM. Logic lives in `SurfCore` (`Sources/SurfCore`, no AppKit/WebKit, unit-tested by `Tests/SurfCoreTests`, swift-testing); the app is `Sources/Surf`. Much of what runs in a page is JavaScript injected from Swift string literals (`Sources/Surf/PageScripts.swift` and the `*Bridge`/`*Agent`/`*Domain` files), so a "Swift bug" is often a JS bug or a contract mismatch between the two.

## Redact

This skill has you show commands, outputs and captured artifacts. **Redact every secret first**: write `<REDACTED>` in its place. Keep credentials in env vars, not in what you show. Page dumps and logs can carry cookies, tokens, and personal content: quote only the lines that carry the signal.

If the redacted output is not enough to diagnose the bug, say so and ask the user.

## Phase 1: Build a feedback loop

**This is the skill.** Everything else is mechanical. If you have a **tight** pass/fail signal for the bug (one that goes red on _this_ bug), you will find the cause; bisection, hypothesis-testing, and instrumentation all just consume it. If you don't, no amount of staring at code will save you.

Spend disproportionate effort here. **Be aggressive. Be creative. Refuse to give up.**

### Ways to construct one, in priority order

1. **SurfCore unit test.** `swift test --filter <SuiteOrTestName>`. If the bug is in parsing, ranking, layout math, model state, or wire decoding, it is (or should be) in `SurfCore`, and a failing `@Test` is the whole loop. If the logic is in `Sources/Surf` and can't be reached, the first move is often to push it across the module boundary so it can be (see the `tdd` skill). Runs in seconds, fully deterministic.
2. **Injected-JS contract check.** `scripts/check-js.sh` builds Surf, dumps every injected script via `SURF_DUMP_SCRIPTS`, `node --check`s them, and asks a real JS engine whether every method `PageProtocol.Method` / `DevToolsMethod` declares is actually registered. A method that "silently does nothing" is usually caught here. You can also read the dumped `.js` files directly: `SURF_DUMP_SCRIPTS=.build/js-check .build/debug/Surf`.
3. **Fixture page + stderr assertions.** Put the smallest HTML that shows the bug in `testpages/` (there are existing fixtures for focus, recipe, media, console, layout, video). Build with `scripts/bundle.sh` (WKWebView needs a real bundle to run), then launch with the dev env vars and grep stderr:
   ```
   SURF_URL=testpages/recipe-demo.html SURF_FOCUS=1 SURF_SILENT=1 \
     ./Surf.app/Contents/MacOS/Surf 2>&1 | grep -E '^\[surf\]|^agent:' | tee /tmp/run.log
   ```
   `SURF_URL` is the dev switch: it opens the page at launch **and** enables `debugLog` (`[surf] …`, `Sources/Surf/DebugLog.swift`) and `pageAgentLog` (`agent: …`, `Sources/Surf/PageAgent.swift`). `SURF_FOCUS=1` enters Focus once the page loads, `SURF_FOCUS=2` also starts narration, `SURF_SILENT=1` mutes it, `SURF_DEVTOOLS=<pane>` opens dev tools on that pane (see `Sources/Surf/ContentView.swift`, `applyLaunchEnvironment`). Add a tagged `debugLog` at the symptom and assert on its presence/absence; kill the app after a timeout. If `.claude/skills/verify-surf/scripts/launch.sh` exists, it already does this (isolated HOME, waits for a stderr pattern, exits 1 on timeout) and is the right thing to wrap.
4. **Evaluate JS in the page through the agent.** When the symptom lives in the DOM, temporarily call `PageAgent.call` (or `callAsyncJavaScript`) from a dev hook and log the result with `pageAgentLog`, or ask the user to run a snippet in Surf's own console (`SURF_DEVTOOLS=console`). The dumped scripts from (2) run in plain `node` for logic that doesn't need a DOM.
5. **Bisect.** If it worked at some commit, wrap any of the above in a script that exits 0/1 and `git bisect run ./repro.sh`. `swift test --filter` and `check-js.sh` already have that exit contract.
6. **Differential / property loop.** Run old vs new (two builds, two fixtures, two configs) through the same input and diff. For "sometimes wrong output", feed 1000 generated inputs to the SurfCore function and look for the failure mode.
7. **HITL bash script.** Last resort, for things that need a human at the window (gestures, real sites behind a login, audio). Drive _them_ with `scripts/hitl-loop.template.sh` so the loop is still structured and the captured output feeds back to you.

Build the right feedback loop, and the bug is 90% fixed.

### Tighten the loop

Treat the loop as a product. Once you have _a_ loop, **tighten** it:

- Faster? (`--filter` one test; skip `bundle.sh` when a plain `swift build` binary will do; cache the dumped scripts.)
- Sharper? (Assert on the specific symptom, not "didn't crash" or "a log line appeared".)
- More deterministic? (Pin time, seed RNG, use a local fixture instead of a live site, freeze the network.)

A 30-second flaky loop is barely better than no loop; a 2-second deterministic one is a debugging superpower.

### Non-deterministic bugs

The goal is not a clean repro but a **higher reproduction rate**. Loop the trigger 100×, add stress (`testpages/heavy.html`), narrow timing windows, inject sleeps around the `Task.sleep` polling the launch hooks already use. A 50% flake is debuggable; 1% is not, so keep raising the rate until it is.

### When you genuinely cannot build a loop

Stop and say so explicitly. List what you tried. Ask the user for: (a) the URL or a saved copy of the page that reproduces it, (b) a redacted stderr capture from a `SURF_URL=` launch or a screen recording with timestamps, or (c) permission to add temporary instrumentation they run. Do **not** proceed to hypothesise without a loop.

### Completion criterion: a tight loop that goes red

Phase 1 is done when the loop is **tight** and **red-capable**: you can name **one command** (a `swift test --filter`, a script path, a launch line) that you have **already run at least once** (show the invocation and its output, redacted), and that is:

- [ ] **Red-capable**: it drives the actual bug code path and asserts the **user's exact symptom**, so it can go red on this bug and green once fixed. Not "runs without erroring".
- [ ] **Deterministic**: same verdict every run (flaky bugs: a pinned, high reproduction rate).
- [ ] **Fast**: seconds, not minutes.
- [ ] **Agent-runnable**: you can run it unattended; a human in the loop only via `scripts/hitl-loop.template.sh`.

If you catch yourself reading code to build a theory before this command exists, **stop: jumping straight to a hypothesis is the exact failure this skill prevents.** No red-capable command, no Phase 2.

## Phase 2: Reproduce + minimise

Run the loop. Watch it go red.

Confirm:

- [ ] It produces the failure the **user** described, not a nearby one. Wrong bug = wrong fix.
- [ ] It reproduces across multiple runs (or at a high enough rate).
- [ ] You have captured the exact symptom (message, wrong output, timing) so later phases can verify the fix addresses it.

### Minimise

Shrink the repro to the **smallest scenario that still goes red**: cut HTML from the fixture, fields from the JSON payload, steps, config, one at a time, re-running after each cut. Done when **every remaining element is load-bearing**. A minimal fixture shrinks the hypothesis space and becomes the regression test.

## Phase 3: Hypothesise

Generate **3–5 ranked hypotheses** before testing any. Each must be **falsifiable**: state its prediction.

> "If <X> is the cause, then <changing Y> will make the bug disappear / <changing Z> will make it worse."

No prediction, no hypothesis: discard or sharpen it.

Surf-specific suspects worth keeping on the list: Swift and JS disagreeing on a method name or payload shape (check-js catches names, not shapes); the wrong content world (`.isolated` vs `.page` in `PageRuntime`); running on a page that is still loading; `@MainActor` / Sendable hops reordering events; an extractor reading a DOM the site mutates after load.

**Show the ranked list to the user before testing.** They often re-rank it instantly. Don't block on it.

## Phase 4: Instrument

Each probe maps to one prediction. **Change one variable at a time.**

1. A failing `@Test` with a narrowed input, or `swift test` under `lldb`, when the env supports it.
2. **Targeted** `debugLog` / `pageAgentLog` / `console.log` at the boundaries that distinguish hypotheses (the Swift-JS seam is usually the right one).
3. Never "log everything and grep".

**Tag every debug log** with a unique prefix, e.g. `[DEBUG-a4f2]`, so cleanup is a single grep.

**Perf branch.** For regressions, logs are usually wrong. Establish a baseline (a timing harness around the SurfCore call, Instruments, `performance.now()` in the injected script), then bisect. Measure first, fix second.

## Phase 5: Fix + regression test

Write the regression test **before the fix**, but only at a **correct seam**: one where the test exercises the real bug pattern as it occurs at the call site. In Surf that is usually a `SurfCore` test over the decoded payload or model; if the bug is in injected JS, the seam may be the dumped script run in `node`, or a `testpages/` fixture.

If the only available seam is too shallow, a test there gives false confidence. **If no correct seam exists, that itself is the finding**: note it, and consider moving the logic into `SurfCore` so one does.

If a correct seam exists: turn the minimised repro into a failing test, watch it fail, fix, watch it pass, then re-run the Phase 1 loop against the original un-minimised scenario.

## Phase 6: Cleanup

- [ ] Original repro no longer reproduces (re-run the Phase 1 loop)
- [ ] Regression test passes (or absence of seam is documented)
- [ ] All `[DEBUG-...]` instrumentation removed (`grep` the prefix, in Swift and in the JS literals)
- [ ] Throwaway fixtures and scripts deleted, or kept in `testpages/` with a clear name if they earn it
- [ ] `swift test` and `scripts/check-js.sh` green
- [ ] The hypothesis that turned out correct is stated in the commit message, so the next debugger learns
