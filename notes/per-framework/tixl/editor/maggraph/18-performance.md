# Chapter 18: Performance - Optimization Strategies

> *Staying smooth at 60fps with 500 operators*

---

## The Problem: Node Editors Get Slow

You've probably used node editors that choke on large graphs. The graph fills up with operators, and suddenly everything lags. Dragging a node stutters. Zooming feels sluggish. The UI thread is overwhelmed.

This happens because most node editors recalculate everything every frame. 500 operators × 4 inputs each × 60 fps = 120,000 input checks per second. And that's before connection routing, hit testing, or rendering.

MagGraph avoids this fate through several strategies:

- **Lazy layout** - Only recompute when structure actually changes
- **Visibility culling** - Don't process off-screen elements
- **Cycle counters** - Detect stale items without expensive list operations
- **Pre-sized collections** - Avoid allocation spikes
- **Aggressive inlining** - Eliminate function call overhead on hot paths

The result: smooth performance even with complex compositions.

---

## Lazy Layout Computation

The layout is only recomputed when necessary:

```csharp
public void ComputeLayout(GraphUiContext context, bool forceUpdate = false)
{
    // Only refresh on structural changes
    if (forceUpdate || FrameStats.Last.UndoRedoTriggered || StructureFlaggedAsChanged ||
        HasCompositionDataChanged(compositionOp.Symbol, ref _compositionModelHash))
    {
        RefreshDataStructure(context, parentSymbolUi);
    }

    // These are fast and always run
    UpdateConnectionLayout();
    ComputeVerticalStackBoundaries(context.View);
}
```

`★ Insight ─────────────────────────────────────`
The `StructureFlaggedAsChanged` pattern is a manual dirty flag that avoids expensive hash computation every frame. Code that modifies the graph explicitly calls `FlagStructureAsChanged()` when needed.
`─────────────────────────────────────────────────`

---

## Cycle Counter Pattern

Instead of clearing and rebuilding collections, a cycle counter detects stale entries:

```csharp
private int _structureUpdateCycle;

private void CollectItemReferences(Instance compositionOp, SymbolUi compositionSymbolUi)
{
    _structureUpdateCycle++;  // Increment each refresh
    var addedItemCount = 0;
    var updatedItemCount = 0;

    foreach (var (childId, childInstance) in compositionOp.Children)
    {
        if (Items.TryGetValue(childId, out var opItem))
        {
            // Existing item - mark as current
            opItem.LastUpdateCycle = _structureUpdateCycle;
            updatedItemCount++;
        }
        else
        {
            // New item - create and add
            opItem = new MagGraphItem { /* ... */ };
            Items[childId] = opItem;
            addedItemCount++;
        }
    }

    // Remove stale items (not touched this cycle)
    var hasObsoleteItems = Items.Count > updatedItemCount + addedItemCount;
    if (hasObsoleteItems)
    {
        foreach (var item in Items.Values)
        {
            if (item.LastUpdateCycle < _structureUpdateCycle)
            {
                Items.Remove(item.Id);
                item.Variant = MagGraphItem.Variants.Obsolete;
            }
        }
    }
}
```

`★ Insight ─────────────────────────────────────`
This pattern avoids creating temporary `HashSet<Guid>` collections to track what should be removed. The cycle counter is an integer comparison, which is extremely fast.
`─────────────────────────────────────────────────`

---

## Pre-Sized Collections

Collections are initialized with expected capacities:

```csharp
internal sealed class MagGraphLayout
{
    // Initial capacities based on typical graph sizes
    public readonly Dictionary<Guid, MagGraphItem> Items = new(127);
    public readonly List<MagGraphConnection> MagConnections = new(127);
    public readonly Dictionary<Guid, MagGraphAnnotation> Annotations = new(63);
}
```

And capacities are maintained during updates:

```csharp
private void CollectConnectionReferences(Instance composition)
{
    MagConnections.Clear();
    MagConnections.Capacity = composition.Symbol.Connections.Count;
    // ...
}
```

---

## Visibility Culling

Only visible elements are rendered:

```csharp
private void DrawNodes(ImDrawListPtr drawList)
{
    foreach (var item in _context.Layout.Items.Values)
    {
        // Skip if not visible on screen
        if (!IsVisible(item.Area))
            continue;

        // Skip collapsed items
        if (item.IsCollapsedAway)
            continue;

        DrawNode(drawList, item);
    }
}

private bool IsVisible(ImRect rect)
{
    var windowSize = ImGui.GetWindowSize();
    var viewRect = new ImRect(
        InverseTransformPositionFloat(WindowPos),
        InverseTransformPositionFloat(WindowPos + windowSize)
    );

    return viewRect.Overlaps(rect);
}
```

---

## Aggressive Inlining

Hot path methods use aggressive inlining:

```csharp
[MethodImpl(MethodImplOptions.AggressiveInlining)]
private static int GetConnectionSourceHash(Symbol.Connection c)
{
    var hash = c.SourceSlotId.GetHashCode();
    hash = hash * 31 + c.SourceParentOrChildId.GetHashCode();
    return hash;
}

[MethodImpl(MethodImplOptions.AggressiveInlining)]
public static int GetItemInputHash(Guid itemId, Guid inputId, int multiInputIndex)
{
    return itemId.GetHashCode() * 31 + inputId.GetHashCode() * 31 + multiInputIndex;
}
```

`★ Insight ─────────────────────────────────────`
The `AggressiveInlining` attribute hints to the JIT compiler to inline these methods. The hash multiplier 31 is a prime number commonly used for hash combining - it provides good distribution and can be optimized by the compiler to `(x << 5) - x`.
`─────────────────────────────────────────────────`

---

## Struct Usage

Performance-critical data uses structs to avoid heap allocations:

```csharp
public struct InputLine
{
    public Type Type;
    public Guid Id;
    public ISlot Input;
    public IInputUi InputUi;
    public int VisibleIndex;
    public MagGraphConnection? ConnectionIn;
    public int MultiInputIndex;
    public InputLineStates ConnectionState;
}

public struct InputAnchorPoint
{
    public Vector2 PositionOnCanvas;
    public Directions Direction;
    public Type ConnectionType;
    public int SnappedConnectionHash;
    public Guid SlotId;
    public InputLine InputLine;
}
```

And accessed by reference to avoid copying:

```csharp
// Use 'ref' to avoid struct copies
for (var i = 0; i < item.InputLines.Length; i++)
{
    ref var inputLine = ref item.InputLines[i];  // ← ref avoids copy
    // Use inputLine...
}
```

---

## Static Scratch Collections

Temporary collections are reused via static fields:

```csharp
// Reused list for vertical stack computation
private static readonly List<MagGraphItem> _listStackedItems = new(32);

private void ComputeVerticalStackBoundaries(ScalableCanvas canvas)
{
    _listStackedItems.Clear();  // Clear, don't reallocate

    foreach (var item in Items.Values.OrderBy(...))
    {
        _listStackedItems.Add(item);
        // ...
    }

    _listStackedItems.Clear();
}
```

---

## Connection Layout Optimization

Connection style is determined without complex logic:

```csharp
private void UpdateConnectionLayout()
{
    foreach (var sc in MagConnections)
    {
        var sourceMax = sc.SourceItem.PosOnCanvas + sc.SourceItem.Size;
        var targetMin = sc.TargetItem.PosOnCanvas;

        // Fast position comparison for snapped detection
        if (MathF.Abs(sourceMax.X - targetMin.X) < 1
            && MathF.Abs((sourceMin.Y + sc.VisibleOutputIndex * GridSize.Y)
                        - (targetMin.Y + sc.InputLineIndex * GridSize.Y)) < 1)
        {
            sc.Style = ConnectionStyles.MainOutToMainInSnappedHorizontal;
            // Snapped = no curve to draw
            continue;
        }

        // Not snapped - will need to draw curve
        sc.Style = ConnectionStyles.RightToLeft;
    }
}
```

---

## Damping Efficiency

Position damping uses simple lerp:

```csharp
private void SmoothPositions()
{
    const float dampAmount = 0.33f;

    foreach (var item in _context.Layout.Items.Values)
    {
        // Vector2.Lerp is highly optimized
        item.DampedPosOnCanvas = Vector2.Lerp(
            item.PosOnCanvas,
            item.DampedPosOnCanvas,
            dampAmount
        );
    }
}
```

---

## Hash-Based Change Detection

Simple hash comparison for navigation changes:

```csharp
private static bool HasCompositionDataChanged(Symbol composition, ref int originalHash)
{
    var newHash = composition.Id.GetHashCode();

    if (newHash == originalHash)
        return false;  // Common case: no change

    originalHash = newHash;
    return true;
}
```

---

## Profiling Tips

When investigating performance issues:

```csharp
// Debug timing
#if DEBUG
private Stopwatch _sw = new();

private void ComputeLayout(...)
{
    _sw.Restart();
    RefreshDataStructure(...);
    var structureTime = _sw.ElapsedMilliseconds;

    _sw.Restart();
    UpdateConnectionLayout();
    var connectionTime = _sw.ElapsedMilliseconds;

    if (structureTime + connectionTime > 16)
    {
        Log.Warning($"Layout took {structureTime + connectionTime}ms");
    }
}
#endif
```

---

## Memory Considerations

- **Items dictionary**: ~127 entries × ~200 bytes = ~25KB typical
- **Connections list**: ~127 entries × ~100 bytes = ~12KB typical
- **InputLines/OutputLines**: Stored in arrays, not lists (no overhead)
- **Damped positions**: Extra Vector2 per item (~8 bytes)

Total memory for a typical 100-operator graph: ~50-100KB

---

## Next Steps

- **[Undo Redo](19-undo-redo.md)** - Command pattern implementation
- **[Model Layout](05-model-layout.md)** - Layout computation details
- **[Extending MagGraph](20-extending-maggraph.md)** - Adding new features
