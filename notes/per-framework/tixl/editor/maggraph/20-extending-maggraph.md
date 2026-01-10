# Chapter 20: Extending MagGraph - Adding New Features

> *Where to put your code when you want to add something new*

## Key Insight

> **Extending MagGraph's core idea:** New states go in GraphStates.cs with Enter/Update/Exit hooks; new item variants need Layout and Rendering handlers; all structure modifications need ICommand wrappers for undo and FlagStructureAsChanged calls.

---

## The Question: "I Want to Add X - Where Do I Start?"

You've read through the architecture. You understand the layers. Now you want to add something: a new interaction mode, a custom node type, a new keyboard shortcut. Where do you put the code?

This chapter provides recipes for common extension patterns:

- **New interaction state** - When you need a new "mode" (like annotation editing)
- **New item variant** - When you need something besides operators/inputs/outputs
- **Custom node UI** - When a node needs special parameter widgets
- **New keyboard shortcut** - When you want another hotkey
- **New command** - When you're modifying graph structure

Each section shows the minimum changes needed to integrate with the existing architecture.

---

## Adding a New State

### Step 1: Define the State

In `GraphStates.cs`, add a new static state:

```csharp
internal static State<GraphUiContext> MyNewState = new(
    Enter: context => {
        // Initialize state-specific data
        Log.Debug("Entering MyNewState");
    },
    Update: context => {
        // Per-frame update logic
        if (ShouldExit())
        {
            context.StateMachine.SetState(Default, context);
            return;
        }

        // Handle state-specific logic
        HandleMyStateLogic(context);
    },
    Exit: context => {
        // Clean up state-specific data
        Log.Debug("Exiting MyNewState");
    }
);
```

### Step 2: Trigger the State

Add transitions from existing states:

```csharp
// In Default state Update:
if (MyNewStateTriggerCondition())
{
    context.StateMachine.SetState(MyNewState, context);
}
```

### Step 3: Add Context Properties (if needed)

In `GraphUiContext.cs`:

```csharp
// Add properties for your state's data
internal MyStateData? MyStateData { get; set; }
```

---

## Adding a New Item Variant

### Step 1: Add Variant Enum

In `MagGraphItem.cs`:

```csharp
public enum Variants
{
    Operator,
    Input,
    Output,
    Placeholder,
    Obsolete,
    MyNewVariant,  // Add here
}
```

### Step 2: Handle in Layout

In `MagGraphLayout.UpdateVisibleItemLines()`:

```csharp
switch (item.Variant)
{
    case MagGraphItem.Variants.Operator:
        // Existing logic
        break;

    case MagGraphItem.Variants.MyNewVariant:
        // Set up input/output lines for your variant
        break;
}
```

### Step 3: Handle in Rendering

In `MagGraphCanvas.DrawNodes()`:

```csharp
switch (item.Variant)
{
    case MagGraphItem.Variants.Operator:
        DrawOperatorNode(drawList, item);
        break;

    case MagGraphItem.Variants.MyNewVariant:
        DrawMyNewVariantNode(drawList, item);
        break;
}
```

---

## Adding Custom Node UI

### Step 1: Create OpUiBinding

```csharp
public class MyOperatorUi : OpUiBinding
{
    public override bool DrawCustomUi(Instance instance, float availableWidth)
    {
        var myOp = instance as MyOperator;
        if (myOp == null)
            return false;

        // Draw custom ImGui UI
        ImGui.Text($"Value: {myOp.CurrentValue}");

        if (ImGui.Button("Reset"))
        {
            myOp.Reset();
            return true;  // Return true if UI captured focus
        }

        return false;
    }
}
```

### Step 2: Register the Binding

```csharp
// In your operator's registration:
OpUiRegistry.Register<MyOperator, MyOperatorUi>();
```

### Step 3: Handle in Node Drawing

The drawing code already checks for `OpUiBinding`:

```csharp
if (item.OpUiBinding != null)
{
    if (item.OpUiBinding.DrawCustomUi(item.Instance, availableWidth))
    {
        context.ItemWithActiveCustomUi = item;
    }
}
```

---

## Adding New Keyboard Shortcuts

### Step 1: Define the UserAction

In `UserActions.cs`:

```csharp
public static readonly UserAction MyNewAction = new(
    "My New Action",
    ImGuiKey.M,                    // Primary key
    KeyboardModifiers.Ctrl,        // Modifiers
    alternatives: []               // Alternative keys
);
```

### Step 2: Handle in KeyboardActions

In `KeyboardActions.cs`:

```csharp
internal static void HandleKeyboardInput(GraphUiContext context)
{
    // Existing shortcuts...

    if (UserActions.MyNewAction.Triggered())
    {
        PerformMyNewAction(context);
    }
}

private static void PerformMyNewAction(GraphUiContext context)
{
    // Create command for undo support
    var command = new MyNewActionCommand(context.CompositionInstance.Symbol);
    UndoRedoStack.AddAndExecute(command);

    context.Layout.FlagStructureAsChanged();
}
```

---

## Adding a New Command

### Step 1: Create the Command Class

```csharp
public class MyNewActionCommand : ICommand
{
    private readonly Symbol _symbol;
    private readonly List<SavedState> _originalStates;

    public string Name => "My New Action";
    public bool IsDone { get; private set; }

    public MyNewActionCommand(Symbol symbol)
    {
        _symbol = symbol;
        _originalStates = CaptureCurrentState();
    }

    public void Do()
    {
        // Perform the action
        foreach (var item in _symbol.Children.Values)
        {
            // Modify items...
        }
        IsDone = true;
    }

    public void Undo()
    {
        // Restore original state
        RestoreState(_originalStates);
        IsDone = false;
    }

    private List<SavedState> CaptureCurrentState()
    {
        // Capture whatever state you need to restore
        return _symbol.Children.Values
            .Select(c => new SavedState { Id = c.Id, /* ... */ })
            .ToList();
    }

    private void RestoreState(List<SavedState> states)
    {
        foreach (var state in states)
        {
            // Restore each item...
        }
    }

    private record SavedState
    {
        public Guid Id;
        // Other properties to save/restore
    }
}
```

---

## Adding to the Context Menu

### Step 1: Extend GraphContextMenu

In `GraphContextMenu.cs`:

```csharp
private static void DrawContextMenu(GraphUiContext context)
{
    if (ImGui.BeginPopupContextWindow())
    {
        // Existing menu items...

        ImGui.Separator();

        if (ImGui.MenuItem("My New Action", "Ctrl+M"))
        {
            PerformMyNewAction(context);
        }

        ImGui.EndPopup();
    }
}
```

---

## Extending Connection Rendering

### Step 1: Add New Connection Style

In `MagGraphConnection.cs`:

```csharp
public enum ConnectionStyles
{
    // Existing styles...

    MyNewStyle,  // Add your style
}
```

### Step 2: Detect the Style

In `MagGraphLayout.UpdateConnectionLayout()`:

```csharp
// Check for your custom style condition
if (IsMyNewStyleCondition(sc))
{
    sc.Style = ConnectionStyles.MyNewStyle;
    // Set SourcePos, TargetPos as needed
    continue;
}
```

### Step 3: Render the Style

In `MagGraphCanvas.Drawing.cs`:

```csharp
private void GetControlPoints(ConnectionStyles style, ...)
{
    switch (style)
    {
        // Existing styles...

        case ConnectionStyles.MyNewStyle:
            // Custom control points
            cp1 = source + customOffset1;
            cp2 = target + customOffset2;
            break;
    }
}
```

---

## Best Practices

1. **Follow existing patterns** - Look at similar features for guidance
2. **Use commands for all modifications** - Enable undo/redo
3. **Flag structure changes** - Call `context.Layout.FlagStructureAsChanged()`
4. **Test with large graphs** - Ensure performance with 100+ operators
5. **Add debug visualization** - Use `if (view.ShowDebug)` for development aids
6. **Document state transitions** - Comment which states can transition to yours

---

## Common Pitfalls

- **Forgetting to flag changes** - Layout won't update
- **Modifying Symbol directly** - Breaks undo/redo
- **Not handling all item variants** - Causes crashes with switch expressions
- **Blocking ImGui input** - Check `ImGui.GetIO().WantTextInput`
- **Not clearing temporary state** - State persists after transitions

---

## Next Steps

- **[Appendix A: File Reference](A-file-reference.md)** - Complete file listing
- **[Appendix B: ImGui Patterns](B-imgui-patterns.md)** - Common ImGui usage
- **[Appendix C: Legacy Comparison](C-legacy-comparison.md)** - Differences from legacy system
