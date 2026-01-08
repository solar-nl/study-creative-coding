# Appendix B: ImGui Patterns

> *The rendering API that powers everything visual*

MagGraph renders through ImGui's draw list API. If you're modifying rendering code, you'll use these patterns constantly. This appendix collects the most common ones for quick reference.

---

## Draw Lists

### Getting Draw Lists

```csharp
// Window draw list (clipped to window)
var drawList = ImGui.GetWindowDrawList();

// Background draw list (behind all windows)
var bgDrawList = ImGui.GetBackgroundDrawList();

// Foreground draw list (in front of all windows)
var fgDrawList = ImGui.GetForegroundDrawList();
```

### Drawing Primitives

```csharp
// Filled rectangle
drawList.AddRectFilled(min, max, color, cornerRadius);

// Rectangle outline
drawList.AddRect(min, max, color, cornerRadius, flags, thickness);

// Circle
drawList.AddCircleFilled(center, radius, color, segments);
drawList.AddCircle(center, radius, color, segments, thickness);

// Line
drawList.AddLine(p1, p2, color, thickness);

// Triangle
drawList.AddTriangleFilled(p1, p2, p3, color);

// Bezier curve
drawList.AddBezierCubic(p0, p1, p2, p3, color, thickness, segments);

// Text
drawList.AddText(fontSize, pos, color, text);
```

### Clip Rects

```csharp
// Restrict drawing to a rectangle
drawList.PushClipRect(min, max, intersectWithCurrent: true);
// ... draw operations ...
drawList.PopClipRect();
```

---

## Input Handling

### Mouse State

```csharp
// Mouse position
var mousePos = ImGui.GetMousePos();

// Mouse buttons
if (ImGui.IsMouseClicked(ImGuiMouseButton.Left)) { }
if (ImGui.IsMouseDown(ImGuiMouseButton.Left)) { }
if (ImGui.IsMouseReleased(ImGuiMouseButton.Left)) { }
if (ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)) { }

// Dragging
if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
{
    var delta = ImGui.GetIO().MouseDelta;
}

// Scroll
var wheel = ImGui.GetIO().MouseWheel;
```

### Keyboard State

```csharp
// Key presses
if (ImGui.IsKeyPressed(ImGuiKey.Tab)) { }
if (ImGui.IsKeyDown(ImGuiKey.Escape)) { }
if (ImGui.IsKeyReleased(ImGuiKey.Enter)) { }

// Modifiers
var io = ImGui.GetIO();
if (io.KeyCtrl) { }
if (io.KeyShift) { }
if (io.KeyAlt) { }

// Check if text input is active
if (io.WantTextInput) { /* don't process shortcuts */ }
```

---

## Window and Focus

### Window State

```csharp
// Window position and size
var pos = ImGui.GetWindowPos();
var size = ImGui.GetWindowSize();

// Focus and hover
var isFocused = ImGui.IsWindowFocused();
var isHovered = ImGui.IsWindowHovered();

// Hovered with flags
var hoveredInPopup = ImGui.IsWindowHovered(ImGuiHoveredFlags.AllowWhenBlockedByPopup);
```

### Item State

```csharp
// After ImGui widget calls
if (ImGui.IsItemHovered()) { }
if (ImGui.IsItemClicked()) { }
if (ImGui.IsItemActive()) { }
if (ImGui.IsAnyItemActive()) { }
```

---

## Common Widgets

### Input Fields

```csharp
// Text input
string text = "";
if (ImGui.InputText("Label", ref text, 256))
{
    // Text changed
}

// With flags
ImGui.InputText("Label", ref text, 256, ImGuiInputTextFlags.EnterReturnsTrue);

// Set focus
ImGui.SetKeyboardFocusHere();
```

### Buttons and Selectables

```csharp
// Button
if (ImGui.Button("Click Me"))
{
    // Clicked
}

// Selectable (for lists)
var isSelected = currentItem == thisItem;
if (ImGui.Selectable("Item Name", isSelected))
{
    currentItem = thisItem;
}
```

### Popups

```csharp
// Context menu
if (ImGui.BeginPopupContextWindow("menu_id"))
{
    if (ImGui.MenuItem("Option 1")) { }
    if (ImGui.MenuItem("Option 2", "Ctrl+O")) { }
    ImGui.Separator();
    if (ImGui.MenuItem("Exit")) { }
    ImGui.EndPopup();
}

// Modal popup
if (ImGui.BeginPopupModal("Confirm?"))
{
    ImGui.Text("Are you sure?");
    if (ImGui.Button("Yes")) { ImGui.CloseCurrentPopup(); }
    if (ImGui.Button("No")) { ImGui.CloseCurrentPopup(); }
    ImGui.EndPopup();
}
```

---

## Positioning

### Cursor Control

```csharp
// Set cursor for next widget
ImGui.SetCursorPos(localPos);
ImGui.SetCursorScreenPos(screenPos);

// Get cursor
var cursorPos = ImGui.GetCursorPos();
var cursorScreenPos = ImGui.GetCursorScreenPos();
```

### Window Positioning

```csharp
// Set next window position
ImGui.SetNextWindowPos(pos);
ImGui.SetNextWindowSize(size);
ImGui.SetNextWindowFocus();

// Constrain to work area
ImGui.SetNextWindowPos(pos, ImGuiCond.Always, pivot);
```

---

## Colors

### Color Conversion

```csharp
// Create color from RGBA (0-1)
var color = new Color(0.8f, 0.2f, 0.2f, 1.0f);

// Create color from uint (0xAABBGGRR)
var colorUint = ImGui.ColorConvertFloat4ToU32(new Vector4(r, g, b, a));

// Fade alpha
var fadedColor = color.Fade(0.5f);  // 50% alpha
```

### Color Styling

```csharp
// Push style color
ImGui.PushStyleColor(ImGuiCol.Button, buttonColor);
ImGui.Button("Styled Button");
ImGui.PopStyleColor();

// Multiple colors
ImGui.PushStyleColor(ImGuiCol.Button, buttonColor);
ImGui.PushStyleColor(ImGuiCol.ButtonHovered, hoverColor);
// ... widgets ...
ImGui.PopStyleColor(2);  // Pop 2 colors
```

---

## Timing

### Frame Timing

```csharp
// Delta time
var deltaTime = ImGui.GetIO().DeltaTime;

// Total time
var time = ImGui.GetTime();

// Frame count
var frameCount = ImGui.GetFrameCount();
```

---

## Clipboard

```csharp
// Get
var text = ImGui.GetClipboardText();

// Set
ImGui.SetClipboardText("Copy this");
```

---

## Common Patterns in MagGraph

### Transform and Draw

```csharp
private void DrawElement(ImDrawListPtr dl, Vector2 posOnCanvas)
{
    // Transform to screen space
    var screenPos = TransformPosition(posOnCanvas);

    // Draw at screen position
    dl.AddCircleFilled(screenPos, 10 * Scale.X, Color.White);
}
```

### Interactive Rectangle

```csharp
private bool DrawInteractiveRect(ImRect rect)
{
    var dl = ImGui.GetWindowDrawList();

    // Draw background
    dl.AddRectFilled(rect.Min, rect.Max, UiColors.Background);

    // Check interaction
    var mousePos = ImGui.GetMousePos();
    var isHovered = rect.Contains(mousePos);

    if (isHovered)
    {
        dl.AddRect(rect.Min, rect.Max, UiColors.Hover, 0, 0, 2);
    }

    return isHovered && ImGui.IsMouseClicked(ImGuiMouseButton.Left);
}
```

### Invisible Button

```csharp
// Create an invisible clickable area
var id = $"##InvisibleButton_{itemId}";
ImGui.SetCursorScreenPos(screenPos);
if (ImGui.InvisibleButton(id, size))
{
    // Clicked
}
```
