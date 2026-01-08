# Chapter 9: Item Movement - Drag, Snap, and Insert

> *Making nodes "want" to connect to each other*

---

## The Magic: Nodes That Snap Together

Drag a node near another node's output. Release. They connect. No cable dragging, no precise targeting - just proximity. That's the "magnetic" behavior that makes MagGraph distinctive.

But making this feel good requires solving several problems:

1. **When should things snap?** Too eager feels jumpy; too reluctant feels broken.
2. **What happens to connections?** Snapping creates them; unsnapping breaks them.
3. **What about groups?** Drag one node, and snapped neighbors follow.
4. **How do you insert?** Drag over an existing wire, and the node splices in.
5. **How do you disconnect?** Shake a node to break free.

`MagItemMovement` handles all of this. At ~1500 lines, it's the largest file in MagGraph - because this behavior is the core of the user experience.

**Sources:**

- [MagItemMovement.cs](../../../Editor/Gui/MagGraph/Interaction/MagItemMovement.cs) (~1500 lines)
- [MagItemMovement.Snapping.cs](../../../Editor/Gui/MagGraph/Interaction/MagItemMovement.Snapping.cs) (~240 lines)

---

## The Drag Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Drag Lifecycle                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. SetDraggedItems()           ─── Select items to drag                │
│          │                                                               │
│          ▼                                                               │
│  2. StartDragOperation()        ─── Initialize undo command             │
│          │                           Collect border connections          │
│          │                           Init splice links                   │
│          │                           Init primary output                 │
│          ▼                                                               │
│  3. UpdateDragging() [per frame]                                        │
│          │                                                               │
│          ├── HandleShakeDisconnect() ─── Detect shake gesture           │
│          │                                                               │
│          ├── HandleSnappedDragging() ─── Move items, find snaps         │
│          │                                                               │
│          ├── HandleUnsnapAndCollapse() ─── Break connections            │
│          │                                                               │
│          └── TryCreateNewConnectionFromSnap() ─── Make new connections  │
│                  or                                                      │
│              TrySplitInsert() ─── Insert into existing connection       │
│          ▼                                                               │
│  4. CompleteDragOperation()     ─── Finalize undo command               │
│          │                                                               │
│          ▼                                                               │
│  5. StopDragOperation()         ─── Clear state                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Selecting What to Drag

When a drag starts, items are selected in one of two ways:

### Drag Selection

If the clicked item is part of the selection:

```csharp
internal void SetDraggedItems(List<ISelectableCanvasObject> selection)
{
    DraggedItems.Clear();
    foreach (var s in selection)
    {
        if (_layout.Items.TryGetValue(s.Id, out var i))
        {
            DraggedItems.Add(i);
        }
    }
}
```

### Drag Snapped Group

If the clicked item is **not** selected, drag its entire snapped group:

```csharp
internal void SetDraggedItemIdsToSnappedForItem(MagGraphItem item)
{
    DraggedItems.Clear();
    CollectSnappedItems(item, DraggedItems);
}
```

### Collecting Snapped Items

This is a **flood-fill** through snapped connections:

```csharp
public static HashSet<MagGraphItem> CollectSnappedItems(MagGraphItem rootItem,
    HashSet<MagGraphItem>? set = null,
    bool includeRoot = true,
    int ignoreConnectionHash = 0)
{
    set ??= [];

    void Collect(MagGraphItem item)
    {
        if (!set.Add(item))
            return;

        // Follow snapped input connections
        for (var index = 0; index < item.InputLines.Length; index++)
        {
            var c = item.InputLines[index].ConnectionIn;
            if (c == null || c.ConnectionHash == ignoreConnectionHash)
                continue;

            if (c.IsSnapped && !c.IsTemporary)
                Collect(c.SourceItem);
        }

        // Follow snapped output connections
        for (var index = 0; index < item.OutputLines.Length; index++)
        {
            var connections = item.OutputLines[index].ConnectionsOut;
            foreach (var c in connections)
            {
                if (c.ConnectionHash != ignoreConnectionHash && c.IsSnapped)
                    Collect(c.TargetItem);
            }
        }
    }

    Collect(rootItem);
    if (!includeRoot)
        set.Remove(rootItem);

    return set;
}
```

---

## The Snapping System

### Snapping Class

The `Snapping` helper class tracks the best snap candidate:

```csharp
private sealed class Snapping
{
    public float BestDistance;
    public MagGraphItem? TargetItem;
    public MagGraphItem? SourceItem;
    public MagGraphItem.Directions Direction;
    public int InputLineIndex;
    public int MultiInputIndex;
    public int OutLineIndex;
    public Vector2 OutAnchorPos;
    public Vector2 InputAnchorPos;
    public bool Reverse;
    public bool IsSnapped => BestDistance < MagGraphItem.LineHeight * (IsInsertion ? 0.35 : 0.5f);
    public bool IsInsertion;
    public SpliceLink? InsertionPoint;
}
```

### Testing for Snaps

Each frame, we test all overlapping items for potential snaps:

```csharp
public void TestItemsForSnap(MagGraphItem outputItem, MagGraphItem inputItem,
    bool revert, MagGraphView view)
{
    for (var bInputLineIndex = 0; bInputLineIndex < inputItem.InputLines.Length; bInputLineIndex++)
    {
        ref var bInputLine = ref inputItem.InputLines[bInputLineIndex];

        for (var aOutLineIndex = 0; aOutLineIndex < outputItem.OutputLines.Length; aOutLineIndex++)
        {
            ref var outputLine = ref outputItem.OutputLines[aOutLineIndex];

            // Type must match
            if (bInputLine.Type != outputLine.Output.ValueType)
                continue;

            // Vertical snap (primary output to primary input)
            if (aOutLineIndex == 0 && bInputLineIndex == 0)
            {
                TestAndKeepPositionsForSnapping(
                    ref outputLine, 0,
                    MagGraphItem.Directions.Vertical,
                    new Vector2(outputItem.Area.Min.X + MagGraphItem.WidthHalf,
                               outputItem.Area.Max.Y),
                    new Vector2(inputItem.Area.Min.X + MagGraphItem.WidthHalf,
                               inputItem.Area.Min.Y)
                );
            }

            // Horizontal snap (any matching types)
            if (outputLine.Output.ValueType == bInputLine.Input.ValueType)
            {
                TestAndKeepPositionsForSnapping(
                    ref outputLine,
                    bInputLine.MultiInputIndex,
                    MagGraphItem.Directions.Horizontal,
                    new Vector2(outputItem.Area.Max.X,
                               outputItem.Area.Min.Y + (0.5f + outputLine.VisibleIndex) * LineHeight),
                    new Vector2(inputItem.Area.Min.X,
                               inputItem.Area.Min.Y + (0.5f + bInputLine.VisibleIndex) * LineHeight)
                );
            }
        }
    }
}
```

### Snap Distance Threshold

```csharp
public bool IsSnapped => BestDistance < MagGraphItem.LineHeight * (IsInsertion ? 0.35 : 0.5f);
```

- Regular snaps: within 17.5 pixels (half a line height)
- Insertion snaps: within 12.25 pixels (tighter tolerance)

---

## Handling the Drag

### Main Update Loop

```csharp
internal void UpdateDragging(GraphUiContext context)
{
    // 1. Check for shake disconnect gesture
    if (!T3Ui.IsCurrentlySaving && _shakeDetector.TestDragForShake(ImGui.GetMousePos()))
    {
        _shakeDetector.ResetShaking();
        if (HandleShakeDisconnect(context))
        {
            _layout.FlagStructureAsChanged();
            return;
        }
    }

    // 2. Handle the main dragging logic
    var snappingChanged = HandleSnappedDragging(context);
    if (!snappingChanged)
        return;

    _layout.FlagStructureAsChanged();

    // 3. Handle breaking connections when unsnapping
    HandleUnsnapAndCollapse(context);

    // 4. Create new connections if snapped
    if (!_snapping.IsSnapped)
        return;

    if (_snapping.IsInsertion)
    {
        TrySplitInsert(context);
    }
    else
    {
        TryCreateNewConnectionFromSnap(context);
    }
}
```

### Snapped Dragging Details

```csharp
private bool HandleSnappedDragging(GraphUiContext context)
{
    var mousePosOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    var requestedDeltaOnCanvas = mousePosOnCanvas - _dragStartPosInOpOnCanvas;

    // Find overlapping items
    var dragExtend = MagGraphItem.GetItemsBounds(DraggedItems);
    dragExtend.Expand(SnapThreshold * context.View.Scale.X);

    var overlappingItems = new List<MagGraphItem>();
    foreach (var otherItem in _layout.Items.Values)
    {
        if (DraggedItems.Contains(otherItem) || !dragExtend.Overlaps(otherItem.Area))
            continue;
        overlappingItems.Add(otherItem);
    }

    // Move items to requested position
    foreach (var n in DraggedItems)
    {
        n.PosOnCanvas -= _lastAppliedOffset;
        n.PosOnCanvas += requestedDeltaOnCanvas;
    }
    _lastAppliedOffset = requestedDeltaOnCanvas;

    // Reset snap detection
    _snapping.Reset();

    // Test for insertion snaps
    foreach (var ip in SpliceSets)
    {
        var insertionAnchorItem = DraggedItems.FirstOrDefault(i => i.Id == ip.InputItemId);
        if (insertionAnchorItem == null) continue;

        foreach (var otherItem in overlappingItems)
        {
            _snapping.TestItemsForInsertion(otherItem, insertionAnchorItem, ip, _view);
        }
    }

    // Test for regular snaps
    foreach (var otherItem in overlappingItems)
    {
        foreach (var draggedItem in DraggedItems)
        {
            _snapping.TestItemsForSnap(otherItem, draggedItem, false, _view);
            _snapping.TestItemsForSnap(draggedItem, otherItem, true, _view);
        }
    }

    // Apply snap offset if snapped
    if (_snapping.IsSnapped)
    {
        var bestSnapDelta = _snapping.Reverse
            ? _snapping.InputAnchorPos - _snapping.OutAnchorPos
            : _snapping.OutAnchorPos - _snapping.InputAnchorPos;

        foreach (var n in DraggedItems)
        {
            n.PosOnCanvas += bestSnapDelta;
        }
        _lastAppliedOffset += bestSnapDelta;
    }

    return _snapping.IsSnapped != _wasSnapped || snapPositionChanged;
}
```

---

## Creating Connections on Snap

When items snap together, connections are automatically created:

```csharp
private void TryCreateNewConnectionFromSnap(GraphUiContext context)
{
    if (!_snapping.IsSnapped) return;

    var newConnections = new List<PotentialConnection>();

    foreach (var draggedItem in DraggedItems)
    {
        foreach (var otherItem in _layout.Items.Values)
        {
            if (DraggedItems.Contains(otherItem)) continue;

            GetPotentialConnectionsAfterSnap(ref newConnections, draggedItem, otherItem);
            GetPotentialConnectionsAfterSnap(ref newConnections, otherItem, draggedItem);
        }
    }

    foreach (var potentialConnection in newConnections)
    {
        // Check for cycles
        if (Structure.CheckForCycle(context.CompositionInstance.Symbol, newConnection))
        {
            Log.Debug("Sorry, this connection would create a cycle.");
            continue;
        }

        // Create the connection
        context.MacroCommand.AddAndExecCommand(
            new AddConnectionCommand(context.CompositionInstance.Symbol,
                                     newConnection,
                                     potentialConnection.InputLine.MultiInputIndex)
        );
    }
}
```

---

## Insertion (Splicing)

Inserting items into existing connections requires:

### SpliceLink

A `SpliceLink` describes how dragged items could split a connection:

```csharp
internal sealed record SpliceLink(
    Guid InputItemId,       // Item that would receive input
    Guid InputId,           // Input slot ID
    Guid OutputItemId,      // Item that would provide output
    Guid OutputId,          // Output slot ID
    MagGraphItem.Directions Direction,
    Type Type,
    float Distance,         // Width of the dragged items
    Vector2 DragPositionWithinBlock,  // Mouse offset within block
    Vector2 AnchorOffset
);
```

### Testing for Insertion

```csharp
public void TestItemsForInsertion(MagGraphItem inputItem,
    MagGraphItem insertionAnchorItem,
    SpliceLink insertionPoint,
    MagGraphView view)
{
    if (inputItem.InputLines.Length < 1)
        return;

    var mainInputLine = inputItem.InputLines[0];
    var mainInputConnectionIn = mainInputLine.ConnectionIn;

    if (mainInputConnectionIn != null && mainInputLine.Type == insertionPoint.Type)
    {
        // Test vertical insertion
        if (mainInputConnectionIn.Style == ConnectionStyles.MainOutToMainInSnappedVertical
            && insertionPoint.Direction == MagGraphItem.Directions.Vertical)
        {
            // Calculate snap distance and update if better
        }

        // Test horizontal insertion
        if (mainInputConnectionIn.Style == ConnectionStyles.MainOutToMainInSnappedHorizontal
            && insertionPoint.Direction == MagGraphItem.Directions.Horizontal)
        {
            // Calculate snap distance and update if better
        }
    }
}
```

### Performing the Insertion

```csharp
private static bool TrySplitInsert(GraphUiContext context)
{
    var connection = _snapping.TargetItem.InputLines[_snapping.InputLineIndex].ConnectionIn;
    var spliceLink = _snapping.InsertionPoint;

    // Check for cycles in both directions
    if (Structure.CheckForCycle(connection.SourceItem.Instance, spliceLink.InputItemId))
        return false;
    if (Structure.CheckForCycle(connection.TargetItem.Instance, spliceLink.OutputItemId))
        return false;

    // 1. Delete original connection
    context.MacroCommand.AddAndExecCommand(
        new DeleteConnectionCommand(context.CompositionInstance.Symbol,
                                    connection.AsSymbolConnection(), 0));

    // 2. Connect original source to inserted item
    context.MacroCommand.AddAndExecCommand(
        new AddConnectionCommand(context.CompositionInstance.Symbol,
            new Symbol.Connection(connection.SourceItem.Id,
                                 connection.SourceOutput.Id,
                                 spliceLink.InputItemId,
                                 spliceLink.InputId), 0));

    // 3. Connect inserted item to original target
    context.MacroCommand.AddAndExecCommand(
        new AddConnectionCommand(context.CompositionInstance.Symbol,
            new Symbol.Connection(spliceLink.OutputItemId,
                                 spliceLink.OutputId,
                                 connection.TargetItem.Id,
                                 connection.TargetInput.Id), 0));

    // 4. Move surrounding items to make room
    if (spliceLink.Direction == MagGraphItem.Directions.Vertical)
    {
        MoveSnappedItemsVertically(context, ...);
    }
    else
    {
        // Horizontal insertion moves left and right groups
    }

    return true;
}
```

---

## Unsnapping and Collapsing

When items are dragged away from a snapped position:

```csharp
private void HandleUnsnapAndCollapse(GraphUiContext context)
{
    var unsnappedConnections = new List<MagGraphConnection>();

    foreach (var mc in _layout.MagConnections)
    {
        if (!IsBorderConnection(mc, DraggedItems))
            continue;

        // Delete the connection
        context.MacroCommand.AddAndExecCommand(
            new DeleteConnectionCommand(context.CompositionInstance.Symbol,
                                        mc.AsSymbolConnection(),
                                        mc.MultiInputIndex));
        mc.IsTemporary = true;
        unsnappedConnections.Add(mc);
    }

    // Try to collapse vertical gaps
    if (TryCollapseDragFromVerticalStack(context, unsnappedConnections))
        return;

    // Try to collapse horizontal gaps
    if (TryCollapseDragFromHorizontalStack(context, unsnappedConnections))
        return;

    // Collapse disconnected optional inputs
    TryCollapseDisconnectedInputs(context, unsnappedConnections);
}
```

### Collapsing Vertical Gaps

When dragging items from a vertical stack, the gap is closed:

```csharp
private bool TryCollapseDragFromVerticalStack(GraphUiContext context,
    List<MagGraphConnection> unsnappedConnections)
{
    var pairs = FindVerticalCollapsableConnectionPairs(unsnappedConnections);

    if (pairs.Count != 1)
        return false;

    var pair = pairs[0];

    // Check for cycles
    if (Structure.CheckForCycle(pair.Ca.SourceItem.Instance, pair.Cb.TargetItem.Id))
        return false;

    var potentialMovers = CollectSnappedItems(pair.Cb.TargetItem);
    var movableItems = MoveToCollapseVerticalGaps(pair.Ca, pair.Cb, potentialMovers, true);

    if (movableItems.Count == 0)
        return false;

    // Create move command
    var newMoveCommand = new ModifyCanvasElementsCommand(...);
    context.MacroCommand.AddExecutedCommandForUndo(newMoveCommand);

    // Apply the movement
    MoveToCollapseVerticalGaps(pair.Ca, pair.Cb, movableItems, false);
    newMoveCommand.StoreCurrentValues();

    // Create new connection to close the gap
    context.MacroCommand.AddAndExecCommand(
        new AddConnectionCommand(context.CompositionInstance.Symbol,
            new Symbol.Connection(pair.Ca.SourceItem.Id,
                                 pair.Ca.SourceOutput.Id,
                                 pair.Cb.TargetItem.Id,
                                 pair.Cb.TargetInput.Id), 0));

    return true;
}
```

---

## Shake to Disconnect

A shake gesture disconnects all border connections:

```csharp
private bool HandleShakeDisconnect(GraphUiContext context)
{
    if (_connectionsToDraggedItems.Count == 0)
        return false;

    NodeActions.DisconnectDraggedNodes(
        context.CompositionInstance,
        DraggedItems.Select(i => i.Selectable).ToList()
    );

    _layout.FlagStructureAsChanged();
    return true;
}
```

---

## Long Press Indicator

Visual feedback during long press:

```csharp
internal static void UpdateLongPressIndicator(float longTapProgress)
{
    var dl = ImGui.GetWindowDrawList();
    dl.AddCircle(
        ImGui.GetMousePos(),
        100 * (1 - longTapProgress),
        Color.White.Fade(MathF.Pow(longTapProgress, 3))
    );
}
```

---

## Horizontal Alignment Snapping

Items can also snap to align with other items (not creating connections):

```csharp
private void HandleHorizontalAlignmentSnapping(GraphUiContext context)
{
    if (!UserSettings.Config.EnableHorizontalSnapping)
        return;

    // Collect visible items in bounds
    _visibleItemsForSnapping.Clear();
    foreach (var snapTo in context.Layout.Items.Values)
    {
        if (bounds.Overlaps(snapTo.Bounds))
            _visibleItemsForSnapping.Add(snapTo);
    }

    // Check for X alignment snap
    if (_snapHandlerX.TryCheckForSnapping(newDragPosInCanvas.X, out var snappedXValue,
                                          context.View.Scale.X * snapFactor,
                                          DraggedItems,
                                          _visibleItemsForSnapping))
    {
        var snapDelta = snappedXValue - newDragPosInCanvas.X;
        var offset = new Vector2((float)snapDelta, 0);

        foreach (var n in DraggedItems)
        {
            n.PosOnCanvas += offset;
        }
        _lastAppliedOffset += offset;
    }
}
```

---

## Next Steps

- **[Interaction Connections](10-interaction-connections.md)** - Dragging connection wires
- **[Interaction Browser](11-interaction-browser.md)** - The operator browser
- **[State Machine](07-state-machine.md)** - How movement integrates with states
