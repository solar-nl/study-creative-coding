# Documentation Agent Orchestration

> How to use the writer, reviewer, and editor agents together

---

## Overview

This documentation pipeline transforms code-heavy technical notes into narrative documentation following the style guide. It uses three specialized agents in a quality-controlled loop.

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
│  REVIEWER AGENT                                                       │
│  Input: Draft + style guide + original notes                         │
│  Output: Scores + structured feedback                                 │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                         ┌───────┴───────┐
                         │  Score ≥ 3.5? │
                         └───────┬───────┘
                          No     │     Yes
                    ┌────────────┴────────────┐
                    ▼                         ▼
        ┌───────────────────┐     ┌───────────────────────┐
        │  EDITOR AGENT     │     │  EDITOR AGENT         │
        │  (Major revision) │     │  (Polish only)        │
        └─────────┬─────────┘     └───────────┬───────────┘
                  │                           │
                  ▼                           ▼
           Loop back to              ┌─────────────────┐
           REVIEWER                  │  FINAL DOCUMENT │
                                     └─────────────────┘
```

---

## Prerequisites

Before starting, ensure you have:

1. **Style guide**: `STYLE_GUIDE.md` in repository root
2. **Agent prompts**: All three agent templates in `templates/`
3. **Source material**: The raw technical notes to transform
4. **Related documents**: Other docs in the set for cross-reference context

---

## Step-by-Step Process

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

### Step 3: Invoke Reviewer Agent

Use the reviewer agent prompt from `templates/agent-reviewer.md`.

Provide:
- The writer's draft
- Style guide for checklist reference
- Original notes for accuracy checking

**Expected output**: Structured review with scores and feedback.

### Step 4: Check Threshold

Evaluate the review:

| Condition | Action |
|-----------|--------|
| Average ≥ 3.5 AND no category at 1 | **PASS** — proceed to final edit |
| Average < 3.5 OR any category at 1 | **FAIL** — major revision needed |

### Step 5a: If PASS — Final Edit

Invoke editor agent for polish:
- Address minor issues
- Light touch, preserve voice
- Output is final document

### Step 5b: If FAIL — Major Revision

Invoke editor agent for substantial revision:
- Address all major issues
- May require significant restructuring
- Output goes back to reviewer (Step 3)

### Step 6: Iteration Limit

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

### Reviewer Invocation

```
I need you to act as the Reviewer Agent. Please read the agent prompt at:
templates/agent-reviewer.md

Then review this draft:

## Document to Review
[paste the writer's draft]

## Style Guide
Reference: STYLE_GUIDE.md

## Original Notes
[paste or reference original notes for accuracy checking]

Please provide a structured review with scores and specific feedback.
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
| `templates/agent-writer.md` | Writer agent prompt |
| `templates/agent-reviewer.md` | Reviewer agent prompt |
| `templates/agent-editor.md` | Editor agent prompt |
| `templates/agent-orchestration.md` | This file — how to use them together |
