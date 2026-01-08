# Chapter 15: Node Rendering - Drawing Operators

> *600 lines to draw a box - because it's not just a box*

---

## Why Node Rendering Is Complex

At first glance, drawing a node seems simple: a rectangle with some text. But look closer:

- The **name** needs to fit, truncate, or show custom labels
- Each **input line** has a type color, connection state, and hover target
- Each **output line** has type indicators and connection dots
- **Hidden inputs/outputs** need expand affordances
- **Selection** and **hover** require visual feedback
- **Custom UI** (parameter widgets) can expand the node
- All of this must work at **any zoom level**

The node renderer is ~600 lines because each of these elements interacts with the others. A connected input looks different from a disconnected one. A selected node draws differently than an unselected one. Hover targets must be precise enough to distinguish inputs from the node body.

**Key Source Files:**

- [MagGraphCanvas.DrawNode.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphCanvas.DrawNode.cs) (~600 lines)
- [MagGraphCanvas.Drawing.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs)

---

## Node Anatomy

```
┌─────────────────────────────────────────────────────────────────┐
│                         MagGraphItem                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────── Vertical Input Anchor ──────────────┐            │
│  │                    ●                             │            │
│  ├──────────────────────────────────────────────────┤            │
│  │                                                  │            │
│  │  ●─── Input Line 0 ────────── Output Line 0 ───●  │ ← Primary │
│  │     (Type Color)              (Type Color)       │            │
│  │                                                  │            │
│  │  ●─── Input Line 1 ────────────────────────────  │            │
│  │     (Type Color)                                 │            │
│  │                                                  │            │
│  │  ●─── Input Line 2 ────────── Output Line 1 ───●  │            │
│  │                                                  │            │
│  ├──────────────────────────────────────────────────┤            │
│  │                    ●                             │            │
│  └──────────── Vertical Output Anchor ─────────────┘            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Main Draw Method

```csharp
private void DrawNodes(ImDrawListPtr drawList)
{
    foreach (var item in _context.Layout.Items.Values)
    {
        // Skip invisible items
        if (!IsVisible(item.Area))
            continue;

        // Skip collapsed items
        if (item.IsCollapsedAway)
            continue;

        switch (item.Variant)
        {
            case MagGraphItem.Variants.Operator:
                DrawOperatorNode(drawList, item);
                break;

            case MagGraphItem.Variants.Input:
                DrawInputNode(drawList, item);
                break;

            case MagGraphItem.Variants.Output:
                DrawOutputNode(drawList, item);
                break;

            case MagGraphItem.Variants.Placeholder:
                DrawPlaceholder(drawList, item);
                break;
        }
    }
}
```

---

## Drawing an Operator Node

```csharp
private void DrawOperatorNode(ImDrawListPtr drawList, MagGraphItem item)
{
    var screenRect = TransformRect(item.Area);
    var typeColor = TypeUiRegistry.GetPropertiesForType(item.PrimaryType).Color;

    // Determine visual state
    var isSelected = _context.Selector.IsSelected(item);
    var isHovered = item == _context.HoveredItem;
    var isDragged = _context.ItemMovement.IsItemDragged(item);

    // Background
    DrawNodeBackground(drawList, screenRect, typeColor, isSelected, isHovered);

    // Input lines
    for (var i = 0; i < item.InputLines.Length; i++)
    {
        DrawInputLine(drawList, item, ref item.InputLines[i], i);
    }

    // Output lines
    for (var i = 0; i < item.OutputLines.Length; i++)
    {
        DrawOutputLine(drawList, item, ref item.OutputLines[i], i);
    }

    // Name label
    DrawNodeLabel(drawList, item, screenRect);

    // Input/Output anchors
    DrawAnchors(drawList, item);

    // Selection indicator
    if (isSelected)
    {
        DrawSelectionBorder(drawList, screenRect);
    }

    // Snap indicator during drag
    if (isDragged && _context.ItemMovement.LastSnapTime > ImGui.GetTime() - 0.3)
    {
        DrawSnapIndicator(drawList, item);
    }
}
```

---

## Node Background

```csharp
private void DrawNodeBackground(ImDrawListPtr drawList, ImRect screenRect,
    Color typeColor, bool isSelected, bool isHovered)
{
    // Main background
    var bgColor = isHovered
        ? UiColors.NodeBackgroundHover
        : UiColors.NodeBackground;

    drawList.AddRectFilled(
        screenRect.Min,
        screenRect.Max,
        bgColor,
        CornerRadius
    );

    // Type color accent bar (top)
    var accentRect = new ImRect(
        screenRect.Min,
        new Vector2(screenRect.Max.X, screenRect.Min.Y + AccentHeight * Scale.Y)
    );

    drawList.AddRectFilled(
        accentRect.Min,
        accentRect.Max,
        typeColor,
        CornerRadius,
        ImDrawFlags.RoundCornersTop
    );

    // Border
    var borderColor = isSelected
        ? UiColors.Selection
        : isHovered
            ? UiColors.NodeBorderHover
            : UiColors.NodeBorder;

    drawList.AddRect(
        screenRect.Min,
        screenRect.Max,
        borderColor,
        CornerRadius
    );
}
```

---

## Drawing Input Lines

```csharp
private void DrawInputLine(ImDrawListPtr drawList, MagGraphItem item,
    ref MagGraphItem.InputLine line, int lineIndex)
{
    var typeColor = TypeUiRegistry.GetPropertiesForType(line.Type).Color;
    var lineY = item.DampedPosOnCanvas.Y + (0.5f + line.VisibleIndex) * MagGraphItem.LineHeight;

    var screenY = TransformY(lineY);
    var leftX = TransformX(item.DampedPosOnCanvas.X);
    var rightX = TransformX(item.DampedPosOnCanvas.X + MagGraphItem.Width);

    // Type color bar on left
    var barWidth = 4 * Scale.X;
    drawList.AddRectFilled(
        new Vector2(leftX, screenY - LineHeight / 2),
        new Vector2(leftX + barWidth, screenY + LineHeight / 2),
        typeColor
    );

    // Input name
    var inputName = line.InputUi?.InputDefinition.Name ?? "???";
    DrawText(drawList, inputName,
        new Vector2(leftX + barWidth + Padding, screenY),
        UiColors.Text,
        TextAlignment.Left
    );

    // Connection state indicator
    if (line.ConnectionState == MagGraphItem.InputLineStates.NotConnected)
    {
        // Draw empty circle
        DrawCircleStroke(drawList, new Vector2(leftX - AnchorRadius, screenY), AnchorRadius, typeColor);
    }
}
```

---

## Drawing Output Lines

```csharp
private void DrawOutputLine(ImDrawListPtr drawList, MagGraphItem item,
    ref MagGraphItem.OutputLine line, int lineIndex)
{
    var typeColor = TypeUiRegistry.GetPropertiesForType(line.Output.ValueType).Color;
    var lineY = item.DampedPosOnCanvas.Y + (0.5f + line.VisibleIndex) * MagGraphItem.LineHeight;

    var screenY = TransformY(lineY);
    var rightX = TransformX(item.DampedPosOnCanvas.X + MagGraphItem.Width);

    // Type color bar on right
    var barWidth = 4 * Scale.X;
    drawList.AddRectFilled(
        new Vector2(rightX - barWidth, screenY - LineHeight / 2),
        new Vector2(rightX, screenY + LineHeight / 2),
        typeColor
    );

    // Output name (right aligned)
    var outputName = line.OutputUi?.OutputDefinition.Name ?? "Out";
    DrawText(drawList, outputName,
        new Vector2(rightX - barWidth - Padding, screenY),
        UiColors.Text,
        TextAlignment.Right
    );
}
```

---

## Drawing Anchors

```csharp
private void DrawAnchors(ImDrawListPtr drawList, MagGraphItem item)
{
    // Vertical input anchor (top center)
    if (item.InputLines.Length > 0)
    {
        MagGraphItem.InputAnchorPoint anchor = default;
        item.GetInputAnchorAtIndex(0, ref anchor);
        DrawVerticalAnchor(drawList, anchor.PositionOnCanvas, anchor.ConnectionType,
            anchor.SnappedConnectionHash == MagGraphItem.FreeAnchor);
    }

    // Vertical output anchor (bottom center)
    if (item.OutputLines.Length > 0)
    {
        MagGraphItem.OutputAnchorPoint anchor = default;
        item.GetOutputAnchorAtIndex(0, ref anchor);
        DrawVerticalAnchor(drawList, anchor.PositionOnCanvas, anchor.ConnectionType,
            anchor.SnappedConnectionHash == MagGraphItem.FreeAnchor);
    }

    // Horizontal input anchors (left side)
    for (var i = 1; i < item.GetInputAnchorCount(); i++)
    {
        MagGraphItem.InputAnchorPoint anchor = default;
        item.GetInputAnchorAtIndex(i, ref anchor);
        DrawHorizontalInputAnchor(drawList, anchor.PositionOnCanvas, anchor.ConnectionType,
            anchor.SnappedConnectionHash == MagGraphItem.FreeAnchor);
    }

    // Horizontal output anchors (right side)
    for (var i = 1; i < item.GetOutputAnchorCount(); i++)
    {
        MagGraphItem.OutputAnchorPoint anchor = default;
        item.GetOutputAnchorAtIndex(i, ref anchor);
        DrawHorizontalOutputAnchor(drawList, anchor.PositionOnCanvas, anchor.ConnectionType,
            anchor.SnappedConnectionHash == MagGraphItem.FreeAnchor);
    }
}
```

---

## Anchor Visuals

```csharp
private void DrawVerticalAnchor(ImDrawListPtr drawList, Vector2 posOnCanvas,
    Type connectionType, bool isFree)
{
    var screenPos = TransformPosition(posOnCanvas);
    var color = TypeUiRegistry.GetPropertiesForType(connectionType).Color;

    if (isFree)
    {
        // Empty circle for free anchor
        drawList.AddCircle(screenPos, AnchorRadius * Scale.X, color, 12, 2);
    }
    else
    {
        // Filled circle for connected anchor
        drawList.AddCircleFilled(screenPos, AnchorRadius * Scale.X, color);
    }
}

private void DrawHorizontalInputAnchor(ImDrawListPtr drawList, Vector2 posOnCanvas,
    Type connectionType, bool isFree)
{
    var screenPos = TransformPosition(posOnCanvas);
    var color = TypeUiRegistry.GetPropertiesForType(connectionType).Color;
    var radius = AnchorRadius * Scale.X;

    // Draw triangle pointing left
    var p1 = screenPos + new Vector2(-radius, 0);
    var p2 = screenPos + new Vector2(radius * 0.5f, -radius);
    var p3 = screenPos + new Vector2(radius * 0.5f, radius);

    if (isFree)
    {
        drawList.AddTriangle(p1, p2, p3, color, 2);
    }
    else
    {
        drawList.AddTriangleFilled(p1, p2, p3, color);
    }
}
```

---

## Node Label

```csharp
private void DrawNodeLabel(ImDrawListPtr drawList, MagGraphItem item, ImRect screenRect)
{
    var name = item.ReadableName;

    // Truncate if too long
    var maxWidth = screenRect.GetWidth() - Padding * 2;
    var fontSize = DefaultFontSize * Scale.Y;

    var textSize = ImGui.CalcTextSize(name) * Scale;
    if (textSize.X > maxWidth)
    {
        name = TruncateText(name, maxWidth, fontSize);
    }

    // Center text
    var textPos = new Vector2(
        screenRect.Min.X + (screenRect.GetWidth() - textSize.X) / 2,
        screenRect.Min.Y + AccentHeight * Scale.Y + Padding
    );

    drawList.AddText(fontSize, textPos, UiColors.Text, name);
}
```

---

## Selection Border

```csharp
private void DrawSelectionBorder(ImDrawListPtr drawList, ImRect screenRect)
{
    var thickness = 2 * Scale.X;
    var offset = thickness / 2;

    drawList.AddRect(
        screenRect.Min - new Vector2(offset),
        screenRect.Max + new Vector2(offset),
        UiColors.Selection,
        CornerRadius + offset,
        ImDrawFlags.None,
        thickness
    );
}
```

---

## Snap Indicator

```csharp
private void DrawSnapIndicator(ImDrawListPtr drawList, MagGraphItem item)
{
    var timeSinceSnap = ImGui.GetTime() - _context.ItemMovement.LastSnapTime;
    var alpha = 1f - (float)(timeSinceSnap / 0.3);

    if (alpha <= 0)
        return;

    var targetPos = TransformPosition(_context.ItemMovement.LastSnapTargetPositionOnCanvas);
    var color = UiColors.SnapIndicator.Fade(alpha);

    // Draw expanding circle
    var radius = (1 - alpha) * 30 * Scale.X;
    drawList.AddCircle(targetPos, radius, color, 32, 2);
}
```

---

## Input/Output Nodes (Symbol Boundaries)

```csharp
private void DrawInputNode(ImDrawListPtr drawList, MagGraphItem item)
{
    var screenRect = TransformRect(item.Area);
    var typeColor = TypeUiRegistry.GetPropertiesForType(item.PrimaryType).Color;

    // Special styling for input nodes
    drawList.AddRectFilled(
        screenRect.Min,
        screenRect.Max,
        typeColor.Fade(0.3f),
        CornerRadius
    );

    // Arrow pointing right
    var center = screenRect.GetCenter();
    var arrowSize = 10 * Scale.X;
    drawList.AddTriangleFilled(
        center + new Vector2(-arrowSize, -arrowSize),
        center + new Vector2(arrowSize, 0),
        center + new Vector2(-arrowSize, arrowSize),
        typeColor
    );

    // Label
    var name = item.ReadableName;
    DrawText(drawList, name, center + new Vector2(0, -20 * Scale.Y), UiColors.Text, TextAlignment.Center);
}
```

---

## Custom UI Integration

Some operators have custom inline UI:

```csharp
private void DrawOperatorCustomUi(MagGraphItem item)
{
    if (item.OpUiBinding == null)
        return;

    var screenRect = TransformRect(item.Area);

    ImGui.SetCursorScreenPos(screenRect.Min + new Vector2(Padding, AccentHeight + Padding));

    // Draw custom UI if implemented
    if (item.OpUiBinding.DrawCustomUi(item.Instance, screenRect.GetWidth() - Padding * 2))
    {
        _context.ItemWithActiveCustomUi = item;
    }
}
```

---

## Next Steps

- **[Rendering Connections](16-rendering-connections.md)** - Drawing wires
- **[Rendering Annotations](17-rendering-annotations.md)** - Drawing frames
- **[Model Items](03-model-items.md)** - The data model behind nodes
