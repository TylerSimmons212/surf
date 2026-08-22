# Focus (article lens)

`⌘⇧F` replaces an article with the native SwiftUI reader. A resident script counts the page; Swift classifies it (`SurfCore/FocusClassification.swift`); when confident, a pill offers Focus. Entering injects the extractor (`focus-extract.js`) and renders the blocks.

## Sub-features

- Classification and the offer pill
- Extraction into headings, paragraphs, quotes, code, lists, figures
- Leaving Focus lands on the passage being read
- Declining when the page has no article

## How to get to it (user POV)

Open an article. A pill appears in the corner when Surf is confident; click it or press `⌘⇧F`. `⌘⇧F` again (or Escape) leaves.

## Driving it with verify-surf

```bash
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh focus "file://$PWD/testpages/focus-demo.html" 'focus: extracted' 40
.claude/skills/verify-surf/scripts/window.sh focus
.claude/skills/verify-surf/scripts/stop.sh focus
```

`SURF_FOCUS=1` waits for the load to settle, then calls `tab.enterFocus()` — the same path the pill takes (`ContentView.swift`, `enterFocusIfAsked`).

## What proves it

- `focus: article <confidence> — <words> words in <paragraphs> paragraphs` — the classifier saw an article above `offerThreshold`.
- `focus: extracted <blocks> blocks, <words> words from <container> — "<title>"` — extraction ran and chose a container. For `focus-demo.html` expect 14 blocks from `div.layout > article`, titled "The Long Memory of Tides".
- A non-article fixture (`testpages/index-imposter.html`) should log `focus: declined — N words extracted` instead.

## Gotchas

- `SURF_FOCUS` polls up to 15 s for the load to settle, then waits 1 s more; give `launch.sh` a timeout of 40.
- Classification runs from the resident script; extraction only when Focus is entered. A page that classifies but never extracts points at `focus-extract.js` or `Tab.enterFocus`, not the classifier.
- Unit-level: `swift test --filter FocusClassificationTests` and `FocusModelTests` cover the Swift half without launching.
