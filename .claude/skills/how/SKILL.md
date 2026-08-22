---
name: how
description: "Use for 'how does X work', code walkthroughs before changing something, and placement or ownership questions ('where should this live', 'is this the right layer'). Explains subsystem architecture and runtime flow; can critique architecture."
---

# How

Adapted from cursor/plugins pstack.

Explore the codebase to answer "how does X work?" at the level of a senior engineer onboarding onto a subsystem. Enough to build a working mental model, not annotated source.

Two modes:

1. **Explain** (default). Explore and produce a clear explanation.
2. **Critique.** Explain first, then run independent critics with distinct lenses.

For history and motivation, use `git log`, `git blame`, and PR descriptions rather than guessing.

## Explain mode

### Step 1. Understand the question and assess complexity

Identify the scope: a subsystem, a feature flow, an architectural overview, or a runtime trace. If ambiguous, state your best-guess interpretation and go. Don't ask.

- **Simple** (one module, a narrow question): explore and explain yourself in one pass. Go to Step 2b.
- **Complex** (spans multiple files or targets, cross-cutting, full overview): spawn parallel explorers first. Go to Step 2a.

When in doubt, lean simple.

### Step 2a. Explore (complex only)

Decompose into 2-4 angles that don't overlap. Example for "how does the page agent work?": the Swift side and method enum; the JS runtime and content worlds; injection and teardown timing.

Spawn all explorers in one message with the Agent tool, `subagent_type: Explore`, each given the base prompt from `references/explorer-prompt.md` plus its angle. Each returns structured findings. Overlap is fine; you reconcile.

### Step 2b. Direct explain (simple only)

Explore with Grep, Glob, and Read, then write the explanation using the format in `references/explainer-prompt.md`.

### Step 3. Synthesize (complex only)

Write the explanation yourself from the explorers' findings, or hand them to one `general-purpose` subagent with `references/explainer-prompt.md`. Reconcile overlaps, resolve contradictions by reading the code, and weave the slices together.

### Step 4. Present

Present the explanation. Light edits for clarity are fine.

### Output format

Adapt to the question; not every section is needed.

**Overview.** 1-2 paragraphs. What it is, what it does, why it exists.

**Key concepts.** The types, services, or abstractions needed to follow the rest.

**How it works.** The core. What triggers it, what happens step by step, where data goes, the decision points. Prose, with file and function references. No code dumps unless a snippet is essential.

**Where things live.** The files someone needs to start working here.

**Gotchas.** Non-obvious behavior, historical context, sharp edges.

## Critique mode

Triggered when the user asks for architectural issues, problems, or improvements.

### Step 1. Explain first

Run the full explain flow. Understand before critiquing.

### Step 2. Spawn critics

Spawn 2-3 `general-purpose` subagents in one message, each with a distinct lens so they don't converge: for example, one on abstraction fit and data model, one on boundary discipline and testability, one on evolution readiness and consistency. Build each prompt from `references/critic-prompt.md`, giving it the explanation, the file paths, and the rubric in `references/critique-rubric.md`.

### Step 3. Lead judgment

You're a pragmatic lead, not an aggregator. Categorize findings:

- **Act on.** Worth fixing now.
- **Consider.** Real, but cost/benefit unclear.
- **Noted.** Valid, low priority.
- **Dismissed.** Wrong, missing context, or style preference.

Present the explanation first, then the verdict below it. The explanation should stand on its own.
