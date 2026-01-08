# Chapter 10: Connection Interaction - Wiring Nodes

> *Drag from output, drop on input - but what happens in between?*

---

## The Challenge: Flexible Connection Workflows

Users want multiple ways to wire nodes:

- **Direct:** Click output, drag to input, release
- **Reverse:** Click input, search for the operator you want to connect
- **Rip and rewire:** Grab an existing wire, drag it to a new target
- **Insert:** Drop a new node onto an existing wire to splice it in
- **Hidden slots:** Access inputs that aren't visible by default

Each workflow has its own state transitions, preview rendering, and edge cases. The connection interaction layer coordinates all of this, working with the state machine to handle each mode correctly.

**Key Source Files:**

- [InputSnapper.cs](../../../Editor/Gui/MagGraph/Interaction/InputSnapper.cs) - Finding inputs to connect to
- [OutputSnapper.cs](../../../Editor/Gui/MagGraph/Interaction/OutputSnapper.cs) - Finding outputs to connect from
- [InputPicking.cs](../../../Editor/Gui/MagGraph/Interaction/InputPicking.cs) - Selecting hidden inputs
- [OutputPicking.cs](../../../Editor/Gui/MagGraph/Interaction/OutputPicking.cs) - Selecting hidden outputs
- [ConnectionHovering.cs](../../../Editor/Gui/MagGraph/Interaction/ConnectionHovering.cs) - Detecting hover on wires

---

## Connection Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Connection Interaction Workflows                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  NEW CONNECTION (from output):                                           │
│  ┌────────────┐                                                         │
│  │ Click on   │──► HoldOutput ──► DragConnectionEnd ──► [destination]   │
│  │ output     │                                                         │
│  └────────────┘                                                         │
│                                                                          │
│  NEW CONNECTION (from input):                                            │
│  ┌────────────┐                                                         │
│  │ Click on   │──► HoldInput ──► Opens Placeholder (search for source)  │
│  │ input      │                                                         │
│  └────────────┘                                                         │
│                                                                          │
│  RIPPING FROM TARGET:                                                    │
│  ┌────────────┐                                                         │
│  │ Drag from  │──► HoldingConnectionEnd ──► DragConnectionEnd           │
│  │ wire (near │          │                                              │
│  │ target)    │    (click = insert)                                     │
│  └────────────┘                                                         │
│                                                                          │
│  RIPPING FROM SOURCE:                                                    │
│  ┌────────────┐                                                         │
│  │ Drag from  │──► HoldingConnectionBeginning ──► DragConnectionBeginning│
│  │ wire (near │          │                                              │
│  │ source)    │    (click = insert)                                     │
│  └────────────┘                                                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Temporary Connections

During drag operations, temporary connections are created:

```csharp
// Creating a temp connection when dragging from output
var tempConnection = new MagGraphConnection
{
    Style = MagGraphConnection.ConnectionStyles.Unknown,
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

Temp connections are stored in `context.TempConnections` and rendered separately from layout connections.

---

## Connection Hovering

The `ConnectionHovering` class tracks which connections are under the mouse:

```csharp
internal sealed class ConnectionHovering
{
    internal readonly List<ConnectionHover> ConnectionHovers = [];
    internal readonly List<ConnectionHover> ConnectionHoversWhenClicked = [];

    internal void Update(GraphUiContext context)
    {
        ConnectionHovers.Clear();

        foreach (var connection in context.Layout.MagConnections)
        {
            if (connection.IsSnapped)
                continue;  // Can't hover snapped connections

            var distance = DistanceToConnection(connection, mousePos);
            if (distance < HoverThreshold)
            {
                ConnectionHovers.Add(new ConnectionHover(connection, distance, position));
            }
        }

        // Sort by distance
        ConnectionHovers.Sort((a, b) => a.Distance.CompareTo(b.Distance));
    }

    internal void CaptureClickedHovers()
    {
        ConnectionHoversWhenClicked.Clear();
        ConnectionHoversWhenClicked.AddRange(ConnectionHovers);
    }
}
```

---

## Dragging Connection End

The `DragConnectionEnd` state handles dragging a connection to find a target:

```csharp
internal static State<GraphUiContext> DragConnectionEnd = new(
    Enter: _ => { },
    Update: context => {
        // Escape to cancel
        if (ImGui.IsKeyDown(ImGuiKey.Escape))
        {
            context.StateMachine.SetState(Default, context);
            return;
        }

        // Track mouse position for connection preview
        var posOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
        context.PeekAnchorInCanvas = posOnCanvas;

        // Wait for mouse release
        if (!ImGui.IsMouseReleased(ImGuiMouseButton.Left))
            return;

        // Try snap reconnection first
        if (InputSnapper.TryToReconnect(context))
        {
            context.Layout.FlagStructureAsChanged();
            context.CompleteMacroCommand();
            context.StateMachine.SetState(Default, context);
            return;
        }

        // Check if dropped on an item
        if (InputPicking.TryInitializeAtPosition(context, posOnCanvas))
        {
            context.StateMachine.SetState(PickInput, context);
        }
        // Check for disconnection (ripped wire)
        else if (context.TempConnections.Any(c => c.WasDisconnected))
        {
            context.CompleteMacroCommand();
            context.StateMachine.SetState(Default, context);
        }
        // Open placeholder browser
        else
        {
            context.Placeholder.OpenOnCanvas(context, posOnCanvas, context.DraggedPrimaryOutputType);
            context.StateMachine.SetState(Placeholder, context);
        }
    },
    Exit: _ => { }
);
```

---

## InputSnapper - Finding Target Inputs

`InputSnapper` handles finding and connecting to inputs when dropping a connection:

```csharp
internal static class InputSnapper
{
    internal static bool TryToReconnect(GraphUiContext context)
    {
        if (context.TempConnections.Count == 0)
            return false;

        foreach (var item in context.Layout.Items.Values)
        {
            // Skip the source item
            if (item == context.ActiveSourceItem)
                continue;

            // Check each input anchor
            for (var i = 0; i < item.GetInputAnchorCount(); i++)
            {
                MagGraphItem.InputAnchorPoint anchor = default;
                item.GetInputAnchorAtIndex(i, ref anchor);

                // Check distance to mouse
                var distance = Vector2.Distance(anchor.PositionOnCanvas, context.PeekAnchorInCanvas);
                if (distance > SnapThreshold)
                    continue;

                // Check type compatibility
                if (!IsTypeCompatible(context.DraggedPrimaryOutputType, anchor.ConnectionType))
                    continue;

                // Check if anchor is free or can accept connection
                if (anchor.SnappedConnectionHash != MagGraphItem.FreeAnchor)
                    continue;

                // Create the connection
                CreateConnection(context, item, anchor);
                return true;
            }
        }

        return false;
    }
}
```

---

## OutputSnapper - Finding Source Outputs

`OutputSnapper` handles finding outputs when dragging a connection backward:

```csharp
internal static class OutputSnapper
{
    internal static bool TryToReconnect(GraphUiContext context)
    {
        if (context.TempConnections.Count == 0)
            return false;

        var tempConnection = context.TempConnections[0];
        var targetItem = tempConnection.TargetItem;
        var targetInput = tempConnection.TargetInput;

        foreach (var item in context.Layout.Items.Values)
        {
            // Skip the target item
            if (item == targetItem)
                continue;

            // Check each output anchor
            for (var i = 0; i < item.GetOutputAnchorCount(); i++)
            {
                MagGraphItem.OutputAnchorPoint anchor = default;
                item.GetOutputAnchorAtIndex(i, ref anchor);

                var distance = Vector2.Distance(anchor.PositionOnCanvas, context.PeekAnchorInCanvas);
                if (distance > SnapThreshold)
                    continue;

                // Check type compatibility
                if (anchor.ConnectionType != targetInput.ValueType)
                    continue;

                // Check for cycles
                if (Structure.CheckForCycle(item.Instance, targetItem.Id))
                    continue;

                // Create the connection
                CreateConnection(context, item, anchor, targetItem, targetInput);
                return true;
            }
        }

        return false;
    }
}
```

---

## Input Picking

When dropping on an item with multiple hidden inputs, a picker UI appears:

```csharp
internal static class InputPicking
{
    internal static bool TryInitializeAtPosition(GraphUiContext context, Vector2 posOnCanvas)
    {
        // Find item at position
        foreach (var item in context.Layout.Items.Values)
        {
            if (!item.Area.Contains(posOnCanvas))
                continue;

            // Get hidden inputs of matching type
            var hiddenInputs = GetHiddenInputsOfType(item, context.DraggedPrimaryOutputType);
            if (hiddenInputs.Count == 0)
                continue;

            context.ItemForInputSelection = item;
            _hiddenInputs = hiddenInputs;
            return true;
        }

        return false;
    }

    internal static void Init(GraphUiContext context)
    {
        // Initialize picker state
    }

    internal static void DrawHiddenInputSelector(GraphUiContext context)
    {
        // Draw the input picker UI (cables.gl inspired)
        var item = context.ItemForInputSelection;
        var pos = context.View.TransformPosition(item.PosOnCanvas);

        ImGui.SetNextWindowPos(pos);
        if (ImGui.BeginPopup("InputPicker"))
        {
            foreach (var input in _hiddenInputs)
            {
                if (ImGui.Selectable(input.Name))
                {
                    // Create connection to selected input
                    CreateConnectionToInput(context, item, input);
                    context.StateMachine.SetState(Default, context);
                }
            }
            ImGui.EndPopup();
        }
    }

    internal static void Reset(GraphUiContext context)
    {
        context.ItemForInputSelection = null;
        _hiddenInputs.Clear();
    }
}
```

---

## Ripping Connections

### From the Target End

When clicking on a connection near the target (input) end:

```csharp
internal static State<GraphUiContext> HoldingConnectionEnd = new(
    Enter: _ => { },
    Update: context => {
        // Click = open placeholder to insert
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
        {
            context.Placeholder.OpenToSplitHoveredConnections(context);
            return;
        }

        // Drag = rip connection
        if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
        {
            var connection = context.ConnectionHovering.ConnectionHoversWhenClicked[0].Connection;

            // Start macro command
            context.StartMacroCommand("Reconnect from input")
                   .AddAndExecCommand(new DeleteConnectionCommand(...));

            // Handle line collapse if needed
            if (MagItemMovement.DisconnectedInputWouldCollapseLine(connection))
            {
                MagItemMovement.MoveSnappedItemsVertically(...);
            }

            // Create temp connection
            var tempConnection = new MagGraphConnection
            {
                IsTemporary = true,
                WasDisconnected = true,
                SourceItem = connection.SourceItem,
                SourceOutput = connection.SourceOutput,
                // ... target is null (following mouse)
            };
            context.TempConnections.Add(tempConnection);

            context.StateMachine.SetState(DragConnectionEnd, context);
            context.Layout.FlagStructureAsChanged();
        }
    },
    Exit: _ => { }
);
```

### From the Source End

When clicking near the source (output) end, multiple connections can be ripped:

```csharp
internal static State<GraphUiContext> HoldingConnectionBeginning = new(
    Enter: _ => { },
    Update: context => {
        // Click = insert
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
        {
            context.Placeholder.OpenToSplitHoveredConnections(context);
            return;
        }

        // Drag = rip all connections from this output
        if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
        {
            context.StartMacroCommand("Reconnect from output");

            // Process in reverse order to maintain indices
            foreach (var h in context.ConnectionHovering.ConnectionHoversWhenClicked
                                     .OrderByDescending(h => h.Connection.MultiInputIndex))
            {
                var connection = h.Connection;

                // Keep input visible during drag
                context.DisconnectedInputHashes.Add(connection.GetItemInputHash());

                // Delete the connection
                context.MacroCommand.AddAndExecCommand(
                    new DeleteConnectionCommand(...));

                // Create temp connection (source is null, target is known)
                var tempConnection = new MagGraphConnection
                {
                    IsTemporary = true,
                    WasDisconnected = true,
                    TargetItem = connection.TargetItem,
                    InputLineIndex = connection.InputLineIndex,
                    // ... source is null
                };
                context.TempConnections.Add(tempConnection);
            }

            context.StateMachine.SetState(DragConnectionBeginning, context);
            context.Layout.FlagStructureAsChanged();
        }
    },
    Exit: _ => { }
);
```

---

## Connection Line Collapse

When disconnecting an optional input, the line may collapse:

```csharp
public static bool DisconnectedInputWouldCollapseLine(MagGraphConnection connection)
{
    var inputWasNotPrimary = connection.InputLineIndex > 0;
    if (connection.TargetItem.Variant != MagGraphItem.Variants.Operator)
        return false;

    var inputWasOptional = connection.TargetItem
        .InputLines[connection.InputLineIndex]
        .InputUi.Relevancy == Relevancy.Optional;

    var multiInputConnectionCount = 0;
    foreach (var line in connection.TargetItem.InputLines)
    {
        if (line.InputUi.Id == connection.TargetItem.InputLines[connection.InputLineIndex].Id)
            multiInputConnectionCount++;
    }

    var multiInputHadOtherConnectedMultiInput = multiInputConnectionCount > 1;
    var connectedToLeftInput = connection.Style is
        ConnectionStyles.BottomToLeft or
        ConnectionStyles.RightToLeft or
        ConnectionStyles.MainOutToMainInSnappedHorizontal or
        ConnectionStyles.MainOutToInputSnappedHorizontal;

    return connectedToLeftInput
        && ((inputWasNotPrimary && inputWasOptional) || multiInputHadOtherConnectedMultiInput);
}
```

---

## Type Compatibility

Connection creation checks type compatibility:

```csharp
// Exact type match
if (outputType == inputType)
    return true;

// Polymorphic connections (base class compatibility)
if (inputType.IsAssignableFrom(outputType))
    return true;

return false;
```

---

## Cycle Detection

Before creating any connection, cycles are checked:

```csharp
if (Structure.CheckForCycle(context.CompositionInstance.Symbol, newConnection))
{
    Log.Debug("Sorry, this connection would create a cycle.");
    return;
}
```

---

## Visual Feedback

During connection drag, visual feedback is provided:

1. **Temporary connection wire** - Follows the mouse
2. **Snap indicator** - Highlights when near a valid target
3. **Type color** - Wire uses the data type color
4. **Invalid indicators** - Red overlay on incompatible targets

---

## Next Steps

- **[Interaction Browser](11-interaction-browser.md)** - The operator browser
- **[Rendering Connections](16-rendering-connections.md)** - How wires are drawn
- **[State Machine](07-state-machine.md)** - Connection state transitions
