# Chapter 5: MagGraphLayout - The Cached View Model

> *The performance secret: compute once, render many times*

---

## The Problem: Symbol Data Isn't Render-Ready

A `Symbol` knows which operators exist and how they connect. But it doesn't know:

- Which inputs are visible (some are collapsed)
- Where nodes appear on screen (that's stored in UI data)
- What color each connection should be (based on type)
- Whether items are snapped together or separate

Computing this every frame would be wasteful. For a graph with 200 nodes and 300 connections, that's thousands of dictionary lookups, type checks, and calculations - 60 times per second.

`MagGraphLayout` is the cache that solves this. It transforms Symbol data into render-ready structures **once**, then reuses them until the graph structure actually changes.

This is why MagGraph stays smooth even with large graphs: the expensive work happens rarely, not constantly.

**Source:** [MagGraphLayout.cs](../../../Editor/Gui/MagGraph/Model/MagGraphLayout.cs) (~930 lines)

---

## Core Data Structures

```csharp
internal sealed class MagGraphLayout
{
    public readonly Dictionary<Guid, MagGraphItem> Items = new(127);
    public readonly List<MagGraphConnection> MagConnections = new(127);
    public readonly Dictionary<Guid, MagGraphAnnotation> Annotations = new(63);
}
```

The initial capacities (127, 63) are tuned for typical graph sizes to minimize reallocations.

```
┌────────────────────────────────────────────────────────────┐
│                      MagGraphLayout                         │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  Items Dictionary                                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Guid → MagGraphItem                                  │   │
│  │ (Operators, Inputs, Outputs, Placeholder)            │   │
│  └─────────────────────────────────────────────────────┘   │
│                          ↓                                  │
│  MagConnections List                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [MagGraphConnection, MagGraphConnection, ...]        │   │
│  │ (Each has SourceItem & TargetItem references)        │   │
│  └─────────────────────────────────────────────────────┘   │
│                          ↓                                  │
│  Annotations Dictionary                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Guid → MagGraphAnnotation                            │   │
│  │ (Frames and labels)                                  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

---

## The Update Cycle

### Main Entry Point

```csharp
public void ComputeLayout(GraphUiContext context, bool forceUpdate = false)
{
    var compositionOp = context.CompositionInstance;

    if (!SymbolUiRegistry.TryGetSymbolUi(compositionOp.Symbol.Id, out var parentSymbolUi))
        return;

    // Mark symbol as modified if structure changed
    if (StructureFlaggedAsChanged)
    {
        context.CompositionInstance.GetSymbolUi().FlagAsModified();
    }

    // Determine if we need a full refresh
    if (forceUpdate || FrameStats.Last.UndoRedoTriggered || StructureFlaggedAsChanged ||
        HasCompositionDataChanged(compositionOp.Symbol, ref _compositionModelHash))
    {
        RefreshDataStructure(context, parentSymbolUi);
    }

    // These always run
    UpdateConnectionLayout();
    ComputeVerticalStackBoundaries(context.View);
}
```

### Refresh Triggers

A full `RefreshDataStructure` happens when:

| Condition | Description |
|-----------|-------------|
| `forceUpdate` | Explicit parameter (rarely used) |
| `FrameStats.Last.UndoRedoTriggered` | User pressed Undo/Redo |
| `StructureFlaggedAsChanged` | Something called `FlagStructureAsChanged()` |
| Hash mismatch | Composition ID changed (navigation) |

---

## The Refresh Pipeline

```csharp
private void RefreshDataStructure(GraphUiContext context, SymbolUi parentSymbolUi)
{
    var composition = context.CompositionInstance;

    _structureUpdateCycle++;
    CollectItemReferences(composition, parentSymbolUi);   // Step 1
    CollectedAnnotations(parentSymbolUi);                 // Step 2
    UpdateConnectionSources(composition);                 // Step 3
    UpdateVisibleItemLines(context);                      // Step 4
    CollectConnectionReferences(composition);             // Step 5
    StructureFlaggedAsChanged = false;
}
```

### Step 1: CollectItemReferences

Builds the `Items` dictionary from composition children:

```csharp
private void CollectItemReferences(Instance compositionOp, SymbolUi compositionSymbolUi)
{
    var addedItemCount = 0;
    var updatedItemCount = 0;

    // Collect operator children
    foreach (var (childId, childInstance) in compositionOp.Children)
    {
        if (!compositionSymbolUi.ChildUis.TryGetValue(childId, out var childUi))
            continue;

        if (!SymbolUiRegistry.TryGetSymbolUi(childInstance.Symbol.Id, out var symbolUi))
            continue;

        if (Items.TryGetValue(childId, out var opItem))
        {
            opItem.ResetConnections(_structureUpdateCycle);
            updatedItemCount++;
        }
        else
        {
            opItem = new MagGraphItem
            {
                Id = childId,
                Selectable = childUi,
                SymbolChild = childInstance.SymbolChild,
                ChildUi = childUi,
                DampedPosOnCanvas = childUi.PosOnCanvas,
                InstancePath = childInstance.InstancePath,
            };
            Items[childId] = opItem;
            addedItemCount++;
        }

        // Update properties that may have changed
        opItem.Variant = MagGraphItem.Variants.Operator;
        opItem.SymbolUi = symbolUi;
        // ...
    }

    // Also collect exposed inputs and outputs
    foreach (var input in compositionOp.Inputs)
    {
        // Create/update Input variant items
    }

    foreach (var output in compositionOp.Outputs)
    {
        // Create/update Output variant items
    }

    // Remove obsolete items
    var hasObsoleteItems = Items.Count > updatedItemCount + addedItemCount;
    if (hasObsoleteItems)
    {
        foreach (var item in Items.Values)
        {
            if (item.LastUpdateCycle >= _structureUpdateCycle)
                continue;

            Items.Remove(item.Id);
            item.Variant = MagGraphItem.Variants.Obsolete;
        }
    }
}
```

The `_structureUpdateCycle` counter is key for detecting obsolete items without allocating temporary collections.

### Step 2: CollectedAnnotations

Similar pattern for annotations:

```csharp
private void CollectedAnnotations(SymbolUi compositionSymbolUi)
{
    Annotations.Clear();
    var addedCount = 0;
    var updatedCount = 0;

    foreach (var (annotationId, annotation) in compositionSymbolUi.Annotations)
    {
        if (Annotations.TryGetValue(annotationId, out var opItem))
        {
            updatedCount++;
            opItem.LastUpdateCycle = _structureUpdateCycle;
        }
        else
        {
            opItem = new MagGraphAnnotation
            {
                Id = annotation.Id,
                Annotation = annotation,
                DampedPosOnCanvas = annotation.PosOnCanvas,
                DampedSize = annotation.Size,
            };
            Annotations[annotationId] = opItem;
            addedCount++;
        }
    }

    // Remove obsolete annotations
    // ...
}
```

### Step 3: UpdateConnectionSources

Builds a hash set of outputs that have connections:

```csharp
private readonly HashSet<int> _connectedOutputs = new(100);

private void UpdateConnectionSources(Instance composition)
{
    _connectedOutputs.Clear();

    foreach (var c in composition.Symbol.Connections)
    {
        if (c.IsConnectedToSymbolInput)
            continue;

        _connectedOutputs.Add(GetConnectionSourceHash(c));
    }
}

private static int GetConnectionSourceHash(Symbol.Connection c)
{
    var hash = c.SourceSlotId.GetHashCode();
    hash = hash * 31 + c.SourceParentOrChildId.GetHashCode();
    return hash;
}
```

This is used later to determine if secondary outputs should be visible.

### Step 4: UpdateVisibleItemLines

This is the most complex step - computing which input/output lines are visible:

```csharp
private void UpdateVisibleItemLines(GraphUiContext context)
{
    var inputLines = new List<MagGraphItem.InputLine>(8);
    var outputLines = new List<MagGraphItem.OutputLine>(4);

    foreach (var item in Items.Values)
    {
        inputLines.Clear();
        outputLines.Clear();

        var visibleIndex = 0;

        switch (item.Variant)
        {
            case MagGraphItem.Variants.Operator:
                visibleIndex = CollectVisibleLines(context, item, inputLines, outputLines, _connectedOutputs);
                break;

            case MagGraphItem.Variants.Input:
                // Exposed inputs only have an output line
                outputLines.Add(new MagGraphItem.OutputLine { /* ... */ });
                break;

            case MagGraphItem.Variants.Output:
                // Exposed outputs only have an input line
                inputLines.Add(new MagGraphItem.InputLine { /* ... */ });
                break;
        }

        item.InputLines = inputLines.ToArray();
        item.OutputLines = outputLines.ToArray();
        item.Size = new Vector2(MagGraphItem.Width, MagGraphItem.LineHeight * Math.Max(1, visibleIndex));
    }
}
```

The `CollectVisibleLines` helper handles complex logic for multi-inputs, relevancy, and temporary connections.

### Step 5: CollectConnectionReferences

Builds the `MagConnections` list with full references:

```csharp
private void CollectConnectionReferences(Instance composition)
{
    MagConnections.Clear();
    MagConnections.Capacity = composition.Symbol.Connections.Count;

    for (var cIndex = 0; cIndex < composition.Symbol.Connections.Count; cIndex++)
    {
        var c = composition.Symbol.Connections[cIndex];

        // Handle symbol input connections
        if (c.IsConnectedToSymbolInput)
        {
            // Create connection from exposed input to child
            // ...
            continue;
        }

        // Handle symbol output connections
        if (c.IsConnectedToSymbolOutput)
        {
            // Create connection from child to exposed output
            // ...
            continue;
        }

        // Regular child-to-child connections
        if (!Items.TryGetValue(c.SourceParentOrChildId, out var sourceItem)
            || !Items.TryGetValue(c.TargetParentOrChildId, out var targetItem))
            continue;

        var snapGraphConnection = new MagGraphConnection
        {
            Style = MagGraphConnection.ConnectionStyles.Unknown,
            SourceItem = sourceItem,
            SourceOutput = output,
            TargetItem = targetItem,
            InputLineIndex = inputLineIndex,
            OutputLineIndex = outputLineIndex,
            ConnectionHash = c.GetHashCode(),
            MultiInputIndex = multiInputIndex,
        };

        // Link connection to input/output lines
        targetItem.InputLines[inputLineIndex].ConnectionIn = snapGraphConnection;
        sourceItem.OutputLines[outputLineIndex].ConnectionsOut.Add(snapGraphConnection);
        MagConnections.Add(snapGraphConnection);
    }
}
```

---

## Connection Layout Update

After structure refresh, connection positions are always updated:

```csharp
private void UpdateConnectionLayout()
{
    foreach (var sc in MagConnections)
    {
        var sourceMin = sc.SourceItem.PosOnCanvas;
        var sourceMax = sourceMin + sc.SourceItem.Size;
        var targetMin = sc.TargetItem.PosOnCanvas;

        // Determine style based on item positions

        // Snapped horizontally?
        if (MathF.Abs(sourceMax.X - targetMin.X) < 1
            && MathF.Abs((sourceMin.Y + sc.VisibleOutputIndex * GridSize.Y)
                        - (targetMin.Y + sc.InputLineIndex * GridSize.Y)) < 1)
        {
            sc.Style = sc.InputLineIndex == 0
                ? ConnectionStyles.MainOutToMainInSnappedHorizontal
                : ConnectionStyles.MainOutToInputSnappedHorizontal;
            var p = new Vector2(sourceMax.X, sourceMin.Y + (sc.VisibleOutputIndex + 0.5f) * GridSize.Y);
            sc.SourcePos = p;
            sc.TargetPos = p;
            continue;
        }

        // Snapped vertically?
        if (sc.InputLineIndex == 0 && sc.OutputLineIndex == 0
            && MathF.Abs(sourceMin.X - targetMin.X) < 1
            && MathF.Abs(sourceMax.Y - targetMin.Y) < 1)
        {
            sc.Style = ConnectionStyles.MainOutToMainInSnappedVertical;
            // ...
            continue;
        }

        // Not snapped - flowing connection
        sc.SourcePos = new Vector2(sourceMax.X, sourceMin.Y + (sc.VisibleOutputIndex + 0.5f) * GridSize.Y);
        sc.TargetPos = new Vector2(targetMin.X, targetMin.Y + (sc.InputLineIndex + 0.5f) * GridSize.Y);
        sc.Style = ConnectionStyles.RightToLeft;
    }
}
```

---

## Vertical Stack Computation

MagGraph groups vertically stacked items for better arc rendering:

```csharp
private static readonly List<MagGraphItem> _listStackedItems = new(32);

private void ComputeVerticalStackBoundaries(ScalableCanvas canvas)
{
    MagGraphItem? previousItem = null;
    _listStackedItems.Clear();

    // Sort items by X position, then Y
    foreach (var item in Items.Values
        .OrderBy(i => MathF.Round(i.PosOnCanvas.X))
        .ThenBy(i => i.PosOnCanvas.Y))
    {
        item.VerticalStackArea = item.Area;

        if (previousItem == null)
        {
            _listStackedItems.Clear();
            _listStackedItems.Add(item);
            previousItem = item;
            continue;
        }

        // Check if stacked (same X, close Y)
        if (!(Math.Abs(item.PosOnCanvas.X - previousItem.PosOnCanvas.X) < 10f)
            || !(Math.Abs(item.PosOnCanvas.Y - previousItem.Area.Max.Y) < 180f))
        {
            ApplyStackToItems();  // Finalize current stack
        }

        _listStackedItems.Add(item);
        previousItem = item;
    }

    ApplyStackToItems();  // Handle last stack

    void ApplyStackToItems()
    {
        if (_listStackedItems.Count > 1)
        {
            var stackArea = new ImRect(_listStackedItems[0].PosOnCanvas,
                                       _listStackedItems[^1].Area.Max);
            foreach (var x in _listStackedItems)
            {
                x.VerticalStackArea = stackArea;
            }
        }
        _listStackedItems.Clear();
    }
}
```

This information helps connection rendering avoid overlapping with stacked operators.

---

## Flagging Changes

To trigger a layout refresh, call:

```csharp
context.Layout.FlagStructureAsChanged();
```

This sets `StructureFlaggedAsChanged = true`, causing refresh on the next frame:

```csharp
public void FlagStructureAsChanged()
{
    StructureFlaggedAsChanged = true;
}
```

Common places that flag changes:
- After creating/deleting operators
- After creating/deleting connections
- After drag operations complete
- After undo/redo

---

## Hash-Based Change Detection

For composition navigation, a simple hash detects changes:

```csharp
private static bool HasCompositionDataChanged(Symbol composition, ref int originalHash)
{
    var newHash = composition.Id.GetHashCode();

    if (newHash == originalHash)
        return false;

    originalHash = newHash;
    return true;
}

private int _compositionModelHash;
```

This triggers a full refresh when navigating to a different composition.

---

## Performance Considerations

The layout is designed for efficiency:

1. **Incremental Updates** - Only recompute when necessary
2. **Cycle Counter** - Detect obsolete items without allocations
3. **Pre-sized Collections** - Minimize reallocations
4. **Static Scratch Lists** - Reuse temporary lists
5. **Inline Methods** - `[MethodImpl(MethodImplOptions.AggressiveInlining)]` for hot paths

```csharp
// Example of aggressive inlining for hash computation:
[MethodImpl(MethodImplOptions.AggressiveInlining)]
private static int GetConnectionSourceHash(Symbol.Connection c)
{
    var hash = c.SourceSlotId.GetHashCode();
    hash = hash * 31 + c.SourceParentOrChildId.GetHashCode();
    return hash;
}
```

---

## Next Steps

- **[Model Annotations](06-model-annotations.md)** - Annotation data model
- **[State Machine](07-state-machine.md)** - How layout updates trigger state changes
- **[Performance](18-performance.md)** - Deep dive into optimization strategies
