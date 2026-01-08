# Window System Technical Documentation

> **UI panels and windows in the Tooll3 Editor**
>
> *Understanding how docked windows organize and present information*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## About This Documentation

The Window System encompasses all dockable panels in the Tooll3 Editor—from the Symbol Library for browsing operators, to the Parameters window for editing values, to the Timeline for animation.

**Focus:** This documentation set covers the **Symbol Library**—the docked window where users browse, search, and organize the operator hierarchy.

---

## Documentation Structure

### Symbol Library Interface

| Chapter | Title | Description |
|---------|-------|-------------|
| [01](01-symbol-library.md) | The Symbol Library Window | Tree browser UI, search, drag-and-drop namespace reorganization |
| [02](02-namespace-tree.md) | Namespace Tree & Filtering | NamespaceTreeNode structure, predicate filtering, quality filters |

---

## Quick Reference

### Source Location

```
Editor/Gui/Windows/SymbolLib/
├── SymbolLibrary.cs          (~580 LOC)  Main window class
├── NamespaceTreeNode.cs      (~130 LOC)  Recursive tree structure
├── LibraryFiltering.cs       (~150 LOC)  Quality filter UI
└── RandomPromptGenerator.cs   (~80 LOC)  "?" search feature
```

### Key Classes at a Glance

| Class | Purpose | LOC |
|-------|---------|-----|
| `SymbolLibrary` | Docked window with tree view and search | ~580 |
| `NamespaceTreeNode` | Recursive namespace hierarchy builder | ~130 |
| `LibraryFiltering` | Quality/status filter checkboxes | ~150 |

---

## The Mental Model: File Explorer for Operators

Think of the Symbol Library as a **file explorer** for your operator collection:

1. **Hierarchical Tree** — Namespaces nest like folders (`Lib.3d.mesh.Generate`)
2. **Search Bar** — Filter the tree to find specific operators
3. **Drag-and-Drop** — Reorganize by dragging symbols to different namespaces
4. **Quality Filters** — Show only operators missing documentation, unused, etc.

Unlike the SymbolBrowser popup (context-aware, type-filtered), the Symbol Library is a **persistent discovery interface**—always visible, always browsable.

---

## Related Systems

- **[Symbol Browser Popup](../graph/01-symbol-browser.md)** — The context-sensitive popup (Tab key)
- **[Search & Relevance](../graph/02-search-relevance.md)** — The SymbolFilter algorithm shared by both UIs
- **[Symbol Instance Commands](../commands/01-symbol-commands.md)** — What happens when you click an operator

---

## Where to Start?

**Understanding the window UI:**
Start with [Chapter 1: Symbol Library Window](01-symbol-library.md) to see how the tree renders and responds to interaction.

**Understanding the data structure:**
Jump to [Chapter 2: Namespace Tree & Filtering](02-namespace-tree.md) to understand how flat namespaces become hierarchical trees.

---

## Version

This documentation describes the Window System as of **January 2026**.

Last updated: 2026-01-08
