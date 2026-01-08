# Chapter 8: GraphUiContext - The Shared State Hub

> *The "where do I find X?" answer: probably in the context*

---

## The Problem: Passing Parameters Everywhere

Imagine you're deep in the snapping logic and need to know:

- What item is being dragged?
- What's the current state?
- Where are the temporary connections?
- How do I access the layout?

You could pass each as a separate parameter. But that gets unwieldy fast - some methods would need 10+ parameters. And when you need access to something new, you'd have to update every call site.

`GraphUiContext` is the solution: **one object that holds everything relevant to the current graph session**. Pass it once, access whatever you need.

It's intentionally a "fat" object - it knows about the view, the layout, the state machine, active items, temporary connections, undo commands, and dialogs. This trades a bit of encapsulation for massive convenience.

**Source:** [GraphUiContext.cs](../../../Editor/Gui/MagGraph/States/GraphUiContext.cs) (~260 lines)

---

## The Design: One Object to Rule Them All

The context follows the **"God Object for a Scope"** pattern:

```
┌─────────────────────────────────────────────────────────────────┐
│                       GraphUiContext                             │
│                  (Scoped to one composition)                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Core References                                                 │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                 │
│  │ ProjectView│  │ MagGraphView│ │ MagGraphLayout│               │
│  │ (project)  │  │ (canvas)    │ │ (model)      │               │
│  └────────────┘  └────────────┘  └────────────┘                 │
│                                                                  │
│  Interaction Handlers                                            │
│  ┌────────────┐  ┌────────────┐  ┌────────────────┐             │
│  │ItemMovement│  │ Placeholder │ │ConnectionHover │             │
│  │ (drag)     │  │ (browser)   │ │(line hover)    │             │
│  └────────────┘  └────────────┘  └────────────────┘             │
│                                                                  │
│  State Machine                                                   │
│  ┌──────────────────────────────────────────────────────┐       │
│  │ StateMachine<GraphUiContext>                          │       │
│  │ Current: [Default | HoldItem | DragItems | ...]       │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                  │
│  Active Elements (set during interaction)                        │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                 │
│  │ ActiveItem │  │HoveredItem │  │ TempConns  │                 │
│  │ (clicked)  │  │ (mouse)    │  │ (dragging) │                 │
│  └────────────┘  └────────────┘  └────────────┘                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Context Lifecycle

A new context is created when:
- The composition changes (navigating into/out of operators)
- The window changes

```csharp
internal GraphUiContext(ProjectView projectView, MagGraphView view)
{
    ProjectView = projectView;
    View = view;
    ItemMovement = new MagItemMovement(this, view, Layout, projectView.NodeSelection);
    Placeholder = new PlaceholderCreation();
    StateMachine = new StateMachine<GraphUiContext>(typeof(GraphStates), GraphStates.Default);
}
```

---

## Core References

### ProjectView

Access to the project-level state:

```csharp
internal readonly ProjectView ProjectView;

// Convenience accessors
internal Instance CompositionInstance => ProjectView.CompositionInstance!;
internal NodeSelection Selector => ProjectView.NodeSelection;
```

### View and Layout

```csharp
internal readonly MagGraphView View;      // Canvas rendering and transforms
internal readonly MagGraphLayout Layout = new();  // Cached view model
```

### State Machine

```csharp
internal readonly StateMachine<GraphUiContext> StateMachine;
```

---

## Interaction Handlers

### ItemMovement

Handles dragging, snapping, and inserting operators:

```csharp
internal readonly MagItemMovement ItemMovement;
```

### Placeholder

Manages the operator browser:

```csharp
internal readonly PlaceholderCreation Placeholder;
```

### ConnectionHovering

Tracks connection line hover state:

```csharp
internal readonly ConnectionHovering ConnectionHovering = new();
```

---

## Active Elements

These properties track what the user is interacting with:

### Item Activation

```csharp
/** Set when clicking on a node. Cleared at start of each Default state frame. */
internal MagGraphItem? ActiveItem { get; set; }

/** The item currently under the mouse cursor */
internal MagGraphItem? HoveredItem { get; set; }

/** Item with custom UI taking focus (parameter widgets) */
internal MagGraphItem? ItemWithActiveCustomUi { get; set; }
```

### Connection Activation

```csharp
/** Source item when dragging from output */
internal MagGraphItem? ActiveSourceItem;
internal Guid ActiveSourceOutputId { get; set; }
internal MagGraphItem.Directions ActiveOutputDirection { get; set; }

/** Target item when dragging to input */
internal MagGraphItem? ActiveTargetItem;
internal Guid ActiveTargetInputId { get; set; }
internal MagGraphItem.Directions ActiveInputDirection { get; set; }
```

### Annotation Activation

```csharp
internal Guid ActiveAnnotationId { get; set; }
```

### Temporary State

```csharp
/** Temporary connections being dragged */
internal readonly List<MagGraphConnection> TempConnections = [];

/** Keep disconnected inputs visible during drag */
internal readonly HashSet<int> DisconnectedInputHashes = [];

/** Type being dragged (for type filtering) */
internal Type? DraggedPrimaryOutputType;

/** Mouse position in canvas space during connection drag */
internal Vector2 PeekAnchorInCanvas;
internal bool ShouldAttemptToSnapToInput;
```

---

## Helper Methods

### Getting Active Lines

```csharp
internal bool TryGetActiveOutputLine(out MagGraphItem.OutputLine outputLine)
{
    if (ActiveSourceItem == null || ActiveSourceItem.OutputLines.Length == 0)
    {
        outputLine = default;
        return false;
    }

    foreach (var l in ActiveSourceItem.OutputLines)
    {
        if (l.Id != ActiveSourceOutputId)
            continue;

        outputLine = l;
        return true;
    }
    outputLine = default;
    return false;
}

internal bool TryGetActiveInputLine(out MagGraphItem.InputLine inputLine)
{
    // Similar implementation for inputs
}
```

### Preventing Interaction

```csharp
internal bool PreventInteraction => ProjectView.GraphImageBackground.HasInteractionFocus;

/** Used for fading out graph on left edge */
internal float GraphOpacity = 1;
```

---

## Undo/Redo Integration

### MacroCommand Pattern

The context manages grouped undo operations via `MacroCommand`:

```csharp
internal MacroCommand? MacroCommand { get; private set; }

internal MacroCommand StartMacroCommand(string title)
{
    Debug.Assert(MacroCommand == null);
    MacroCommand = new MacroCommand(title);
    return MacroCommand;
}

internal MacroCommand StartOrContinueMacroCommand(string title)
{
    MacroCommand ??= new MacroCommand(title);
    return MacroCommand;
}

internal void CompleteMacroCommand()
{
    Debug.Assert(MacroCommand != null);
    UndoRedoStack.Add(MacroCommand);
    MacroCommand = null;
}

internal void CancelMacroCommand()
{
    Debug.Assert(MacroCommand != null);
    MacroCommand.Undo();
    MacroCommand = null;
}
```

### Usage Pattern

```csharp
// Start a macro for a complex operation
context.StartMacroCommand("Move and Reconnect");

// Add multiple commands to the macro
context.MacroCommand.AddAndExecCommand(new DeleteConnectionCommand(...));
context.MacroCommand.AddAndExecCommand(new AddConnectionCommand(...));
context.MacroCommand.AddAndExecCommand(new ModifyPositionCommand(...));

// Complete (adds to undo stack) or cancel (reverts all)
if (success)
    context.CompleteMacroCommand();
else
    context.CancelMacroCommand();
```

### Move Elements Command

For continuous position updates during drag:

```csharp
/** Keeps position changes for continuous update of dragged items */
internal ModifyCanvasElementsCommand? MoveElementsCommand;
```

---

## Dialogs

The context holds references to various modal dialogs:

```csharp
internal readonly EditCommentDialog EditCommentDialog = new();
internal readonly AddInputDialog AddInputDialog = new();
internal readonly AddOutputDialog AddOutputDialog = new();
internal readonly CombineToSymbolDialog CombineToSymbolDialog = new();
internal readonly DuplicateSymbolDialog DuplicateSymbolDialog = new();
public readonly RenameSymbolDialog RenameSymbolDialog = new();

// Variables for dialog input
internal string SymbolNameForDialogEdits = "";
internal string NameSpaceForDialogEdits = "";
internal string SymbolDescriptionForDialog = "";
```

### Drawing Dialogs

```csharp
public ChangeSymbol.SymbolModificationResults DrawDialogs(ProjectView projectView)
{
    EditCommentDialog.Draw(Selector);
    var results = ChangeSymbol.SymbolModificationResults.Nothing;

    if (projectView.CompositionInstance != null)
    {
        var compositionSymbol = projectView.InstView!.Symbol;

        // Only show edit dialogs for non-root, non-readonly compositions
        if (projectView.CompositionInstance != projectView.RootInstance
            && !compositionSymbol.SymbolPackage.IsReadOnly)
        {
            results |= AddInputDialog.Draw(compositionSymbol);
            results |= AddOutputDialog.Draw(compositionSymbol);
        }

        results |= DuplicateSymbolDialog.Draw(...);
        results |= CombineToSymbolDialog.Draw(...);
        results |= EditTourPointsPopup.Draw(...);
        RenameSymbolDialog.Draw(...);

        if (results != ChangeSymbol.SymbolModificationResults.Nothing)
            Layout.FlagStructureAsChanged();
    }

    return results;
}
```

---

## Input Picking State

For selecting hidden inputs when dropping a connection:

```csharp
/** Only relevant while picking inputs or hovering an op while dragging connection end */
internal MagGraphItem? ItemForInputSelection;
```

---

## Context Usage Pattern

The context is passed to almost every method:

```csharp
// In state update:
Update: context => {
    context.View.DoSomething();
    context.Layout.Items...
    context.ItemMovement.UpdateDragging(context);
}

// In helper methods:
public static void SomeHelper(GraphUiContext context)
{
    var item = context.ActiveItem;
    var layout = context.Layout;
    // ...
}

// In rendering:
public void Draw(GraphUiContext context)
{
    foreach (var item in context.Layout.Items.Values)
    {
        DrawItem(context, item);
    }
}
```

---

## Thread Safety

The context is **not thread-safe**. All access should be from the main UI thread. This is enforced by ImGui's single-threaded nature.

---

## Next Steps

- **[Interaction Movement](09-interaction-movement.md)** - How ItemMovement uses context
- **[Interaction Connections](10-interaction-connections.md)** - Connection handling
- **[Undo Redo](19-undo-redo.md)** - Deep dive into command pattern
