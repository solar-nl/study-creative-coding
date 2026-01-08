# Chapter 13: Keyboard Interaction - Shortcuts and Actions

> *Power users don't reach for the mouse*

---

## The Goal: Mouse-Optional Workflow

Expert users want to keep their hands on the keyboard. Tab to create, Enter to dive in, Backspace to navigate up, D to duplicate, Delete to remove. The mouse becomes optional for common operations.

MagGraph supports this through a layered shortcut system:

- **Direct checks** - ImGui key events in state updates for immediate response
- **UserActions** - Configurable shortcuts for common operations
- **KeyboardActions** - Graph-specific actions with state awareness

The key insight: keyboard shortcuts must be state-aware. Pressing Delete while editing a text field shouldn't delete the selected operator. The state machine and input routing handle this coordination.

**Key Source Files:**

- [KeyboardActions.cs](../../../Editor/Gui/MagGraph/Interaction/KeyboardActions.cs)
- [UserActions.cs](../../../Editor/Gui/Interaction/Keyboard/UserActions.cs)
- [GraphStates.cs](../../../Editor/Gui/MagGraph/States/GraphStates.cs)

---

## Key Shortcuts Overview

### Navigation

| Shortcut | Action |
|----------|--------|
| `Enter` / `E` | Enter selected operator (navigate into) |
| `Backspace` / `U` | Exit current operator (navigate up) |
| `F` | Frame selection (zoom to fit) |
| `Home` | Reset view |

### Creation

| Shortcut | Action |
|----------|--------|
| `Tab` | Open operator browser |
| Long press on background | Open operator browser at position |

### Selection

| Shortcut | Action |
|----------|--------|
| `Ctrl+A` | Select all |
| `Escape` | Deselect all / Cancel operation |
| `Shift+Click` | Add to selection |
| `Ctrl+Click` | Toggle selection |

### Editing

| Shortcut | Action |
|----------|--------|
| `Delete` / `Backspace` | Delete selected |
| `Ctrl+D` | Duplicate selected |
| `Ctrl+C` | Copy selected |
| `Ctrl+V` | Paste |
| `Ctrl+X` | Cut selected |
| `Ctrl+G` | Group into new symbol |
| `R` | Rename selected |

### Undo/Redo

| Shortcut | Action |
|----------|--------|
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl+Y` | Redo (alternative) |

---

## UserActions System

Keyboard shortcuts are defined through the `UserActions` system:

```csharp
public static class UserActions
{
    public static readonly UserAction OpenOperator = new(
        "Open Operator",
        ImGuiKey.Enter,
        KeyboardModifiers.None,
        alternatives: [ImGuiKey.E]
    );

    public static readonly UserAction CloseOperator = new(
        "Close Operator",
        ImGuiKey.Backspace,
        KeyboardModifiers.None,
        alternatives: [ImGuiKey.U]
    );

    public static readonly UserAction DeleteSelection = new(
        "Delete Selection",
        ImGuiKey.Delete,
        KeyboardModifiers.None,
        alternatives: [ImGuiKey.Backspace]
    );

    public static readonly UserAction DuplicateSelection = new(
        "Duplicate Selection",
        ImGuiKey.D,
        KeyboardModifiers.Ctrl
    );

    // ... more actions
}
```

### UserAction Class

```csharp
public class UserAction
{
    public string Name { get; }
    public ImGuiKey PrimaryKey { get; }
    public KeyboardModifiers Modifiers { get; }
    public ImGuiKey[] Alternatives { get; }

    public bool Triggered()
    {
        // Check primary key with modifiers
        if (IsKeyPressed(PrimaryKey) && AreModifiersActive(Modifiers))
            return true;

        // Check alternatives
        foreach (var altKey in Alternatives)
        {
            if (IsKeyPressed(altKey) && AreModifiersActive(Modifiers))
                return true;
        }

        return false;
    }

    private static bool IsKeyPressed(ImGuiKey key)
    {
        return ImGui.IsKeyPressed(key) && !ImGui.GetIO().WantTextInput;
    }

    private static bool AreModifiersActive(KeyboardModifiers mods)
    {
        var io = ImGui.GetIO();

        if (mods.HasFlag(KeyboardModifiers.Ctrl) != io.KeyCtrl)
            return false;
        if (mods.HasFlag(KeyboardModifiers.Shift) != io.KeyShift)
            return false;
        if (mods.HasFlag(KeyboardModifiers.Alt) != io.KeyAlt)
            return false;

        return true;
    }
}
```

---

## Handling in Default State

Most keyboard shortcuts are handled in the Default state:

```csharp
internal static State<GraphUiContext> Default = new(
    Update: context => {
        // Skip if text input is active
        if (ImGui.GetIO().WantTextInput)
            return;

        // Skip if not focused
        if (!context.View.IsFocused || !context.View.IsHovered)
            return;

        // Tab - Open operator browser
        if (ImGui.IsKeyReleased(ImGuiKey.Tab))
        {
            OpenOperatorBrowser(context);
            return;
        }

        // Navigation
        if (UserActions.CloseOperator.Triggered() && ProjectView.Focused != null)
        {
            ProjectView.Focused.TrySetCompositionOpToParent();
        }

        if (UserActions.OpenOperator.Triggered() && ProjectView.Focused != null)
        {
            var itemToOpen = context.ActiveItem ?? context.HoveredItem;
            if (itemToOpen != null && itemToOpen.Variant == MagGraphItem.Variants.Operator)
            {
                if (itemToOpen.Instance.Children.Count > 0)
                {
                    ProjectView.Focused.TrySetCompositionOpToChild(itemToOpen.Instance.SymbolChildId);
                }
            }
        }

        // Deletion
        if (UserActions.DeleteSelection.Triggered())
        {
            Modifications.DeleteSelectedOps(context);
        }
    }
);
```

---

## KeyboardActions Class

Graph-specific keyboard actions are centralized:

```csharp
internal static class KeyboardActions
{
    internal static void HandleKeyboardInput(GraphUiContext context)
    {
        if (!context.View.IsFocused)
            return;

        if (ImGui.GetIO().WantTextInput)
            return;

        // Frame selection
        if (ImGui.IsKeyPressed(ImGuiKey.F))
        {
            FrameSelection(context);
        }

        // Reset view
        if (ImGui.IsKeyPressed(ImGuiKey.Home))
        {
            ResetView(context);
        }

        // Select all
        if (UserActions.SelectAll.Triggered())
        {
            SelectAll(context);
        }

        // Deselect
        if (ImGui.IsKeyPressed(ImGuiKey.Escape))
        {
            context.Selector.Clear();
        }

        // Copy/Paste
        if (UserActions.Copy.Triggered())
        {
            CopySelection(context);
        }

        if (UserActions.Paste.Triggered())
        {
            PasteClipboard(context);
        }

        if (UserActions.Cut.Triggered())
        {
            CutSelection(context);
        }

        // Duplicate
        if (UserActions.DuplicateSelection.Triggered())
        {
            DuplicateSelection(context);
        }

        // Group
        if (UserActions.GroupSelection.Triggered())
        {
            GroupIntoSymbol(context);
        }

        // Rename
        if (ImGui.IsKeyPressed(ImGuiKey.R) && !ImGui.GetIO().KeyCtrl)
        {
            StartRenameSelected(context);
        }
    }
}
```

---

## Frame Selection

Zoom to fit selected items:

```csharp
internal static void FrameSelection(GraphUiContext context)
{
    var selectedItems = context.Selector.Selection
        .Where(s => context.Layout.Items.ContainsKey(s.Id))
        .Select(s => context.Layout.Items[s.Id])
        .ToList();

    if (selectedItems.Count == 0)
    {
        // Frame all items if nothing selected
        selectedItems = context.Layout.Items.Values.ToList();
    }

    if (selectedItems.Count == 0)
        return;

    var bounds = MagGraphItem.GetItemsBounds(selectedItems);
    bounds.Expand(50);  // Add padding

    context.View.FitRectIntoView(bounds);
}
```

---

## Copy/Paste

```csharp
internal static void CopySelection(GraphUiContext context)
{
    var selectedChildUis = context.Selector.GetSelectedChildUis();
    if (selectedChildUis.Count == 0)
        return;

    var clipboard = new ClipboardContent
    {
        SymbolId = context.CompositionInstance.Symbol.Id,
        Children = selectedChildUis.Select(c => c.ToSerializable()).ToList(),
        Connections = GetInternalConnections(context, selectedChildUis)
    };

    var json = JsonSerializer.Serialize(clipboard);
    ImGui.SetClipboardText(json);
}

internal static void PasteClipboard(GraphUiContext context)
{
    var json = ImGui.GetClipboardText();
    if (string.IsNullOrEmpty(json))
        return;

    try
    {
        var clipboard = JsonSerializer.Deserialize<ClipboardContent>(json);
        if (clipboard == null)
            return;

        var mousePos = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
        PasteContent(context, clipboard, mousePos);
    }
    catch (JsonException)
    {
        // Invalid clipboard content - ignore
    }
}
```

---

## Duplicate

```csharp
internal static void DuplicateSelection(GraphUiContext context)
{
    var selectedChildUis = context.Selector.GetSelectedChildUis();
    if (selectedChildUis.Count == 0)
        return;

    var macroCommand = context.StartMacroCommand("Duplicate");

    var offset = new Vector2(MagGraphItem.Width + 20, 0);
    var newItems = new List<Guid>();

    foreach (var childUi in selectedChildUis)
    {
        var command = new DuplicateSymbolChildCommand(
            context.CompositionInstance.Symbol,
            childUi.SymbolChild.Id,
            childUi.PosOnCanvas + offset
        );
        macroCommand.AddAndExecCommand(command);
        newItems.Add(command.NewChildId);
    }

    // Copy internal connections
    CopyInternalConnections(context, macroCommand, selectedChildUis, newItems);

    context.CompleteMacroCommand();
    context.Layout.FlagStructureAsChanged();

    // Select new items
    context.Selector.Clear();
    foreach (var id in newItems)
    {
        if (context.Layout.Items.TryGetValue(id, out var item))
        {
            item.AddToSelection(context.Selector);
        }
    }
}
```

---

## Rename

```csharp
internal static void StartRenameSelected(GraphUiContext context)
{
    var selected = context.Selector.Selection;
    if (selected.Count != 1)
        return;

    if (!context.Layout.Items.TryGetValue(selected[0].Id, out var item))
        return;

    if (item.Variant != MagGraphItem.Variants.Operator)
        return;

    context.ActiveItem = item;
    context.StateMachine.SetState(GraphStates.RenameChild, context);
}
```

---

## Arrow Key Navigation

Arrow keys can navigate between operators:

```csharp
internal static void HandleArrowNavigation(GraphUiContext context)
{
    if (!context.View.IsFocused)
        return;

    var current = context.Selector.Selection.FirstOrDefault();
    if (current == null || !context.Layout.Items.TryGetValue(current.Id, out var currentItem))
        return;

    MagGraphItem? target = null;

    if (ImGui.IsKeyPressed(ImGuiKey.LeftArrow))
    {
        target = FindNearestItemInDirection(context, currentItem, Direction.Left);
    }
    else if (ImGui.IsKeyPressed(ImGuiKey.RightArrow))
    {
        target = FindNearestItemInDirection(context, currentItem, Direction.Right);
    }
    else if (ImGui.IsKeyPressed(ImGuiKey.UpArrow))
    {
        target = FindNearestItemInDirection(context, currentItem, Direction.Up);
    }
    else if (ImGui.IsKeyPressed(ImGuiKey.DownArrow))
    {
        target = FindNearestItemInDirection(context, currentItem, Direction.Down);
    }

    if (target != null)
    {
        if (ImGui.GetIO().KeyShift)
        {
            target.AddToSelection(context.Selector);
        }
        else
        {
            target.Select(context.Selector);
        }
    }
}
```

---

## Escape Handling

Escape has context-dependent behavior:

```csharp
if (ImGui.IsKeyPressed(ImGuiKey.Escape))
{
    // Cancel current operation first
    if (context.StateMachine.CurrentState != GraphStates.Default)
    {
        if (context.MacroCommand != null)
        {
            context.CancelMacroCommand();
        }
        context.StateMachine.SetState(GraphStates.Default, context);
        return;
    }

    // Clear temporary connections
    if (context.TempConnections.Count > 0)
    {
        context.TempConnections.Clear();
        return;
    }

    // Deselect
    if (context.Selector.Selection.Count > 0)
    {
        context.Selector.Clear();
        return;
    }
}
```

---

## Next Steps

- **[Rendering Canvas](14-rendering-canvas.md)** - How the canvas is rendered
- **[State Machine](07-state-machine.md)** - State transitions from keyboard
- **[Undo Redo](19-undo-redo.md)** - How keyboard actions integrate with undo
