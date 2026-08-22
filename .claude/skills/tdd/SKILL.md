---
name: tdd
description: Test-driven development for Surf. Use when the user wants to build features or fix bugs test-first, mentions "red-green-refactor", or asks how to make app code testable.
---

<!-- Adapted from mattpocock/skills (MIT). -->

# Test-Driven Development

TDD is the red → green loop. This skill is the reference that makes that loop produce tests worth keeping: what a good test is, where tests go in this repo, the anti-patterns, and the rules of the loop. Consult it before and during the loop, not after.

If the repo has a context doc or design notes for the area you're touching, read them first so test names and interface vocabulary match the project's language.

## Where tests live in Surf

There is one test target: `Tests/SurfCoreTests` (swift-testing: `import Testing`, `@Suite`, `@Test`, `#expect`), testing `Sources/SurfCore` via `@testable import SurfCore`. Run one suite with `swift test --filter FocusModelTests`.

`SurfCore` is the seam. It is pure Swift with no AppKit or WebKit, so anything in it is testable in seconds; `Sources/Surf` (views, `WKWebView`, the page agent) is not unit-tested at all. **The house pattern is to push logic out of `Sources/Surf` into `SurfCore`** until what's left in the app is a thin adapter: decode the payload, call the model, render the result. Examples to copy:

- `FocusModel.swift` / `FocusModelTests.swift`: the extractor's JSON payload decodes into `FocusArticle`; the tests feed literal JSON and assert on the model, never on a web view.
- `RecipeModel.swift` / `RecipeModelTests.swift`: `FocusRecipe` parsing, with `testpages/recipe-demo.html` as the matching end-to-end fixture.
- `MediaRanking.swift`, `DOMTree.swift`, `IslandLayout.swift`: ranking, tree, and layout math that the app only calls.
- `*Wire.swift` files: the shapes that cross the Swift–JS seam, decodable without a page.

If a behaviour can't be tested because it's tangled into a view or a `WKWebView` callback, that is the first thing to fix: extract the decision into a `SurfCore` type that takes values and returns values, then test that.

Injected JavaScript has no unit tests; its contract with Swift is checked by `scripts/check-js.sh`, and its behaviour by `testpages/*.html` fixtures launched with `SURF_URL=`. Keep JS logic small and push decisions to Swift where you can test them.

## What a good test is

Tests verify behaviour through public interfaces, not implementation details. Code can change entirely; tests shouldn't. A good test reads like a specification: "a recipe with no yield still parses" tells you what capability exists, and survives refactors because it doesn't care about internal structure.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## Seams: where tests go

A **seam** is the public boundary you test at: the interface where you observe behaviour without reaching inside. Tests live at seams, never against internals.

**Test only at pre-agreed seams.** Before writing any test, write down the seams under test and confirm them with the user. You can't test everything, so agreeing the seams up front is how effort lands on the critical paths and complex logic instead of every edge case.

Ask: "What's the public interface, and which seams should we test?" In Surf the answer is usually "the `SurfCore` type the app will call", and the question becomes whether that type exists yet.

When the shape of the interface is itself in question (how deep the module is, where the seam belongs, what it should expose), call the Skill tool with "codebase-design" for the vocabulary. It is the shared source of the module, interface, depth, seam, adapter, leverage and locality terms: a reference to consult, not a session to run.

## Anti-patterns

- **Implementation-coupled**: mocks internal collaborators, tests private methods, or verifies through a side channel. The tell: the test breaks when you refactor but behaviour hasn't changed.
- **Tautological**: the assertion recomputes the expected value the way the code does, so it passes by construction. Expected values come from an independent source of truth: a known-good literal, a worked example, a real page's payload.
- **Horizontal slicing**: writing all tests first, then all implementation. Bulk tests verify _imagined_ behaviour and commit you to structure before you understand it. Work in **vertical slices**: one test → one implementation → repeat, each test a **tracer bullet** that responds to what the last cycle taught you.
- **Testing the view**: asserting on SwiftUI or `WKWebView` state. If the behaviour matters, it belongs in `SurfCore` where a value-in, value-out test can reach it.

## Rules of the loop

- **Red before green.** Write the failing test first, then only enough code to pass it. Don't anticipate future tests or add speculative features.
- **One slice at a time.** One seam, one test, one minimal implementation per cycle.
- **Prefer no test over a bad test, and say why.** If the only reachable seam would give a tautological or implementation-coupled test, don't write it; say which seam is missing and what extraction would create it. A `@Test` that can't fail is worse than a gap someone can see.
- **Refactoring is not part of the loop.** It belongs to the review stage (see the `code-review` skill), not the red → green cycle.
