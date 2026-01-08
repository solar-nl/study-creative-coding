# Chapter 14: Canvas Rendering - The Drawing System

> *Turning coordinates into pixels at any zoom level*

---

## The Fundamental Challenge: Two Coordinate Systems

When you zoom into a graph, a node at canvas position (100, 200) might appear at screen position (450, 380). When you pan, those same canvas coordinates map to completely different screen pixels.

The rendering system's job is to handle this translation automatically. You work in "canvas space" (where operators live), and MagGraph transforms everything to "screen space" (where pixels appear) transparently.

This transform must be:

- **Fast** - Applied thousands of times per frame
- **Accurate** - No drift or rounding errors
- **Consistent** - Same rules for items, connections, annotations, mouse input

The `ScalableCanvas` class handles this, providing transform methods that every rendering call uses.

**Key Source Files:**

- [MagGraphView.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphView.cs) (~800 lines) - The main view
- [MagGraphCanvas.Drawing.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs) (~400 lines) - Draw orchestration
- [ScalableCanvas.cs](../../../Editor/Gui/UiHelpers/ScalableCanvas.cs) - Transform system

---

## Coordinate Systems

MagGraph uses two coordinate systems:

```
┌────────────────────────────────────────────────────────────────────────┐
│                         Screen Space                                    │
│  (0,0) ────────────────────────────────────────────────────► X         │
│    │                                                                    │
│    │    ┌─────────────────────────────────────────────┐                │
│    │    │              Canvas Viewport                 │                │
│    │    │                                              │                │
│    │    │    ┌─────────────────────────────┐          │                │
│    │    │    │  Canvas Space (transformed)  │          │                │
│    │    │    │                              │          │                │
│    │    │    │   Scale + Scroll applied     │          │                │
│    │    │    │                              │          │                │
│    │    │    └─────────────────────────────┘          │                │
│    │    │                                              │                │
│    │    └─────────────────────────────────────────────┘                │
│    ▼                                                                    │
│    Y                                                                    │
└────────────────────────────────────────────────────────────────────────┘
```

### Transform Methods

```csharp
public class ScalableCanvas
{
    public Vector2 Scale = Vector2.One;
    public Vector2 Scroll = Vector2.Zero;
    public Vector2 WindowPos;  // Top-left of the canvas window

    /// <summary>
    /// Convert canvas position to screen position
    /// </summary>
    public Vector2 TransformPosition(Vector2 posOnCanvas)
    {
        return (posOnCanvas - Scroll) * Scale + WindowPos;
    }

    /// <summary>
    /// Convert screen position to canvas position
    /// </summary>
    public Vector2 InverseTransformPositionFloat(Vector2 screenPos)
    {
        return (screenPos - WindowPos) / Scale + Scroll;
    }

    /// <summary>
    /// Transform a direction (no translation)
    /// </summary>
    public Vector2 TransformDirection(Vector2 direction)
    {
        return direction * Scale;
    }

    /// <summary>
    /// Transform a rectangle
    /// </summary>
    public ImRect TransformRect(ImRect rect)
    {
        return new ImRect(
            TransformPosition(rect.Min),
            TransformPosition(rect.Max)
        );
    }
}
```

---

## MagGraphView

The main view class extends `ScalableCanvas`:

```csharp
internal sealed class MagGraphView : ScalableCanvas
{
    private GraphUiContext _context;

    public bool IsFocused { get; private set; }
    public bool IsHovered { get; private set; }
    public bool ShowDebug { get; set; }

    internal void Draw(GraphUiContext context)
    {
        _context = context;

        BeginCanvas();
        {
            HandlePanAndZoom();
            DrawBackground();
            DrawAnnotations();
            DrawConnections();
            DrawNodes();
            DrawPlaceholder();
            DrawTemporaryConnections();
            DrawSelectionRect();
            DrawDebugInfo();
        }
        EndCanvas();

        SmoothPositions();
    }
}
```

---

## The Render Loop

### Main Draw Method

```csharp
internal void Draw(GraphUiContext context)
{
    // Update layout if needed
    context.Layout.ComputeLayout(context);

    // Get window properties
    WindowPos = ImGui.GetWindowPos();
    var windowSize = ImGui.GetWindowSize();

    // Check focus and hover
    IsFocused = ImGui.IsWindowFocused();
    IsHovered = ImGui.IsWindowHovered();

    // Handle input
    HandlePanAndZoom();

    // Get draw list
    var drawList = ImGui.GetWindowDrawList();

    // Set clip rect
    drawList.PushClipRect(WindowPos, WindowPos + windowSize);

    // Draw in order (back to front)
    DrawBackground(drawList);
    DrawAnnotations(drawList);
    DrawConnections(drawList);
    DrawNodes(drawList);
    DrawPlaceholder(drawList);
    DrawTemporaryConnections(drawList);
    DrawSelectionRect(drawList);

    drawList.PopClipRect();

    // Update state machine
    _context.StateMachine.Update(_context);
}
```

---

## Pan and Zoom

### Panning

```csharp
private void HandlePanAndZoom()
{
    if (!IsHovered)
        return;

    // Pan with middle mouse or Alt+Left
    if (ImGui.IsMouseDragging(ImGuiMouseButton.Middle)
        || (ImGui.IsMouseDragging(ImGuiMouseButton.Left) && ImGui.GetIO().KeyAlt))
    {
        var delta = ImGui.GetIO().MouseDelta;
        Scroll -= delta / Scale;
    }
}
```

### Zooming

```csharp
private void HandleZoom()
{
    if (!IsHovered)
        return;

    var mouseWheel = ImGui.GetIO().MouseWheel;
    if (Math.Abs(mouseWheel) < 0.01f)
        return;

    // Zoom towards mouse position
    var mousePos = ImGui.GetMousePos();
    var mousePosOnCanvas = InverseTransformPositionFloat(mousePos);

    // Apply zoom
    var zoomFactor = mouseWheel > 0 ? 1.1f : 0.9f;
    Scale *= zoomFactor;

    // Clamp zoom
    Scale = Vector2.Clamp(Scale, new Vector2(0.1f), new Vector2(5f));

    // Adjust scroll to keep mouse position stable
    var newMousePosOnCanvas = InverseTransformPositionFloat(mousePos);
    Scroll += mousePosOnCanvas - newMousePosOnCanvas;
}
```

### Frame to Fit

```csharp
public void FitRectIntoView(ImRect rect, float padding = 0.1f)
{
    var windowSize = ImGui.GetWindowSize();
    var rectSize = rect.GetSize();

    // Calculate required scale
    var scaleX = windowSize.X / (rectSize.X * (1 + padding * 2));
    var scaleY = windowSize.Y / (rectSize.Y * (1 + padding * 2));
    var newScale = Math.Min(scaleX, scaleY);

    // Clamp scale
    newScale = Math.Clamp(newScale, 0.1f, 5f);
    Scale = new Vector2(newScale);

    // Center the rect
    var rectCenter = rect.GetCenter();
    var viewCenter = InverseTransformPositionFloat(WindowPos + windowSize / 2);
    Scroll = rectCenter - (viewCenter - Scroll);
}
```

---

## Drawing Background

```csharp
private void DrawBackground(ImDrawListPtr drawList)
{
    var windowSize = ImGui.GetWindowSize();

    // Fill background
    drawList.AddRectFilled(
        WindowPos,
        WindowPos + windowSize,
        UiColors.GraphBackground
    );

    // Draw grid
    if (Scale.X > 0.3f)
    {
        DrawGrid(drawList, MagGraphItem.LineHeight, UiColors.GridMinor);
    }

    if (Scale.X > 0.2f)
    {
        DrawGrid(drawList, MagGraphItem.Width, UiColors.GridMajor);
    }
}

private void DrawGrid(ImDrawListPtr drawList, float spacing, uint color)
{
    var windowSize = ImGui.GetWindowSize();
    var scaledSpacing = spacing * Scale.X;

    // Vertical lines
    var startX = (WindowPos.X - Scroll.X * Scale.X) % scaledSpacing;
    for (var x = startX; x < windowSize.X; x += scaledSpacing)
    {
        drawList.AddLine(
            new Vector2(WindowPos.X + x, WindowPos.Y),
            new Vector2(WindowPos.X + x, WindowPos.Y + windowSize.Y),
            color
        );
    }

    // Horizontal lines
    var startY = (WindowPos.Y - Scroll.Y * Scale.Y) % scaledSpacing;
    for (var y = startY; y < windowSize.Y; y += scaledSpacing)
    {
        drawList.AddLine(
            new Vector2(WindowPos.X, WindowPos.Y + y),
            new Vector2(WindowPos.X + windowSize.X, WindowPos.Y + y),
            color
        );
    }
}
```

---

## Draw Order

Elements are drawn in this order (back to front):

1. **Background** - Grid and canvas color
2. **Annotations** - Colored frames
3. **Connections** - Wires between nodes
4. **Nodes** - Operators and their content
5. **Placeholder** - Operator browser overlay
6. **Temporary Connections** - Wires being dragged
7. **Selection Rect** - Fence selection rectangle
8. **Overlays** - Tooltips, context menus

---

## Visibility Culling

Only visible elements are drawn:

```csharp
private bool IsVisible(ImRect rect)
{
    var windowSize = ImGui.GetWindowSize();
    var viewRect = new ImRect(
        InverseTransformPositionFloat(WindowPos),
        InverseTransformPositionFloat(WindowPos + windowSize)
    );

    return viewRect.Overlaps(rect);
}

// Usage:
foreach (var item in _context.Layout.Items.Values)
{
    if (!IsVisible(item.Area))
        continue;

    DrawNode(item);
}
```

---

## Position Damping

Smooth animations are achieved through damping:

```csharp
private void SmoothPositions()
{
    const float dampAmount = 0.33f;

    // Damp item positions
    foreach (var item in _context.Layout.Items.Values)
    {
        item.DampedPosOnCanvas = Vector2.Lerp(
            item.PosOnCanvas,
            item.DampedPosOnCanvas,
            dampAmount
        );
    }

    // Damp connection endpoints
    foreach (var connection in _context.Layout.MagConnections)
    {
        connection.DampedSourcePos = Vector2.Lerp(
            connection.SourcePos,
            connection.DampedSourcePos,
            dampAmount
        );
        connection.DampedTargetPos = Vector2.Lerp(
            connection.TargetPos,
            connection.DampedTargetPos,
            dampAmount
        );
    }

    // Damp annotations
    foreach (var annotation in _context.Layout.Annotations.Values)
    {
        annotation.DampedPosOnCanvas = Vector2.Lerp(
            annotation.PosOnCanvas,
            annotation.DampedPosOnCanvas,
            dampAmount
        );
        annotation.DampedSize = Vector2.Lerp(
            annotation.Size,
            annotation.DampedSize,
            dampAmount
        );
    }
}
```

---

## Draw Lists

ImGui provides multiple draw lists:

```csharp
// Window draw list (clipped to window)
var windowDrawList = ImGui.GetWindowDrawList();

// Background draw list (behind all windows)
var backgroundDrawList = ImGui.GetBackgroundDrawList();

// Foreground draw list (in front of all windows)
var foregroundDrawList = ImGui.GetForegroundDrawList();

// Usage for debug overlays:
if (ShowDebug)
{
    var fgDrawList = ImGui.GetForegroundDrawList();
    fgDrawList.AddText(
        new Vector2(10, 10),
        Color.Yellow,
        $"Items: {_context.Layout.Items.Count}"
    );
}
```

---

## Next Steps

- **[Rendering Nodes](15-rendering-nodes.md)** - Drawing operators
- **[Rendering Connections](16-rendering-connections.md)** - Drawing wires
- **[Rendering Annotations](17-rendering-annotations.md)** - Drawing frames
