# tixl: The Reference/Target Pattern

> How do you track what needs recomputation across thousands of nodes?

---

## A Familiar Challenge

tixl is a visual programming tool built on Stride (the C#/.NET game engine), and it faces a common challenge for node graph systems: upstream changes must propagate downstream, but doing so naively would recompute far too much.

The naive approach—mark everything dirty, recompute everything—works for a hundred nodes. For a thousand nodes with complex interconnections, it collapses. The graph becomes a swamp of redundant computation.

The question guiding this exploration: *how do you track what changed without drowning in bookkeeping?*

---

## Two Integers and a Comparison

### The Core Insight

Open `Core/Operator/Slots/DirtyFlag.cs` and you'll find the heart of tixl's system:

```csharp
public class DirtyFlag
{
    public int Reference;           // Last known clean state
    public int Target = 1;          // Current dirty state (starts dirty)
    public int InvalidatedWithRefFrame;  // Prevents double invalidation

    public bool IsDirty => TriggerIsEnabled || Reference != Target;
}
```

A slot is dirty when its `Reference` doesn't match its `Target`. That's it. Two integers and a comparison.

Initial state: `Reference = 0, Target = 1`. The slot is dirty because 0 ≠ 1. After computing the slot's value, you call `Clear()`, which sets `Reference = Target`. Now 1 = 1, and the slot is clean.

When an upstream change invalidates the slot, `Target` increments. Now `Reference` (still 1) ≠ `Target` (now 2). The slot is dirty again.

### Why Not a Boolean?

A boolean flag seems simpler: `isDirty = true` when something changes, `isDirty = false` after processing. But boolean flags have a subtle flaw.

Consider a node with two upstream connections, A and B. Both change in the same frame. With a boolean:
1. A changes → set `isDirty = true`
2. B changes → set `isDirty = true` (redundant, but harmless)
3. Process the node → set `isDirty = false`

This works, but you've lost information. You can't tell whether the node was invalidated once or twice. More importantly, if you try to track "when was this node last invalidated?" a boolean tells you nothing.

The target integer preserves history. Each invalidation increments `Target`, so you could theoretically detect "this was invalidated twice this frame"—useful for debugging dependency cycles.

---

## Frame Deduplication

### The Problem

In a complex graph, the same node might receive invalidation signals multiple times per frame. Node C might be downstream of both A and B; when both change, C gets two invalidation calls.

Without protection, `Target` would increment twice unnecessarily. Over time, overflow becomes a concern. And the redundant work adds up.

### tixl's Solution: Global Tick Counter

```csharp
public static void IncrementGlobalTicks()
{
    _globalTickCount += GlobalTickDiffPerFrame;  // += 100
}
```

Every frame, a global tick counter advances. Each `DirtyFlag` remembers the frame when it was last invalidated:

```csharp
public int Invalidate()
{
    if (InvalidatedWithRefFrame == _globalTickCount)
        return Target;  // Already invalidated this frame

    InvalidatedWithRefFrame = _globalTickCount;
    Target++;
    return Target;
}
```

If you try to invalidate twice in the same frame, the second call is a no-op. The graph can send redundant signals; the receiving node ignores duplicates.

### Why 100 per Frame?

The spacing of 100 between frame ticks isn't arbitrary. It leaves room for intra-frame events or debugging without worrying about collision. At 100 ticks per frame and 60fps, you get about 400,000 years before integer overflow—plenty of headroom.

The spacing also enables a useful diagnostic:

```csharp
public int FramesSinceLastUpdate =>
    (_globalTickCount - _lastUpdateTick) / GlobalTickDiffPerFrame;
```

"This node hasn't updated in 30 frames" is immediately actionable debugging information.

---

## Lazy Evaluation

### The Update Dance

When it's time to compute a node's value, tixl doesn't blindly recompute. It checks first:

```csharp
public void Update(EvaluationContext context)
{
    if (_dirtyFlag.IsDirty || _valueIsCommand)
    {
        OpUpdateCounter.CountUp();
        UpdateAction?.Invoke(context);
        _dirtyFlag.Clear();
        _dirtyFlag.SetUpdated();
    }
}
```

If the flag isn't dirty, the node skips computation entirely. The expensive work only happens when necessary.

The `_valueIsCommand` escape hatch handles nodes that must execute every frame regardless of input changes—rendering nodes, audio output, anything with side effects.

The counter enables profiling. "This node updated 47 times this session" tells you where optimization effort should focus.

---

## Propagation Through the Graph

### Walking Upstream

When a node evaluates, it must first check whether its inputs have changed. tixl walks upstream recursively:

```csharp
internal virtual int InvalidationOverride()
{
    if (_inputConnections == null || _inputConnections.Count == 0)
        return _dirtyFlag.Invalidate();

    // Check if already processed this frame
    if (_dirtyFlag.InvalidatedWithRefFrame == _globalTickCount)
        return _dirtyFlag.Target;

    // Sum targets from all inputs
    var targetSum = 0;
    foreach (var slot in _inputConnections)
    {
        if (slot.InvalidationOverride() > 0)
            targetSum += slot._dirtyFlag.Target;
    }

    // If any input's target changed, we're dirty
    if (targetSum != _dirtyFlag.Reference)
    {
        _dirtyFlag.Target = targetSum;
        _dirtyFlag.InvalidatedWithRefFrame = _globalTickCount;
    }

    return _dirtyFlag.Target;
}
```

The recursion short-circuits via `InvalidatedWithRefFrame`. If this node already participated in invalidation this frame, it returns its cached `Target` immediately. No redundant graph traversal.

The target sum aggregates changes from all inputs. This means "how dirty am I" reflects the cumulative dirtiness of the entire upstream subgraph—a richer signal than a simple boolean.

---

## Handling Massive Graphs

### When 1,000 Nodes Isn't Enough

For graphs with thousands of nodes, even efficient invalidation propagation can become a bottleneck. tixl provides an escape valve:

```csharp
// From MultiInputSlot.cs
public HashSet<int>? LimitMultiInputInvalidationToIndices;
```

If you know only certain inputs matter for a particular node, you can restrict invalidation checking to just those inputs. The graph walks less; propagation costs less.

```csharp
if (LimitMultiInputInvalidationToIndices != null)
{
    foreach (var index in LimitMultiInputInvalidationToIndices)
    {
        if (index < _collectedInputs.Count)
            ProcessInput(_collectedInputs[index]);
    }
}
```

This is an optimization for expert users building complex patches. Most graphs don't need it. But when you're instancing 10,000 particles with interconnected behavior, selective invalidation makes the difference between responsive and sluggish.

---

## Trigger Modes

### Beyond Input-Driven Dirtiness

Some nodes must execute every frame regardless of inputs:

```csharp
[Flags]
public enum DirtyFlagTrigger : byte
{
    None = 0,      // Only dirty when inputs change
    Always = 0x1,  // Always dirty (every frame)
    Animated = 0x2 // Dirty when animation is playing
}
```

Time nodes, mouse input, audio analysis—these don't have "inputs" in the traditional sense. They sample the world. The `Always` trigger forces them to update regardless of the graph's change detection.

The `Animated` trigger is more subtle. It forces updates only when the animation timeline is playing, not when paused. Scrubbing through a timeline, you want frame-accurate updates; idle, you want the graph to rest.

---

## GPU Resources in a Node Graph

### Bundling Buffer and Views

tixl wraps DirectX 11 resources into coherent units:

```csharp
public sealed class BufferWithViews : IDisposable
{
    public SharpDX.Direct3D11.Buffer Buffer;
    public SharpDX.Direct3D11.ShaderResourceView Srv;
    public SharpDX.Direct3D11.UnorderedAccessView Uav;

    public void Dispose()
    {
        Buffer?.Dispose();
        Srv?.Dispose();
        Uav?.Dispose();
    }
}
```

A buffer rarely travels alone. Shaders need views to bind it. Bundling them ensures they're created together, disposed together, never orphaned.

### Pragmatic Buffer Reuse

```csharp
public static SharpDX.Direct3D11.Buffer GetDynamicConstantBuffer(
    SharpDX.Direct3D11.Buffer? existingBuffer,
    int neededSize)
{
    if (existingBuffer != null && existingBuffer.Description.SizeInBytes >= neededSize)
        return existingBuffer;

    existingBuffer?.Dispose();
    return CreateDynamicConstantBuffer(neededSize);
}
```

No elaborate pooling, no complex allocation tracking. If the existing buffer is big enough, reuse it. If not, dispose and recreate. Simple, and sufficient for most creative coding workloads.

---

## Shader Caching

### Two Levels

Compiling shaders is expensive. tixl caches at two levels:

```csharp
Dictionary<ulong, byte[]> _shaderBytecodeCache;  // In-memory
string _shaderCacheDirectory;  // On disk
```

Hot shaders stay in memory. Cold shaders load from disk. First-time compilations hit the compiler, but the result persists across sessions.

### Integration with Dirty Flags

Shader operators check dirty flags before recompiling:

```csharp
if (!Code.DirtyFlag.IsDirty && !EntryPoint.DirtyFlag.IsDirty)
    return;  // Skip recompilation
```

The same pattern that governs node evaluation governs shader compilation. Changed inputs trigger recompilation; stable inputs skip it.

---

## Lessons for the GPU Resource Pool

tixl's patterns suggest several approaches:

**Reference/Target over booleans.** Two integers provide richer information than one boolean. You get deduplication for free, debugging information as a bonus, and overflow is a non-concern for any realistic workload.

**Global tick counter for frame awareness.** Knowing "what frame is it" enables deduplication, diagnostics, and time-dependent behavior without threading complexity.

**Lazy evaluation everywhere.** Check before computing. If the inputs haven't changed, don't recompute. The check is cheap; the computation isn't.

**Selective invalidation for scale.** Most graphs don't need it, but when you're pushing thousands of nodes, being able to limit propagation paths is invaluable.

**Trigger modes for special cases.** Time-dependent nodes, input nodes, side-effect nodes—they all need exemptions from the normal dirty-tracking rules. Design for the exceptions from the start.

**Bundle related resources.** Buffer + views travel together. Create together, dispose together. Don't let them drift apart.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `Core/Operator/Slots/DirtyFlag.cs` | 6-101 | DirtyFlag class |
| `Core/Operator/Slots/Slot.cs` | 160-326 | Update and invalidation |
| `Core/Operator/Slots/MultiInputSlot.cs` | 46-83 | Multi-input optimization |
| `Core/Operator/Slots/DirtyFlagTrigger.cs` | 1-11 | Trigger modes |
| `Core/DataTypes/BufferWithViews.cs` | 5-23 | GPU buffer wrapper |
| `Core/Rendering/ResourceUtils.cs` | 48-64 | Buffer reuse |
| `Core/Resource/ShaderCompiler.Caching.cs` | 113-178 | Shader caching |

---

## Related Documents

- [openrndr.md](openrndr.md) — LRU approach to caching
- [../cache-invalidation.md](../cache-invalidation.md) — Cross-framework comparison
- [../../node-graphs/node-graph-architecture.md](../../node-graphs/node-graph-architecture.md) — Broader context
