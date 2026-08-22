# Focus (recipe lens)

A page carrying `schema.org/Recipe` JSON-LD gets the recipe lens instead of the article: ingredients with checkboxes and scaling, sectioned steps, Cook Mode, "Add to Groceries". Parser in `SurfCore` (tested); view in `Sources/Surf/RecipeLensView.swift`.

## Sub-features

- Recipe beats article in classification
- Ingredient scaling (½× to 3×) and yield chip
- Cook Mode (large steps, screen stays awake)
- Add unchecked ingredients to Reminders (needs the real bundle: `./scripts/bundle.sh`)

## How to get to it (user POV)

Open a recipe page; the pill offers Focus; enter it. The lens opens on ingredients; toggle to the article lens to see the prose.

## Driving it with verify-surf

```bash
SURF_FOCUS=1 .claude/skills/verify-surf/scripts/launch.sh recipe "file://$PWD/testpages/recipe-demo.html" 'focus: ' 40
.claude/skills/verify-surf/scripts/window.sh recipe
.claude/skills/verify-surf/scripts/stop.sh recipe
```

## What proves it

- `focus: recipe …` classification line (not `focus: article`) for `recipe-demo.html` ("Mariner's Chowder").
- With Screen Recording permission, window title "Mariner's Chowder — Sea Journal Kitchen" in `windows.txt`.
- Scaling, Cook Mode, and Groceries are click-driven: hand the user the steps and ask for what they see; Reminders side effect is a list named "Groceries" containing the unchecked items.

## Gotchas

- Reminders access requires the bundled app, not the bare SwiftPM binary `launch.sh` uses. Verify Groceries with `Surf.app` built by `scripts/bundle.sh`, launched with the same env and `SURF_STATE_DIR`.
- Parser edge cases (`@graph`, entity-encoded text, nested sections) belong in `swift test --filter Recipe`, not here.
