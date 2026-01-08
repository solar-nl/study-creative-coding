# Chapter 12: Annotation Interaction - Frames and Labels

> *Colored boxes that make complex graphs comprehensible*

---

## Why Annotations Matter

A graph with 100 operators is overwhelming. A graph with 100 operators organized into labeled groups - "Audio Processing", "Visual Effects", "Output Routing" - tells a story.

Annotations are the organizational layer. They're colored frames with titles that group related operators visually. Unlike nodes, they don't affect execution - they're purely for human understanding.

Making them feel good to use requires handling:

- **Dragging** - Move the frame (and optionally, the operators inside it)
- **Resizing** - Adjust dimensions from any edge or corner
- **Renaming** - Click the title to edit

Each interaction has its own state in the state machine, keeping the logic clean and debuggable.

**Key Source Files:**

- [AnnotationDragging.cs](../../../Editor/Gui/MagGraph/Interaction/AnnotationDragging.cs)
- [AnnotationResizing.cs](../../../Editor/Gui/MagGraph/Interaction/AnnotationResizing.cs)
- [AnnotationRenaming.cs](../../../Editor/Gui/MagGraph/Interaction/AnnotationRenaming.cs)

---

## Annotation States

Annotations have dedicated states in the state machine:

```csharp
internal static State<GraphUiContext> DragAnnotation = new(
    Enter: _ => { },
    Update: _ => { },
    Exit: _ => { }
);

internal static State<GraphUiContext> ResizeAnnotation = new(
    Enter: _ => { },
    Update: AnnotationResizing.Draw,
    Exit: _ => { }
);

internal static State<GraphUiContext> RenameAnnotation = new(
    Enter: _ => { },
    Update: _ => { },
    Exit: _ => { }
);
```

---

## Annotation Dragging

### Detecting Drag Start

When clicking on an annotation header (title bar area):

```csharp
internal static class AnnotationDragging
{
    internal static bool TryStartDrag(GraphUiContext context, MagGraphAnnotation annotation, Vector2 mousePos)
    {
        var headerRect = GetHeaderRect(annotation);

        if (!headerRect.Contains(mousePos))
            return false;

        _draggedAnnotation = annotation;
        _dragOffset = mousePos - annotation.PosOnCanvas;
        context.ActiveAnnotationId = annotation.Id;

        return true;
    }

    private static ImRect GetHeaderRect(MagGraphAnnotation annotation)
    {
        return new ImRect(
            annotation.PosOnCanvas,
            annotation.PosOnCanvas + new Vector2(annotation.Size.X, HeaderHeight)
        );
    }
}
```

### During Drag

```csharp
internal static void UpdateDrag(GraphUiContext context)
{
    if (_draggedAnnotation == null)
        return;

    if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
    {
        CompleteDrag(context);
        return;
    }

    var mousePos = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    var newPos = mousePos - _dragOffset;

    // Apply snap to grid if enabled
    if (UserSettings.Config.SnapToGrid)
    {
        newPos = SnapToGrid(newPos);
    }

    _draggedAnnotation.PosOnCanvas = newPos;
}
```

### Completing Drag

```csharp
internal static void CompleteDrag(GraphUiContext context)
{
    if (_draggedAnnotation == null)
        return;

    // Create undo command
    var command = new ModifyAnnotationCommand(
        context.CompositionInstance.Symbol.Id,
        _draggedAnnotation.Annotation
    );
    UndoRedoStack.Add(command);

    _draggedAnnotation = null;
    context.ActiveAnnotationId = Guid.Empty;
    context.StateMachine.SetState(GraphStates.Default, context);
}
```

---

## Annotation Resizing

### Resize Handles

Annotations have resize handles at corners and edges:

```
┌─────────────────────────────────────────┐
│ ● Title                                ●│ ← Corner handles
├─────────────────────────────────────────┤
│                                         │
│                                         │
│                 Content                 │
│                                         │
│                                         │
│ ●─────────────────────────────────────●│ ← Corner handles
└─────────────────────────────────────────┘
      ↑                              ↑
   Edge handles (top, bottom, left, right)
```

### Handle Detection

```csharp
internal static class AnnotationResizing
{
    private const float HandleSize = 10f;

    internal static ResizeHandle GetHoveredHandle(MagGraphAnnotation annotation, Vector2 mousePos)
    {
        var rect = new ImRect(annotation.PosOnCanvas, annotation.PosOnCanvas + annotation.Size);

        // Check corners first (they overlap with edges)
        if (IsNearCorner(mousePos, rect.Min))
            return ResizeHandle.TopLeft;
        if (IsNearCorner(mousePos, new Vector2(rect.Max.X, rect.Min.Y)))
            return ResizeHandle.TopRight;
        if (IsNearCorner(mousePos, rect.Max))
            return ResizeHandle.BottomRight;
        if (IsNearCorner(mousePos, new Vector2(rect.Min.X, rect.Max.Y)))
            return ResizeHandle.BottomLeft;

        // Check edges
        if (IsNearEdge(mousePos.Y, rect.Min.Y) && IsInRange(mousePos.X, rect.Min.X, rect.Max.X))
            return ResizeHandle.Top;
        if (IsNearEdge(mousePos.Y, rect.Max.Y) && IsInRange(mousePos.X, rect.Min.X, rect.Max.X))
            return ResizeHandle.Bottom;
        if (IsNearEdge(mousePos.X, rect.Min.X) && IsInRange(mousePos.Y, rect.Min.Y, rect.Max.Y))
            return ResizeHandle.Left;
        if (IsNearEdge(mousePos.X, rect.Max.X) && IsInRange(mousePos.Y, rect.Min.Y, rect.Max.Y))
            return ResizeHandle.Right;

        return ResizeHandle.None;
    }

    internal enum ResizeHandle
    {
        None,
        Top, Bottom, Left, Right,
        TopLeft, TopRight, BottomLeft, BottomRight
    }
}
```

### Resize Logic

```csharp
internal static void Draw(GraphUiContext context)
{
    if (_resizingAnnotation == null)
        return;

    if (!ImGui.IsMouseDown(ImGuiMouseButton.Left))
    {
        CompleteResize(context);
        return;
    }

    var mousePos = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    var delta = mousePos - _resizeStartPos;

    // Apply resize based on active handle
    switch (_activeHandle)
    {
        case ResizeHandle.Right:
            _resizingAnnotation.Size = new Vector2(
                Math.Max(MinWidth, _originalSize.X + delta.X),
                _resizingAnnotation.Size.Y
            );
            break;

        case ResizeHandle.Bottom:
            _resizingAnnotation.Size = new Vector2(
                _resizingAnnotation.Size.X,
                Math.Max(MinHeight, _originalSize.Y + delta.Y)
            );
            break;

        case ResizeHandle.BottomRight:
            _resizingAnnotation.Size = new Vector2(
                Math.Max(MinWidth, _originalSize.X + delta.X),
                Math.Max(MinHeight, _originalSize.Y + delta.Y)
            );
            break;

        case ResizeHandle.TopLeft:
            // Top-left moves position AND changes size
            var newPos = _originalPos + delta;
            var newSize = _originalSize - delta;

            // Clamp to minimum size
            if (newSize.X >= MinWidth && newSize.Y >= MinHeight)
            {
                _resizingAnnotation.PosOnCanvas = newPos;
                _resizingAnnotation.Size = newSize;
            }
            break;

        // ... other handles
    }
}
```

### Completing Resize

```csharp
internal static void CompleteResize(GraphUiContext context)
{
    if (_resizingAnnotation == null)
        return;

    // Store undo command
    var command = new ModifyAnnotationCommand(
        context.CompositionInstance.Symbol.Id,
        _resizingAnnotation.Annotation
    );
    UndoRedoStack.Add(command);

    _resizingAnnotation = null;
    context.StateMachine.SetState(GraphStates.Default, context);
}
```

---

## Annotation Renaming

### Starting Rename

Double-click on the title to start renaming:

```csharp
internal static class AnnotationRenaming
{
    internal static bool TryStartRename(GraphUiContext context, MagGraphAnnotation annotation, Vector2 clickPos)
    {
        var headerRect = GetHeaderRect(annotation);

        if (!headerRect.Contains(clickPos))
            return false;

        _renamingAnnotation = annotation;
        _editText = annotation.Annotation.Title;

        context.ActiveAnnotationId = annotation.Id;
        context.StateMachine.SetState(GraphStates.RenameAnnotation, context);

        return true;
    }
}
```

### Rename UI

```csharp
internal static void Draw(GraphUiContext context)
{
    if (_renamingAnnotation == null)
        return;

    var pos = context.View.TransformPosition(_renamingAnnotation.PosOnCanvas);

    ImGui.SetNextWindowPos(pos);
    ImGui.SetNextWindowSize(new Vector2(
        _renamingAnnotation.Size.X * context.View.Scale.X,
        HeaderHeight * context.View.Scale.Y
    ));

    if (ImGui.Begin("##RenameAnnotation", ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize))
    {
        ImGui.SetKeyboardFocusHere();

        if (ImGui.InputText("##Title", ref _editText, 256, ImGuiInputTextFlags.EnterReturnsTrue))
        {
            ApplyRename(context);
        }

        // Cancel on Escape
        if (ImGui.IsKeyPressed(ImGuiKey.Escape))
        {
            CancelRename(context);
        }

        // Cancel if clicked outside
        if (ImGui.IsMouseClicked(ImGuiMouseButton.Left) && !ImGui.IsWindowHovered())
        {
            ApplyRename(context);  // Apply on click outside
        }

        ImGui.End();
    }
}
```

### Applying Rename

```csharp
internal static void ApplyRename(GraphUiContext context)
{
    if (_renamingAnnotation == null)
        return;

    if (_editText != _renamingAnnotation.Annotation.Title)
    {
        var command = new RenameAnnotationCommand(
            context.CompositionInstance.Symbol.Id,
            _renamingAnnotation.Id,
            _editText
        );
        UndoRedoStack.AddAndExecute(command);
    }

    _renamingAnnotation = null;
    context.ActiveAnnotationId = Guid.Empty;
    context.StateMachine.SetState(GraphStates.Default, context);
}
```

---

## Context Menu Actions

Right-clicking an annotation shows a context menu:

```csharp
internal static void DrawAnnotationContextMenu(GraphUiContext context, MagGraphAnnotation annotation)
{
    if (ImGui.BeginPopupContextItem($"##AnnotationContext_{annotation.Id}"))
    {
        if (ImGui.MenuItem("Rename"))
        {
            StartRename(context, annotation);
        }

        if (ImGui.MenuItem("Change Color"))
        {
            _showColorPicker = true;
            _colorPickerAnnotation = annotation;
        }

        ImGui.Separator();

        if (ImGui.MenuItem("Collapse Items"))
        {
            CollapseItemsIntoAnnotation(context, annotation);
        }

        if (ImGui.MenuItem("Expand Items"))
        {
            ExpandItemsFromAnnotation(context, annotation);
        }

        ImGui.Separator();

        if (ImGui.MenuItem("Delete"))
        {
            DeleteAnnotation(context, annotation);
        }

        ImGui.EndPopup();
    }
}
```

---

## Collapsing Items

Items can be collapsed into an annotation for a cleaner view:

```csharp
internal static void CollapseItemsIntoAnnotation(GraphUiContext context, MagGraphAnnotation annotation)
{
    var itemsInBounds = new List<MagGraphItem>();

    foreach (var item in context.Layout.Items.Values)
    {
        if (annotation.Area.Contains(item.PosOnCanvas))
        {
            itemsInBounds.Add(item);
        }
    }

    var command = new MacroCommand("Collapse Items");

    foreach (var item in itemsInBounds)
    {
        if (item.ChildUi != null)
        {
            command.AddAndExecCommand(
                new SetCollapsedIntoAnnotationCommand(
                    item.ChildUi,
                    annotation.Id
                )
            );
        }
    }

    UndoRedoStack.Add(command);
    context.Layout.FlagStructureAsChanged();
}
```

---

## Creating Annotations

Annotations are created via the context menu or keyboard shortcut:

```csharp
internal static void CreateAnnotationForSelection(GraphUiContext context)
{
    var selectedItems = context.Selector.Selection
        .Where(s => context.Layout.Items.ContainsKey(s.Id))
        .Select(s => context.Layout.Items[s.Id])
        .ToList();

    if (selectedItems.Count == 0)
        return;

    var bounds = MagGraphItem.GetItemsBounds(selectedItems);

    // Add padding
    bounds.Expand(20);

    var annotation = new Annotation
    {
        Id = Guid.NewGuid(),
        Title = "New Group",
        PosOnCanvas = bounds.Min,
        Size = bounds.GetSize(),
        Color = GetNextAnnotationColor()
    };

    var command = new AddAnnotationCommand(
        context.CompositionInstance.Symbol.Id,
        annotation
    );
    UndoRedoStack.AddAndExecute(command);
    context.Layout.FlagStructureAsChanged();
}
```

---

## Next Steps

- **[Interaction Keyboard](13-interaction-keyboard.md)** - Keyboard shortcuts
- **[Rendering Annotations](17-rendering-annotations.md)** - How frames are drawn
- **[Model Annotations](06-model-annotations.md)** - The annotation data model
