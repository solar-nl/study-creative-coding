# Chapter 1: Architecture Overview

> *Why building a node editor the "obvious" way leads to problems - and how MagGraph solves them*

---

## The Problem: Why Rewrite the Graph Editor?

Imagine you're maintaining a node editor that's grown organically over years. Every feature was added incrementally. The result? A single 3,000-line file where:

- Mouse click handling is scattered across dozens of `if (IsMouseClicked)` checks
- Nobody knows if you're in "dragging mode" or "connecting mode" without tracing through nested conditionals
- Adding a new interaction means touching 15 different places
- Performance degrades as graphs grow because everything is recalculated every frame

The legacy Tooll3 graph editor hit these walls. MagGraph is the answer - a ground-up redesign that makes the complexity manageable through deliberate architectural choices.

### What Makes MagGraph Different

The name "MagGraph" comes from "Magnetic Graph" - nodes snap together intelligently, magnetically aligning for clean layouts. But the real innovation is structural:

- **Explicit state machine** - You're either in "dragging" state or "connecting" state - never ambiguously both
- **Cached layout** - Structure is computed once, not every frame
- **Layered architecture** - Rendering code doesn't know about snapping logic, and vice versa
- **Grouped undo** - Dragging a node through multiple snap points is one undo, not fifty

The result: ~11,000 lines of C# across 29 focused files, each with a clear purpose.

---

## The Four-Layer Architecture

Think of MagGraph as a restaurant. The kitchen (Model) prepares the ingredients. The head chef (State Machine) decides what's being made right now. The line cooks (Interaction) handle the actual cooking. The waitstaff (Rendering) presents the finished dish. Each team has clear responsibilities; chaos ensues when they blur.

Here's how this maps to code:

```
┌─────────────────────────────────────────────────────────────┐
│                     RENDERING LAYER                         │
│  MagGraphView, MagGraphCanvas.Draw*                         │
│  "How things look on screen"                                │
├─────────────────────────────────────────────────────────────┤
│                    INTERACTION LAYER                         │
│  MagItemMovement, PlaceHolderUi, ConnectionHovering, etc.   │
│  "How users interact with the graph"                        │
├─────────────────────────────────────────────────────────────┤
│                   STATE MACHINE LAYER                        │
│  GraphStates, GraphUiContext                                │
│  "What mode the graph is in"                                │
├─────────────────────────────────────────────────────────────┤
│                      MODEL LAYER                             │
│  MagGraphItem, MagGraphConnection, MagGraphLayout           │
│  "What the graph contains"                                  │
└─────────────────────────────────────────────────────────────┘
```

Each layer has clear responsibilities and communicates through well-defined interfaces.

---

## Key Design Decisions (And Why)

### Why Cache the Layout?

Here's a question: if you have 200 nodes with 300 connections, how many dictionary lookups do you need per frame?

The naive approach: for each connection, look up the source node, look up the target node, find their positions, compute the curve. That's 600 lookups per frame, 60 times per second = 36,000 lookups per second. For a static graph that isn't changing.

MagGraph's answer: compute once, cache it. The `MagGraphLayout` class builds a complete view of the graph whenever structure changes. Moving a node just updates position values - no structural recomputation.

```csharp
// Layout only recomputes when something actually changed
if (forceUpdate || FrameStats.Last.UndoRedoTriggered || StructureFlaggedAsChanged ||
    HasCompositionDataChanged(compositionOp.Symbol, ref _compositionModelHash))
    RefreshDataStructure(context, parentSymbolUi);
```

**The rule:** Adding nodes, deleting connections → recompute. Dragging nodes around → just update positions.

### Why Use a State Machine?

You might wonder: why not just check `if (isDragging) { ... } else if (isConnecting) { ... }`?

Because that gets ugly fast. What if you start dragging, then press a modifier key to also start connecting? What if you're in a text field and shouldn't respond to keyboard shortcuts? What if...

The state machine makes the answer obvious: **you're in exactly one state at a time**. Each state knows what it responds to and how to exit.

```
User clicks operator → HoldItem state
User drags → DragItems state
User releases → Default state
```

This makes debugging trivial. Instead of "why isn't my click working?", you ask "what state am I in, and does that state handle clicks?"

### Why Group Undo Operations?

Picture this: you drag a node across the canvas. It snaps to one position, then another, then a third. Without grouping, that's three undo steps. Press Ctrl+Z three times to get back to where you started.

Worse: inserting a node between two connected nodes requires: (1) break the existing connection, (2) create connection to new node's input, (3) create connection from new node's output. Three commands. But the user did one action: "insert here."

The `MacroCommand` pattern groups related operations:

```csharp
context.StartMacroCommand("Insert operator");
// ... break connection, create input connection, create output connection ...
context.CompleteMacroCommand();  // All three become one undo step
```

One action = one undo. Always.

---

## Component Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            MagGraphView                                  │
│                    (ScalableCanvas, IGraphView)                          │
│                         Pan, Zoom, Culling                               │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          GraphUiContext                                  │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ StateMachine │  │    Layout    │  │ ItemMovement │  │  Placeholder │ │
│  │              │  │              │  │              │  │              │ │
│  │ GraphStates  │  │MagGraphLayout│  │MagItemMovement│ │PlaceholderCr.│ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘ │
│                                                                          │
│  ActiveItem, HoveredItem, TempConnections, MacroCommand, Dialogs...     │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │
                ┌─────────────────┼─────────────────┐
                ▼                 ▼                 ▼
        ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
        │ MagGraphItem │  │MagGraphConn. │  │MagGraphAnnot.│
        │              │  │              │  │              │
        │ Operators    │  │ Connections  │  │ Comments     │
        │ Inputs       │  │ Styles       │  │ Frames       │
        │ Outputs      │  │ Positions    │  │ Collapse     │
        └──────────────┘  └──────────────┘  └──────────────┘
```

### Data Flow

The typical frame update follows this flow:

```
1. ImGui Event Loop
        │
        ▼
2. MagGraphView.DrawGraph()
        │
        ├──► Update Layout (if needed)
        │         │
        │         └──► MagGraphLayout.ComputeLayout()
        │
        ├──► Update State Machine
        │         │
        │         └──► GraphStates.[CurrentState].Update()
        │
        ├──► Draw Annotations (background)
        │
        ├──► Draw Connections
        │
        ├──► Draw Nodes
        │
        └──► Handle Placeholder/Browser UI
```

---

## Understanding Each Layer

### Model Layer: "What's in the graph?"

Think of the Model as the blueprint. It doesn't know how to draw anything or respond to clicks - it just describes what exists.

A `MagGraphItem` says: "There's an Add operator at position (100, 200) with two float inputs and one float output." A `MagGraphConnection` says: "Output 0 of item A connects to input 1 of item B, and they're snapped together horizontally."

**The key files:**

- [MagGraphItem.cs](03-model-items.md) - What a node *is*: position, size, inputs, outputs
- [MagGraphConnection.cs](04-model-connections.md) - What a wire *is*: endpoints, style, type
- [MagGraphLayout.cs](05-model-layout.md) - The cached "view" of all items and connections
- [MagGraphAnnotation.cs](06-model-annotations.md) - Comment frames that group operators

### State Machine Layer: "What mode are we in?"

At any moment, MagGraph is in exactly one state. Are we idle (Default)? Holding an item, waiting to see if it's a click or drag (HoldItem)? Actively dragging (DragItems)? Typing in the operator browser (Placeholder)?

The state machine answers: "What happens when the user does X?" The answer depends entirely on current state.

**The key files:**

- [GraphStates.cs](07-state-machine.md) - All 15+ states: Default, DragItems, Placeholder, RenameChild, etc.
- [GraphUiContext.cs](08-context.md) - Shared data that states access: current item, hover targets, etc.

### Interaction Layer: "What should happen?"

This is where the logic lives. When you drag a node, *something* decides where it should snap. When you type in the browser, *something* filters the operator list. When you hover a connection, *something* highlights it.

That "something" is the Interaction layer. It doesn't draw pixels or store data - it computes what should change.

**The key files:**

- [MagItemMovement.cs](09-interaction-movement.md) - Dragging, snapping, inserting
- [PlaceHolderUi.cs](11-interaction-browser.md) - Operator browser UI and filtering
- [ConnectionHovering.cs](10-interaction-connections.md) - Detecting wire hover
- `InputPicking.cs` / `OutputPicking.cs` - Selecting hidden slots

### Rendering Layer: "What do I see?"

Finally, pixels. The Rendering layer transforms abstract positions into screen coordinates, draws rectangles and curves, applies colors based on types, and handles visual polish like smooth animation.

It knows nothing about *why* a node is at a certain position - just that it needs to draw it there.

**The key files:**

- [MagGraphView.cs](14-rendering-canvas.md) - Canvas pan/zoom, coordinate transforms
- `MagGraphCanvas.Draw*.cs` - The actual drawing: [nodes](15-rendering-nodes.md), [connections](16-rendering-connections.md), [annotations](17-rendering-annotations.md)

---

## What Changed from the Legacy System?

If you're familiar with the old graph editor, here's what's different:

| Aspect | Legacy Graph | MagGraph |
|--------|-------------|----------|
| **Layout** | Computed every frame | Cached, updated on change |
| **Input visibility** | Runtime computation | Precomputed in layout |
| **State management** | Scattered flags | Explicit state machine |
| **Code organization** | Single large file | 29 focused files |
| **Undo/redo** | Per-command | MacroCommand grouping |
| **Connection routing** | Per-frame calculation | Cached style + positions |
| **Performance** | Acceptable | Optimized |

The biggest wins: predictable state, better performance at scale, and code you can actually navigate.

---

## Directory Structure

```
Editor/Gui/MagGraph/
│
├── Model/                          # Data structures
│   ├── MagGraphItem.cs            # ~370 lines
│   ├── MagGraphConnection.cs      # ~100 lines
│   ├── MagGraphLayout.cs          # ~930 lines
│   └── MagGraphAnnotation.cs      # ~50 lines
│
├── States/                         # State machine
│   ├── GraphStates.cs             # ~730 lines
│   └── GraphUiContext.cs          # ~260 lines
│
├── Interaction/                    # User interaction
│   ├── MagItemMovement.cs         # ~400 lines
│   ├── MagItemMovement.Snapping.cs# ~200 lines
│   ├── PlaceHolderUi.cs           # ~500 lines
│   ├── PlaceholderCreation.cs     # ~630 lines
│   ├── SymbolBrowsing.cs          # ~360 lines
│   ├── ConnectionHovering.cs      # ~150 lines
│   ├── InputPicking.cs            # ~200 lines
│   ├── OutputPicking.cs           # ~100 lines
│   ├── InputSnapper.cs            # ~150 lines
│   ├── OutputSnapper.cs           # ~100 lines
│   ├── AnnotationDragging.cs      # ~100 lines
│   ├── AnnotationResizing.cs      # ~100 lines
│   ├── AnnotationRenaming.cs      # ~50 lines
│   ├── GraphContextMenu.cs        # ~200 lines
│   ├── KeyboardActions.cs         # ~100 lines
│   ├── Modifications.cs           # ~150 lines
│   ├── RenamingOperator.cs        # ~100 lines
│   └── TourInteraction.cs         # ~50 lines
│
└── Ui/                             # Rendering
    ├── MagGraphView.cs            # ~460 lines
    ├── MagGraphCanvas.Drawing.cs  # ~300 lines
    ├── MagGraphCanvas.DrawNode.cs # ~400 lines
    ├── MagGraphCanvas.DrawConnection.cs # ~350 lines
    └── MagGraphCanvas.DrawAnnotation.cs # ~200 lines
```

---

## What's Next?

You now have the big picture. The four layers, the key design decisions, how data flows. Next, pick your path:

- **[Core Concepts](02-core-concepts.md)** - Understand the fundamental abstractions before diving into code
- **[State Machine](07-state-machine.md)** - See exactly how user interactions flow through states
- **[Model Items](03-model-items.md)** - Get into the details of what a node actually *is*
