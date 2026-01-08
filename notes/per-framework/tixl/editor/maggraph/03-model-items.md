# Chapter 3: MagGraphItem - The Node Abstraction

> *How a single class represents operators, inputs, outputs, and more*

---

## The Design Question: One Class or Many?

When building a node editor, you face an early architectural decision. You have operators (the main nodes). You have symbol inputs and outputs (the ports at composition boundaries). You have placeholders (the temporary search UI). How do you represent these?

**Option A: Separate classes.** `OperatorItem`, `InputItem`, `OutputItem`, `PlaceholderItem`. Each knows its own behavior.

**Option B: Unified class with variants.** One `MagGraphItem` class with a variant enum. Shared behavior, variant-specific logic where needed.

MagGraph chose Option B. Here's why:

These elements share 90% of their behavior. They all have positions. They all can be selected. They all participate in snapping. They all have anchor points. Creating separate classes means duplicating this logic four times - and keeping it synchronized.

The variant approach gives you:

- **One layout algorithm** that works for all items
- **One selection system** - no type checking
- **One snapping system** - consistent feel everywhere
- **One anchor calculation** - centralized, tested once

**Source:** [MagGraphItem.cs](../../../Editor/Gui/MagGraph/Model/MagGraphItem.cs) (~370 lines)

```
┌────────────────────────────────────────────────────────┐
│                   MagGraphItem                          │
├────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────┐ │
│  │ Operator │  │  Input   │  │  Output  │  │Placeholder│
│  │          │  │(exposed) │  │(exposed) │  │(temp)   │ │
│  └──────────┘  └──────────┘  └──────────┘  └────────┘ │
│                 All share:                              │
│   • Position & Size logic                               │
│   • Anchor point calculation                            │
│   • Selection behavior                                  │
│   • Damping animation                                   │
└────────────────────────────────────────────────────────┘
```

---

## Item Variants

```csharp
public enum Variants
{
    Operator,    // A symbol child instance (the main node type)
    Input,       // A symbol input (exposed at composition level)
    Output,      // A symbol output (exposed at composition level)
    Placeholder, // Temporary item during operator creation
    Obsolete,    // Marked for removal
}
```

### Operator Variant

The most common variant - represents an actual operator instance:

```csharp
// When Variant == Operator:
item.SymbolChild   // The Symbol.Child definition
item.Instance      // The runtime Instance (computed property)
item.SymbolUi      // The UI metadata for the symbol
item.ChildUi       // The UI properties for this specific child
```

### Input Variant

Represents a symbol's exposed input (appears at composition boundary):

```csharp
// When Variant == Input:
item.Selectable  // Cast to IInputUi for input metadata
item.Instance    // The parent composition's Instance
```

### Output Variant

Represents a symbol's exposed output:

```csharp
// When Variant == Output:
item.Selectable  // Cast to IOutputUi for output metadata
```

### Placeholder Variant

A temporary item used during operator creation:

```csharp
// Special static ID used for placeholders
public static readonly Guid PlaceHolderId = new("...");
```

---

## Key Properties

### Identity and References

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `Guid` | Unique identifier (matches SymbolChild.Id for operators) |
| `Variant` | `Variants` | Type of item |
| `Selectable` | `ISelectableCanvasObject` | Interface for selection system |
| `SymbolChild` | `Symbol.Child?` | The symbol definition (operators only) |
| `SymbolUi` | `SymbolUi?` | UI metadata for the symbol |
| `ChildUi` | `SymbolUi.Child?` | UI properties for this child instance |
| `InstancePath` | `IReadOnlyList<Guid>?` | Path to the runtime instance |

### Positioning

| Property | Type | Description |
|----------|------|-------------|
| `PosOnCanvas` | `Vector2` | Current logical position |
| `DampedPosOnCanvas` | `Vector2` | Smoothed position for animation |
| `Size` | `Vector2` | Computed size based on visible lines |
| `Area` | `ImRect` | Bounding rectangle (computed) |
| `VerticalStackArea` | `ImRect` | Bounds of the vertical stack this item belongs to |

### Lines (Input/Output Slots)

| Property | Type | Description |
|----------|------|-------------|
| `InputLines` | `InputLine[]` | Visible input slots |
| `OutputLines` | `OutputLine[]` | Visible output slots |
| `HasHiddenOutputs` | `bool` | True if some outputs are collapsed |
| `PrimaryType` | `Type` | The main data type (first output's type) |

---

## The Instance Property: Why It's Computed, Not Stored

Here's a subtle but important design decision. A `MagGraphItem` doesn't *store* its `Instance`. It *computes* it on demand:

```csharp
public Instance? Instance
{
    get
    {
        if (InstancePath == null || SymbolChild == null)
            return null;

        SymbolChild.TryGetOrCreateInstance(InstancePath, out var instance, out _, true);
        return instance;
    }
}
```

Why not just store a reference? Because instances are contextual.

Imagine an `Add` operator symbol. In one project, it might be used 50 times in different compositions. Each use creates a different Instance - same symbol, different runtime state. The MagGraphItem for a specific use needs to find *its* instance, not just any instance of `Add`.

The `InstancePath` solves this: it's a list of GUIDs that traces from the root composition down to this specific operator. When you ask for `Instance`, MagGraph walks that path and returns (or creates) the right one.

This lazy resolution also means items don't hold stale references. If the symbol hierarchy changes, the next access gets the current state.

---

## Input and Output Lines

### InputLine Structure

```csharp
public struct InputLine
{
    public Type Type;                    // Data type (float, Texture2D, etc.)
    public Guid Id;                      // Slot identifier
    public ISlot Input;                  // The actual slot
    public IInputUi InputUi;             // UI metadata
    public int VisibleIndex;             // Position in the visual stack
    public MagGraphConnection? ConnectionIn;  // Incoming connection (if any)
    public int MultiInputIndex;          // For multi-input slots
    public InputLineStates ConnectionState;   // Connected, temp, or free
}

public enum InputLineStates
{
    Connected,      // Has a real connection
    TempConnection, // Has a temporary dragged connection
    NotConnected,   // Available for connection
}
```

### OutputLine Structure

```csharp
public struct OutputLine
{
    public Guid Id;
    public ISlot Output;
    public IOutputUi? OutputUi;
    public int VisibleIndex;
    public int OutputIndex;
    public List<MagGraphConnection> ConnectionsOut;  // Multiple outputs possible
}
```

### Line Visibility Rules

Not all inputs/outputs are visible. The visibility rules are:

```
Input Visible If:
├── Is the primary (first) input
├── Is marked as Relevant or Required in UI
├── Has an active connection
└── Has a temporary (being-dragged) connection

Output Visible If:
├── Is the primary (first) output
└── Has at least one connection
```

---

## Anchor Points: Where Connections Attach

When you drag a connection toward a node, it doesn't snap anywhere - it snaps to specific *anchor points*. Understanding the anchor system helps you understand connection routing.

```
         ┌──────────────────┐
    [0]  │   Vertical In    │ ← GetInputAnchorAtIndex(0)
         ├──────────────────┤
[1] ──●──│    Input Line 0  │──●── [1]  ← GetOutputAnchorAtIndex(1)
[2] ──●──│    Input Line 1  │
[3] ──●──│    Input Line 2  │
         ├──────────────────┤
    [0]  │   Vertical Out   │ ← GetOutputAnchorAtIndex(0)
         └──────────────────┘
```

### Getting Input Anchors

```csharp
public void GetInputAnchorAtIndex(int index, ref InputAnchorPoint anchorPoint)
{
    if (index == 0)
    {
        // Vertical anchor at top center
        anchorPoint.PositionOnCanvas = new Vector2(WidthHalf, 0) + DampedPosOnCanvas;
        anchorPoint.Direction = Directions.Vertical;
        anchorPoint.ConnectionType = InputLines[0].Type;
        anchorPoint.SnappedConnectionHash = InputLines[0].ConnectionIn?.ConnectionHash ?? FreeAnchor;
        anchorPoint.SlotId = InputLines[0].Id;
        anchorPoint.InputLine = InputLines[0];
        return;
    }

    // Horizontal anchors on left side
    var lineIndex = index - 1;
    anchorPoint.PositionOnCanvas = new Vector2(0, (0.5f + InputLines[lineIndex].VisibleIndex) * LineHeight)
                                   + DampedPosOnCanvas;
    anchorPoint.Direction = Directions.Horizontal;
    // ...
}
```

### Getting Output Anchors

```csharp
public void GetOutputAnchorAtIndex(int index, ref OutputAnchorPoint point)
{
    if (index == 0)
    {
        // Vertical anchor at bottom center
        point.PositionOnCanvas = new Vector2(WidthHalf, Size.Y) + DampedPosOnCanvas;
        point.Direction = Directions.Vertical;
        point.ConnectionType = OutputLines[0].Output.ValueType;
        // ...
        return;
    }

    // Horizontal anchors on right side
    var lineIndex = index - 1;
    point.PositionOnCanvas = new Vector2(Width, (0.5f + OutputLines[lineIndex].VisibleIndex) * LineHeight)
                             + DampedPosOnCanvas;
    point.Direction = Directions.Horizontal;
    // ...
}
```

### AnchorPoint Structures

```csharp
public struct InputAnchorPoint
{
    public Vector2 PositionOnCanvas;
    public Directions Direction;       // Horizontal or Vertical
    public Type ConnectionType;
    public int SnappedConnectionHash;  // FreeAnchor (-1) if available
    public Guid SlotId;
    public InputLine InputLine;
}

public struct OutputAnchorPoint
{
    public Vector2 PositionOnCanvas;
    public Directions Direction;
    public Type ConnectionType;
    public int SnappedConnectionHash;
    public Guid SlotId;
    public int OutputLineIndex;
}
```

---

## Grid Constants

MagGraph uses a fixed grid for consistent sizing:

```csharp
public const float Width = 140;
public const float WidthHalf = Width / 2;  // 70
public const float LineHeight = 35;
public static readonly Vector2 GridSize = new(Width, LineHeight);  // (140, 35)
```

### Size Calculation

Item height is computed from visible lines:

```csharp
// In MagGraphLayout.UpdateVisibleItemLines():
var visibleLineCount = Math.Max(1, visibleIndex);
item.Size = new Vector2(Width, LineHeight * visibleLineCount);
```

---

## Selection Integration

Items implement `ISelectableCanvasObject` for integration with the selection system:

```csharp
public void Select(NodeSelection nodeSelection)
{
    if (Variant == Variants.Operator
        && Instance?.Parent != null
        && SymbolUiRegistry.TryGetSymbolUi(Instance.Parent.Symbol.Id, out var parentSymbolUi)
        && parentSymbolUi.ChildUis.TryGetValue(Instance.SymbolChildId, out var childUi))
    {
        nodeSelection.SetSelection(childUi, Instance);
    }
    else
    {
        nodeSelection.SetSelection(Selectable);
    }
}

public void AddToSelection(NodeSelection nodeSelection)
{
    // Similar logic but calls AddSelection instead of SetSelection
}
```

---

## Value Snapping

Items implement `IValueSnapAttractor` for value-based snapping in the transform system:

```csharp
void IValueSnapAttractor.CheckForSnap(ref SnapResult snapResult)
{
    if (snapResult.Orientation == SnapResult.Orientations.Horizontal)
    {
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.X);
    }
    else if (snapResult.Orientation == SnapResult.Orientations.Vertical)
    {
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.Y);
    }
}
```

---

## Helper Methods

### Getting Primary Connections

```csharp
public bool TryGetPrimaryInConnection(out MagGraphConnection? connection)
{
    connection = null;
    if (InputLines.Length == 0)
        return false;

    connection = InputLines[0].ConnectionIn;
    return connection != null;
}

public bool TryGetPrimaryOutConnections(out List<MagGraphConnection> connections)
{
    if (OutputLines.Length == 0)
    {
        connections = [];
        return false;
    }

    connections = OutputLines[0].ConnectionsOut;
    return connections.Count > 0;
}
```

### Computing Bounds

```csharp
public static ImRect GetItemsBounds(IEnumerable<MagGraphItem> items)
{
    ImRect extend = default;
    var index = 0;

    foreach (var item in items)
    {
        if (index == 0)
            extend = item.Area;
        else
            extend.Add(item.Area);
        index++;
    }

    return extend;
}
```

---

## Readable Name

For display purposes, items have a computed readable name:

```csharp
public string ReadableName
{
    get
    {
        return Variant switch
        {
            Variants.Operator => SymbolChild == null
                ? "???"
                : SymbolChild.HasCustomName
                    ? "\"" + SymbolChild.ReadableName + "\""
                    : SymbolChild.ReadableName,
            Variants.Input  => Selectable is IInputUi inputUi ? inputUi.InputDefinition.Name : "???",
            Variants.Output => Selectable is IOutputUi outputUi ? outputUi.OutputDefinition.Name : "???",
            _ => "???"
        };
    }
}
```

---

## Collapsed Items

Items can be "collapsed away" into annotations:

```csharp
public bool IsCollapsedAway => ChildUi != null && ChildUi.CollapsedIntoAnnotationFrameId != Guid.Empty;
```

When collapsed:
- The item is not rendered in its normal position
- It appears within the annotation frame instead
- Connections to/from it are still tracked

---

## What's Next?

You now understand what an item *is*. Next, learn how they connect:

- **[Model Connections](04-model-connections.md)** - The wires between items, and why some are invisible
- **[Model Layout](05-model-layout.md)** - How items are collected into the cached layout
- **[Rendering Nodes](15-rendering-nodes.md)** - How items get drawn to screen
