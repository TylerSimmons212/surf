# Narration (read aloud)

Inside Focus, Listen reads the article with lyric mode: the current sentence washed, the current word lit, the passage kept in view. System voice by default; Kokoro (neural, downloaded on request) from Settings › Reader. `Sources/Surf/Narrator.swift`, `KokoroEngine.swift`, `SurfCore/NarrationModel.swift`.

## Sub-features

- Sentence-level script from a real tokenizer
- Word highlight (system voice) or sentence highlight (Kokoro)
- Pausing page media when narration starts; survives tab switches
- Seeking by tapping a paragraph

## How to get to it (user POV)

Enter Focus, press Listen in the reader chrome.

## Driving it with verify-surf

```bash
SURF_FOCUS=2 SURF_SILENT=1 .claude/skills/verify-surf/scripts/launch.sh narrate "file://$PWD/testpages/focus-demo.html" 'narrate: reading' 60
sleep 5
.claude/skills/verify-surf/scripts/stop.sh narrate
```

`SURF_FOCUS=2` enters Focus, waits for the `.active` phase, then toggles the narrator on the extracted article; `SURF_SILENT=1` mutes output so the pipeline runs without sound.

## What proves it

- `narrate: reading N utterances` — the script was built and playback started.
- One or more `narrate: highlighting block <id> from word <range>` lines — callbacks are flowing and highlights advance. None after 5 s means the engine started but never reported progress.
- `voice: model loaded in Nms` is the voice engine warming up; present only when Kokoro is installed in the state directory.

## Gotchas

- A scratch state directory has no Kokoro model, so narration uses the system voice; `voice: model loaded` will be absent. To force the system voice or Kokoro, set it in Settings › Reader by hand.
- Word-level highlights come only from the system synthesiser; Kokoro reports sentences. Don't read a sentence-only log as a bug when Kokoro is active.
