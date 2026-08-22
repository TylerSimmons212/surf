<!-- Adapted from mattpocock/skills (MIT). -->

# When to Mock

Mock at **system boundaries** only. In Surf those are:

- The web view and the page agent (anything that needs `WKWebView` or a DOM)
- The network (filter-list downloads, yt-dlp, model downloads)
- Time and randomness
- The file system and `UserDefaults` (sometimes; prefer a temp directory)
- Speech and audio engines

Don't mock:

- Your own `SurfCore` types
- Internal collaborators
- Anything you control

Mostly you won't need a mock at all: the house pattern is to decode what the boundary produced into a value (`FocusArticle`, a `*Wire` struct, a ranked list) and test the logic on that value. The page agent's JSON payload pasted into a test *is* the stand-in for the web view.

## Designing for Mockability

At the boundaries you do keep, design interfaces that are easy to substitute:

**1. Inject dependencies**

Pass the boundary in rather than reaching for it internally:

```swift
// Easy to test: the clock is a parameter
func shouldRefresh(list: FilterList, now: Date) -> Bool

// Hard to test
func shouldRefresh(list: FilterList) -> Bool {
    Date().timeIntervalSince(list.fetchedAt) > week
}
```

**2. Prefer value-in, value-out over callbacks into the view**

A `SurfCore` function that returns a decision is testable; one that mutates a view model it was handed is not. Return the result and let the app apply it.

**3. Prefer specific operations over a generic fetcher**

One method per operation at the boundary means each substitute returns one specific shape, with no conditional logic in test setup:

```swift
// GOOD: each independently substitutable
protocol PageQuerying {
    func article() async throws -> FocusArticle
    func mediaCandidates() async throws -> [MediaSource]
}

// BAD: the fake has to dispatch on the method name
protocol PageQuerying {
    func call(_ method: String, _ args: [String: Any]) async throws -> Data
}
```
