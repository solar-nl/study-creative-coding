# Chapter 19: Undo/Redo - The Command Pattern

> *One action = one Ctrl+Z, even when that action does five things*

---

## The Problem: Users Expect Undo to Just Work

You drag a node onto an existing wire. Internally, that operation requires: (1) break the existing connection, (2) create connection to the new node's input, (3) create connection from the new node's output, (4) update the node position. Four separate changes.

If the user presses Ctrl+Z, what should happen? Four separate undos? That would be confusing. The user did one action - "insert here" - so undo should reverse it completely, in one step.

The Command Pattern solves this. Each atomic change is a command. Complex operations group commands into `MacroCommand`s. The undo stack sees one entry, containing all four changes. Ctrl+Z reverses everything at once.

**Key Source Files:**

- [MacroCommand.cs](../../../Editor/UiModel/Commands/MacroCommand.cs) - Groups multiple commands
- [AddConnectionCommand.cs](../../../Editor/UiModel/Commands/Graph/AddConnectionCommand.cs)
- [DeleteConnectionCommand.cs](../../../Editor/UiModel/Commands/Graph/DeleteConnectionCommand.cs)
- [ModifyCanvasElementsCommand.cs](../../../Editor/UiModel/Commands/Graph/ModifyCanvasElementsCommand.cs)

---

## Command Interface

All commands implement `ICommand`:

```csharp
public interface ICommand
{
    string Name { get; }
    bool IsDone { get; }

    void Do();
    void Undo();
}
```

---

## The Undo/Redo Stack

```csharp
public static class UndoRedoStack
{
    private static readonly List<ICommand> _undoStack = new();
    private static readonly List<ICommand> _redoStack = new();

    public static void Add(ICommand command)
    {
        _undoStack.Add(command);
        _redoStack.Clear();  // New action clears redo history
    }

    public static void AddAndExecute(ICommand command)
    {
        command.Do();
        Add(command);
    }

    public static void Undo()
    {
        if (_undoStack.Count == 0)
            return;

        var command = _undoStack[^1];
        _undoStack.RemoveAt(_undoStack.Count - 1);

        command.Undo();
        _redoStack.Add(command);
    }

    public static void Redo()
    {
        if (_redoStack.Count == 0)
            return;

        var command = _redoStack[^1];
        _redoStack.RemoveAt(_redoStack.Count - 1);

        command.Do();
        _undoStack.Add(command);
    }
}
```

---

## MacroCommand - Grouping Operations

Complex operations use `MacroCommand` to group multiple commands:

```csharp
public class MacroCommand : ICommand
{
    private readonly List<ICommand> _commands = new();

    public string Name { get; }
    public bool IsDone { get; private set; }

    public MacroCommand(string name)
    {
        Name = name;
    }

    public void AddAndExecCommand(ICommand command)
    {
        command.Do();
        _commands.Add(command);
    }

    public void AddExecutedCommandForUndo(ICommand command)
    {
        // Command already executed, just track for undo
        _commands.Add(command);
    }

    public void Do()
    {
        foreach (var command in _commands)
        {
            command.Do();
        }
        IsDone = true;
    }

    public void Undo()
    {
        // Undo in reverse order
        for (var i = _commands.Count - 1; i >= 0; i--)
        {
            _commands[i].Undo();
        }
        IsDone = false;
    }
}
```

`★ Insight ─────────────────────────────────────`
Commands are undone in reverse order because later operations may depend on earlier ones. For example, if you add a connection then move the target, undoing must first undo the move, then remove the connection.
`─────────────────────────────────────────────────`

---

## Using MacroCommand in MagGraph

The `GraphUiContext` provides helpers for macro commands:

```csharp
internal MacroCommand? MacroCommand { get; private set; }

internal MacroCommand StartMacroCommand(string title)
{
    Debug.Assert(MacroCommand == null);
    MacroCommand = new MacroCommand(title);
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

### Example: Move and Reconnect

```csharp
// Start a macro for the entire drag operation
var macroCommand = context.StartMacroCommand("Move and Reconnect");

// Track position changes
context.MoveElementsCommand = new ModifyCanvasElementsCommand(...);
macroCommand.AddExecutedCommandForUndo(context.MoveElementsCommand);

// If unsnapping breaks a connection
macroCommand.AddAndExecCommand(new DeleteConnectionCommand(...));

// If snapping creates a new connection
macroCommand.AddAndExecCommand(new AddConnectionCommand(...));

// Move additional items to close gap
var moveCommand = new ModifyCanvasElementsCommand(...);
macroCommand.AddExecutedCommandForUndo(moveCommand);

// Finalize
context.MoveElementsCommand.StoreCurrentValues();
moveCommand.StoreCurrentValues();
context.CompleteMacroCommand();
```

---

## Connection Commands

### AddConnectionCommand

```csharp
public class AddConnectionCommand : ICommand
{
    private readonly Symbol _symbol;
    private readonly Symbol.Connection _connection;
    private readonly int _multiInputIndex;

    public string Name => "Add Connection";
    public bool IsDone { get; private set; }

    public AddConnectionCommand(Symbol symbol, Symbol.Connection connection, int multiInputIndex)
    {
        _symbol = symbol;
        _connection = connection;
        _multiInputIndex = multiInputIndex;
    }

    public void Do()
    {
        _symbol.AddConnection(_connection, _multiInputIndex);
        IsDone = true;
    }

    public void Undo()
    {
        _symbol.RemoveConnection(_connection, _multiInputIndex);
        IsDone = false;
    }
}
```

### DeleteConnectionCommand

```csharp
public class DeleteConnectionCommand : ICommand
{
    private readonly Symbol _symbol;
    private readonly Symbol.Connection _connection;
    private readonly int _multiInputIndex;

    public string Name => "Delete Connection";
    public bool IsDone { get; private set; }

    public DeleteConnectionCommand(Symbol symbol, Symbol.Connection connection, int multiInputIndex)
    {
        _symbol = symbol;
        _connection = connection;
        _multiInputIndex = multiInputIndex;
    }

    public void Do()
    {
        _symbol.RemoveConnection(_connection, _multiInputIndex);
        IsDone = true;
    }

    public void Undo()
    {
        _symbol.AddConnection(_connection, _multiInputIndex);
        IsDone = false;
    }
}
```

---

## Position Commands

### ModifyCanvasElementsCommand

This command handles position changes with before/after snapshots:

```csharp
public class ModifyCanvasElementsCommand : ICommand
{
    private readonly Guid _symbolId;
    private readonly List<ElementState> _originalStates;
    private readonly List<ElementState> _newStates;
    private readonly NodeSelection _selection;

    public string Name => "Move Elements";
    public bool IsDone { get; private set; }

    public ModifyCanvasElementsCommand(Guid symbolId,
        List<ISelectableCanvasObject> elements, NodeSelection selection)
    {
        _symbolId = symbolId;
        _selection = selection;

        // Capture original positions
        _originalStates = elements.Select(e => new ElementState
        {
            Id = e.Id,
            Position = e.PosOnCanvas,
            Size = e is Annotation a ? a.Size : Vector2.Zero
        }).ToList();

        _newStates = new List<ElementState>(_originalStates.Count);
    }

    public void StoreCurrentValues()
    {
        // Capture current positions as "new" state
        _newStates.Clear();
        foreach (var original in _originalStates)
        {
            if (TryGetElement(original.Id, out var element))
            {
                _newStates.Add(new ElementState
                {
                    Id = original.Id,
                    Position = element.PosOnCanvas,
                    Size = element is Annotation a ? a.Size : Vector2.Zero
                });
            }
        }
    }

    public void Do()
    {
        ApplyStates(_newStates);
        IsDone = true;
    }

    public void Undo()
    {
        ApplyStates(_originalStates);
        IsDone = false;
    }

    private void ApplyStates(List<ElementState> states)
    {
        foreach (var state in states)
        {
            if (TryGetElement(state.Id, out var element))
            {
                element.PosOnCanvas = state.Position;
                if (element is Annotation annotation)
                {
                    annotation.Size = state.Size;
                }
            }
        }
    }

    private record ElementState
    {
        public Guid Id;
        public Vector2 Position;
        public Vector2 Size;
    }
}
```

`★ Insight ─────────────────────────────────────`
The `StoreCurrentValues()` method is called when dragging completes. This captures the final positions after all snapping and adjustment. The command stores both before and after states, allowing Do/Undo to simply swap between them.
`─────────────────────────────────────────────────`

---

## Continuous Updates During Drag

During drag operations, positions are updated continuously:

```csharp
internal void UpdateDragging(GraphUiContext context)
{
    // Move items to new positions
    foreach (var item in DraggedItems)
    {
        item.PosOnCanvas = newPosition;
    }

    // The MoveElementsCommand was created at drag start
    // It will capture final positions when drag completes
}

internal void CompleteDragOperation(GraphUiContext context)
{
    // Capture final positions
    context.MoveElementsCommand?.StoreCurrentValues();

    // Add to undo stack
    context.CompleteMacroCommand();
}
```

---

## Symbol Child Commands

### AddSymbolChildCommand

```csharp
public class AddSymbolChildCommand : ICommand
{
    private readonly Symbol _parentSymbol;
    private readonly Guid _childSymbolId;
    private readonly Vector2 _position;

    public Guid AddedChildId { get; private set; }
    public string Name => "Add Operator";
    public bool IsDone { get; private set; }

    public void Do()
    {
        var child = _parentSymbol.AddChild(_childSymbolId, _position);
        AddedChildId = child.Id;
        IsDone = true;
    }

    public void Undo()
    {
        _parentSymbol.RemoveChild(AddedChildId);
        IsDone = false;
    }
}
```

### DeleteSymbolChildCommand

```csharp
public class DeleteSymbolChildCommand : ICommand
{
    private readonly Symbol _parentSymbol;
    private readonly Guid _childId;
    private Symbol.Child? _deletedChild;
    private SymbolUi.Child? _deletedChildUi;
    private List<Symbol.Connection> _deletedConnections;

    public string Name => "Delete Operator";
    public bool IsDone { get; private set; }

    public void Do()
    {
        // Store for undo
        _deletedChild = _parentSymbol.Children[_childId];
        _deletedChildUi = _parentSymbol.GetSymbolUi().ChildUis[_childId];
        _deletedConnections = _parentSymbol.Connections
            .Where(c => c.SourceParentOrChildId == _childId || c.TargetParentOrChildId == _childId)
            .ToList();

        // Remove connections first
        foreach (var connection in _deletedConnections)
        {
            _parentSymbol.RemoveConnection(connection, 0);
        }

        // Remove the child
        _parentSymbol.RemoveChild(_childId);
        IsDone = true;
    }

    public void Undo()
    {
        // Restore child
        _parentSymbol.RestoreChild(_deletedChild, _deletedChildUi);

        // Restore connections
        foreach (var connection in _deletedConnections)
        {
            _parentSymbol.AddConnection(connection, 0);
        }

        IsDone = false;
    }
}
```

---

## Best Practices

1. **Always use commands for modifications** - Never modify Symbol directly
2. **Group related operations** - Use MacroCommand for multi-step actions
3. **Capture state early** - Store original values before any changes
4. **Store final values late** - Call StoreCurrentValues after all changes
5. **Handle cancellation** - Use CancelMacroCommand to revert incomplete operations

---

## Next Steps

- **[Extending MagGraph](20-extending-maggraph.md)** - Adding new features
- **[Context](08-context.md)** - MacroCommand integration in context
- **[Interaction Movement](09-interaction-movement.md)** - Commands during drag
