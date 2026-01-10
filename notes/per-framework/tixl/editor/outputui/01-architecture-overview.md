# Chapter 1: Architecture Overview

> *Understanding how the OutputUi system thinks about visualization*

## Key Insight

> **OutputUi's core idea:** A factory-driven type dispatch system where each output type (float, texture, command) gets a specialized renderer, with per-view state automatically managed via ConditionalWeakTable for memory-safe multi-view support.

---

## The Problem We're Solving

Imagine you're building a visual programming environment. Users connect operators together, and each operator produces some output - a number, an image, a 3D scene. You need to show these outputs to users in a meaningful way.

The challenge: **a float and a texture are fundamentally different things**. A float makes sense as a curve over time. A texture makes sense as an image you can pan and zoom. A rendered 3D scene needs an entire GPU pipeline to display. How do you build a system that handles all these cases elegantly?

The naive approach would be a giant switch statement:

```csharp
void DrawOutput(object value)
{
    if (value is float f)
        DrawCurve(f);
    else if (value is Texture2D tex)
        DrawImage(tex);
    else if (value is Command cmd)
        RenderAndDisplay(cmd);
    // ... 20 more cases
}
```

This gets ugly fast. Every time you add a new type, you modify this central function. The logic for each type is scattered. Testing is painful.

---

## The OutputUi Solution

OutputUi takes a different approach: **type-driven dispatch with specialized renderers**.

Instead of one function that knows about all types, we have:
- A **factory** that knows which renderer to create for each type
- A **base class** that defines the contract (what every renderer must do)
- **Specialized implementations** that know how to render their specific type

Think of it like a plugin system. The core says "I need to display a float" and the factory returns a FloatOutputUi that knows everything about displaying floats. The core never needs to know the details.

```
"I have a float to display"
        │
        ▼
   ┌─────────────────────────────────────┐
   │          OutputUiFactory            │
   │                                     │
   │  "Ah, float! I'll give you a       │
   │   FloatOutputUi for that."         │
   └─────────────────┬───────────────────┘
                     │
                     ▼
   ┌─────────────────────────────────────┐
   │          FloatOutputUi              │
   │                                     │
   │  I know floats. I'll show you a    │
   │  curve that scrolls over time,     │
   │  with the current value displayed. │
   └─────────────────────────────────────┘
```

---

## Why This Design?

### 1. Each Type Gets Expert Treatment

A `FloatOutputUi` can be hyper-specialized for floats. It knows that floats change over time, so it keeps a history and shows a curve. It knows that seeing the exact current value matters, so it displays that prominently.

A `Texture2dOutputUi` knows completely different things. It knows images need pan and zoom. It knows about texture formats and array slices.

Neither pollutes the other's code.

### 2. Adding New Types is Clean

When someone adds a new data type like `ParticleSystem`, they write a `ParticleSystemOutputUi` that knows how to visualize particles. They register it with the factory. Done. No changes to existing code.

### 3. Multi-View Support is Built In

The same output might appear in multiple places - in the graph, in a dedicated output window, in a pop-out panel. Each view needs its own state (its own scroll position, its own curve history).

OutputUi handles this through **per-view state**. Each view has an ID, and each OutputUi can store state keyed by that ID. When FloatOutputUi draws in "graph-view-1", it uses one curve buffer. When drawing in "output-panel", it uses another.

---

## The Mental Model

Think of the system in three layers:

### Layer 1: The Contract (What All Outputs Do)

Every OutputUi must be able to:
- **Draw** its value given a slot and context
- **Clone** itself for use in multiple views
- **Report** its type

This is the `IOutputUi` interface and `OutputUi<T>` base class.

### Layer 2: The Dispatcher (Who Handles What)

The factory maintains a registry: "float → FloatOutputUi, Texture2D → Texture2dOutputUi, etc."

When asked to create an OutputUi for a type, it looks up the registry and instantiates the right class.

For unknown types, it falls back to a generic `ValueOutputUi<T>` that just shows the type name and calls ToString().

### Layer 3: The Specialists (How Each Type Renders)

Each specialized OutputUi knows its domain deeply:

- **FloatOutputUi**: Maintains a 500-sample circular buffer, renders with ImGui.PlotLines, shows current value
- **Texture2dOutputUi**: Delegates to ImageOutputCanvas for pan/zoom, shows format info
- **CommandOutputUi**: Creates render targets, sets up the GPU pipeline, executes the operator, displays the result

---

## Data Flow: What Happens When You Display an Output

Let's trace what happens when the editor needs to display a float output:

### Step 1: Creation (When Loading a Symbol)

When loading a symbol, the editor sees an output of type `float`. It asks the factory:

```
OutputUiFactory.CreateFor(typeof(float))
```

The factory looks up `float` in its registry, finds FloatOutputUi, and creates a new instance.

### Step 2: Association

The new FloatOutputUi is stored with the symbol and associated with the specific output slot. It receives the OutputDefinition (metadata about this output - its ID, name, etc.).

### Step 3: Drawing (Each Frame)

When the graph renders this output, it calls:

```
outputUi.DrawValue(slot, context, viewId, recompute: true)
```

Inside DrawValue, the base class orchestrates:

1. **Should we recompute?** If `recompute` is true, the operator is evaluated (the float is calculated).

2. **Delegate to specialized drawing.** The abstract `DrawTypedValue` method is called. FloatOutputUi implements this to:
   - Cast the slot to `Slot<float>` (type safety)
   - Get/create per-view state using the viewId
   - Add the current value to the curve history
   - Render the curve using ImGui

### Step 4: Cleanup (Automatic)

When views close or objects are garbage collected, the ConditionalWeakTable automatically cleans up per-view state. No manual cleanup needed.

---

## The Evaluation Question

Notice that `DrawValue` has a `recompute` parameter. Why separate evaluation from drawing?

Some contexts want fresh values every frame (the main graph view). Others might want to show the last computed value without re-running the operator (for performance, or when showing a snapshot).

By separating "recompute" from "draw", the system supports both patterns.

Inside `Recompute`, the base class:
1. Invalidates the slot (marks it as needing recalculation)
2. Calls `slot.Update(context)` (runs the operator)

Subclasses can override this. CommandOutputUi does - it needs to set up render targets *before* the operator runs and restore the previous GPU state *after*.

---

## Why Not Just Use Polymorphism on the Values?

You might wonder: why not have `float` know how to draw itself? Or have a `IDisplayable` interface that all output types implement?

The problem is **separation of concerns**. The `float` type (or the operator that produces it) is about *computation*, not UI. It might run on a background thread, or be serialized to disk, or evaluated on a remote machine. It shouldn't know about ImGui or the editor at all.

OutputUi is the bridge between the value world and the UI world. It lives entirely in the editor, can be swapped out, and can evolve independently of the data types it displays.

---

## Per-View State: Solving a Subtle Problem

A subtle but important challenge: how do we handle state for multiple views?

The obvious approach:
```csharp
private Dictionary<string, ViewSettings> _settings = new();
```

The problem: when a view closes, its viewId string is no longer used anywhere... but our dictionary still holds a reference to the settings. Memory leak. Over time, the dictionary accumulates ghost entries for views that no longer exist.

The solution: `ConditionalWeakTable`:
```csharp
private ConditionalWeakTable<string, ViewSettings> _settings = [];
```

ConditionalWeakTable has special garbage collector integration. When the key (the viewId string) is collected, the associated value is automatically removed. No explicit cleanup, no memory leaks.

This is why OutputUis can be "fire and forget" - you don't need to track their lifecycle carefully.

---

## The Type Hierarchy

```
IOutputUi (interface)
    │
    └─── OutputUi<T> (abstract base)
            │
            ├─── FloatOutputUi           ← Curve plotting
            ├─── BoolOutputUi            ← 0/1 curve
            ├─── StringOutputUi          ← Line-numbered text
            ├─── VectorOutputUi<T>       ← Multi-channel curves
            │
            ├─── Texture2dOutputUi       ← Image display
            ├─── Texture3dOutputUi       ← Z-slice viewer
            │
            ├─── FloatListOutputUi       ← Grid/plot modes
            ├─── DataSetOutputUi         ← Event timeline
            │
            ├─── CommandOutputUi         ← Full GPU pipeline
            │
            └─── ValueOutputUi<T>        ← Fallback for unknown types
```

---

## Summary: The Big Picture

1. **OutputUi is a type-driven visualization system.** Each output type gets a specialized renderer that knows how to display it best.

2. **The factory dispatches creation.** You register your type, the factory creates the right renderer automatically.

3. **The base class defines the contract.** Clone, DrawValue, and Type property. The base class also orchestrates the evaluate-then-draw flow.

4. **Specialists know their domain.** FloatOutputUi knows about curves. Texture2dOutputUi knows about images. CommandOutputUi knows about GPU pipelines.

5. **Per-view state is automatic.** ConditionalWeakTable handles cleanup without explicit lifecycle management.

6. **Evaluation is separated from drawing.** This allows flexibility in when and whether to recompute values.

This architecture scales to new types without modifying existing code, keeps each type's logic isolated and testable, and handles the tricky multi-view state management automatically.

---

## What's Next

Now that you understand the overall architecture, the following chapters explore each piece in detail:

- **[Chapter 2: Factory Pattern](02-factory-pattern.md)** - How the type → renderer mapping works, and why we use expression compilation
- **[Chapter 3: Base Classes](03-base-classes.md)** - The contract defined by IOutputUi and OutputUi<T>, and the template method pattern
- **[Chapter 4: Scalar Outputs](04-scalar-outputs.md)** - How floats, bools, and vectors build their visualizations

