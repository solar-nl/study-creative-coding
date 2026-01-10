# Chapter 7: State Machine - Interaction Modes

> *Why "am I dragging or connecting?" should never be a question*

## Key Insight

> **State machine's core idea:** At any moment the editor is in exactly one state (Default, DragItems, Placeholder, etc.)—each state has Enter/Update/Exit hooks, and transitions are explicit method calls, eliminating nested boolean flag nightmares.

---

## The Problem: Implicit State is a Nightmare

Picture a node editor without a state machine. You'd have code like:

```csharp
if (isDragging && !isConnecting && !isBrowsing && mouseDown && !textFieldActive)
{
    // Handle drag... maybe?
}
```

Every interaction checks a dozen boolean flags. Add a new feature? Check every flag combination. Bug report about unexpected behavior? Good luck tracing through nested conditionals.

MagGraph takes a different approach: **one state at a time, always explicit**.

At any moment, you're in exactly one state: `Default`, `DragItems`, `Placeholder`, etc. Each state knows what input it handles. Transitions are explicit method calls, not flag flipping. Debugging is straightforward: "What state am I in? What does that state's `Update` method do?"

**Sources:**

- [GraphStates.cs](../../../Editor/Gui/MagGraph/States/GraphStates.cs) (~730 lines) - All state definitions
- [StateMachine.cs](../../../Editor/Gui/UiHelpers/StateMachine.cs) - Generic implementation

---

## State Machine Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                      StateMachine<GraphUiContext>                  │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Current State: [DragItems]                                        │
│  State Time: 0.34 seconds                                          │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                     Active State                              │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐           │ │
│  │  │   Enter()   │→ │  Update()   │→ │   Exit()    │           │ │
│  │  │ (once)      │  │ (every frame│  │ (once)      │           │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘           │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  Transition via: SetState(newState, context)                       │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

---

## State Structure

Each state has three hooks:

```csharp
internal static State<GraphUiContext> Default = new(
    Enter: context => {
        // Called once when entering the state
        // Initialize state-specific data
    },
    Update: context => {
        // Called every frame while state is active
        // Handle input, check for transitions
    },
    Exit: context => {
        // Called once when leaving the state
        // Clean up state-specific data
    }
);
```

---

## All Available States

### Primary States

| State | Description |
|-------|-------------|
| `Default` | Idle, waiting for user input |
| `HoldBackground` | Mouse pressed on empty canvas |
| `Placeholder` | Operator browser is open |

### Item Interaction States

| State | Description |
|-------|-------------|
| `HoldItem` | Mouse pressed on an operator |
| `HoldItemAfterLongTap` | After long-press on item |
| `DragItems` | Dragging operators around |

### Connection States

| State | Description |
|-------|-------------|
| `HoldOutput` | Mouse pressed on output anchor |
| `HoldInput` | Mouse pressed on input anchor |
| `DragConnectionEnd` | Dragging connection to target |
| `DragConnectionBeginning` | Dragging connection from source |
| `HoldingConnectionEnd` | Pressed on connection line (near target) |
| `HoldingConnectionBeginning` | Pressed on connection line (near source) |
| `PickInput` | Selecting from hidden inputs |
| `PickOutput` | Selecting from hidden outputs |

### Annotation States

| State | Description |
|-------|-------------|
| `DragAnnotation` | Moving an annotation frame |
| `ResizeAnnotation` | Resizing an annotation frame |
| `RenameAnnotation` | Editing annotation title |
| `RenameChild` | Renaming an operator |

### Special States

| State | Description |
|-------|-------------|
| `BackgroundContentIsInteractive` | Prevents graph interaction when background has focus |

---

## State Transitions

Transitions are explicit via `SetState`:

```csharp
context.StateMachine.SetState(GraphStates.DragItems, context);
```

### Transition Example: Click on Item

```
┌─────────────────┐     click      ┌─────────────────┐
│     Default     │ ─────────────► │    HoldItem     │
└─────────────────┘                └─────────────────┘
                                           │
                     ┌─────────────────────┼─────────────────────┐
                     │                     │                     │
                     ▼                     ▼                     ▼
              (release)              (drag)               (long tap)
                     │                     │                     │
         ┌──────────────────┐   ┌─────────────────┐   ┌─────────────────────┐
         │     Default      │   │    DragItems    │   │ HoldItemAfterLongTap│
         │(item is selected)│   └─────────────────┘   └─────────────────────┘
         └──────────────────┘           │                       │
                                        │                       │
                                 (release)               (drag starts)
                                        │                       │
                                        ▼                       ▼
                              ┌─────────────────┐     ┌─────────────────┐
                              │     Default     │     │    DragItems    │
                              └─────────────────┘     └─────────────────┘
```

---

## The Default State

The Default state is the resting state that handles most initial interactions:

```csharp
internal static State<GraphUiContext> Default = new(
    Enter: context => {
        // Reset all temporary state
        context.TempConnections.Clear();
        context.ActiveSourceItem = null;
        context.ActiveTargetItem = null;
        context.ActiveTargetInputId = Guid.Empty;
        context.DraggedPrimaryOutputType = null;
        context.Placeholder.Reset(context);
        context.DisconnectedInputHashes.Clear();
    },
    Update: context => {
        // Skip if custom UI is active
        if (context.ItemWithActiveCustomUi != null)
            return;

        // Check for background content focus
        if (context.ProjectView.GraphImageBackground.HasInteractionFocus)
        {
            context.StateMachine.SetState(BackgroundContentIsInteractive, context);
            return;
        }

        // Keyboard shortcuts (Tab to create operator)
        if (context.View.IsFocused && context.View.IsHovered && !ImGui.IsAnyItemActive())
        {
            if (ImGui.IsKeyReleased(ImGuiKey.Tab))
            {
                // Open placeholder at mouse position or connected to selection
                context.StateMachine.SetState(Placeholder, context);
            }
        }

        // Navigation shortcuts
        if (UserActions.CloseOperator.Triggered())
            ProjectView.Focused?.TrySetCompositionOpToParent();

        if (UserActions.OpenOperator.Triggered())
        {
            // Enter selected/hovered operator
        }

        // Mouse click handling
        if (ImGui.IsMouseClicked(ImGuiMouseButton.Left))
        {
            // Double-click navigation
            if (ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left))
            {
                // Navigate into/out of composition
            }

            // Route to appropriate hold state
            if (context.ActiveSourceItem != null)
                context.StateMachine.SetState(HoldOutput, context);
            else if (context.ActiveTargetItem != null)
                context.StateMachine.SetState(HoldInput, context);
            else if (context.ActiveItem != null)
                context.StateMachine.SetState(HoldItem, context);
            else
                context.StateMachine.SetState(HoldBackground, context);
        }
    },
    Exit: _ => { }
);
```

---

## Hold States

Hold states wait for either a release (click) or drag:

### HoldItem

```csharp
internal static State<GraphUiContext> HoldItem = new(
    Enter: context => {
        var item = context.ActiveItem;
        var selector = context.Selector;

        // Prepare drag - either selection or snapped group
        if (selector.IsSelected(item))
            context.ItemMovement.SetDraggedItems(selector.Selection);
        else
            context.ItemMovement.SetDraggedItemIdsToSnappedForItem(item);
    },
    Update: context => {
        // Release = click (select item)
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
        {
            MagItemMovement.SelectActiveItem(context);
            context.ItemMovement.Reset();
            context.StateMachine.SetState(Default, context);
            return;
        }

        // Start dragging
        if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
        {
            context.StateMachine.SetState(DragItems, context);
            return;
        }

        // Long tap detection
        const float longTapDuration = 0.3f;
        var longTapProgress = context.StateMachine.StateTime / longTapDuration;
        MagItemMovement.UpdateLongPressIndicator(longTapProgress);

        if (longTapProgress > 1)
        {
            MagItemMovement.SelectActiveItem(context);
            context.ItemMovement.SetDraggedItemIds([context.ActiveItem.Id]);
            context.StateMachine.SetState(HoldItemAfterLongTap, context);
        }
    },
    Exit: _ => { }
);
```

### HoldBackground

```csharp
internal static State<GraphUiContext> HoldBackground = new(
    Enter: _ => { },
    Update: context => {
        // Cancel if released or dragged
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left)
            || !context.View.IsFocused
            || ImGui.IsMouseDragging(ImGuiMouseButton.Left))
        {
            context.StateMachine.SetState(Default, context);
            return;
        }

        // Long tap progress indicator
        const float longTapDuration = 0.3f;
        var longTapProgress = context.StateMachine.StateTime / longTapDuration;
        MagItemMovement.UpdateLongPressIndicator(longTapProgress);

        // Long tap completed - open placeholder
        if (longTapProgress > 1)
        {
            context.StateMachine.SetState(Placeholder, context);
            var posOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
            context.Placeholder.OpenOnCanvas(context, posOnCanvas);
        }
    },
    Exit: _ => { }
);
```

---

## Drag States

### DragItems

```csharp
internal static State<GraphUiContext> DragItems = new(
    Enter: context => {
        context.ItemMovement.PrepareDragInteraction();
        context.ItemMovement.StartDragOperation(context);
    },
    Update: context => {
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
        {
            context.ItemMovement.CompleteDragOperation(context);
            context.StateMachine.SetState(Default, context);
            return;
        }

        context.ItemMovement.UpdateDragging(context);
    },
    Exit: context => {
        context.ItemMovement.StopDragOperation();
    }
);
```

### DragConnectionEnd

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
        if (context.StateMachine.StateTime > 0 && ImGui.IsMouseReleased(ImGuiMouseButton.Left))
        {
            // Try to reconnect to snapped position
            if (InputSnapper.TryToReconnect(context))
            {
                context.Layout.FlagStructureAsChanged();
                context.CompleteMacroCommand();
                context.StateMachine.SetState(Default, context);
                return;
            }

            // Check if dropped on an item (show input picker)
            if (InputPicking.TryInitializeAtPosition(context, posOnCanvas))
            {
                context.StateMachine.SetState(PickInput, context);
            }
            // Dropped on empty space - open placeholder
            else if (!context.TempConnections.Any(c => c.WasDisconnected))
            {
                context.Placeholder.OpenOnCanvas(context, posOnCanvas, context.DraggedPrimaryOutputType);
                context.StateMachine.SetState(Placeholder, context);
            }
            else
            {
                // Was a disconnect - just complete
                context.CompleteMacroCommand();
                context.StateMachine.SetState(Default, context);
            }
        }
    },
    Exit: _ => { }
);
```

---

## The Placeholder State

The Placeholder state manages the operator browser:

```csharp
internal static State<GraphUiContext> Placeholder = new(
    Enter: _ => { },
    Update: context => {
        // Wait for placeholder to be dismissed
        if (context.Placeholder.PlaceholderItem != null)
            return;

        context.Placeholder.Cancel(context);
        context.StateMachine.SetState(Default, context);
    },
    Exit: _ => { }
);
```

The actual browser UI is handled by `PlaceholderCreation`, not the state itself.

---

## State Time

The state machine tracks how long the current state has been active:

```csharp
// In StateMachine<T>:
public float StateTime { get; private set; }

public void Update(T context)
{
    StateTime += ImGui.GetIO().DeltaTime;
    _currentState?.UpdateAction?.Invoke(context);
}
```

This is used for:
- Long tap detection (`StateTime / longTapDuration`)
- Delayed transitions (e.g., wait a frame before checking mouse release)

---

## Connection Manipulation States

### HoldingConnectionEnd (Ripping from target)

```csharp
internal static State<GraphUiContext> HoldingConnectionEnd = new(
    Enter: _ => { },
    Update: context => {
        // Click = split connection (insert operator)
        if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
        {
            context.Placeholder.OpenToSplitHoveredConnections(context);
            return;
        }

        // Drag = rip connection from target
        if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
        {
            var connection = context.ConnectionHovering.ConnectionHoversWhenClicked[0].Connection;

            // Start macro for undo
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
                // ...
            };
            context.TempConnections.Add(tempConnection);
            context.StateMachine.SetState(DragConnectionEnd, context);
            context.Layout.FlagStructureAsChanged();
        }
    },
    Exit: _ => { }
);
```

### HoldingConnectionBeginning (Ripping from source)

Similar to `HoldingConnectionEnd`, but handles multiple connections and removes them all:

```csharp
// Can rip multiple connections from the same output
foreach (var h in context.ConnectionHovering.ConnectionHoversWhenClicked
                         .OrderByDescending(h => h.Connection.MultiInputIndex))
{
    context.DisconnectedInputHashes.Add(connection.GetItemInputHash());
    context.MacroCommand!.AddAndExecCommand(new DeleteConnectionCommand(...));

    var tempConnection = new MagGraphConnection { /* ... */ };
    context.TempConnections.Add(tempConnection);
}
context.StateMachine.SetState(DragConnectionBeginning, context);
```

---

## Picker States

### PickInput

When dropping a connection on an operator with hidden inputs:

```csharp
internal static State<GraphUiContext> PickInput = new(
    Enter: InputPicking.Init,
    Update: InputPicking.DrawHiddenInputSelector,
    Exit: InputPicking.Reset
);
```

### PickOutput

When connecting from an operator with multiple outputs:

```csharp
internal static State<GraphUiContext> PickOutput = new(
    Enter: OutputPicking.Init,
    Update: _ => { },  // TODO: Not fully implemented
    Exit: OutputPicking.Reset
);
```

---

## State Machine Initialization

The state machine is created with a list of all states:

```csharp
// In GraphUiContext constructor:
StateMachine = new StateMachine<GraphUiContext>(
    typeof(GraphStates),
    GraphStates.Default
);
```

This allows reflection-based discovery of all states for debugging.

---

## Debugging States

You can add debug visualization:

```csharp
// Example debug output in any state:
Update: context => {
    if (context.View.ShowDebug)
    {
        ImGui.GetForegroundDrawList().AddText(
            new Vector2(10, 30),
            Color.Yellow,
            $"State: DragItems, Time: {context.StateMachine.StateTime:F2}s"
        );
    }
    // ...
}
```

---

## Next Steps

- **[Context](08-context.md)** - The shared state container
- **[Interaction Movement](09-interaction-movement.md)** - Drag and snap details
- **[Interaction Connections](10-interaction-connections.md)** - Connection manipulation
