# Graph (Legacy) Technical Documentation

> **The original node-graph editor**
>
> *Understanding how Tooll3's legacy graph system handles operator browsing and instantiation*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## About This Documentation

The legacy Graph system provides the original node-graph editing experience in Tooll3. While MagGraph represents the newer "magnetic" approach, the legacy system remains important for understanding the SymbolBrowser—the context-sensitive operator picker that appears when you press Tab.

**Focus:** This documentation set covers the **node library interface**—how users discover, search, and instantiate operators within the graph editor.

---

## Documentation Structure

### Node Library Interface

| Chapter | Title | Description |
|---------|-------|-------------|
| [01](01-symbol-browser.md) | The Symbol Browser Popup | Context-sensitive operator picker, type filtering, keyboard navigation |
| [02](02-search-relevance.md) | Search & Relevance Scoring | Fuzzy matching algorithm, relevancy factors, result ranking |

---

## Quick Reference

### Source Location

```
Editor/Gui/Graph/Legacy/Interaction/
├── SymbolBrowser.cs        (~660 LOC)  Context popup UI
└── ...

Editor/UiModel/Helpers/
├── SymbolFilter.cs         (~390 LOC)  Search algorithm
└── ...
```

### Key Classes at a Glance

| Class | Purpose | LOC |
|-------|---------|-----|
| `SymbolBrowser` | Context popup triggered by Tab, renders results list | ~660 |
| `SymbolFilter` | Regex fuzzy search with relevancy scoring | ~390 |

---

## The Mental Model: Command Palette for Nodes

Think of the SymbolBrowser as a **command palette** (like VS Code's Ctrl+P) specifically designed for visual programming:

1. **Context-Aware** — When completing a connection, it filters to type-compatible operators
2. **Relevancy-Ranked** — Frequently used operators and project-local symbols appear first
3. **Fuzzy Search** — "ds" finds "DrawState", not just exact matches
4. **Preset Support** — "DrawState blur" searches within that operator's presets

The SymbolFilter provides the intelligence behind the scenes—combining 10+ ranking signals into a single relevancy score.

---

## Related Systems

- **[Symbol Library Window](../windows/01-symbol-library.md)** — The docked tree browser (complementary discovery UI)
- **[Symbol Instance Commands](../commands/01-symbol-commands.md)** — How node creation integrates with undo/redo
- **[MagGraph Browser](../maggraph/11-interaction-browser.md)** — The MagGraph equivalent of this system

---

## Where to Start?

**Understanding the user-facing behavior:**
Start with [Chapter 1: Symbol Browser Popup](01-symbol-browser.md) to see how the Tab-key popup works.

**Understanding the search algorithm:**
Jump to [Chapter 2: Search & Relevance](02-search-relevance.md) to understand the ranking math.

---

## Version

This documentation describes the legacy Graph system as of **January 2026**.

Last updated: 2026-01-08
