# Chapter 8: Extending OutputUi

> *Creating custom output type renderers*

---

## When Would You Need This?

You've been happily using T3's built-in output visualizations - floats show as curves, textures display as images, commands render to the output window. Then one day you create a new data type. Maybe it's a `ParticleSystem` that holds thousands of particle positions. Or an `AudioSpectrum` with frequency bins. Or a custom `AnimationCurve` with keyframes.

You connect your operator's output and... you see the type name and a boring ToString() result. The fallback renderer (`ValueOutputUi<T>`) has kicked in. It works, but it's not *useful*. You can't see what's happening inside your data.

The key insight is that **you know things about your data type that the system can't possibly guess**. You know that particle positions are meaningful in 2D space. You know that audio spectrums should be bar graphs. You know that animation curves should show their shape with handles.

Creating a custom OutputUi lets you share that knowledge with the visualization system.

---

## The Mental Model: Becoming a Specialist

Think of the OutputUi system as a hospital with specialists. When a patient (data) arrives, the system asks "what kind of condition is this?" and routes to the right specialist. FloatOutputUi is the cardiologist - it knows all about heart rate curves. Texture2dOutputUi is the radiologist - it knows about images.

When you create a custom OutputUi, you're training a new specialist. You're teaching the system: "When you see a `ParticleSystem`, here's exactly how to examine and display it."

The beautiful thing about this design is that you don't need to modify any central code. You just:

1. Create your specialist class
2. Register it with the reception desk (the factory)
3. The system automatically routes your type to your specialist

---

## What Does Every OutputUi Need?

Before diving into code, let's understand the contract. Every OutputUi must answer three questions:

**1. How do you copy yourself?** (The `Clone` method)

You might wonder why copying matters. Consider this: the same output can appear in multiple places simultaneously - in the graph view, in a pop-out panel, in a dedicated output window. Each view needs its *own* OutputUi instance so they don't interfere with each other.

When the system needs another view of your output, it clones your OutputUi. Your clone method must copy the essential properties that define "which output this visualizes."

**2. How do you draw your value?** (The `DrawTypedValue` method)

This is your main creative space. Given the current value and a view identifier, render something meaningful using ImGui. You receive a `viewId` so you can maintain separate state for each view (more on this later).

**3. Do you need special evaluation logic?** (The `Recompute` method, optional)

Most OutputUis just display values. But some need to do special work before or after the operator runs - setting up GPU resources, capturing intermediate state, etc. You can override `Recompute` for these cases.

---

## A Worked Example: Visualizing Custom Data

Let's walk through creating an OutputUi for a hypothetical `SensorReading` type that contains a timestamp and a measurement value. We want to show a scrolling history of measurements over time.

### Step 1: Think About What Matters

Before writing code, ask yourself:

- What aspects of this data are users trying to understand?
- How does this data behave over time?
- What controls would help exploration?

For sensor readings, users probably care about:

- The current value (prominently displayed)
- How the value has changed recently (a history plot)
- Maybe a pause button to freeze the view while data keeps flowing

### Step 2: Start with the Skeleton

The minimal structure for any OutputUi is:

```csharp
internal sealed class SensorReadingOutputUi : OutputUi<SensorReading>
{
    public override IOutputUi Clone()
    {
        return new SensorReadingOutputUi
        {
            OutputDefinition = OutputDefinition,
            PosOnCanvas = PosOnCanvas,
            Size = Size
        };
    }

    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        if (slot is not Slot<SensorReading> typedSlot)
            return;

        var reading = typedSlot.Value;
        if (reading == null)
        {
            ImGui.TextUnformatted("No data");
            return;
        }

        // Your visualization here
        ImGui.TextUnformatted($"Value: {reading.Measurement}");
    }
}
```

Notice the slot type check at the beginning of `DrawTypedValue`. This is defensive programming - the slot *should* always be the right type, but checking prevents crashes if something goes wrong in the plumbing.

Also notice how we handle null. Users will see "No data" rather than a crash or confusing behavior.

### Step 3: Add Per-View State

Here's where things get interesting. We want each view to have its own history buffer. If you open two windows showing the same output, each should have independent pause states.

You might be tempted to just add instance fields:

```csharp
// Don't do this!
private float[] _history = new float[100];
private bool _paused = false;
```

The problem: when the OutputUi is cloned for a second view, both views share these fields. Pause one, and you pause both.

The solution is a static lookup table keyed by view ID. And not just any table - we use `ConditionalWeakTable` because it automatically cleans up when view IDs are garbage collected:

```csharp
private static readonly ConditionalWeakTable<string, ViewSettings> _viewSettings = [];

private class ViewSettings
{
    public float[] History { get; } = new float[100];
    public int WritePosition { get; set; }
    public bool Paused { get; set; }
}
```

Now `DrawTypedValue` can get or create settings for its view:

```csharp
protected override void DrawTypedValue(ISlot slot, string viewId)
{
    if (slot is not Slot<SensorReading> typedSlot)
        return;

    // Get or create per-view settings
    if (!_viewSettings.TryGetValue(viewId, out var settings))
    {
        settings = new ViewSettings();
        _viewSettings.Add(viewId, settings);
    }

    var reading = typedSlot.Value;
    if (reading == null)
    {
        ImGui.TextUnformatted("No data");
        return;
    }

    // Update history (unless paused)
    if (!settings.Paused)
    {
        settings.History[settings.WritePosition] = reading.Measurement;
        settings.WritePosition = (settings.WritePosition + 1) % settings.History.Length;
    }

    // Draw the plot
    ImGui.PlotLines("##history", ref settings.History[0], settings.History.Length);

    // Pause control
    if (ImGui.Button(settings.Paused ? "Resume" : "Pause"))
        settings.Paused = !settings.Paused;
}
```

Each view now has completely independent history and pause state. Close a view, and ConditionalWeakTable automatically removes its settings - no memory leaks.

### Step 4: Register with the Factory

The final step is telling the system about your new specialist. In `UiRegistration.cs`:

```csharp
OutputUiFactory.Instance.AddFactory(
    typeof(SensorReading),
    () => new SensorReadingOutputUi()
);
```

That's it. From now on, any output of type `SensorReading` will use your custom visualization.

---

## When You Need More: Advanced Patterns

The basic pattern handles most cases, but some visualizations need additional capabilities.

### Complex Visualizations with Helper Classes

If your drawing logic becomes substantial, consider extracting it to a helper canvas class. This keeps the OutputUi focused on orchestration while the canvas handles rendering details.

The pattern looks like this: your OutputUi maintains per-view canvas instances, and each canvas knows how to draw your data type:

```csharp
private static readonly ConditionalWeakTable<string, SensorCanvas> _canvases = [];

protected override void DrawTypedValue(ISlot slot, string viewId)
{
    if (slot is not Slot<SensorReading> typedSlot)
        return;

    if (!_canvases.TryGetValue(viewId, out var canvas))
    {
        canvas = new SensorCanvas();
        _canvases.Add(viewId, canvas);
    }

    canvas.Draw(typedSlot.Value);
}
```

The canvas class can maintain elaborate state - zoom levels, selection, animation - without cluttering the OutputUi.

### Multiple View Modes

Sometimes data can be meaningfully visualized in different ways. Think of `FloatListOutputUi` which offers both grid and plot modes. Users can switch based on what they're trying to understand.

The key insight here is that mode selection is per-view state. One view might be in grid mode while another shows a plot:

```csharp
private enum ViewMode { Summary, Detailed, TimeSeries }

private class ViewSettings
{
    public ViewMode Mode { get; set; } = ViewMode.Summary;
    // ... other state
}

protected override void DrawTypedValue(ISlot slot, string viewId)
{
    // ... get settings ...

    // Mode selector
    if (ImGui.RadioButton("Summary", settings.Mode == ViewMode.Summary))
        settings.Mode = ViewMode.Summary;
    ImGui.SameLine();
    if (ImGui.RadioButton("Detailed", settings.Mode == ViewMode.Detailed))
        settings.Mode = ViewMode.Detailed;
    ImGui.SameLine();
    if (ImGui.RadioButton("Time Series", settings.Mode == ViewMode.TimeSeries))
        settings.Mode = ViewMode.TimeSeries;

    // Draw based on mode
    switch (settings.Mode)
    {
        case ViewMode.Summary:
            DrawSummary(reading);
            break;
        case ViewMode.Detailed:
            DrawDetailed(reading);
            break;
        case ViewMode.TimeSeries:
            DrawTimeSeries(reading, settings);
            break;
    }
}
```

### Custom Evaluation Logic

Most OutputUis accept values as-is. But sometimes you need to do work before or after the operator evaluates. Maybe you're visualizing GPU data that needs render targets set up. Maybe you need to capture something before evaluation overwrites it.

Override `Recompute` for this:

```csharp
protected override void Recompute(ISlot slot, EvaluationContext context)
{
    // Pre-evaluation: set up resources
    PrepareRenderTarget(context.RequestedResolution);

    // Standard evaluation - runs the operator
    base.Recompute(slot, context);

    // Post-evaluation: capture results, restore state
    CaptureResult();
    RestorePreviousState();
}
```

The base implementation invalidates the slot and calls Update. By overriding, you can wrap that with your own setup and teardown.

### GPU Resources

For visualizations that need Direct3D textures or other GPU resources, remember two things:

1. **Create lazily and resize on demand.** Check if your existing texture matches the needed size before recreating.

2. **Dispose properly.** GPU resources don't garbage collect automatically. Implement a finalizer or IDisposable to clean up.

```csharp
private Texture2D _texture;
private ShaderResourceView _srv;

private void EnsureTexture(Size2 size)
{
    if (_texture != null &&
        _texture.Description.Width == size.Width &&
        _texture.Description.Height == size.Height)
    {
        return; // Already the right size
    }

    // Clean up old resources
    _srv?.Dispose();
    _texture?.Dispose();

    // Create new ones
    _texture = new Texture2D(ResourceManager.Device, /* description */);
    _srv = new ShaderResourceView(ResourceManager.Device, _texture);
}

~MyTypeOutputUi()
{
    _srv?.Dispose();
    _texture?.Dispose();
}
```

---

## The Fallback Behavior

What happens if you don't register your type? The system doesn't crash. Instead, `OutputUiFactory` creates a `ValueOutputUi<T>` - a generic fallback that shows the type name and calls `ToString()` on the value.

This is intentional. New types work immediately (albeit with minimal visualization), and you can add specialized renderers incrementally as the need arises.

---

## Common Pitfalls and How to Avoid Them

### Forgetting to Handle Null

Always check for null values and disposed resources. A sensor that hasn't sent data yet, a texture that failed to load - these happen in real usage:

```csharp
if (typedSlot.Value == null)
{
    ImGui.TextUnformatted("No data");
    return;
}
```

### Using Dictionary Instead of ConditionalWeakTable

Regular dictionaries accumulate entries for closed views, causing memory leaks. ConditionalWeakTable automatically cleans up:

```csharp
// Correct: automatic cleanup
private static readonly ConditionalWeakTable<string, ViewSettings> _settings = [];

// Problematic: manual cleanup needed (and often forgotten)
private static readonly Dictionary<string, ViewSettings> _settings = [];
```

### Copying Per-View State in Clone

The `Clone` method should copy the *definition* properties (OutputDefinition, PosOnCanvas, Size), not the per-view state. Each view creates its own state on first access:

```csharp
public override IOutputUi Clone()
{
    return new SensorReadingOutputUi
    {
        OutputDefinition = OutputDefinition,
        PosOnCanvas = PosOnCanvas,
        Size = Size
        // Don't copy _history, _paused, etc. - each view gets fresh state
    };
}
```

---

## Registration Patterns

### Standard Registration

For most types, a simple factory registration suffices:

```csharp
OutputUiFactory.Instance.AddFactory(
    typeof(SensorReading),
    () => new SensorReadingOutputUi()
);
```

### Generic Type Registration

If you build a generic OutputUi (like `VectorOutputUi<T>` that works for Vector2, Vector3, and Vector4), register each closed type separately:

```csharp
OutputUiFactory.Instance.AddFactory(typeof(Vector2), () => new VectorOutputUi<Vector2>());
OutputUiFactory.Instance.AddFactory(typeof(Vector3), () => new VectorOutputUi<Vector3>());
OutputUiFactory.Instance.AddFactory(typeof(Vector4), () => new VectorOutputUi<Vector4>());
```

---

## Putting It All Together

Here's a complete, production-ready example that incorporates the patterns we've discussed:

```csharp
using System.Runtime.CompilerServices;
using ImGuiNET;
using T3.Core.Operator.Slots;
using T3.Editor.Gui.UiHelpers;

namespace T3.Editor.Gui.OutputUi;

internal sealed class SensorReadingOutputUi : OutputUi<SensorReading>
{
    private static readonly ConditionalWeakTable<string, ViewSettings> _settings = [];

    private class ViewSettings
    {
        public CurvePlotCanvas Canvas { get; } = new();
        public bool ShowDetails { get; set; }
    }

    public override IOutputUi Clone()
    {
        return new SensorReadingOutputUi
        {
            OutputDefinition = OutputDefinition,
            PosOnCanvas = PosOnCanvas,
            Size = Size
        };
    }

    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        // Validate slot type
        if (slot is not Slot<SensorReading> typedSlot)
            return;

        var reading = typedSlot.Value;
        if (reading == null)
        {
            ImGui.TextUnformatted("No sensor data");
            return;
        }

        // Get or create per-view settings
        if (!_settings.TryGetValue(viewId, out var settings))
        {
            settings = new ViewSettings();
            _settings.Add(viewId, settings);
        }

        // Toggle for additional details
        ImGui.Checkbox("Show Details", ref settings.ShowDetails);

        // Main visualization - the measurement curve
        settings.Canvas.Draw(reading.Measurement);

        // Optional detailed view
        if (settings.ShowDetails)
        {
            ImGui.Separator();
            ImGui.TextUnformatted($"Timestamp: {reading.Timestamp:F3}s");
            ImGui.TextUnformatted($"Measurement: {reading.Measurement:F4}");
            ImGui.TextUnformatted($"Sensor ID: {reading.SensorId}");
        }
    }
}
```

Register it once in `UiRegistration.cs`:

```csharp
OutputUiFactory.Instance.AddFactory(
    typeof(SensorReading),
    () => new SensorReadingOutputUi()
);
```

---

## Summary

Creating a custom OutputUi is about teaching the visualization system how to display your data meaningfully. The key ideas:

1. **Inherit from `OutputUi<T>`** to get the base infrastructure.

2. **Implement `Clone`** copying definition properties (OutputDefinition, PosOnCanvas, Size) so multiple views work correctly.

3. **Implement `DrawTypedValue`** with your visualization logic. Always validate the slot type and handle null gracefully.

4. **Use ConditionalWeakTable for per-view state** to get automatic cleanup when views close.

5. **Register your type with the factory** so the system knows to use your specialist.

For complex cases, factor rendering into helper canvas classes, offer multiple view modes, or override `Recompute` to hook into the evaluation lifecycle. But even simple OutputUis dramatically improve the user experience by showing data in its most meaningful form.

