# Chapter 4: MagGraphConnection - The Wire Model

> *The invisible wires that aren't invisible, and why that matters*

---

## The Insight: Many Wires Are Invisible

Here's what makes MagGraph feel "magnetic": when you drag a node close to another and release, they snap together. No visible wire connects them - they're just touching. But under the hood, a `MagGraphConnection` still exists.

This means connections aren't just about drawing curves. They're about tracking data flow, even when visually hidden. A snapped connection is logically identical to a flowing connection - only the rendering differs.

`MagGraphConnection` captures this duality. It stores:

- **What's connected:** source and target items, specific slots
- **How it looks:** snapped (invisible) or flowing (curved)
- **Where it renders:** endpoint positions with smooth animation
- **Temporary state:** for drag operations in progress

**Source:** [MagGraphConnection.cs](../../../Editor/Gui/MagGraph/Model/MagGraphConnection.cs) (~100 lines)

---

## Connection Styles

The most distinctive feature of MagGraph is its **snapped connection** concept:

```csharp
public enum ConnectionStyles
{
    // Snapped connections (items are aligned)
    MainOutToMainInSnappedHorizontal = 0,  // ══════════
    MainOutToMainInSnappedVertical,         // ║
    MainOutToInputSnappedHorizontal,        // ══ (to secondary input)
    AdditionalOutToMainInputSnappedVertical,// ║ (from secondary output)

    // Flowing connections (items are not aligned)
    BottomToTop = 4,   // Curved from bottom to top
    BottomToLeft,      // Curved from bottom to left side
    RightToTop,        // Curved from right to top
    RightToLeft,       // Standard horizontal curve

    Unknown,           // Not yet determined
}
```

### Visual Representation

```
SNAPPED CONNECTIONS:

Vertical (MainOutToMainInSnappedVertical):
    ┌───────────┐
    │  Source   │
    └─────┬─────┘
          ║ (no curve drawn)
    ┌─────┴─────┐
    │  Target   │
    └───────────┘

Horizontal (MainOutToMainInSnappedHorizontal):
    ┌───────────┐    ┌───────────┐
    │  Source   │════│  Target   │
    └───────────┘    └───────────┘
    (items touching, no curve)


FLOWING CONNECTIONS:

RightToLeft:
    ┌───────────┐         ┌───────────┐
    │  Source   │──────╮  │  Target   │
    └───────────┘      ╰──│           │
                          └───────────┘

BottomToTop:
    ┌───────────┐
    │  Source   │
    └─────┬─────┘
          │
          ╰────────────╮
                       │
                 ┌─────┴─────┐
                 │  Target   │
                 └───────────┘
```

---

## Snapped vs Flowing

The `IsSnapped` property is crucial for understanding MagGraph's magnetic behavior:

```csharp
public bool IsSnapped => Style < ConnectionStyles.BottomToTop;
```

When snapped:
- **No visible curve** is drawn between items
- Items are visually **touching**
- Moving one item **moves the connected item** as well
- The connection is essentially **invisible** (just adjacent placement)

When flowing:
- A **Bezier curve** is drawn between endpoints
- Items can be **anywhere** relative to each other
- Moving one item **does not** affect the other

---

## Key Properties

### Item References

| Property | Type | Description |
|----------|------|-------------|
| `SourceItem` | `MagGraphItem` | The item with the output |
| `TargetItem` | `MagGraphItem` | The item with the input |
| `SourceOutput` | `ISlot` | The specific output slot |
| `TargetInput` | `ISlot` | The specific input slot (computed) |
| `Type` | `Type` | The data type being transferred |

### Positioning

| Property | Type | Description |
|----------|------|-------------|
| `SourcePos` | `Vector2` | Logical source endpoint position |
| `TargetPos` | `Vector2` | Logical target endpoint position |
| `DampedSourcePos` | `Vector2` | Smoothed source for animation |
| `DampedTargetPos` | `Vector2` | Smoothed target for animation |

### Indexing

| Property | Type | Description |
|----------|------|-------------|
| `InputLineIndex` | `int` | Index into TargetItem.InputLines |
| `OutputLineIndex` | `int` | Index into SourceItem.OutputLines |
| `VisibleOutputIndex` | `int` | Visual position of the output |
| `MultiInputIndex` | `int` | For multi-input slots, which sub-input |
| `ConnectionHash` | `int` | Unique identifier for tracking |

### State Flags

| Property | Type | Description |
|----------|------|-------------|
| `Style` | `ConnectionStyles` | Current visual style |
| `IsTemporary` | `bool` | True during drag operations |
| `WasDisconnected` | `bool` | True if ripped from an input |

---

## The Type Property

The connection type is derived from available sources:

```csharp
public Type Type
{
    get
    {
        if (SourceOutput != null)
        {
            return SourceOutput.ValueType;
        }

        if (TargetItem != null)
        {
            if (InputLineIndex >= TargetItem.InputLines.Length)
            {
                Log.Warning("Invalid target input for connection?");
                return null;
            }
            return TargetInput.ValueType;
        }
        return null;
    }
}
```

This handles temporary connections where either end might be null.

---

## Converting to Symbol.Connection

The layout uses rich `MagGraphConnection` objects, but modifications require the simpler `Symbol.Connection`:

```csharp
public Symbol.Connection AsSymbolConnection()
{
    var sourceParentOfSymbolChildId =
        SourceItem.Variant == MagGraphItem.Variants.Input ? Guid.Empty : SourceItem.Id;

    var targetParentOfSymbolChildId =
        TargetItem.Variant == MagGraphItem.Variants.Output ? Guid.Empty : TargetItem.Id;

    return new Symbol.Connection(
        sourceParentOfSymbolChildId,
        SourceOutput.Id,
        targetParentOfSymbolChildId,
        TargetInput.Id
    );
}
```

The `Guid.Empty` handling is for symbol-level inputs/outputs which have different ID semantics.

---

## Connection Hashing

For efficient tracking of connections, a hash is computed:

```csharp
public int GetItemInputHash()
{
    return GetItemInputHash(TargetItem.Id, TargetInput.Id, MultiInputIndex);
}

[MethodImpl(MethodImplOptions.AggressiveInlining)]
public static int GetItemInputHash(Guid itemId, Guid inputId, int multiInputIndex)
{
    return itemId.GetHashCode() * 31 + inputId.GetHashCode() * 31 + multiInputIndex;
}
```

This hash uniquely identifies a specific input slot, accounting for multi-inputs.

---

## Style Determination

Connection styles are computed in `MagGraphLayout.UpdateConnectionLayout()`:

```csharp
private void UpdateConnectionLayout()
{
    foreach (var sc in MagConnections)
    {
        var sourceMin = sc.SourceItem.PosOnCanvas;
        var sourceMax = sourceMin + sc.SourceItem.Size;
        var targetMin = sc.TargetItem.PosOnCanvas;

        // Check for horizontal snapping
        if (MathF.Abs(sourceMax.X - targetMin.X) < 1
            && MathF.Abs((sourceMin.Y + sc.VisibleOutputIndex * GridSize.Y)
                         - (targetMin.Y + sc.InputLineIndex * GridSize.Y)) < 1)
        {
            sc.Style = sc.InputLineIndex == 0
                           ? ConnectionStyles.MainOutToMainInSnappedHorizontal
                           : ConnectionStyles.MainOutToInputSnappedHorizontal;
            // Position at the touching point
            var p = new Vector2(sourceMax.X,
                               sourceMin.Y + (sc.VisibleOutputIndex + 0.5f) * GridSize.Y);
            sc.SourcePos = p;
            sc.TargetPos = p;
            continue;
        }

        // Check for vertical snapping
        if (sc.InputLineIndex == 0
            && sc.OutputLineIndex == 0
            && MathF.Abs(sourceMin.X - targetMin.X) < 1
            && MathF.Abs(sourceMax.Y - targetMin.Y) < 1)
        {
            sc.Style = ConnectionStyles.MainOutToMainInSnappedVertical;
            var p = new Vector2(sourceMin.X + GridSize.X / 2, targetMin.Y);
            sc.SourcePos = p;
            sc.TargetPos = p;
            continue;
        }

        // Not snapped - use flowing style
        sc.SourcePos = new Vector2(sourceMax.X,
                                   sourceMin.Y + (sc.VisibleOutputIndex + 0.5f) * GridSize.Y);
        sc.TargetPos = new Vector2(targetMin.X,
                                   targetMin.Y + (sc.InputLineIndex + 0.5f) * GridSize.Y);
        sc.Style = ConnectionStyles.RightToLeft;
    }
}
```

---

## Temporary Connections

During drag operations, temporary connections are created:

```csharp
// From GraphStates.HoldOutput:
var tempConnection = new MagGraphConnection
{
    Style = ConnectionStyles.Unknown,
    SourcePos = posOnCanvas,
    TargetPos = default,          // Will follow mouse
    SourceItem = sourceItem,
    TargetItem = null,            // Not connected yet
    SourceOutput = output,
    OutputLineIndex = outputLine.VisibleIndex,
    VisibleOutputIndex = 0,
    ConnectionHash = 0,
    IsTemporary = true,
};
context.TempConnections.Add(tempConnection);
```

Temporary connections:
- Have `IsTemporary = true`
- May have null `SourceItem` or `TargetItem`
- Are stored in `context.TempConnections` (not in `Layout.MagConnections`)
- Are rendered differently (dashed or with connection preview)

---

## Connection to InputLines

Each input line tracks its incoming connection:

```csharp
public struct InputLine
{
    // ...
    public MagGraphConnection? ConnectionIn;  // The incoming connection, if any
}
```

And each output line tracks all outgoing connections:

```csharp
public struct OutputLine
{
    // ...
    public List<MagGraphConnection> ConnectionsOut;  // All outgoing connections
}
```

This bidirectional reference makes traversal efficient:

```csharp
// From an item, find what's connected to its primary input:
if (item.TryGetPrimaryInConnection(out var inConnection))
{
    var sourceOp = inConnection.SourceItem;
    // ...
}

// Find all items connected to primary output:
if (item.TryGetPrimaryOutConnections(out var outConnections))
{
    foreach (var outConn in outConnections)
    {
        var targetOp = outConn.TargetItem;
        // ...
    }
}
```

---

## Multi-Input Connections

Some inputs accept multiple connections (like `Execute` chains):

```csharp
// Each connection to a multi-input has a unique MultiInputIndex
connection.MultiInputIndex = 0;  // First connection
connection.MultiInputIndex = 1;  // Second connection
// etc.

// The hash includes this index for uniqueness:
var hash = GetItemInputHash(targetId, inputId, multiInputIndex);
```

Multiple input lines may share the same `Id` but have different `MultiInputIndex` values.

---

## WasDisconnected Flag

When dragging a connection from an existing wire (ripping it off), this flag is set:

```csharp
var tempConnection = new MagGraphConnection
{
    // ...
    WasDisconnected = true,  // Was ripped from input
};
```

This affects behavior when dropped:
- If dropped on empty space, **don't** open the placeholder browser (just disconnect)
- The visual style may differ

---

## Next Steps

- **[Model Layout](05-model-layout.md)** - How connections are collected and updated
- **[Rendering Connections](16-rendering-connections.md)** - How curves are drawn
- **[Interaction Connections](10-interaction-connections.md)** - Drag and connect behavior
