<!-- Adapted from mattpocock/skills (MIT). -->

# Good and Bad Tests

Surf tests are swift-testing suites in `Tests/SurfCoreTests`, testing `SurfCore` through its public types.

## Good Tests

**Integration-style**: test through the real interface, not mocks of internal parts.

```swift
// GOOD: observable behaviour, through the type the app actually calls
@Test("A recipe with no yield still parses, with no serving count")
func recipeWithoutYield() throws {
    let recipe = try #require(FocusRecipe.parse(fromJSONLD: ["""
    { "@type": "Recipe", "name": "Toast",
      "recipeIngredient": ["1 slice bread"], "recipeInstructions": ["Toast it."] }
    """]))
    #expect(recipe.servings == nil)
    #expect(recipe.ingredients.count == 1)
}
```

Characteristics:

- Tests behaviour callers care about
- Uses the public interface only
- Survives internal refactors
- Describes WHAT, not HOW
- One logical assertion per test
- Inputs are literal payloads or fixtures, the same shape the page agent delivers

## Bad Tests

**Implementation-detail tests**: coupled to internal structure.

```swift
// BAD: asserts on how the ranking is computed, not what it ranks
@Test func rankingCallsScoreOnEveryCandidate() {
    let spy = SpyScorer()
    _ = MediaRanking.rank(candidates, scorer: spy)
    #expect(spy.calls == candidates.count)
}
```

Red flags:

- Mocking internal collaborators
- Testing private methods (`@testable import` lets you; don't)
- Asserting on call counts or order
- Test breaks when refactoring without behaviour change
- Test name describes HOW not WHAT
- Verifying through a side channel instead of the interface

```swift
// BAD: bypasses the interface to verify
@Test func sanitizedSessionWritesFile() throws {
    try JSONEncoder().encode(session.sanitized()).write(to: sessionURL)
    #expect(try Data(contentsOf: sessionURL).count > 0)
}

// GOOD: verifies through the interface
@Test func selectedIndexSurvivesRoundTrip() throws {
    let data = try JSONEncoder().encode(session)
    let restored = try JSONDecoder().decode(PersistedSession.self, from: data)
    #expect(restored.selectedIndex == 2)
}
```

**Tautological tests**: the expected value restates the implementation.

```swift
// BAD: recomputed the way the code computes it
@Test func zoomingInPicksNextLevel() {
    let expected = ZoomSteps.levels.first { $0 > 1.0 }!
    #expect(ZoomSteps.zoomingIn(from: 1.0) == expected)
}

// GOOD: an independent, known literal
@Test func zoomingInFromStandardGivesOneTen() {
    #expect(ZoomSteps.zoomingIn(from: 1.0) == 1.1)
}
```
