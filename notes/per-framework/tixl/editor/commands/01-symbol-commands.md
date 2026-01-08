# Chapter 1: Symbol Instance Commands

> *One click creates an operator, wires it in, and remembers how to undo it all—that's four database transactions disguised as one.*

**Previous:** [Index](00-index.md) | **Next:** (none yet)

---

## The Problem: Atomic Node Creation in a Multi-Step World

Picture yourself working in a node-based editor. You drag a connection from a Noise generator and drop it on empty canvas. The Symbol Browser opens, you type "blur," and press Enter. In the span of a single click, the editor must:

1. Create a new Blur operator instance
2. Position it on the canvas where you dropped
3. Connect the Noise output to the Blur input
4. Apply any selected preset parameters
5. Update the selection to highlight the new node

That's five distinct operations. But when you press Ctrl+Z, you expect *all* of them to reverse together—not undo the selection, then undo the connection, then undo the node creation across three separate undos. One action should mean one undo.

The naive approach is to just execute these operations in sequence. But that creates a brittle system where partial failures leave the graph in an inconsistent state. What if the connection fails after the node is created? You'd have a dangling operator with no wires.

The solution is to treat node creation like a **database transaction**: group all related operations so they succeed or fail together, and so undo reverses the entire group atomically.

---

## The Mental Model: Database Transactions for Graph Operations

If you've worked with SQL databases, the command system will feel familiar. Every graph modification is encapsulated in a **command object** that knows how to do *and* undo its operation:

```
┌─────────────────────────────────────────────────────────────┐
│                      ICommand Interface                      │
├─────────────────────────────────────────────────────────────┤
│  Do()        Execute the operation                          │
│  Undo()      Reverse the operation                          │
│  Name        Human-readable description ("Add Blur")        │
│  IsUndoable  True if Undo() is supported                    │
└─────────────────────────────────────────────────────────────┘
```

This interface is deceptively simple, but it enables powerful composition. Multiple commands can be grouped into a **MacroCommand** that executes them in sequence:

```
┌───────────────────────────────────────────────────────────────────┐
│                   MacroCommand: "Insert Op Blur"                  │
├───────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐                                         │
│  │ AddSymbolChildCommand│  Create the Blur node                  │
│  └─────────────────────┘                                         │
│  ┌─────────────────────┐                                         │
│  │ AddConnectionCommand │  Wire Noise.output → Blur.input        │
│  └─────────────────────┘                                         │
│  ┌─────────────────────┐                                         │
│  │ AddConnectionCommand │  Wire Blur.output → ColorGrade.input   │
│  └─────────────────────┘                                         │
└───────────────────────────────────────────────────────────────────┘
                              │
                              ▼
          Undo() reverses ALL commands in reverse order
```

When you call `Undo()` on a MacroCommand, it undoes each sub-command in **reverse order**. This is critical—if you created a connection after creating a node, you must delete the connection before deleting the node. The command system handles this automatically.

---

## AddSymbolChildCommand: Creating an Operator Instance

The foundational command for node creation is `AddSymbolChildCommand`. It handles adding a child symbol (operator) to a parent composition.

### What It Stores

The command captures just enough information to recreate or destroy the node:

```csharp
public sealed class AddSymbolChildCommand : ICommand
{
    // Core data - what we need to create/delete the node
    private readonly Guid _parentSymbolId;   // Which composition contains this node
    private readonly Guid _addedSymbolId;    // What type of operator to create
    private readonly Guid _addedChildId;     // Unique ID for this instance

    // UI data - positioning and appearance
    public Vector2 PosOnCanvas { get; set; } = Vector2.Zero;
    public Vector2 Size { get; set; } = SymbolUi.Child.DefaultOpSize;
    public string ChildName { get; set; } = string.Empty;
}
```

Notice that `_addedChildId` is generated in the constructor with `Guid.NewGuid()`. This is important: the command decides the new node's ID upfront, before execution. This allows callers to reference the node immediately after calling `Do()` without waiting for a lookup.

### The Do() Method

Creating a node involves looking up both the parent composition and the symbol type, then delegating to the parent's `AddChild` method:

```csharp
public void Do()
{
    if (!SymbolUiRegistry.TryGetSymbolUi(_parentSymbolId, out var parentSymbolUi))
    {
        Log.Warning($"Could not find symbol with id {_parentSymbolId}");
        return;
    }

    if (!SymbolUiRegistry.TryGetSymbolUi(_addedSymbolId, out var symbolToAdd))
    {
        Log.Warning($"Could not find symbol with id {_addedSymbolId}");
        return;
    }

    parentSymbolUi.AddChild(symbolToAdd.Symbol, _addedChildId, PosOnCanvas, Size, ChildName);
}
```

The `AddChild` call is where the actual work happens—the parent symbol creates a new `SymbolChild` instance, registers it in its children dictionary, and updates both the data model and UI model.

### The Undo() Method

Undoing is simpler—just remove the child by its ID:

```csharp
public void Undo()
{
    if (!SymbolUiRegistry.TryGetSymbolUi(_parentSymbolId, out var parentSymbolUi))
    {
        Log.Warning($"Could not find symbol with id {_parentSymbolId}");
        return;
    }

    parentSymbolUi.RemoveChild(_addedChildId);
}
```

### The AddedChildId Property

Here's where the pre-generated ID pays off. After executing the command, callers can retrieve the new node's ID:

```csharp
public Guid AddedChildId => _addedChildId;
```

This enables code like:

```csharp
var addCommand = new AddSymbolChildCommand(parentSymbol, blur.Id);
addCommand.Do();

// Now we can immediately reference the new node
var newNodeUi = parentSymbolUi.ChildUis[addCommand.AddedChildId];
```

No searching, no waiting—the ID is known from the moment the command is constructed.

---

## AddConnectionCommand: Wiring Nodes Together

Creating a node is only half the story. Most nodes need connections. The `AddConnectionCommand` handles creating a single wire between two slots.

### What It Stores

```csharp
internal sealed class AddConnectionCommand : ICommand
{
    private readonly Guid _compositionSymbolId;        // Parent composition
    private readonly Symbol.Connection _addedConnection;  // Source/target info
    private readonly int _multiInputIndex;             // Position in multi-input list
}
```

The `Symbol.Connection` object contains the full routing information: source node ID, source slot ID, target node ID, and target slot ID. For multi-inputs (slots that accept multiple connections), the index specifies where in the list this connection should be inserted.

### Do() and Undo()

```csharp
public void Do()
{
    if (!SymbolUiRegistry.TryGetSymbolUi(_compositionSymbolId, out var compositionSymbolUi))
        return;

    compositionSymbolUi.Symbol.AddConnection(_addedConnection, _multiInputIndex);
    compositionSymbolUi.FlagAsModified();
}

public void Undo()
{
    if (!SymbolUiRegistry.TryGetSymbolUi(_compositionSymbolId, out var compositionSymbolUi))
        return;

    compositionSymbolUi.Symbol.RemoveConnection(_addedConnection, _multiInputIndex);
    compositionSymbolUi.FlagAsModified();
}
```

The `FlagAsModified()` call is a UI detail—it tells the composition that something changed, triggering redraws and save-state updates.

---

## MacroCommand: Grouping Multiple Operations

When you need multiple operations to undo as one, wrap them in a `MacroCommand`:

```csharp
internal sealed class MacroCommand : ICommand
{
    internal MacroCommand(string name)
    {
        Name = name;
        _commands = new List<ICommand>();
    }

    private readonly List<ICommand> _commands;
}
```

### Building Up Commands

MacroCommand offers two ways to add sub-commands:

**1. AddAndExecCommand** — Add and immediately execute:
```csharp
internal void AddAndExecCommand(ICommand command)
{
    _commands.Add(command);
    command.Do();
}
```

**2. AddExecutedCommandForUndo** — Add a command that was already executed:
```csharp
internal void AddExecutedCommandForUndo(ICommand command)
{
    _commands.Add(command);
}
```

The second method is crucial for the Symbol Browser flow. Commands are executed as soon as they're needed, then collected into a list for undo grouping later.

### Undo in Reverse Order

Here's where it gets interesting. The key insight is in `Undo()`:

```csharp
public void Undo()
{
    var tmpCommands = new List<ICommand>(_commands);
    tmpCommands.Reverse();
    tmpCommands.ForEach(c => c.Undo());
}
```

If you created a connection after creating a node, you must delete the connection first. The reverse order ensures dependencies are respected—you can't remove a node while a connection still references it.

### Checking IsUndoable

A MacroCommand is only undoable if *all* its sub-commands are undoable:

```csharp
public bool IsUndoable => _commands.Aggregate(true, (result, current) => result && current.IsUndoable);
```

One non-undoable command makes the entire group non-undoable. This prevents partial undos that would leave the graph inconsistent.

---

## Instance Creation Flow in SymbolBrowser

Now let's trace how these commands come together when you select an operator from the Symbol Browser.

### The CreateInstance() Method

When you press Enter or click an operator in the results list, `CreateInstance()` orchestrates the entire operation:

```csharp
private void CreateInstance(Symbol symbol)
{
    // Step 1: Prepare the command list
    var commandsForUndo = new List<ICommand>();
    var parentOp = _components.CompositionInstance;
    var parentSymbol = parentOp.Symbol;
    var parentSymbolUi = parentSymbol.GetSymbolUi();

    // Step 2: Create the node
    var addSymbolChildCommand = new AddSymbolChildCommand(parentSymbol, symbol.Id)
    {
        PosOnCanvas = PosOnCanvas  // Position captured when browser opened
    };
    commandsForUndo.Add(addSymbolChildCommand);
    addSymbolChildCommand.Do();

    // ... (rest of the method)
}
```

Notice the pattern: create command, add to list, execute. This "collect as we go" approach means commands can reference each other—the connection command needs to know the new node's ID, which only exists after `addSymbolChildCommand.Do()` runs.

### Retrieving the New Node

After creating the node, we need references to both its UI model and runtime instance:

```csharp
if (!parentSymbolUi.ChildUis.TryGetValue(addSymbolChildCommand.AddedChildId, out var newChildUi))
{
    Log.Warning("Unable to create new operator");
    return;
}

var newSymbolChild = newChildUi.SymbolChild;
var newInstance = _components.CompositionInstance.Children[newChildUi.Id];
```

Here's where `AddedChildId` pays off—we immediately look up the newly created node without scanning.

### Applying Presets

If the user selected a preset via two-part search (e.g., "DrawState blur"), we apply it now:

```csharp
var presetPool = VariationHandling.GetOrLoadVariations(_selectedSymbolUi.Symbol.Id);
if (presetPool != null && _selectedPreset != null)
{
    presetPool.Apply(newInstance, _selectedPreset);
}
```

You might wonder why this uses `_selectedSymbolUi.Symbol.Id` instead of `symbol.Id`. They actually refer to the same symbol—`_selectedSymbolUi` is the UI wrapper around the symbol that was selected in the browser, and `symbol` is the parameter passed to `CreateInstance()`. The code uses `_selectedSymbolUi` here because it's already tracking the selection state and has direct access to the preset pool lookup.

Preset application isn't captured in a command—it modifies the node's parameter values directly. This is a design choice: presets are considered part of node creation, not a separate undoable action.

### Updating Selection

The new node becomes selected, providing visual feedback:

```csharp
_components.NodeSelection.SetSelection(newChildUi, newInstance);
```

---

## Auto-Connection via ConnectionMaker

The real complexity emerges when the Symbol Browser opened from a dropped connection. The `ConnectionMaker` has been holding **temporary connections**—placeholders that say "connect this slot to whatever node gets created."

### TempConnection: The Pending Wire

`TempConnection` is a nested class within `ConnectionMaker` (i.e., `ConnectionMaker.TempConnection`) that extends `Symbol.Connection` with status tracking:

```csharp
public sealed class TempConnection : Symbol.Connection
{
    public readonly Type ConnectionType;  // Required type for matching
    public readonly int MultiInputIndex;  // Position in multi-input list

    public Status GetStatus()
    {
        if (TargetParentOrChildId == UseDraftChildId)
            return Status.TargetIsDraftNode;

        if (SourceParentOrChildId == UseDraftChildId)
            return Status.SourceIsDraftNode;

        // ... other cases
    }

    public enum Status
    {
        NotTemporary,
        SourceIsUndefined,
        SourceIsDraftNode,    // Output from new node
        TargetIsUndefined,
        TargetIsDraftNode,    // Input to new node
        Undefined
    }
}
```

The `UseDraftChildId` sentinel value indicates "this end connects to the node we're about to create." When the browser opened from dragging an output, the temp connection has `TargetIsDraftNode` status—we're connecting *to* the new node's input.

### Processing Temp Connections

After creating the node, `CreateInstance()` iterates through pending connections:

```csharp
var tempConnections = ConnectionMaker.GetTempConnectionsFor(_graphView);

foreach (var c in tempConnections)
{
    switch (c.GetStatus())
    {
        case ConnectionMaker.TempConnection.Status.SourceIsDraftNode:
            // New node is the SOURCE → find its output slot
            var outputDef = newSymbolChild.Symbol.GetOutputMatchingType(c.ConnectionType);
            if (outputDef == null)
            {
                Log.Error("Failed to find matching output connection type " + c.ConnectionType);
                return;
            }

            var newConnection = new Symbol.Connection(
                sourceParentOrChildId: newSymbolChild.Id,
                sourceSlotId: outputDef.Id,
                targetParentOrChildId: c.TargetParentOrChildId,
                targetSlotId: c.TargetSlotId);

            var addCmd = new AddConnectionCommand(parentSymbol, newConnection, c.MultiInputIndex);
            addCmd.Do();
            commandsForUndo.Add(addCmd);
            break;

        case ConnectionMaker.TempConnection.Status.TargetIsDraftNode:
            // New node is the TARGET → find its input slot
            var inputDef = newSymbolChild.Symbol.GetInputMatchingType(c.ConnectionType);
            if (inputDef == null)
            {
                Log.Warning("Failed to complete node creation");
                return;
            }

            var newConnectionToInput = new Symbol.Connection(
                sourceParentOrChildId: c.SourceParentOrChildId,
                sourceSlotId: c.SourceSlotId,
                targetParentOrChildId: newSymbolChild.Id,
                targetSlotId: inputDef.Id);

            var connCmd = new AddConnectionCommand(parentSymbol, newConnectionToInput, 0);
            connCmd.Do();
            commandsForUndo.Add(connCmd);
            break;
    }
}
```

The key insight: `GetOutputMatchingType()` and `GetInputMatchingType()` find the first slot of the new operator that matches the required data type. This is why the Symbol Browser filtered by type—we already know a compatible slot exists.

---

## CompleteOperation: Wrapping It All Up

After all commands are executed and collected, `CompleteOperation()` bundles them into a single undo unit:

```csharp
ConnectionMaker.CompleteOperation(_graphView, commandsForUndo, "Insert Op " + newChildUi.SymbolChild.ReadableName);
```

Inside `ConnectionMaker`:

```csharp
private static void CompleteOperation(ConnectionInProgress inProgress,
                                       List<ICommand>? doneCommands = null,
                                       string? newCommandTitle = null)
{
    var inProgressCommand = inProgress.Command ?? StartOperation(inProgress, "Temp op");

    if (doneCommands != null)
    {
        foreach (var c in doneCommands)
        {
            inProgressCommand.AddExecutedCommandForUndo(c);
        }
    }

    if (!string.IsNullOrEmpty(newCommandTitle))
    {
        inProgressCommand.Name = newCommandTitle;
    }

    UndoRedoStack.Add(inProgressCommand);
    Reset(inProgress);
}
```

The `inProgress.Command` is a MacroCommand that was created when the connection operation started (when you began dragging). All the individual commands are added to it, then the entire macro is pushed to the undo stack.

### The UndoRedoStack

Finally, the bundled command lands in the global undo history:

```csharp
public static void Add(ICommand command)
{
    if (command.IsUndoable)
    {
        UndoStack.Push(command);
        RedoStack.Clear();  // New action invalidates redo history
    }
    else
    {
        Clear();  // Non-undoable action clears all history
    }
}
```

When you press Ctrl+Z, the stack pops the MacroCommand and calls its `Undo()`, which reverses all sub-commands in reverse order.

---

## Code Trace: Full Creation Flow

Let's trace through a complete scenario: dragging from a Noise output and creating a Blur operator.

```
1. User drags from Noise.output (Type: Texture2D)
   └─ ConnectionMaker.StartFromOutputSlot()
      └─ Creates MacroCommand: "Connect from Noise.Output"
      └─ Creates TempConnection:
           Source: Noise.Id / outputSlotId
           Target: NotConnectedId (incomplete)
           Type: Texture2D

2. User drops on empty canvas
   └─ ConnectionMaker.InitSymbolBrowserAtPosition()
      └─ Updates TempConnection:
           Target: UseDraftChildId (will connect to new node)
      └─ Opens SymbolBrowser with inputType: Texture2D

3. User types "blur" and presses Enter
   └─ SymbolBrowser.CreateInstance(Blur.Symbol)

4. CreateInstance() executes:

   a) Create node command
      └─ new AddSymbolChildCommand(parentSymbol, Blur.Id)
      └─ addSymbolChildCommand.Do()
          └─ parentSymbolUi.AddChild(...)
          └─ Blur node now exists with known ID
      └─ commandsForUndo.Add(addSymbolChildCommand)

   b) Look up the new node
      └─ parentSymbolUi.ChildUis[addSymbolChildCommand.AddedChildId]
      └─ Get newChildUi, newSymbolChild, newInstance

   c) Apply preset (if selected)
      └─ presetPool.Apply(newInstance, _selectedPreset)

   d) Update selection
      └─ _components.NodeSelection.SetSelection(newChildUi, newInstance)

   e) Process temp connections
      └─ c.GetStatus() == TargetIsDraftNode
      └─ inputDef = newSymbolChild.Symbol.GetInputMatchingType(Texture2D)
      └─ Create Symbol.Connection:
           Source: Noise.Id / outputSlotId
           Target: newSymbolChild.Id / inputDef.Id
      └─ new AddConnectionCommand(...)
      └─ connectionCommand.Do()
          └─ compositionSymbol.AddConnection(...)
      └─ commandsForUndo.Add(connectionCommand)

   f) Complete operation
      └─ ConnectionMaker.CompleteOperation(commandsForUndo, "Insert Op Blur")
          └─ MacroCommand contains:
               [0] AddSymbolChildCommand
               [1] AddConnectionCommand
          └─ UndoRedoStack.Add(macroCommand)

5. Result:
   ┌───────────┐     ┌───────────┐
   │   Noise   │────▶│   Blur    │  (selected)
   └───────────┘     └───────────┘
                Texture2D

6. User presses Ctrl+Z:
   └─ UndoRedoStack.Undo()
      └─ macroCommand.Undo()
          └─ Reverse order:
               [1] AddConnectionCommand.Undo() → removes wire
               [0] AddSymbolChildCommand.Undo() → removes Blur node
```

Notice how the reverse order is essential—we can't remove the node while a connection still references it.

---

## Integration Points

### NodeSelection.SetSelection()

After creation, the new node becomes selected:

```csharp
_components.NodeSelection.SetSelection(newChildUi, newInstance);
```

This updates the selection state so the node appears highlighted in the graph view. The user immediately sees which node was created.

### ParameterPopUp Activation

The final line before closing the browser:

```csharp
ParameterPopUp.NodeIdRequestedForParameterWindowActivation = newSymbolChild.Id;
```

This tells the parameter popup system to open for the newly created node. If you have parameter windows enabled, they'll immediately show the Blur operator's parameters—ready for adjustment.

---

## Edge Cases and Gotchas

### What Happens When Type Matching Fails?

If `GetInputMatchingType()` or `GetOutputMatchingType()` returns null (no compatible slot found), the operation aborts with a warning:

```csharp
if (outputDef == null)
{
    Log.Error("Failed to find matching output connection type " + c.ConnectionType);
    return;
}
```

This should rarely happen if the Symbol Browser filtered correctly, but defensive coding handles edge cases.

### Override Create Callback

The browser supports a callback for custom creation logic:

```csharp
if (_overrideCreate != null)
{
    Close();
    _overrideCreate(symbol);
    return;
}
```

When set, this bypasses the standard creation flow entirely. It's used for specialized scenarios where standard node creation doesn't apply.

### Connection Abort on Cancel

If you press Escape or click outside the browser, `Cancel()` calls `ConnectionMaker.AbortOperation()`:

```csharp
private static void AbortOperation(ConnectionInProgress inProgress)
{
    inProgress.Command?.Undo();
    Reset(inProgress);
}
```

If any preparatory commands were executed (like deleting existing connections when inserting between nodes), they're undone. The graph returns to its pre-operation state.

---

## Key Source Files

| File | LOC (approx.) | Purpose |
|------|---------------|---------|
| `Editor/UiModel/Commands/Graph/AddSymbolChildCommand.cs` | ~58 | Create operator instance |
| `Editor/UiModel/Commands/Graph/AddConnectionCommand.cs` | ~45 | Create single connection |
| `Editor/UiModel/Commands/MacroCommand.cs` | ~55 | Group commands for undo |
| `Editor/UiModel/Commands/UndoRedoStack.cs` | ~100 | Undo/redo history management |
| `Editor/Gui/Graph/Legacy/Interaction/SymbolBrowser.cs` | ~660 | CreateInstance() method |
| `Editor/Gui/Graph/Legacy/Interaction/Connections/ConnectionMaker.cs` | ~1100 | TempConnection, CompleteOperation |

---

## Summary

The command system transforms a seemingly simple "add operator" action into a robust, undoable transaction:

- **ICommand Interface** — Every operation implements `Do()` and `Undo()`
- **AddSymbolChildCommand** — Creates nodes with pre-generated IDs for immediate reference
- **AddConnectionCommand** — Wires individual connections
- **MacroCommand** — Groups multiple commands into a single undo unit
- **ConnectionMaker.TempConnection** — Tracks pending connections until the new node exists
- **CompleteOperation** — Bundles everything and pushes to the undo stack

The key insight is "collect as we go": commands are executed immediately as needed, collected into a list, then bundled into a MacroCommand at the end. This allows each command to reference the results of previous commands while still achieving atomic undo behavior.

When you press Ctrl+Z, the MacroCommand undoes its sub-commands in reverse order—first removing connections, then removing nodes—ensuring the graph never enters an inconsistent state.

---

**Next:** (additional command chapters to come)
