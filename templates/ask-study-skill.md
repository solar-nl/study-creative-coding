---
name: ask-study
description: Ask the creative-coding study repo for design advice - how existing frameworks (openrndr, nannou, p5.js, Processing, openFrameworks, Cinder, tixl, cables, three.js, wgpu, apEx, ...) solve a problem, with citations and a recommendation. Use when making an architecture or API decision that prior art could inform, e.g. rendering pipeline, node graphs, color, typography, instancing, asset loading, or event systems.
argument-hint: "\"question\" | --resume <session_id> \"follow-up\""
---

# Ask the Study Repo

The study repository at `STUDY_REPO_PATH` contains deep-dive notes, cross-framework comparisons, and design insights for a Rust creative coding framework, plus the source of every framework studied. Its `consult` agent answers questions from that material.

## How to ask

```bash
"STUDY_REPO_PATH/scripts/consult.sh" "<question>"
# follow-up in the same consult session:
"STUDY_REPO_PATH/scripts/consult.sh" --resume <session_id> "<follow-up>"
```

The answer ends with `consult-session: <id>`. Keep the id if you might ask a follow-up. A consult takes about 15–90 seconds; run it in the background if you have other work.

## Writing good questions

The consult agent cannot see this project. Include the context it needs:
- what you are building and the constraint that matters (e.g. "wgpu, must run on web, 100k instances"),
- what you are deciding between, if you have candidates,
- what form of answer you want (comparison, recommendation, specific code pointer).

Bad: "how do I do instancing?"
Good: "We need per-instance attributes for a particle renderer on wgpu (web + desktop). How do tixl, three.js and apEx pass per-instance data to shaders, and which approach fits a Rust API with typed buffers?"

## Using the answer

Treat it as informed prior art, not a spec. Answers cite paths inside the study repo; read them directly if you need detail. If the answer reports a gap in the study, mention it to the user, since it may be worth a new study note.
