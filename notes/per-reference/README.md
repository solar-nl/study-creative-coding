# Reference Documentation Studies

> Analysis of documentation, manuals, and guides that inform our framework design

---

## What is a "Reference"?

Unlike code studies which analyze source implementations, **reference studies** examine documentation, specifications, and guides to extract:

- **Concepts** — Mental models and terminology that shape how users think about a system
- **Design rationale** — Why decisions were made, not just what they are
- **API documentation patterns** — How to explain complex systems to developers
- **Cross-pollination** — Ideas from one paradigm applicable to others

---

## References

| Reference | Status | Description |
|-----------|--------|-------------|
| [The-Gray-Book](./the-gray-book/) | Partial | Reference manual for vvvv gamma and VL visual programming |

---

## Documentation Structure

Each reference study follows this structure:

```
notes/per-reference/<name>/
├── README.md        # Overview and study rationale
├── concepts.md      # Core concepts and mental models extracted
├── patterns.md      # Design patterns documented (not implemented)
├── api-insights.md  # API design decisions explained in the docs
└── extracts/        # Key quoted sections with analysis
```

---

## Study Approach

Reference studies prioritize different questions than code studies:

| Code Study Question | Reference Study Question |
|---------------------|-------------------------|
| How is this implemented? | How is this explained? |
| What patterns does the code use? | What patterns does the documentation teach? |
| What are the entry points? | What are the core concepts? |
| How does data flow? | How does understanding build? |

---

## Related Categories

- **Frameworks** — Full creative coding environments (code-based)
- **Libraries** — Specialized components (code-based)
- **Visual Programming** — Node-based environments (code + UI)
- **Examples** — Reference implementations and samples
