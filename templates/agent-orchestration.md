# Documentation Agent Orchestration

> How to use the writer, reviewer, and editor agents together

---

## Overview

This documentation pipeline transforms code-heavy technical notes into narrative documentation following the style guide. It uses specialized agents in a quality-controlled loop with a fast path for passing documents.

### Standard Flow (for failing documents)
```
Writer → Reviewer → Editor (major revision) → Reviewer → ... → Final
```

### Fast Path (for passing documents)
```
Writer → Reviewer-Editor → Final
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                           ORCHESTRATION                               │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  WRITER AGENT                                                         │
│  Input: Raw notes + style guide + related docs                       │
│  Output: Narrative draft                                              │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  REVIEWER-EDITOR AGENT (Fast Path)                                   │
│  Input: Draft + style guide + original notes                         │
│  Output: PASS → polished final | FAIL → structured feedback          │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                         ┌───────┴───────┐
                         │  Score ≥ 3.5? │
                         └───────┬───────┘
                          No     │     Yes
                    ┌────────────┴────────────┐
                    ▼                         ▼
        ┌───────────────────┐     ┌───────────────────────┐
        │  EDITOR AGENT     │     │  DONE                 │
        │  (Major revision) │     │  (Document finalized  │
        └─────────┬─────────┘     │   by Reviewer-Editor) │
                  │               └───────────────────────┘
                  ▼
           Loop back to
           REVIEWER-EDITOR
```

---

## Prerequisites

Before starting, ensure you have:

1. **Style guide**: `STYLE_GUIDE.md` in repository root
2. **Agent prompts**: All agent templates in `templates/`
3. **Source material**: The raw technical notes to transform
4. **Related documents**: Other docs in the set for cross-reference context

---

## Context Digest (Include with Every Invocation)

To avoid re-reading full documents, include this digest with agent invocations:

```markdown
### Style Guide Essentials (Non-Negotiables)

1. First 3 paragraphs: ZERO code — problem and mental model first
2. Every code block must have a preceding explanatory paragraph
3. At least ONE strong analogy connecting unfamiliar to familiar
4. Problem statement ("why does this exist?") in first 5 paragraphs
5. No passive voice walls (3+ consecutive passive sentences)

### Pass/Fail Threshold

- **PASS**: Score ≥ 3.5 AND no category at 1
- **FAIL**: Score < 3.5 OR any category at 1

### Related Documents Context

[For each related doc, one line summary:]
- rendering-pipeline.md: Scene traversal, 5-phase render loop, RenderObject pattern
- webgpu-backend.md: Command encoding, beginRender/finishRender, draw calls
- pipeline-bindings.md: Pipeline caching, bind group management, cache keys
- node-system.md: TSL shader graphs, WGSL compilation
```

Customize the "Related Documents" section for each documentation set.

---

## Batch Processing

When transforming multiple documents, parallelize where possible:

### Phase 1: Parallel Writing

Invoke Writer Agent for up to 3 documents simultaneously:

```
┌─────────┐ ┌─────────┐ ┌─────────┐
│ Writer  │ │ Writer  │ │ Writer  │
│ Doc A   │ │ Doc B   │ │ Doc C   │
└────┬────┘ └────┬────┘ └────┬────┘
     │           │           │
     ▼           ▼           ▼
  Draft A     Draft B     Draft C
```

### Phase 2: Parallel Review

Once all drafts complete, invoke Reviewer-Editor in parallel:

```
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ Rev-Editor A │ │ Rev-Editor B │ │ Rev-Editor C │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       ▼                ▼                ▼
    PASS/FAIL        PASS/FAIL        PASS/FAIL
```

### Phase 3: Group by Outcome

- **PASS documents**: Done — Reviewer-Editor already output final versions
- **FAIL documents**: Route to Editor Agent for major revision, then back to Reviewer-Editor

### Throughput Gains

| Approach | Agent Invocations (3 docs, all pass) |
|----------|--------------------------------------|
| Sequential standard | 9 (W→R→E × 3) |
| Sequential fast path | 6 (W→RE × 3) |
| Parallel fast path | 6, but ~3x faster wall time |

---

## Step-by-Step Process (Single Document)

### Step 1: Gather Context

Collect the inputs for the writer agent:

```markdown
## Document to Rewrite
[Path to raw technical notes, e.g., notes/per-library/threejs/rendering-pipeline.md]

## Related Documents
[List paths to other documents in this set]
- notes/per-library/threejs/README.md
- notes/per-library/threejs/webgpu-backend.md
- notes/per-library/threejs/pipeline-bindings.md
- notes/per-library/threejs/node-system.md

## Style Guide
STYLE_GUIDE.md

## Framework Source (if exploring is needed)
libraries/threejs/src/renderers/
```

### Step 2: Invoke Writer Agent

Use the writer agent prompt from `templates/agent-writer.md`.

Provide:
- The raw notes content
- Related document context (at minimum, list their topics)
- Style guide reference

**Expected output**: A narrative draft following the chapter structure.

### Step 3: Invoke Reviewer-Editor Agent (Fast Path)

Use the combined agent from `templates/agent-reviewer-editor.md`.

Provide:
- The writer's draft
- Style guide (or context digest)
- Original notes for accuracy checking

**Expected output**:
- If PASS: Polished final document (done!)
- If FAIL: Structured review with scores and feedback

### Step 4: If FAIL — Major Revision

Invoke editor agent for substantial revision:
- Address all major issues from the review
- May require significant restructuring
- Output goes back to Reviewer-Editor (Step 3)

### Step 5: Iteration Limit

To prevent infinite loops:

- **Maximum iterations**: 3
- If still failing after 3 rounds, flag for human review
- Document what's blocking and why

---

## Invocation Templates

### Writer Invocation

```
I need you to act as the Writer Agent. Please read the agent prompt at:
templates/agent-writer.md

Then transform this document:

## Document to Rewrite
[paste content or path]

## Related Documents
[list related docs with brief descriptions]

## Style Guide
Reference: STYLE_GUIDE.md

Please produce a narrative draft following the style guide principles.
```

### Reviewer-Editor Invocation (Fast Path)

```
I need you to act as the Reviewer-Editor Agent. Please read the agent prompt at:
templates/agent-reviewer-editor.md

Then review and (if passing) finalize this draft:

## Document to Review
[paste the writer's draft]

## Context Digest
[paste the context digest from above]

## Original Notes
[paste or reference original notes for accuracy checking]

If the document scores ≥ 3.5 with no category at 1, apply minor fixes and output
the final document. Otherwise, output structured feedback for major revision.
```

### Editor Invocation

```
I need you to act as the Editor Agent. Please read the agent prompt at:
templates/agent-editor.md

Then edit this draft:

## Draft Document
[paste the current draft]

## Reviewer Feedback
[paste the reviewer's feedback]

## Style Guide
Reference: STYLE_GUIDE.md

## Original Notes
[paste or reference original notes]

Please produce a polished final document addressing the feedback.
```

---

## Tracking Progress

For each document transformation, track:

```markdown
## Document: [name]

### Iteration 1
- Writer: Complete
- Reviewer: Score 2.8/5 - FAIL
  - Major: Missing problem framing, code-first in section 3
- Editor: Revised

### Iteration 2
- Reviewer: Score 3.7/5 - PASS
  - Minor: Some passive voice, weak transitions
- Editor: Polished
- Status: COMPLETE
```

---

## Tips for Success

### For the Writer

- Read the style guide examples carefully
- Start with the problem, always
- When in doubt, add an analogy
- Introduce every code block

### For the Reviewer

- Be specific with line references
- Prioritize — not all issues are equal
- Acknowledge what's working

### For the Editor

- Minimal changes principle
- Don't rewrite what works
- Verify technical accuracy after changes

### For Orchestration

- Don't skip the reviewer — even good drafts benefit
- Document iterations for learning
- If stuck, the issue might be the source material, not the agents

---

## Example Session

```
User: Let's transform notes/per-library/threejs/rendering-pipeline.md

[Invoke Writer Agent with the document and context]

Writer Output: [Narrative draft...]

[Invoke Reviewer Agent with the draft]

Reviewer Output:
| Category | Score |
|----------|-------|
| Problem-First | 4/5 |
| Mental Models | 3/5 |
| Code Placement | 2/5 |
| ... | ... |
Average: 3.2/5 - FAIL

Major Issues:
1. Section 3 leads with code block before explanation
2. Missing analogy for RenderObject pattern

[Invoke Editor Agent with draft + feedback]

Editor Output: [Revised draft...]

[Invoke Reviewer Agent again]

Reviewer Output:
Average: 3.8/5 - PASS

Minor Issues:
1. Some passive voice in Section 4

[Invoke Editor Agent for final polish]

Editor Output: [Final document]

Done! Document ready for publication.
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `STYLE_GUIDE.md` | Quality standards and examples |
| `.claude/settings.json` | Pre-approved tool permissions (reduces prompts) |
| `templates/agent-writer.md` | Writer agent prompt |
| `templates/agent-reviewer.md` | Reviewer agent prompt (standalone) |
| `templates/agent-reviewer-editor.md` | Combined review + polish (fast path) |
| `templates/agent-editor.md` | Editor agent prompt (major revisions) |
| `templates/agent-orchestration.md` | This file — how to use them together |
