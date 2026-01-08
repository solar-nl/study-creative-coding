# Chapter 16: Connection Rendering - Drawing Wires

> *Most connections are invisible - that's the point*

---

## The Visual Philosophy: Less Wire, More Flow

Traditional node editors draw every connection as a visible curve. MagGraph takes a different approach: **snapped connections are invisible**.

When two nodes touch, there's no wire between them - they just touch. The connection exists logically (data flows), but visually, the nodes merge into a clean stack. Only when nodes are separated do curves appear.

This means connection rendering is really about the flowing connections:

- **Bezier curves** - Smooth S-shapes between separated nodes
- **Type coloring** - Each data type (float, texture, command) has a color
- **Temporary previews** - Wires that follow the mouse during drag operations
- **Hover feedback** - Highlighting when the mouse nears a wire

The visual result: cluttered graphs become readable because most wires disappear into snapped relationships.

**Key Source Files:**

- [MagGraphCanvas.Drawing.cs](../../../Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs)
- [MagGraphConnection.cs](../../../Editor/Gui/MagGraph/Model/MagGraphConnection.cs)

---

## Connection Styles Recap

```csharp
public enum ConnectionStyles
{
    // Snapped (invisible - items are touching)
    MainOutToMainInSnappedHorizontal = 0,
    MainOutToMainInSnappedVertical,
    MainOutToInputSnappedHorizontal,
    AdditionalOutToMainInputSnappedVertical,

    // Flowing (visible curves)
    BottomToTop = 4,
    BottomToLeft,
    RightToTop,
    RightToLeft,

    Unknown,
}
```

---

## Main Drawing Loop

```csharp
private void DrawConnections(ImDrawListPtr drawList)
{
    foreach (var connection in _context.Layout.MagConnections)
    {
        // Skip snapped connections (invisible)
        if (connection.IsSnapped)
            continue;

        // Skip if both endpoints are off-screen
        if (!IsConnectionVisible(connection))
            continue;

        DrawConnection(drawList, connection);
    }

    // Draw temporary connections (being dragged)
    foreach (var tempConnection in _context.TempConnections)
    {
        DrawTemporaryConnection(drawList, tempConnection);
    }
}
```

---

## Drawing a Connection

```csharp
private void DrawConnection(ImDrawListPtr drawList, MagGraphConnection connection)
{
    var sourcePos = TransformPosition(connection.DampedSourcePos);
    var targetPos = TransformPosition(connection.DampedTargetPos);
    var typeColor = TypeUiRegistry.GetPropertiesForType(connection.Type).Color;

    // Determine curve control points based on style
    Vector2 cp1, cp2;
    GetControlPoints(connection.Style, sourcePos, targetPos, out cp1, out cp2);

    // Draw the bezier curve
    drawList.AddBezierCubic(
        sourcePos,
        cp1,
        cp2,
        targetPos,
        typeColor,
        ConnectionThickness * Scale.X,
        SegmentCount
    );

    // Draw endpoint dots
    DrawConnectionEndpoints(drawList, sourcePos, targetPos, typeColor);
}
```

---

## Control Point Calculation

The curve shape depends on the connection style:

```csharp
private void GetControlPoints(MagGraphConnection.ConnectionStyles style,
    Vector2 source, Vector2 target, out Vector2 cp1, out Vector2 cp2)
{
    var distance = Vector2.Distance(source, target);
    var tangentLength = Math.Max(50, distance * 0.4f) * Scale.X;

    switch (style)
    {
        case ConnectionStyles.RightToLeft:
            // Horizontal S-curve
            cp1 = source + new Vector2(tangentLength, 0);
            cp2 = target - new Vector2(tangentLength, 0);
            break;

        case ConnectionStyles.BottomToTop:
            // Vertical S-curve
            cp1 = source + new Vector2(0, tangentLength);
            cp2 = target - new Vector2(0, tangentLength);
            break;

        case ConnectionStyles.RightToTop:
            // Right then up
            cp1 = source + new Vector2(tangentLength, 0);
            cp2 = target - new Vector2(0, tangentLength);
            break;

        case ConnectionStyles.BottomToLeft:
            // Down then left
            cp1 = source + new Vector2(0, tangentLength);
            cp2 = target - new Vector2(tangentLength, 0);
            break;

        default:
            // Default horizontal
            cp1 = source + new Vector2(tangentLength, 0);
            cp2 = target - new Vector2(tangentLength, 0);
            break;
    }
}
```

### Visual Examples

```
RightToLeft (horizontal S-curve):

    [Source]──────╮
                  │
                  ╰──────[Target]


BottomToTop (vertical S-curve):

    [Source]
        │
        ╰────────╮
                 │
            [Target]


RightToTop (corner):

    [Source]──────╮
                  │
                  │
            [Target]


BottomToLeft (corner):

    [Source]
        │
        │
        ╰──────[Target]
```

---

## Avoiding Stacked Items

Connections route around vertically stacked items:

```csharp
private void GetControlPointsWithAvoidance(MagGraphConnection connection,
    Vector2 source, Vector2 target, out Vector2 cp1, out Vector2 cp2)
{
    var stackArea = connection.TargetItem.VerticalStackArea;
    var needsAvoidance = stackArea.GetHeight() > MagGraphItem.GridSize.Y * 2;

    if (!needsAvoidance)
    {
        GetControlPoints(connection.Style, source, target, out cp1, out cp2);
        return;
    }

    // Route around the stack
    var stackTop = TransformY(stackArea.Min.Y);
    var stackBottom = TransformY(stackArea.Max.Y);

    if (source.Y < stackTop)
    {
        // Come in from the top
        cp1 = source + new Vector2(50 * Scale.X, 0);
        cp2 = new Vector2(target.X - 30 * Scale.X, stackTop - 20 * Scale.X);
    }
    else if (source.Y > stackBottom)
    {
        // Come in from the bottom
        cp1 = source + new Vector2(50 * Scale.X, 0);
        cp2 = new Vector2(target.X - 30 * Scale.X, stackBottom + 20 * Scale.X);
    }
    else
    {
        // Default behavior
        GetControlPoints(connection.Style, source, target, out cp1, out cp2);
    }
}
```

---

## Connection Endpoints

Small dots at connection endpoints:

```csharp
private void DrawConnectionEndpoints(ImDrawListPtr drawList,
    Vector2 source, Vector2 target, Color typeColor)
{
    var dotRadius = 3 * Scale.X;

    // Source dot
    drawList.AddCircleFilled(source, dotRadius, typeColor);

    // Target dot
    drawList.AddCircleFilled(target, dotRadius, typeColor);
}
```

---

## Temporary Connections

Connections being dragged have special rendering:

```csharp
private void DrawTemporaryConnection(ImDrawListPtr drawList, MagGraphConnection tempConnection)
{
    Vector2 sourcePos, targetPos;
    Color typeColor;

    if (tempConnection.SourceItem != null)
    {
        // Dragging from output
        sourcePos = TransformPosition(tempConnection.SourcePos);
        targetPos = TransformPosition(_context.PeekAnchorInCanvas);
        typeColor = TypeUiRegistry.GetPropertiesForType(tempConnection.SourceOutput.ValueType).Color;
    }
    else
    {
        // Dragging to input
        sourcePos = TransformPosition(_context.PeekAnchorInCanvas);
        targetPos = TransformPosition(tempConnection.TargetPos);
        typeColor = TypeUiRegistry.GetPropertiesForType(tempConnection.Type).Color;
    }

    // Calculate control points
    var tangentLength = Math.Max(50, Vector2.Distance(sourcePos, targetPos) * 0.3f);
    var cp1 = sourcePos + new Vector2(tangentLength, 0);
    var cp2 = targetPos - new Vector2(tangentLength, 0);

    // Draw dashed curve for temporary connection
    DrawDashedBezier(drawList, sourcePos, cp1, cp2, targetPos, typeColor);

    // Draw snap preview if near a valid target
    if (_context.ShouldAttemptToSnapToInput)
    {
        DrawSnapPreview(drawList, targetPos, typeColor);
    }
}
```

---

## Dashed Bezier Curves

For temporary connections:

```csharp
private void DrawDashedBezier(ImDrawListPtr drawList,
    Vector2 p0, Vector2 p1, Vector2 p2, Vector2 p3, Color color)
{
    const int segments = 32;
    const float dashLength = 8;
    const float gapLength = 4;

    var points = new Vector2[segments + 1];
    for (var i = 0; i <= segments; i++)
    {
        var t = i / (float)segments;
        points[i] = EvaluateBezier(p0, p1, p2, p3, t);
    }

    var totalLength = 0f;
    for (var i = 0; i < segments; i++)
    {
        totalLength += Vector2.Distance(points[i], points[i + 1]);
    }

    var currentLength = 0f;
    var dashOn = true;
    var lastPoint = points[0];

    for (var i = 1; i <= segments; i++)
    {
        var segmentLength = Vector2.Distance(lastPoint, points[i]);
        var threshold = dashOn ? dashLength : gapLength;

        if (currentLength + segmentLength >= threshold)
        {
            if (dashOn)
            {
                // Draw dash up to threshold
                var t = (threshold - currentLength) / segmentLength;
                var midPoint = Vector2.Lerp(lastPoint, points[i], t);
                drawList.AddLine(lastPoint, midPoint, color, ConnectionThickness * Scale.X);
            }
            dashOn = !dashOn;
            currentLength = 0;
        }
        else if (dashOn)
        {
            drawList.AddLine(lastPoint, points[i], color, ConnectionThickness * Scale.X);
        }

        currentLength += segmentLength;
        lastPoint = points[i];
    }
}

private Vector2 EvaluateBezier(Vector2 p0, Vector2 p1, Vector2 p2, Vector2 p3, float t)
{
    var u = 1 - t;
    var tt = t * t;
    var uu = u * u;
    var uuu = uu * u;
    var ttt = tt * t;

    return uuu * p0 + 3 * uu * t * p1 + 3 * u * tt * p2 + ttt * p3;
}
```

---

## Connection Hover Detection

For interaction (ripping connections):

```csharp
internal static float DistanceToConnection(MagGraphConnection connection, Vector2 point)
{
    var source = connection.DampedSourcePos;
    var target = connection.DampedTargetPos;

    // Sample points along the bezier
    const int samples = 20;
    var minDistance = float.MaxValue;

    Vector2 cp1, cp2;
    GetControlPointsStatic(connection.Style, source, target, out cp1, out cp2);

    for (var i = 0; i <= samples; i++)
    {
        var t = i / (float)samples;
        var bezierPoint = EvaluateBezier(source, cp1, cp2, target, t);
        var distance = Vector2.Distance(point, bezierPoint);
        minDistance = Math.Min(minDistance, distance);
    }

    return minDistance;
}
```

---

## Type Colors

Connection colors come from the type registry:

```csharp
// Common type colors:
// float      → Orange
// int        → Blue
// bool       → Green
// string     → Yellow
// Texture2D  → Purple
// Command    → White
// Object     → Gray

var typeColor = TypeUiRegistry.GetPropertiesForType(connection.Type).Color;
```

---

## Snapped Connection Indicators

Even though snapped connections are invisible, we show a subtle indicator:

```csharp
private void DrawSnappedConnectionIndicator(ImDrawListPtr drawList, MagGraphConnection connection)
{
    if (!connection.IsSnapped)
        return;

    // Small dot at the connection point
    var pos = TransformPosition(connection.SourcePos);
    var typeColor = TypeUiRegistry.GetPropertiesForType(connection.Type).Color;

    drawList.AddCircleFilled(pos, 2 * Scale.X, typeColor.Fade(0.5f));
}
```

---

## Next Steps

- **[Rendering Annotations](17-rendering-annotations.md)** - Drawing frames
- **[Model Connections](04-model-connections.md)** - Connection data model
- **[Interaction Connections](10-interaction-connections.md)** - Connection interaction
