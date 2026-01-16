# Cache Invalidation: Knowing What Changed

> There are only two hard things in Computer Science: cache invalidation and naming things.

---

## The Staleness Problem

GPU resources shouldn't be re-uploaded every frame. A texture that hasn't changed since last frame doesn't need to consume bandwidth again. But how do you know it hasn't changed? The GPU doesn't tell you; you have to track it yourself.

This is cache invalidation—knowing when cached GPU state has become stale. Get it wrong in one direction, and you waste bandwidth uploading unchanged data. Get it wrong in the other direction, and you render with outdated data, producing visual artifacts that may be subtle or catastrophic.

For a node graph system, cache invalidation becomes even more critical. When an upstream node changes, how do you know which downstream nodes need recomputation? Propagate too eagerly, and you recompute everything unnecessarily. Propagate too conservatively, and you miss updates.

The question guiding this exploration: *what mechanisms track staleness efficiently?*

---

## Boolean Flags: Simple But Brittle

The simplest approach: a boolean flag.

```javascript
texture.needsUpdate = true;

// During render:
if (texture.needsUpdate) {
    uploadTexture(texture);
    texture.needsUpdate = false;
}
```

Set the flag when something changes. Check the flag before using the resource. Clear the flag after processing.

This works, but it has a fundamental flaw. If two systems both need to respond to changes, only one sees the flag as dirty. The first system to check it clears it, stealing the signal from the second.

For single-consumer scenarios—one renderer, one resource—boolean flags suffice. For anything more complex, they break down.

---

## Version Counters: Independent Tracking

Three.js evolved past boolean flags to version counters:

```javascript
set needsUpdate(value) {
    if (value === true) this.version++;
}

// Renderer caches its view of the version
if (cachedVersion !== texture.version) {
    uploadTexture(texture);
    cachedVersion = texture.version;
}
```

Setting `needsUpdate = true` doesn't flip a flag; it increments a counter. Each consumer maintains its own cache of the last version it saw. If the resource's current version exceeds the cached version, the consumer knows something changed since it last processed the resource.

Multiple systems can independently track staleness. Renderer A and Renderer B each maintain their own `cachedVersion`. When the texture changes, both detect it independently. Neither steals the signal from the other.

The counter only increases, never decreases. This provides a clear semantic: "has this changed since version N?" is always answerable with a single comparison.

---

## Reference/Target: The tixl Pattern

tixl's dirty flag system separates "current state" from "last processed state" more explicitly:

```csharp
public class DirtyFlag {
    public int Reference;  // Last known clean state
    public int Target = 1; // Current dirty state

    public bool IsDirty => Reference != Target;

    public void Invalidate() {
        Target++;
    }

    public void Clear() {
        Reference = Target;
    }
}
```

`Target` increments on each invalidation. `Reference` records the `Target` value when you last processed the resource. The flag is dirty when they differ.

This is functionally equivalent to Three.js's version counters, but the naming is more explicit. "Reference" and "Target" make it clear that you're comparing two distinct concepts: what you've processed versus what currently exists.

The pattern also enables a subtle feature: you could detect how many times something was invalidated since you last processed it (the difference between `Target` and `Reference`). tixl doesn't use this capability, but it's there if needed.

---

## Frame Deduplication: Preventing Redundant Work

In a node graph, multiple paths may lead to the same downstream node. When upstream node A changes, it invalidates downstream node C. When upstream node B also changes in the same frame, it tries to invalidate C again.

```
    A
   / \
  B   C
   \ /
    D
```

If A changes, D gets invalidated through B and through C. Without protection, D's dirty counter increments twice unnecessarily.

tixl solves this with frame-based deduplication:

```csharp
public int InvalidatedWithRefFrame;

public int Invalidate() {
    if (InvalidatedWithRefFrame == _globalTickCount)
        return Target;  // Already invalidated this frame

    InvalidatedWithRefFrame = _globalTickCount;
    Target++;
    return Target;
}
```

A global tick counter advances each frame. Each dirty flag remembers the frame when it was last invalidated. If you try to invalidate twice in the same frame, the second call is a no-op.

This elegantly handles diamond dependencies. Multiple invalidation paths converge without multiplying the work.

---

## Update Ranges: Byte-Level Granularity

For large buffers, "this buffer changed" is too coarse. A 10,000-vertex buffer where only 100 vertices moved shouldn't upload all 10,000.

Three.js tracks update ranges:

```javascript
buffer.addUpdateRange(100, 50);   // Vertices 100-149 changed
buffer.addUpdateRange(5000, 100); // Vertices 5000-5099 changed

// During upload:
for (const range of buffer.updateRanges) {
    uploadPartialBuffer(range.start, range.count);
}
buffer.clearUpdateRanges();
```

Instead of a binary dirty flag, you accumulate a list of byte ranges that changed. The renderer uploads only those ranges.

This is fine-grained invalidation. The overhead is tracking the ranges, but the savings in bandwidth often dwarf the tracking cost—especially for large, sparsely-updated buffers.

---

## LRU with Force: Caching Meets Invalidation

OpenRNDR combines caching with dirty flags in its shader system:

```kotlin
cache.getOrSet(key, forceSet = shadeStyle?.dirty ?: false) {
    shadeStyle?.dirty = false
    computeValue()
}
```

Normally, `getOrSet` returns the cached value if present. But when `forceSet` is true, it bypasses the cache and computes a fresh value.

The `forceSet` parameter hooks into the dirty flag system. When a material's dirty flag is set, its shader recompiles regardless of cache state. The cache enables efficiency; the dirty flag enables correctness.

This pattern elegantly bridges two concerns: "reuse expensive computations" and "respect changes." The same mechanism handles both.

---

## Propagation: Push, Pull, or Both

How do dirty signals flow through a system?

**Push propagation**: When an input changes, immediately mark all downstream dependents dirty.

```
A changes → mark B dirty → mark C dirty → mark D dirty
```

This is eager. You pay the propagation cost upfront, even if you never use the downstream values.

**Pull propagation**: When you need a value, check whether its inputs are dirty.

```
Request D → is C dirty? → is B dirty? → is A dirty?
```

This is lazy. You only check what you actually need. But you might check the same node multiple times through different paths.

**Hybrid (tixl's approach)**: Push invalidation, pull values.

```
A changes → mark B, C, D dirty (push)
Request D → if dirty, compute (pull)
```

Invalidation signals propagate eagerly, but computation happens lazily. You know what might need updating, but you only update what you actually use.

For a node graph, the hybrid approach usually wins. Propagating dirty flags is cheap; recomputing values is expensive. Push the cheap part, pull the expensive part.

---

## Lessons for the GPU Resource Pool

The cache invalidation research points to a clear recommendation:

**Reference/Target with frame deduplication.** tixl's pattern handles diamond dependencies gracefully and provides clear semantics for tracking what's been processed.

**Update ranges for large buffers.** For dynamic geometry or particle systems, tracking which bytes changed enables efficient partial uploads.

**Version counters for multi-consumer resources.** If the same resource feeds multiple systems (multiple render passes, editor previews, etc.), version counters let each track staleness independently.

**Integrate caching with dirty flags.** Use the `forceSet` pattern to let dirty flags bypass caches. One mechanism handles both concerns.

**Propagate dirtiness, not values.** Push the cheap signal (is this dirty?), pull the expensive computation (what's the value?). This minimizes wasted work while ensuring correctness.

---

## Related Documents

- [per-framework/tixl.md](per-framework/tixl.md) — Reference/Target deep dive
- [per-framework/threejs.md](per-framework/threejs.md) — Update ranges deep dive
- [per-framework/openrndr.md](per-framework/openrndr.md) — LRU with dirty integration
