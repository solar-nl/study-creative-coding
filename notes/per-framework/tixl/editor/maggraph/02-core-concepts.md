# Chapter 2: Core Concepts

> *Building a mental model of how MagGraph represents and manipulates node graphs*

## Key Insight

> **MagGraph's core idea:** A node graph is modeled as Items (unified type for operators, inputs, outputs), Connections (snapped or flowing), and Layout (cached visual state)—with damped positions creating the "magnetic" feel.

---

## Before We Dive In: What Problem Are We Solving?

A node graph looks simple on screen: boxes connected by wires. But representing this in code raises surprising questions:

- What exactly *is* a node? An operator? A symbol input? The browser placeholder?
- How do you track which outputs connect to which inputs - and handle multiple connections to the same input?
- When the user drags a node, how do you efficiently update everything that depends on its position?
- How do you animate smooth transitions without recalculating everything each frame?

MagGraph's answer is a set of carefully designed abstractions. Understanding these concepts lets you read the codebase with confidence.

---

## The Three Core Abstractions

At the highest level, MagGraph models a graph with three data structures:

```
┌─────────────────────────────────────────────────────────────┐
│                      MagGraphLayout                          │
│                   (Cached View Model)                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐ │
│  │ MagGraphItem │────▶│MagGraphConn. │────▶│ MagGraphItem │ │
│  │   (Source)   │     │              │     │   (Target)   │ │
│  └──────────────┘     └──────────────┘     └──────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Items: Everything on the Canvas

Here's the key insight: **not everything on the canvas is an operator**. You also have symbol inputs (the ports on the left edge when you're inside a composition), symbol outputs (right edge), and the temporary placeholder that appears when you're searching for an operator.

Rather than having separate classes for each, MagGraph uses one unified type - `MagGraphItem` - with a variant enum:

```csharp
public enum Variants
{
    Operator,    // The main node type - an actual operator instance
    Input,       // Symbol input (exposed at composition boundary)
    Output,      // Symbol output (exposed at composition boundary)
    Placeholder, // Temporary: the browser/search UI
    Obsolete,    // Marked for removal (GC pending)
}
```

Why unify these? Because they share behavior: they all have positions, can be selected, can be connected. The variant just changes *how* they behave in specific situations.

### Key Properties

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `Guid` | Unique identifier |
| `Variant` | `Variants` | Type of item |
| `PosOnCanvas` | `Vector2` | Position on the graph canvas |
| `DampedPosOnCanvas` | `Vector2` | Smoothed position for animation |
| `Size` | `Vector2` | Computed size based on visible lines |
| `InputLines` | `InputLine[]` | Visible input slots |
| `OutputLines` | `OutputLine[]` | Visible output slots |
| `Instance` | `Instance?` | The runtime operator instance |
| `SymbolChild` | `Symbol.Child?` | The symbol definition |

### Input and Output Lines

Items have **lines** representing visible input/output slots:

```csharp
public struct InputLine
{
    public Type Type;           // Data type (float, Texture2D, etc.)
    public Guid Id;             // Slot identifier
    public ISlot Input;         // The actual slot
    public IInputUi InputUi;    // UI metadata
    public int VisibleIndex;    // Position in the visual stack
    public MagGraphConnection? ConnectionIn;  // Incoming connection
    public int MultiInputIndex; // For multi-input slots
    public InputLineStates ConnectionState;
}

public struct OutputLine
{
    public Guid Id;
    public ISlot Output;
    public IOutputUi? OutputUi;
    public int VisibleIndex;
    public int OutputIndex;
    public List<MagGraphConnection> ConnectionsOut;  // Outgoing connections
}
```

### Anchor Points

Items provide anchor points for connections:

```
         ┌──────────────────┐
         │   Vertical In    │ ← Input anchor (top)
         ├──────────────────┤
 Horiz.  │                  │ Horiz.
 Input ──│    Operator      │── Output
         │                  │
         ├──────────────────┤
         │  Vertical Out    │ ← Output anchor (bottom)
         └──────────────────┘
```

Anchors are queried with:
```csharp
item.GetInputAnchorAtIndex(index, ref anchorPoint);
item.GetOutputAnchorAtIndex(index, ref anchorPoint);
```

---

## Connections: More Than Just Wires

Here's something that might surprise you: **many connections in MagGraph are invisible**. When two nodes snap together perfectly, there's no curve to draw - they're touching. The connection exists logically, but visually, the nodes just merge into a stack.

This distinction drives the connection style system:

```csharp
public enum ConnectionStyles
{
    // Snapped: nodes are touching, no visible wire
    MainOutToMainInSnappedHorizontal = 0,   // Nodes side-by-side
    MainOutToMainInSnappedVertical,          // Nodes stacked
    MainOutToInputSnappedHorizontal,         // Snapped to secondary input
    AdditionalOutToMainInputSnappedVertical, // From secondary output

    // Flowing: visible curves between separated nodes
    BottomToTop = 4,   // Curve from bottom to top
    BottomToLeft,      // Curve from bottom to left
    RightToTop,        // Curve from right to top
    RightToLeft,       // The classic horizontal S-curve

    Unknown,
}
```

### The Snapped vs Flowing Distinction

**Snapped connections** (`Style < BottomToTop`):

- Invisible - no curve drawn
- Nodes move together when dragged
- Created automatically when you drag nodes to align

**Flowing connections** (`Style >= BottomToTop`):

- Visible Bezier curves
- Nodes are independent
- What you see when nodes aren't aligned

This is why MagGraph feels "magnetic" - snap detection automatically transitions connections between styles.

### Key Properties

| Property | Type | Description |
|----------|------|-------------|
| `Style` | `ConnectionStyles` | Visual style |
| `SourceItem` | `MagGraphItem` | Origin item |
| `TargetItem` | `MagGraphItem` | Destination item |
| `SourceOutput` | `ISlot` | Output slot |
| `SourcePos` / `TargetPos` | `Vector2` | Endpoint positions |
| `DampedSourcePos` / `DampedTargetPos` | `Vector2` | Smoothed positions |
| `ConnectionHash` | `int` | Unique hash for tracking |
| `IsTemporary` | `bool` | True during drag operations |

---

## Layout: The Secret to Performance

You might wonder: if items and connections are the data, why do we need `MagGraphLayout`? Why not just work with the Symbol directly?

The answer is **caching**. A Symbol stores the *logical* graph: which operators exist, how they connect. But rendering needs *visual* information: where each node is on screen, which inputs are visible, what color each connection should be.

Computing this from scratch every frame would be wasteful. `MagGraphLayout` caches it all:

```csharp
internal sealed class MagGraphLayout
{
    public readonly Dictionary<Guid, MagGraphItem> Items;         // All nodes
    public readonly List<MagGraphConnection> MagConnections;      // All wires
    public readonly Dictionary<Guid, MagGraphAnnotation> Annotations;  // Frames
}
```

### When Does It Actually Recompute?

Layout recomputation is expensive. MagGraph is clever about avoiding it:

1. **Structure changes** - Items added/removed, connections changed
2. **Undo/Redo triggered** - `FrameStats.Last.UndoRedoTriggered`
3. **Forced update** - Explicit `forceUpdate` parameter
4. **Composition changed** - Hash mismatch on symbol

```csharp
public void ComputeLayout(GraphUiContext context, bool forceUpdate = false)
{
    if (forceUpdate || FrameStats.Last.UndoRedoTriggered || StructureFlaggedAsChanged ||
        HasCompositionDataChanged(...))
        RefreshDataStructure(context, parentSymbolUi);

    // These always run
    UpdateConnectionLayout();
    ComputeVerticalStackBoundaries(context.View);
}
```

### The Refresh Process

When structure changes, `RefreshDataStructure` runs these steps:

```
1. CollectItemReferences()        → Build Items dictionary
2. CollectedAnnotations()         → Build Annotations dictionary
3. UpdateConnectionSources()      → Track which outputs have connections
4. UpdateVisibleItemLines()       → Compute visible input/output lines
5. CollectConnectionReferences()  → Build MagConnections list
```

### Flagging Changes

To trigger a layout refresh:

```csharp
context.Layout.FlagStructureAsChanged();
```

This sets `StructureFlaggedAsChanged = true`, causing refresh on next frame.

---

## Context: The Glue That Holds Everything Together

Here's a practical question: when you're in the DragItems state and need to know what item is being dragged, where do you look?

The answer is `GraphUiContext`. Think of it as the "working memory" of the graph editor. It holds:

- What's currently selected, hovered, being dragged
- The state machine itself
- References to all the major subsystems
- Ongoing undo/redo commands

Almost every method in MagGraph takes `GraphUiContext` as a parameter. It's the universal way to access shared state.

### What's Inside

```csharp
internal sealed class GraphUiContext
{
    // Core references
    internal readonly ProjectView ProjectView;
    internal readonly MagGraphView View;
    internal readonly MagGraphLayout Layout;

    // State machine
    internal readonly StateMachine<GraphUiContext> StateMachine;

    // Interaction handlers
    internal readonly MagItemMovement ItemMovement;
    internal readonly PlaceholderCreation Placeholder;
    internal readonly ConnectionHovering ConnectionHovering;

    // Active elements (set during interaction)
    internal MagGraphItem? ActiveItem;
    internal MagGraphItem? ActiveSourceItem;
    internal MagGraphItem? ActiveTargetItem;
    internal MagGraphItem? HoveredItem;

    // Undo/Redo
    internal MacroCommand? MacroCommand;

    // Dialogs
    internal readonly EditCommentDialog EditCommentDialog;
    internal readonly AddInputDialog AddInputDialog;
    // ... more dialogs
}
```

### Context Lifecycle

A new context is created when:
- The composition changes (navigating into/out of operators)
- The window changes

The context is passed to almost every method in the system, providing access to all state.

---

## State Machine: One Mode at a Time

You're either dragging, or connecting, or browsing operators. Never multiple at once. This might seem limiting, but it's actually liberating - you never have to wonder "am I in the middle of something else?"

The state machine makes this explicit:

### The Available States

| State | Description |
|-------|-------------|
| `Default` | Idle, waiting for input |
| `HoldItem` | Mouse pressed on operator |
| `HoldItemAfterLongTap` | After long-press on item |
| `DragItems` | Dragging operators |
| `HoldOutput` | Mouse pressed on output anchor |
| `HoldInput` | Mouse pressed on input anchor |
| `DragConnectionEnd` | Dragging connection to target |
| `DragConnectionBeginning` | Dragging connection from source |
| `HoldingConnectionEnd` | Pressed on connection line |
| `HoldingConnectionBeginning` | Pressed on connection line |
| `PickInput` | Selecting from hidden inputs |
| `PickOutput` | Selecting from hidden outputs |
| `HoldBackground` | Long-press on canvas |
| `Placeholder` | Operator browser is open |
| `RenameChild` | Renaming an operator |
| `RenameAnnotation` | Editing annotation text |
| `DragAnnotation` | Moving an annotation |
| `ResizeAnnotation` | Resizing an annotation |
| `BackgroundContentIsInteractive` | Prevent graph interaction |

### State Structure

Each state has three hooks:

```csharp
internal static State<GraphUiContext> Default = new(
    Enter: context => { /* Called once when entering */ },
    Update: context => { /* Called every frame while active */ },
    Exit: context => { /* Called once when leaving */ }
);
```

### State Transitions

Transitions are explicit:

```csharp
context.StateMachine.SetState(GraphStates.DragItems, context);
```

---

## The Grid System

MagGraph uses a consistent grid for positioning:

```csharp
public const float Width = 140;
public const float LineHeight = 35;
public static readonly Vector2 GridSize = new(Width, LineHeight);
```

### Item Sizing

Item height is determined by visible lines:

```csharp
var visibleLineCount = Math.Max(1, inputLines.Count + outputLines.Count - 1);
item.Size = new Vector2(Width, LineHeight * visibleLineCount);
```

### Snapping Tolerance

Items snap when within tolerance:

```csharp
const float SnapTolerance = 0.01f;  // For position matching
const float SnapThreshold = 30;     // For drag proximity
```

---

## Damping: Why Nodes Glide Instead of Jump

When you drag a node and release it, it doesn't teleport to its final position. It glides there smoothly. This isn't magic - it's intentional damping.

Every item has two positions:

- `PosOnCanvas` - Where it *should* be (logical position)
- `DampedPosOnCanvas` - Where it *appears* to be (visual position)

Each frame, the damped position moves partway toward the logical position:

```csharp
private void SmoothItemPositions()
{
    const float dampAmount = 0.33f;

    foreach (var item in _context.Layout.Items.Values)
    {
        // Move 67% of the way toward the target each frame
        item.DampedPosOnCanvas = Vector2.Lerp(
            item.PosOnCanvas,
            item.DampedPosOnCanvas,
            dampAmount
        );
    }
}
```

This creates the "magnetic" feel. When snapping happens, the logical position jumps instantly, but the visual position follows smoothly. The effect: satisfying, organic movement without any complex animation code.

---

## Type-Based Coloring

Each data type has a distinct color:

```csharp
var typeColor = TypeUiRegistry.GetPropertiesForType(item.PrimaryType).Color;
```

Common type colors:
- **Float** - Green
- **Texture2D** - Blue
- **Command** - Orange
- **BufferWithViews** - Purple

---

## What's Next?

You now have the mental model: Items, Connections, Layout, Context, State Machine, and Damping. These six concepts appear everywhere in MagGraph. When you read the code, you'll recognize them.

Ready to go deeper?

- **[Model Items](03-model-items.md)** - The full story on what makes up a node
- **[Model Connections](04-model-connections.md)** - How wires know where to go
- **[State Machine](07-state-machine.md)** - Every interaction mode, explained
