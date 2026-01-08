# Chapter 17: Annotation Rendering - Drawing Frames

> *Behind the nodes, guiding the eye*

---

## The Visual Challenge: Frames That Don't Overwhelm

Annotations need to be visible enough to organize the graph, but subtle enough not to distract from the operators themselves. The rendering balances:

- **Semi-transparent backgrounds** - You see the frame, but operators on top remain clear
- **Colored headers** - Quick identification of annotation purpose
- **Resize affordances** - Visible handles without cluttering the design
- **Z-ordering** - Frames draw behind nodes, so operators always win

The render order matters: annotations draw first, then connections, then nodes. This layering ensures operators float above their grouping frames.

**Key Source Files:**

- [MagGraphCanvas.Drawing.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs)
- [MagGraphAnnotation.cs](../../../Editor/Gui/MagGraph/Model/MagGraphAnnotation.cs)

---

## Annotation Structure

```
┌─────────────────────────────────────────────────────────────────┐
│ ■ Title                                               [─] [×]   │ ← Header
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│                                                                  │
│                    Content Area                                  │
│               (semi-transparent fill)                            │
│                                                                  │
│                                                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
  ↑                                                             ↑
Resize handles at corners and edges
```

---

## Main Drawing Method

```csharp
private void DrawAnnotations(ImDrawListPtr drawList)
{
    // Draw annotations behind nodes (in render order)
    foreach (var annotation in _context.Layout.Annotations.Values.OrderBy(a => a.PosOnCanvas.Y))
    {
        if (annotation.IsRemoved)
            continue;

        if (!IsVisible(GetAnnotationRect(annotation)))
            continue;

        DrawAnnotation(drawList, annotation);
    }
}
```

---

## Drawing an Annotation

```csharp
private void DrawAnnotation(ImDrawListPtr drawList, MagGraphAnnotation annotation)
{
    var rect = new ImRect(
        TransformPosition(annotation.DampedPosOnCanvas),
        TransformPosition(annotation.DampedPosOnCanvas + annotation.DampedSize)
    );

    var color = annotation.Annotation.Color;
    var isSelected = _context.ActiveAnnotationId == annotation.Id;
    var isHovered = IsAnnotationHovered(annotation);

    // Background fill
    DrawAnnotationBackground(drawList, rect, color, isSelected);

    // Header bar
    DrawAnnotationHeader(drawList, rect, color, annotation.Annotation.Title);

    // Resize handles (when hovered or selected)
    if (isHovered || isSelected)
    {
        DrawResizeHandles(drawList, rect, color);
    }

    // Selection border
    if (isSelected)
    {
        DrawAnnotationSelectionBorder(drawList, rect);
    }
}
```

---

## Background Fill

```csharp
private void DrawAnnotationBackground(ImDrawListPtr drawList, ImRect rect,
    Color color, bool isSelected)
{
    // Semi-transparent fill
    var fillColor = color.Fade(isSelected ? 0.15f : 0.1f);

    drawList.AddRectFilled(
        rect.Min,
        rect.Max,
        fillColor,
        CornerRadius
    );

    // Subtle border
    var borderColor = color.Fade(0.3f);
    drawList.AddRect(
        rect.Min,
        rect.Max,
        borderColor,
        CornerRadius,
        ImDrawFlags.None,
        1
    );
}
```

---

## Header Bar

```csharp
private const float HeaderHeight = 24;

private void DrawAnnotationHeader(ImDrawListPtr drawList, ImRect rect,
    Color color, string title)
{
    var headerRect = new ImRect(
        rect.Min,
        new Vector2(rect.Max.X, rect.Min.Y + HeaderHeight * Scale.Y)
    );

    // Header background
    drawList.AddRectFilled(
        headerRect.Min,
        headerRect.Max,
        color.Fade(0.5f),
        CornerRadius,
        ImDrawFlags.RoundCornersTop
    );

    // Title text
    var textPos = headerRect.Min + new Vector2(8 * Scale.X, 4 * Scale.Y);
    var fontSize = 14 * Scale.Y;

    drawList.AddText(
        fontSize,
        textPos,
        UiColors.Text,
        title
    );

    // Collapse icon
    var collapseIconPos = new Vector2(
        headerRect.Max.X - 20 * Scale.X,
        headerRect.Min.Y + 4 * Scale.Y
    );
    DrawCollapseIcon(drawList, collapseIconPos, color);
}
```

---

## Resize Handles

```csharp
private void DrawResizeHandles(ImDrawListPtr drawList, ImRect rect, Color color)
{
    var handleSize = 8 * Scale.X;
    var handleColor = color.Fade(0.8f);

    // Corner handles
    var corners = new[]
    {
        rect.Min,                                    // Top-left
        new Vector2(rect.Max.X, rect.Min.Y),        // Top-right
        rect.Max,                                    // Bottom-right
        new Vector2(rect.Min.X, rect.Max.Y)         // Bottom-left
    };

    foreach (var corner in corners)
    {
        drawList.AddRectFilled(
            corner - new Vector2(handleSize / 2),
            corner + new Vector2(handleSize / 2),
            handleColor,
            2
        );
    }

    // Edge handles (center of each edge)
    var edges = new[]
    {
        new Vector2((rect.Min.X + rect.Max.X) / 2, rect.Min.Y),  // Top
        new Vector2(rect.Max.X, (rect.Min.Y + rect.Max.Y) / 2),  // Right
        new Vector2((rect.Min.X + rect.Max.X) / 2, rect.Max.Y),  // Bottom
        new Vector2(rect.Min.X, (rect.Min.Y + rect.Max.Y) / 2)   // Left
    };

    foreach (var edge in edges)
    {
        drawList.AddCircleFilled(edge, handleSize / 2, handleColor);
    }
}
```

---

## Selection Border

```csharp
private void DrawAnnotationSelectionBorder(ImDrawListPtr drawList, ImRect rect)
{
    var borderColor = UiColors.Selection;
    var thickness = 2 * Scale.X;

    // Animated dashed border
    var dashOffset = (float)(ImGui.GetTime() * 20) % 16;

    DrawDashedRect(drawList, rect, borderColor, thickness, 8, 4, dashOffset);
}

private void DrawDashedRect(ImDrawListPtr drawList, ImRect rect,
    Color color, float thickness, float dashLength, float gapLength, float offset)
{
    // Draw each edge with dashes
    DrawDashedLine(drawList, rect.Min, new Vector2(rect.Max.X, rect.Min.Y),
        color, thickness, dashLength, gapLength, offset);
    DrawDashedLine(drawList, new Vector2(rect.Max.X, rect.Min.Y), rect.Max,
        color, thickness, dashLength, gapLength, offset);
    DrawDashedLine(drawList, rect.Max, new Vector2(rect.Min.X, rect.Max.Y),
        color, thickness, dashLength, gapLength, offset);
    DrawDashedLine(drawList, new Vector2(rect.Min.X, rect.Max.Y), rect.Min,
        color, thickness, dashLength, gapLength, offset);
}
```

---

## Collapsed Items

When items are collapsed into an annotation:

```csharp
private void DrawCollapsedItems(ImDrawListPtr drawList, MagGraphAnnotation annotation)
{
    var collapsedItems = annotation.Annotation.CollapsedItemIds;
    if (collapsedItems == null || collapsedItems.Count == 0)
        return;

    var rect = GetAnnotationScreenRect(annotation);
    var startY = rect.Min.Y + HeaderHeight * Scale.Y + 4 * Scale.Y;
    var itemHeight = 20 * Scale.Y;

    var y = startY;
    foreach (var itemId in collapsedItems.Take(5))  // Show max 5
    {
        if (!_context.Layout.Items.TryGetValue(itemId, out var item))
            continue;

        var itemRect = new ImRect(
            new Vector2(rect.Min.X + 4 * Scale.X, y),
            new Vector2(rect.Max.X - 4 * Scale.X, y + itemHeight)
        );

        // Draw mini item representation
        DrawCollapsedItem(drawList, item, itemRect);
        y += itemHeight + 2 * Scale.Y;
    }

    // Show count if more items
    if (collapsedItems.Count > 5)
    {
        var moreText = $"+{collapsedItems.Count - 5} more";
        drawList.AddText(
            new Vector2(rect.Min.X + 8 * Scale.X, y),
            UiColors.TextDim,
            moreText
        );
    }
}

private void DrawCollapsedItem(ImDrawListPtr drawList, MagGraphItem item, ImRect rect)
{
    var typeColor = TypeUiRegistry.GetPropertiesForType(item.PrimaryType).Color;

    // Background
    drawList.AddRectFilled(rect.Min, rect.Max, typeColor.Fade(0.2f), 2);

    // Type indicator
    drawList.AddRectFilled(
        rect.Min,
        new Vector2(rect.Min.X + 4 * Scale.X, rect.Max.Y),
        typeColor,
        2,
        ImDrawFlags.RoundCornersLeft
    );

    // Name
    var name = item.ReadableName;
    drawList.AddText(
        rect.Min + new Vector2(8 * Scale.X, 2 * Scale.Y),
        UiColors.Text,
        name
    );
}
```

---

## Hover Detection

```csharp
private bool IsAnnotationHovered(MagGraphAnnotation annotation)
{
    var mousePos = _context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    var rect = new ImRect(annotation.PosOnCanvas, annotation.PosOnCanvas + annotation.Size);

    return rect.Contains(mousePos);
}

private bool IsAnnotationHeaderHovered(MagGraphAnnotation annotation)
{
    var mousePos = _context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    var headerRect = new ImRect(
        annotation.PosOnCanvas,
        annotation.PosOnCanvas + new Vector2(annotation.Size.X, HeaderHeight)
    );

    return headerRect.Contains(mousePos);
}
```

---

## Color Palette

Annotations use a predefined color palette:

```csharp
private static readonly Color[] AnnotationColors =
{
    new Color(0.8f, 0.2f, 0.2f),  // Red
    new Color(0.2f, 0.6f, 0.2f),  // Green
    new Color(0.2f, 0.4f, 0.8f),  // Blue
    new Color(0.8f, 0.6f, 0.2f),  // Orange
    new Color(0.6f, 0.2f, 0.8f),  // Purple
    new Color(0.2f, 0.8f, 0.8f),  // Cyan
    new Color(0.8f, 0.8f, 0.2f),  // Yellow
    new Color(0.5f, 0.5f, 0.5f),  // Gray
};

internal static Color GetNextAnnotationColor()
{
    _colorIndex = (_colorIndex + 1) % AnnotationColors.Length;
    return AnnotationColors[_colorIndex];
}
```

---

## Z-Order

Annotations are drawn before nodes but after the background:

```
Drawing Order:
1. Background grid
2. Annotations (back to front by Y position)
3. Connections
4. Nodes
5. Temporary connections
6. Selection rect
7. Overlays
```

This ensures nodes appear on top of annotation frames.

---

## Next Steps

- **[Performance](18-performance.md)** - Optimization strategies
- **[Model Annotations](06-model-annotations.md)** - Annotation data model
- **[Interaction Annotations](12-interaction-annotations.md)** - Annotation interaction
