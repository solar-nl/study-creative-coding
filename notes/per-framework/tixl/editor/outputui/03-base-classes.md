# Chapter 3: Base Classes

> *The contract every renderer must fulfill, and how the base class does the heavy lifting*

---

## The Problem: Defining a Common Contract

In Chapter 2, we saw how the factory creates the right renderer for each type. But for this to work, all renderers must speak the same language. The factory returns `IOutputUi`, and the code that uses it needs to call methods without knowing whether it got a FloatOutputUi or a Texture2dOutputUi.

This is the classic interface problem: **how do we define what every renderer must be able to do?**

But there's a second, subtler problem. If you've ever written multiple classes that follow the same pattern, you know how much code gets duplicated. Every OutputUi needs to:

- Handle ImGui draw list setup
- Optionally recompute the value
- Deal with channel layering for gizmos
- Clean up afterward

Writing this boilerplate in every single OutputUi would be tedious and error-prone. Worse, if the pattern ever needs to change, you'd have to update every implementation.

The solution is a two-layer design: an **interface** that defines the contract, and an **abstract base class** that handles the common work.

---

## The Mental Model: What Every OutputUi Must Do

Before looking at code, let's think about what capabilities every OutputUi needs:

1. **Identity**: Which output does this UI represent? (For selection and serialization)
2. **Type information**: What type of value does this render? (For factory lookup)
3. **Cloning**: Can we create an independent copy? (For multi-view support)
4. **Drawing**: Can we render the value? (The main purpose)

Think of it like a job description. Every OutputUi candidate must be able to do these four things. They might do them differently - FloatOutputUi draws curves, Texture2dOutputUi draws images - but they all need the same basic capabilities.

**Key Source Files:**
- `Editor/Gui/OutputUi/IOutputUi.cs`
- `Editor/Gui/OutputUi/OutputUi.cs`

---

## IOutputUi: The Contract

The interface defines exactly what consumers can expect:

```csharp
public interface IOutputUi : ISelectableCanvasObject
{
    /// The output definition this UI represents
    Symbol.OutputDefinition OutputDefinition { get; set; }

    /// The C# type being visualized
    Type Type { get; }

    /// Create an independent copy for multi-view support
    IOutputUi Clone();

    /// Main rendering entry point
    void DrawValue(ISlot slot, EvaluationContext context, string viewId, bool recompute = true);
}
```

Notice it also implements `ISelectableCanvasObject`. This allows outputs to be selected on the graph canvas - you can click on them, move them around. The interface is:

```csharp
public interface ISelectableCanvasObject
{
    Guid Id { get; }
    Vector2 PosOnCanvas { get; set; }
    Vector2 Size { get; set; }
}
```

This dual inheritance is a common pattern: one interface for the domain-specific behavior (IOutputUi), another for the UI infrastructure (ISelectableCanvasObject).

---

## Why Do We Need Clone?

You might wonder why cloning matters. Can't we just use the same OutputUi instance everywhere?

The problem is **per-view state**. Remember from Chapter 1: the same output might appear in multiple places - the graph, an output panel, a pop-out window. Each needs its own state.

A FloatOutputUi keeps a history of values to draw a curve. If two views share the same instance, they share the same history buffer. When view A scrolls its curve, view B scrolls too. That's not what users expect.

Clone creates a fresh instance with the same configuration (which output it represents, its position) but independent state:

```csharp
public override IOutputUi Clone()
{
    return new FloatOutputUi
    {
        OutputDefinition = OutputDefinition,  // Same output
        PosOnCanvas = PosOnCanvas,            // Same position
        Size = Size                           // Same size
        // Note: NO per-view state copied
    };
}
```

When the clone starts drawing, it creates its own curve buffer, its own history. Each view is truly independent.

---

## OutputUi<T>: The Abstract Base Class

The interface tells us *what* every OutputUi must do. The abstract base class tells us *how* the common parts work.

Let's build up the understanding piece by piece.

### The Type Parameter

```csharp
internal abstract class OutputUi<T> : IOutputUi
{
    public Type Type { get; } = typeof(T);
    // ...
}
```

The base class is generic. When you write `class FloatOutputUi : OutputUi<float>`, the Type property automatically returns `typeof(float)`. This connects the factory system to the implementation - the factory knows it's dealing with floats because the class declares it.

### The Stored Properties

```csharp
public Symbol.OutputDefinition OutputDefinition { get; set; }
public Guid Id => OutputDefinition.Id;
public Vector2 PosOnCanvas { get; set; } = Vector2.Zero;
public Vector2 Size { get; set; } = SymbolUi.Child.DefaultOpSize;
```

These are the common properties every OutputUi needs. Notice that `Id` is derived from `OutputDefinition` - it's not stored separately. This ensures consistency.

### The Abstract Methods

```csharp
public abstract IOutputUi Clone();
protected abstract void DrawTypedValue(ISlot slot, string viewId);
```

These are what subclasses *must* implement. `Clone()` is public (part of the interface), while `DrawTypedValue()` is protected (only called internally).

The key insight is that `DrawTypedValue` is much simpler than `DrawValue`. The base class handles all the setup and teardown; subclasses just do their specific rendering.

---

## The Template Method Pattern

Here's where the design gets elegant. `DrawValue` is the public method everyone calls. But it's not abstract - it's implemented in the base class:

```csharp
public void DrawValue(ISlot slot, EvaluationContext context, string viewId, bool recompute)
{
    var drawList = ImGui.GetWindowDrawList();
    drawList.ChannelsSplit(2);

    drawList.ChannelsSetCurrent(1);
    {
        TransformGizmoHandling.SetDrawList(drawList);
        if (recompute)
        {
            Recompute(slot, context);
        }
    }

    drawList.ChannelsSetCurrent(0);
    {
        DrawTypedValue(slot, viewId);
    }

    drawList.ChannelsMerge();
}
```

This is the **Template Method pattern**: a base class method that defines the *structure* of an algorithm, with specific steps delegated to subclass methods.

Think of it like a recipe template:
1. Preheat oven (fixed)
2. Mix dry ingredients (fixed)
3. **Add your special filling** (varies by recipe)
4. Bake at 350 for 30 minutes (fixed)

The template handles the common parts. Each recipe just fills in step 3.

For OutputUi:
1. Set up ImGui channels (fixed)
2. Handle gizmo layer (fixed)
3. Optionally recompute the value (fixed, but hookable)
4. **Draw the typed value** (varies by type)
5. Merge channels (fixed)

```
DrawValue(slot, context, viewId, recompute)
    │
    ├─── [Fixed] Setup ImGui channels
    │
    ├─── [Fixed] Channel 1: Gizmo setup
    │
    ├─── [Hook] if (recompute) → Recompute()  ← Can override
    │
    ├─── [Fixed] Channel 0: Switch to front
    │
    ├─── [Abstract] DrawTypedValue()  ← Must implement
    │
    └─── [Fixed] Merge channels
```

FloatOutputUi only needs to implement `DrawTypedValue()`. All the channel management, gizmo integration, and evaluation control comes for free.

---

## Understanding Channel Layering

You might wonder: what's this channel business about?

ImGui draws things in the order you call the draw functions. If you draw a background, then draw text, the text appears on top. Simple.

But sometimes you need to draw things out of order. In OutputUi, gizmos (like transform handles) need to appear *behind* the content, even though we set them up *first*.

Channels solve this. You split the draw list into multiple channels, draw to each channel, then merge them in a controlled order:

```csharp
drawList.ChannelsSplit(2);  // Create channels 0 and 1

drawList.ChannelsSetCurrent(1);  // Draw to back layer
{
    // Gizmo setup goes here
}

drawList.ChannelsSetCurrent(0);  // Draw to front layer
{
    // Content drawing goes here
}

drawList.ChannelsMerge();  // Combine: 0 renders on top of 1
```

The result: content renders in front of gizmos, even though gizmos were drawn first. This is fixed behavior that every OutputUi needs, so it lives in the base class.

---

## The Recompute Hook

Look at this line in `DrawValue`:

```csharp
if (recompute)
{
    Recompute(slot, context);
}
```

`Recompute` is a virtual method - not abstract, but overridable:

```csharp
protected virtual void Recompute(ISlot slot, EvaluationContext context)
{
    StartInvalidation(slot);  // Mark the slot as needing recalculation
    slot.Update(context);      // Run the operator to get a new value
}
```

Most OutputUis use this default behavior. But some need to do extra work. `CommandOutputUi`, for example, needs to set up render targets *before* the operator runs, and restore the previous GPU state *after*:

```csharp
// In CommandOutputUi
protected override void Recompute(ISlot slot, EvaluationContext context)
{
    // Setup before evaluation
    SetupRenderTargets(context.RequestedResolution);
    SetupViewport();

    // Standard evaluation
    base.Recompute(slot, context);

    // Cleanup after
    RestorePreviousRenderTarget();
}
```

This is the "hook" part of the template method pattern. The base class calls `Recompute`, and subclasses can customize what happens without changing the overall flow.

---

## Implementing DrawTypedValue

Now let's look at what subclasses actually implement. The typical pattern:

```csharp
protected override void DrawTypedValue(ISlot slot, string viewId)
{
    // 1. Cast to typed slot
    if (slot is not Slot<T> typedSlot)
        return;

    // 2. Get the value
    var value = typedSlot.Value;

    // 3. Handle null/disposed
    if (value == null)
    {
        ImGui.TextUnformatted("NULL");
        return;
    }

    // 4. Get or create per-view state
    if (!_viewSettings.TryGetValue(viewId, out var settings))
    {
        settings = new ViewSettings();
        _viewSettings.Add(viewId, settings);
    }

    // 5. Do the actual rendering
    settings.Canvas.Draw(value);
}
```

Steps 1-3 are defensive: make sure we have a valid value. Step 4 is the per-view state pattern from Chapter 1. Step 5 is where the type-specific magic happens.

Notice how simple this is compared to `DrawValue`. No channel management, no gizmo handling, no evaluation control. Just: get the value, manage state, render.

---

## Per-View State with ConditionalWeakTable

Chapter 1 introduced ConditionalWeakTable for automatic cleanup. Let's see how it's used in practice:

```csharp
private static readonly ConditionalWeakTable<string, ViewSettings> _viewSettings = [];

private class ViewSettings
{
    public CurvePlotCanvas CurveCanvas { get; } = new();
    public bool Paused { get; set; }
    public Slot<float> CurrentSlot { get; set; }
}
```

Each view gets its own `ViewSettings` instance, keyed by the viewId string. When the view is closed and its viewId is garbage collected, the associated settings are automatically cleaned up.

The usage pattern in `DrawTypedValue`:

```csharp
// Get existing settings or create new ones
if (!_viewSettings.TryGetValue(viewId, out var settings))
{
    settings = new ViewSettings { CurrentSlot = typedSlot };
    _viewSettings.Add(viewId, settings);
}

// Use the settings - each view has independent state
settings.CurveCanvas.AddValue(typedSlot.Value);
settings.CurveCanvas.Draw();
```

This is why you can have the same float output open in two panels with different scroll positions, different zoom levels, different histories. Each view has its own state, and you don't have to manage cleanup manually.

---

## The Minimal Implementation

Armed with this understanding, here's the simplest possible OutputUi:

```csharp
internal sealed class MyTypeOutputUi : OutputUi<MyType>
{
    public override IOutputUi Clone()
    {
        return new MyTypeOutputUi
        {
            OutputDefinition = OutputDefinition,
            PosOnCanvas = PosOnCanvas,
            Size = Size
        };
    }

    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        if (slot is not Slot<MyType> typedSlot)
            return;

        var value = typedSlot.Value;
        ImGui.TextUnformatted(value?.ToString() ?? "NULL");
    }
}
```

That's it. No channel management. No evaluation logic. No gizmo handling. Just two methods: clone yourself, and draw your value.

The base class handles everything else.

---

## Why This Two-Layer Design?

You might wonder: why not just have the interface with all the logic in each implementation?

The template method pattern has several advantages:

1. **Consistency**: Every OutputUi handles channels and gizmos the same way. No one forgets to merge channels or sets them up wrong.

2. **Maintainability**: If the channel setup ever needs to change, you change it in one place. All implementations automatically get the fix.

3. **Simplicity**: Implementers focus on their type-specific logic. The cognitive load is much lower when you just implement `DrawTypedValue` vs. the full `DrawValue`.

4. **Correctness**: The hook pattern (virtual `Recompute`) allows customization without breaking the overall flow. You can't accidentally skip channel merging if you're just overriding `Recompute`.

The tradeoff is a bit more complexity in the base class. But that complexity is paid once, while the simplicity is enjoyed by every implementation.

---

## Summary

The OutputUi type hierarchy solves two problems elegantly:

**IOutputUi defines the contract**:
- What output am I representing?
- What type do I visualize?
- Can you clone yourself?
- Can you draw a value?

**OutputUi<T> provides the structure**:
- Template method pattern for consistent rendering flow
- Channel management handled automatically
- Gizmo integration built in
- Recompute hook for custom evaluation needs
- Subclasses only implement `DrawTypedValue` and `Clone`

The result: adding a new OutputUi type is easy. You inherit from `OutputUi<T>`, implement two methods, and register with the factory. The base class handles everything else.

---

## What's Next

Now that you understand both how renderers are selected (factory pattern) and what they must do (base classes), the following chapters explore specific implementations:

- **[Chapter 4: Scalar Outputs](04-scalar-outputs.md)** - How floats, bools, and vectors build their curve visualizations
- **[Chapter 7: Command Rendering](07-command-rendering.md)** - The complex Recompute override for GPU pipelines

