# tixl: Dirty Flag System for Visual Programming

> How a node graph tracks what needs recomputation

---

## Overview

tixl is a visual programming tool built on Stride (formerly Xenko), a C#/.NET game engine. Its dirty flag system is particularly relevant for Flux because both systems need to track when node outputs require recomputation.

The key insight from studying tixl: **a global tick counter plus reference/target comparison enables O(1) dirty checks while preventing double-invalidation per frame**.

---

## DirtyFlag: The Core Mechanism

### The Pattern

Each slot has a `DirtyFlag` that tracks whether its value needs recomputation:

```csharp
// From Core/Operator/Slots/DirtyFlag.cs:6-67
public class DirtyFlag
{
    public int Reference;           // Last known clean state
    public int Target = 1;          // Current dirty state (starts dirty)
    public int InvalidatedWithRefFrame;  // Prevents double invalidation

    // A slot is dirty if:
    // 1. Always-trigger is enabled, OR
    // 2. Reference doesn't match Target
    public bool IsDirty => TriggerIsEnabled || Reference != Target;
}
```

### How It Works

**Initial state:** `Reference = 0, Target = 1` → slot is dirty (needs first computation)

**After computation:**
```csharp
// From DirtyFlag.cs:46-50
public void Clear()
{
    Reference = Target;  // Mark as clean
}
```

**On invalidation:**
```csharp
// From DirtyFlag.cs:18-37
public int Invalidate()
{
    // Prevent double invalidation in same frame
    if (InvalidatedWithRefFrame == _globalTickCount)
        return Target;

    InvalidatedWithRefFrame = _globalTickCount;
    Target++;  // Increment target → IsDirty becomes true
    return Target;
}
```

### Why Reference/Target Instead of Boolean?

A boolean flag has a problem: if multiple upstream nodes invalidate the same downstream node in one frame, you can't tell if you've already processed that invalidation.

The target integer solves this:
- Each invalidation increments `Target`
- `InvalidatedWithRefFrame` prevents incrementing twice in the same frame
- After processing, `Reference = Target` makes it clean
- If something else invalidates later, `Target++` makes it dirty again

`★ Insight ─────────────────────────────────────`
The reference/target pattern is more expressive than a boolean. It could even support "how many times has this been invalidated?" queries, though tixl doesn't use that capability.
`─────────────────────────────────────────────────`

---

## Global Tick Counter

### The Pattern

A global tick counter advances each frame:

```csharp
// From DirtyFlag.cs:9-12
public static void IncrementGlobalTicks()
{
    _globalTickCount += GlobalTickDiffPerFrame;  // += 100
}
```

### Why 100 per Frame?

The spacing of 100 between frame ticks allows for intra-frame events or debugging without overflow concerns. At 100 ticks per frame and 60fps, you get about 400,000 years before integer overflow.

### Frame Timing

```csharp
// From DirtyFlag.cs:69-70
public int FramesSinceLastUpdate =>
    (_globalTickCount - _lastUpdateTick) / GlobalTickDiffPerFrame;
```

This enables diagnostics like "this node hasn't updated in 30 frames."

---

## Slot Update Loop

### The Pattern

The `Slot.Update()` method implements lazy evaluation:

```csharp
// From Core/Operator/Slots/Slot.cs:160-169
public void Update(EvaluationContext context)
{
    if (_dirtyFlag.IsDirty || _valueIsCommand)
    {
        OpUpdateCounter.CountUp();
        UpdateAction?.Invoke(context);
        _dirtyFlag.Clear();       // Mark clean
        _dirtyFlag.SetUpdated();  // Record update time
    }
}
```

Key points:
- Only executes if dirty
- `_valueIsCommand` forces execution (for side-effect nodes)
- Counter enables profiling
- Clear happens after execution, not before

---

## Invalidation Propagation

### The Pattern

When an input changes, its connected outputs must invalidate:

```csharp
// From Slot.cs:269-326 (simplified)
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

This walks the graph recursively but short-circuits via `InvalidatedWithRefFrame`.

---

## Trigger Modes

### The Pattern

Some operators need to execute every frame regardless of input changes:

```csharp
// From Core/Operator/Slots/DirtyFlagTrigger.cs:1-11
[Flags]
public enum DirtyFlagTrigger : byte
{
    None = 0,      // Only dirty when inputs change
    Always = 0x1,  // Always dirty (every frame)
    Animated = 0x2 // Dirty when animation is playing
}
```

The `Always` trigger is used for:
- Time-dependent nodes (current time)
- Input nodes (mouse, keyboard)
- Audio analysis nodes

---

## Multi-Input Optimization

### The Problem

In large graphs (thousands of nodes), invalidation propagation can become expensive. If a single change propagates through many paths, you visit the same nodes repeatedly.

### tixl's Solution

```csharp
// From Core/Operator/Slots/MultiInputSlot.cs:14
public HashSet<int>? LimitMultiInputInvalidationToIndices;
```

For massive graphs, you can limit which inputs are considered during invalidation:

```csharp
// From MultiInputSlot.cs:46-83 (simplified)
internal override int InvalidationOverride()
{
    // "In situations with extremely large graphs (1000 of instances)
    // invalidation can become bottleneck"

    if (LimitMultiInputInvalidationToIndices != null)
    {
        // Only check specific inputs
        foreach (var index in LimitMultiInputInvalidationToIndices)
        {
            if (index < _collectedInputs.Count)
                ProcessInput(_collectedInputs[index]);
        }
    }
    else
    {
        // Check all inputs
        foreach (var input in GetCollectedTypedInputs())
            ProcessInput(input);
    }
}
```

### Flux Implications

For Flux's dirty tracking:
- **Track which inputs changed** - not just "any input changed"
- **Support partial invalidation** - for large graphs
- **Consider incremental propagation** - only what's needed

---

## GPU Resource Management

### BufferWithViews

tixl wraps DirectX 11 resources together:

```csharp
// From Core/DataTypes/BufferWithViews.cs:5-23
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

This bundles the buffer with its views (needed for shader binding).

### Buffer Reuse Pattern

```csharp
// From Core/Rendering/ResourceUtils.cs:48-64
public static SharpDX.Direct3D11.Buffer GetDynamicConstantBuffer(
    SharpDX.Direct3D11.Buffer? existingBuffer,
    int neededSize)
{
    // Reuse if size matches
    if (existingBuffer != null && existingBuffer.Description.SizeInBytes >= neededSize)
        return existingBuffer;

    // Dispose old, create new
    existingBuffer?.Dispose();
    return CreateDynamicConstantBuffer(neededSize);
}
```

Simple but effective: reuse if big enough, recreate otherwise.

---

## Shader Caching

### Two-Level Cache

tixl caches compiled shaders at two levels:

```csharp
// From Core/Resource/ShaderCompiler.Caching.cs:134
Dictionary<ulong, byte[]> _shaderBytecodeCache;  // In-memory

// From Core/Resource/ShaderCompiler.Caching.cs:178
string _shaderCacheDirectory;  // .shadercache files on disk
```

### Integration with Dirty Flags

Shader operators check dirty flags before recompiling:

```csharp
// From Core/Operator/IShaderOperator.cs:48
if (!Code.DirtyFlag.IsDirty && !EntryPoint.DirtyFlag.IsDirty)
    return;  // Skip recompilation
```

---

## Summary: Key Patterns for Flux

| Pattern | tixl Approach | Flux Application |
|---------|---------------|------------------|
| **Dirty tracking** | Reference/Target integers | More expressive than boolean |
| **Frame deduplication** | Global tick + InvalidatedWithRefFrame | Prevents repeated work |
| **Lazy evaluation** | Check IsDirty before Update() | Only compute what's needed |
| **Propagation** | Recursive with short-circuit | Walk graph, cache results |
| **Trigger modes** | Always, Animated flags | Support time-dependent nodes |
| **Large graph optimization** | LimitMultiInputInvalidationToIndices | Partial invalidation |
| **Buffer reuse** | Check size, recreate if needed | Simple but effective |
| **Shader caching** | Memory + disk | Two-level for persistence |

---

## Design Insight: Simple Integers, Powerful System

tixl's dirty flag system is surprisingly simple at its core - just two integers and a comparison. But the combination of:
- Global tick counter for frame tracking
- InvalidatedWithRefFrame for deduplication
- Recursive propagation with short-circuits
- Trigger modes for special cases

...creates a robust system for managing thousands of operators efficiently.

`★ Insight ─────────────────────────────────────`
tixl's `Target++` on invalidation means you could theoretically detect "this was invalidated twice this frame" - useful for debugging dependency issues. Though tixl doesn't expose this, Flux could consider it.
`─────────────────────────────────────────────────`

---

## Source Files

| File | Purpose |
|------|---------|
| `Core/Operator/Slots/DirtyFlag.cs:6-101` | DirtyFlag class |
| `Core/Operator/Slots/Slot.cs:160-326` | Update and invalidation |
| `Core/Operator/Slots/MultiInputSlot.cs:46-83` | Multi-input optimization |
| `Core/Operator/Slots/DirtyFlagTrigger.cs:1-11` | Trigger modes |
| `Core/DataTypes/BufferWithViews.cs:5-23` | GPU buffer wrapper |
| `Core/Rendering/ResourceUtils.cs:48-64` | Buffer reuse |
| `Core/Resource/ShaderCompiler.Caching.cs:113-178` | Shader caching |

---

## Related Documents

- [../cache-invalidation.md](../cache-invalidation.md) - Cross-framework comparison
- [openrndr.md](openrndr.md) - LRU approach to caching
- [../../node-graphs/node-graph-architecture.md](../../node-graphs/node-graph-architecture.md) - Broader context
