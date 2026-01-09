# OpSelect Subsystem

> *The operator browser and search system*

---

## Overview

The OpSelect subsystem handles how users find and add operators to their patches. It consists of two main components:

1. **OpSelect** - The modal dialog that appears when searching for operators
2. **OpSearch** - The search engine that filters and ranks results

---

## Chapters

| # | Chapter | Description |
|---|---------|-------------|
| 01 | [The Operator Browser Dialog](01-operator-browser.md) | Modal UI, keyboard navigation, context awareness |
| 02 | [Search & Scoring Algorithm](02-search-scoring.md) | Word matching, ranking factors, data sources |

---

## Key Concepts

### The Search Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  User types │────▶│  OpSearch   │────▶│   Ranked    │
│  query      │     │   scores    │     │   results   │
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                    ┌──────┴──────┐
                    │ Data Sources│
                    ├─────────────┤
                    │ Code ops    │
                    │ Op docs     │
                    │ Extensions  │
                    │ Team ops    │
                    │ Patch ops   │
                    └─────────────┘
```

### Context Awareness

When invoked from a port drag, OpSelect filters results by type compatibility:
- Only show operators with matching input/output port types
- Score operators higher if their first port matches
- Suggest converters when types don't match directly

---

## Source Files

| File | LOC | Purpose |
|------|-----|---------|
| `dialogs/opselect.js` | ~860 | Modal dialog, keyboard handling, UI rendering |
| `components/opsearch.js` | ~600 | Search engine, scoring, data aggregation |
| `components/opselect_treelist.js` | ~200 | Namespace tree view |
| `defaultops.js` | ~200 | Math operator shortcuts, default operators |

---

## Mental Model

Think of OpSelect as a **command palette** (like VS Code's Ctrl+P):
- Invoke it anywhere with a keyboard shortcut
- Type to filter results instantly
- Context shapes what appears (e.g., dragging a port restricts types)
- Results are ranked by relevance, not just alphabetically

The key insight is that OpSearch doesn't just filter - it **scores and ranks**. A shorter name, higher popularity, or matching port type all boost the score. This is why typing "ds" shows "DrawState" before "DataSource".

---

## Related Subsystems

- **GlPatch** - Where operators are rendered after creation
- **Connections** - How new operators get wired to existing ports
- **Commands** - How operator creation integrates with undo/redo
