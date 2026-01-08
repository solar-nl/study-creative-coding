# Chapter 4: Scalar Outputs

> *Float, bool, string, and vector visualizations*

---

## The Problem: Making Numbers Meaningful

Here's a challenge that seems simple but isn't: your visual programming environment produces a float value. Maybe it's 0.7532. How do you show that to a user in a way that's actually useful?

You could just display "0.7532" as text. But that tells you almost nothing. Is 0.7532 normal? Is it changing? Is it oscillating? Climbing steadily? Stuck at a value it shouldn't be?

The key insight is that **a number in isolation is nearly meaningless**. What matters is *context* - how that number behaves over time. A user debugging an animation curve needs to see that the value smoothly interpolates from 0 to 1. A user troubleshooting a physics simulation needs to see that velocity is oscillating wildly when it should be stable.

This is the problem scalar outputs solve: **transforming raw values into visual stories**.

---

## The Solution: Time-Series Visualization

Scalar outputs treat values as streams, not snapshots. Every time the system evaluates a float, that value gets added to a history. The history is rendered as a curve that scrolls from right to left, like a heart monitor or an oscilloscope.

Think of it like this: instead of asking "what is the value?" we're asking "how does the value *behave*?"

```
┌─────────────────────────────────────────────────┐
│                                          0.7532 │
│    ╭──╮                                         │
│   ╱    ╲    ╭──╮                    ╭──╮        │
│──╱      ╲──╱    ╲───────╮    ╭──╮  ╱    ╲       │
│           ╲       ╲     ╲──╱    ╲╱      ─       │
│            ╲───────╲────────────────────────────│
│                                                 │
└─────────────────────────────────────────────────┘
      ← 500 samples history →           Current →
```

Now when a user sees their output, they can immediately tell: "Ah, it's oscillating with decreasing amplitude - my damping is working." Or: "Wait, why did it spike there? Something's wrong at frame 230."

---

## Why 500 Samples?

You might wonder: why keep 500 samples of history? Why not 100, or 1000, or unlimited?

This is a balance of competing concerns:

- **Too few samples** (say, 50) and you can't see patterns that develop over time. An oscillation with a long period looks like noise.
- **Too many samples** (say, 5000) and memory adds up. In a complex project, you might have dozens of float outputs visible simultaneously.
- **500 samples** at 60fps gives you about 8 seconds of history - enough to see most patterns while keeping memory reasonable.

The other key decision is using a **circular buffer**. Instead of constantly allocating new memory and copying old values, we just write to the next slot and wrap around when we hit the end. This makes the per-frame cost constant regardless of history length.

---

## The FloatOutputUi Implementation

With that context, let's look at how FloatOutputUi is structured:

```csharp
internal sealed class FloatOutputUi : OutputUi<float>
{
    private static readonly ConditionalWeakTable<string, ViewSettings> _viewSettings = [];

    private class ViewSettings
    {
        public CurvePlotCanvas CurveCanvas { get; } = new();
        public Slot<float> CurrentSlot { get; set; }
    }

    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        if (slot is not Slot<float> typedSlot)
            return;

        if (!_viewSettings.TryGetValue(viewId, out var settings))
        {
            settings = new ViewSettings { CurrentSlot = typedSlot };
            _viewSettings.Add(viewId, settings);
        }

        settings.CurveCanvas.Draw(typedSlot.Value);
    }
}
```

Notice how simple this is - just 20 lines. The key insight is **delegation**: FloatOutputUi doesn't know how to draw curves. It just knows that floats should be visualized as curves, so it hands off to `CurvePlotCanvas` which is an expert at curve drawing.

This separation matters. Tomorrow we might want to add a "bar graph" mode for floats. With delegation, we can swap out the canvas without touching FloatOutputUi at all.

---

## The CurvePlotCanvas: Where the Magic Happens

The real work happens in CurvePlotCanvas. Let's trace through what it does each frame:

### Step 1: Update the History

```csharp
if (!_isPaused)
{
    _graphValues[_sampleOffset] = value;
    _sampleOffset = (_sampleOffset + 1) % MaxSampleCount;
    _lastValue = value;
}
```

This is the circular buffer in action. We write the new value at the current offset, then advance the offset (wrapping at 500). The newest value is always at `_sampleOffset - 1`, the oldest at `_sampleOffset`.

### Step 2: Calculate the Y-Axis Range

```csharp
var min = _graphValues.Min();
var max = _graphValues.Max();
var padding = (max - min) * 0.1f;
```

The Y-axis auto-scales to fit the data. Why? Because a float might range from 0-1, or from -1000 to 1000, or anywhere in between. Fixed axes would either clip data or waste screen space.

The 10% padding prevents the curve from touching the very top and bottom of the canvas, which looks cramped.

### Step 3: Render with ImGui

```csharp
ImGui.PlotLines("##curve",
    ref _graphValues[0],
    MaxSampleCount,
    _sampleOffset,
    null,
    min - padding,
    max + padding,
    windowSize
);
```

ImGui's PlotLines does the heavy lifting. The `_sampleOffset` parameter tells it where the circular buffer starts, so it draws the samples in the right order.

### Step 4: Show the Current Value

```csharp
var valueText = $"{_lastValue:G5}";
var textPos = new Vector2(
    windowPos.X + windowSize.X - ImGui.CalcTextSize(valueText).X - 5,
    windowPos.Y + 5
);
drawList.AddText(fontSize, textPos, UiColors.Text, valueText);
```

The exact current value appears in the top-right corner. Users need both: the curve shows *behavior*, the number shows *precision*. Sometimes you need to know it's exactly 0.5, not approximately 0.5.

### Step 5: Handle Interaction

```csharp
if (ImGui.IsWindowHovered() && ImGui.IsMouseClicked(ImGuiMouseButton.Left))
{
    _isPaused = !_isPaused;
}
```

Clicking pauses the curve. This is essential for debugging - sometimes you need to freeze a moment in time and examine it.

---

## Booleans: A Special Case of Floats

Here's an elegant realization: a boolean is just a float that can only be 0 or 1. So BoolOutputUi doesn't need its own rendering system - it just converts the bool to a float and reuses CurvePlotCanvas:

```csharp
settings.CurveCanvas.Draw(typedSlot.Value ? 1f : 0f);
```

The result is a square wave that shows exactly when the boolean was true or false:

```
┌─────────────────────────────────────────────────┐
│                                               1 │
│ ████      ████████████      ██████████████████  │
│                                                 │
│     ██████            ██████                    │
│                                               0 │
└─────────────────────────────────────────────────┘
```

This is a perfect example of the power of abstraction. BoolOutputUi is essentially one line of interesting code - everything else is inherited from the scalar output pattern.

---

## Strings: A Different Kind of Scalar

Strings don't fit the curve pattern - they're not numerical. But they're still "scalar" in the sense that they're a single value (as opposed to a list or a texture).

StringOutputUi takes a code-editor approach: display the text with line numbers.

```csharp
for (var i = 0; i < lines.Length; i++)
{
    // Line number (gray)
    ImGui.TextColored(UiColors.TextMuted, $"{i + 1,4} ");
    ImGui.SameLine();

    // Line content (with comment highlighting)
    if (line.TrimStart().StartsWith("//"))
    {
        ImGui.TextColored(UiColors.Comment, line);
    }
    else
    {
        ImGui.TextUnformatted(line);
    }
}
```

The result looks like a code editor:

```
┌─────────────────────────────────────────────────┐
│   1  Hello World                                │
│   2  // This is a comment                       │
│   3  Some more text here                        │
│   4                                             │
│   5  Final line                                 │
└─────────────────────────────────────────────────┘
```

Line numbers matter for debugging - "there's an error on line 47" is more useful than "there's an error somewhere in this blob of text."

There's also a subtle UX touch: clicking copies the text to clipboard. Strings are often intermediate results that users need to paste elsewhere.

---

## Vectors: Multiple Curves, One Canvas

Vectors introduce a new challenge: a Vector3 has three components (X, Y, Z) that all change over time. How do you visualize that?

The answer is **overlaid curves with color coding**:

```
┌─────────────────────────────────────────────────┐
│                                     X:  0.532   │
│   ──────────────────────────────────Y:  1.234   │
│  ╱╲    ╱╲         (red line)        Z: -0.891   │
│ ╱  ╲  ╱  ╲   ╱╲                                 │
│╱    ╲╱    ╲ ╱  ╲                                │
│           ──────────────── (green line)         │
│    ╱╲  ╱╲                                       │
│   ╱  ╲╱  ╲───────────────── (blue line)         │
└─────────────────────────────────────────────────┘
```

The color scheme follows the industry convention: **X is red, Y is green, Z is blue**. This is universal in 3D tools - Blender, Maya, Unity all use it. Users can glance at a vector curve and immediately know which component is which.

Why RGB for XYZ? One theory: X/Y/Z and R/G/B are both the first three letters of their respective sequences. Another theory: it's just convention that's been around so long nobody remembers why. Either way, following the convention means users don't have to relearn.

### The VectorCurvePlotCanvas

Unlike CurvePlotCanvas which uses ImGui's PlotLines, VectorCurvePlotCanvas draws manually with polylines:

```csharp
for (int c = 0; c < _componentCount; c++)
{
    var color = GetComponentColor(c);

    drawList.AddPolyline(
        ref _graphPoints[c, 0],
        SampleCount,
        color,
        ImDrawFlags.None,
        1.5f
    );

    // Draw endpoint circle
    var lastPoint = _graphPoints[c, (_sampleOffset - 1 + SampleCount) % SampleCount];
    drawList.AddCircleFilled(lastPoint, 3, color);
}
```

The endpoint circles are a nice touch - they highlight the current position on each curve, making it easy to read off the current values even when curves overlap.

---

## Generics: One Implementation for Many Types

Notice that VectorOutputUi is generic: `VectorOutputUi<T>`. This single class handles Vector2, Vector3, Vector4, and Quaternion.

How does it extract components from different vector types? Through a utility function:

```csharp
public static float[] GetFloatsFromVector<T>(T value)
{
    return value switch
    {
        Vector2 v => new[] { v.X, v.Y },
        Vector3 v => new[] { v.X, v.Y, v.Z },
        Vector4 v => new[] { v.X, v.Y, v.Z, v.W },
        Quaternion q => new[] { q.X, q.Y, q.Z, q.W },
        _ => new[] { 0f }
    };
}
```

This is a classic trade-off. We could have separate Vector2OutputUi, Vector3OutputUi, etc. - more type-specific but more code duplication. Or we can use generics with runtime type checking - less duplication but a small runtime cost.

For UI code that runs at 60fps, the cost of one switch statement per frame is negligible. The reduced maintenance burden of having one implementation is worth it.

---

## Common Patterns Across All Scalar Outputs

Looking at all the scalar outputs together, you'll notice they share the same structure:

### Pattern 1: Per-View State

```csharp
private static readonly ConditionalWeakTable<string, ViewSettings> _viewSettings = [];

if (!_viewSettings.TryGetValue(viewId, out var settings))
{
    settings = new ViewSettings();
    _viewSettings.Add(viewId, settings);
}
```

Each view (graph view, output panel, pop-out window) needs its own curve history. The ConditionalWeakTable ensures automatic cleanup when views close.

### Pattern 2: Typed Slot Validation

```csharp
if (slot is not Slot<T> typedSlot)
    return;
```

Always verify the slot type before proceeding. This is defensive programming - the system should never pass the wrong type, but if it does, we fail gracefully.

### Pattern 3: Canvas Delegation

```csharp
settings.CurveCanvas.Draw(typedSlot.Value);
```

The OutputUi knows *what* to visualize. The Canvas knows *how* to visualize it. This separation keeps both simple and allows mixing and matching.

---

## Summary: From Numbers to Understanding

Scalar outputs solve the fundamental problem of making raw values meaningful:

1. **Floats and bools** become time-series curves, revealing behavior patterns
2. **Strings** become line-numbered text, enabling precise debugging
3. **Vectors** become color-coded multi-channel curves, showing component relationships

The key design decisions:

- **500-sample circular buffers** balance history depth against memory
- **Auto-scaling Y-axis** handles any data range
- **Color-coded components** follow industry convention (RGB = XYZ)
- **Canvas delegation** separates what from how
- **Click-to-pause** enables freezing moments for analysis

The result: users can glance at an output and immediately understand not just what the value is, but how it's behaving. That's the difference between data and insight.

---

## Key Source Files

- `Editor/Gui/OutputUi/FloatOutputUi.cs`
- `Editor/Gui/OutputUi/BoolOutputUi.cs`
- `Editor/Gui/OutputUi/StringOutputUi.cs`
- `Editor/Gui/OutputUi/VectorOutputUi.cs`
- `Editor/Gui/UiHelpers/CurvePlotCanvas.cs`
- `Editor/Gui/UiHelpers/VectorCurvePlotCanvas.cs`

---

## What's Next

- **[Chapter 5: Texture Outputs](05-texture-outputs.md)** - How images are displayed with pan/zoom support
- **[Chapter 6: Collection Outputs](06-collection-outputs.md)** - Lists and dictionaries

