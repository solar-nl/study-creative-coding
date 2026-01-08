# MagGraph Technical Documentation

> **The art of making complex connections feel effortless**
>
> *Understanding how Tooll3's node editor handles hundreds of operators without breaking a sweat*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## The Challenge: Building a Node Editor That Scales

Picture this: you're building a visual effects composition with 500 operators. Each operator has multiple inputs and outputs. Connections snake between them. You're constantly dragging nodes, rewiring connections, zooming in and out.

The naive approach to building such an editor would be straightforward: loop through all operators every frame, draw them, loop through all connections, draw those. But with 500 operators and 600+ connections, that approach crawls. Every frame recalculates everything. Moving one node requires the entire graph to update.

MagGraph is Tooll3's answer to this challenge. It's not just a "node editor" - it's a carefully architected system that makes graph manipulation feel instant, even at scale. The key insight: **separate what you see from what's stored, and only update what's changed**.

This documentation teaches you how MagGraph thinks - not just what classes exist, but *why* they exist and how they work together to create that seamless editing experience.

**Who should read this:** Developers extending Tooll3, contributors to the MagGraph codebase, or anyone building a high-performance node-graph editor who wants to learn from a production implementation.

---

## Documentation Structure

### Part I: Architecture & Concepts

| Document | Description |
|----------|-------------|
| [01-architecture-overview.md](01-architecture-overview.md) | System architecture, design philosophy, and component relationships |
| [02-core-concepts.md](02-core-concepts.md) | Key abstractions: Items, Connections, Layout, Context |

### Part II: Model Layer

| Document | Description |
|----------|-------------|
| [03-model-items.md](03-model-items.md) | `MagGraphItem` - Nodes, inputs, outputs, placeholders |
| [04-model-connections.md](04-model-connections.md) | `MagGraphConnection` - Connection types, snapping, routing |
| [05-model-layout.md](05-model-layout.md) | `MagGraphLayout` - Cached view model, structure updates |
| [06-model-annotations.md](06-model-annotations.md) | `MagGraphAnnotation` - Comment frames, collapsing |

### Part III: State Machine & Context

| Document | Description |
|----------|-------------|
| [07-state-machine.md](07-state-machine.md) | `GraphStates` - All interaction states explained |
| [08-context.md](08-context.md) | `GraphUiContext` - Central context, undo/redo, dialogs |

### Part IV: Interaction Layer

| Document | Description |
|----------|-------------|
| [09-interaction-movement.md](09-interaction-movement.md) | `MagItemMovement` - Dragging, snapping, insertion |
| [10-interaction-connections.md](10-interaction-connections.md) | Connection creation, reconnection, picking |
| [11-interaction-browser.md](11-interaction-browser.md) | Operator browser, symbol filtering, relevancy |
| [12-interaction-annotations.md](12-interaction-annotations.md) | Annotation dragging, resizing, renaming |
| [13-interaction-keyboard.md](13-interaction-keyboard.md) | Keyboard shortcuts and actions |

### Part V: Rendering Layer

| Document | Description |
|----------|-------------|
| [14-rendering-canvas.md](14-rendering-canvas.md) | `MagGraphView` - Canvas, pan/zoom, culling |
| [15-rendering-nodes.md](15-rendering-nodes.md) | Node rendering, type colors, idle fading |
| [16-rendering-connections.md](16-rendering-connections.md) | Connection curves, styles, damping |
| [17-rendering-annotations.md](17-rendering-annotations.md) | Annotation frames, collapse indicators |

### Part VI: Advanced Topics

| Document | Description |
|----------|-------------|
| [18-performance.md](18-performance.md) | Optimization strategies, caching, allocations |
| [19-undo-redo.md](19-undo-redo.md) | MacroCommand pattern, command grouping |
| [20-extending-maggraph.md](20-extending-maggraph.md) | Adding new states, operators, UI elements |

### Appendices

| Document | Description |
|----------|-------------|
| [A-file-reference.md](A-file-reference.md) | Complete file listing with line counts |
| [B-imgui-patterns.md](B-imgui-patterns.md) | ImGui patterns used throughout MagGraph |
| [C-legacy-comparison.md](C-legacy-comparison.md) | MagGraph vs Legacy Graph differences |

---

## Quick Reference

### Source Location

```
Editor/Gui/MagGraph/
├── Model/           # Data structures (4 files)
│   ├── MagGraphItem.cs
│   ├── MagGraphConnection.cs
│   ├── MagGraphLayout.cs
│   └── MagGraphAnnotation.cs
├── States/          # State machine (2 files)
│   ├── GraphStates.cs
│   └── GraphUiContext.cs
├── Interaction/     # User interaction (18 files)
│   ├── MagItemMovement.cs
│   ├── PlaceHolderUi.cs
│   ├── SymbolBrowsing.cs
│   └── ...
└── Ui/              # Rendering (5 files)
    ├── MagGraphView.cs
    ├── MagGraphCanvas.Drawing.cs
    ├── MagGraphCanvas.DrawNode.cs
    ├── MagGraphCanvas.DrawConnection.cs
    └── MagGraphCanvas.DrawAnnotation.cs
```

### Key Classes at a Glance

| Class | Purpose | LOC |
|-------|---------|-----|
| `MagGraphLayout` | Cached view model, structure computation | ~930 |
| `GraphStates` | State machine with 15+ states | ~730 |
| `MagItemMovement` | Drag, snap, insert operations | ~600 |
| `PlaceholderCreation` | Operator browser trigger logic | ~630 |
| `PlaceHolderUi` | Operator browser UI | ~500 |
| `MagGraphItem` | Node/item data structure | ~370 |
| `GraphUiContext` | Central interaction context | ~260 |

### The Mental Model: Four Layers Working Together

Think of MagGraph as four collaborating systems, each with a clear responsibility:

1. **Model Layer** - "What exists in the graph?" Items, connections, annotations - the raw data
2. **State Machine** - "What mode am I in?" Dragging? Connecting? Browsing? The current interaction context
3. **Interaction Layer** - "What should happen?" The logic for snapping, inserting, selecting
4. **Rendering Layer** - "What do I see?" Drawing nodes, curves, highlights on screen

This separation means you can understand each piece independently. The renderer doesn't know about snapping logic. The model doesn't know how it's drawn. Changes stay contained.

### Design Principles

1. **Separation of Concerns** - Each layer has one job and does it well
2. **Lazy Computation** - Why recalculate everything when only one thing changed?
3. **Explicit State Machine** - No hidden flags; the current state tells you exactly what's happening
4. **Grouped Undo/Redo** - Dragging a node across snapping points is one undo, not fifty
5. **Performance First** - Smooth animations, instant response, minimal memory churn

---

## Where to Start?

**First time exploring MagGraph?** Follow this path to build understanding progressively:

1. **[Architecture Overview](01-architecture-overview.md)** - See the big picture and how the pieces fit together
2. **[Core Concepts](02-core-concepts.md)** - Learn the fundamental abstractions that everything builds on
3. **[State Machine](07-state-machine.md)** - Understand how user interactions flow through the system
4. **[Model Items](03-model-items.md)** - Dive into what nodes actually *are* under the hood

**Have a specific goal?** Jump directly to what you need:

| I want to... | Start here |
|--------------|------------|
| Add a new user interaction | [State Machine](07-state-machine.md) → [Extending MagGraph](20-extending-maggraph.md) |
| Understand how connections route | [Model Connections](04-model-connections.md) → [Rendering Connections](16-rendering-connections.md) |
| Debug performance issues | [Performance](18-performance.md) |
| Modify the operator browser | [Interaction Browser](11-interaction-browser.md) |
| Add undo/redo to my feature | [Undo Redo](19-undo-redo.md) |

---

## Version

This documentation describes MagGraph as of **January 2026**.

Last updated: 2026-01-01
