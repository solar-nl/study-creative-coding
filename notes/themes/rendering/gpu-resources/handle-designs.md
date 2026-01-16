# Handle Designs: How to Reference What You Can't Touch

> A GPU resource lives in GPU memory. How does your code refer to it?

---

## The Referencing Problem

GPU buffers and textures don't exist in your program's address space. You can't just have a pointer to vertex data the way you'd have a pointer to a struct. The GPU is a separate device with separate memory. What you hold is a *handle*—an indirect reference that lets you ask the driver to do things with the actual resource.

Handle design determines more than syntax. It affects whether you can accidentally use a freed resource, how much overhead each access costs, what happens when you clone a reference, and who gets to decide when the resource finally dies.

The question guiding this exploration: *what trade-offs shape handle design, and which design fits which situation?*

---

## Arc-Wrapped Handles: Safety Through Counting

wgpu and nannou wrap GPU resources in reference-counted smart pointers. Clone a buffer handle, and you get another Arc pointing to the same resource. Drop all handles, and the resource eventually frees.

```rust
pub struct Buffer {
    inner: dispatch::DispatchBuffer,
    map_context: Arc<Mutex<MapContext>>,
    size: BufferAddress,
    usage: BufferUsages,
}
```

This is Rust's ownership system applied to GPU resources. The compiler can't track GPU memory the way it tracks heap memory, but Arc provides similar guarantees at runtime: the resource outlives all references to it.

The benefits are substantial. Sharing is trivial—pass the handle to multiple systems, and they all reference the same GPU buffer. Cleanup is automatic—no explicit delete calls, no dangling pointers. Thread safety comes built-in—Arc handles synchronization.

The costs are real but often acceptable. Every clone increments an atomic counter; every drop decrements one. For hundreds of resources, this overhead disappears into noise. For millions of particles each with their own buffer handle, it might matter.

More subtly, Arc makes early cleanup difficult. If you know a buffer is no longer needed but handles still exist elsewhere, you can't force reclamation. The resource lingers until the last handle drops.

---

## Dense Integer Indices: Speed Through Simplicity

rend3 takes a different approach. A mesh handle is just a number—an index into an array:

```rust
pub struct HandleAllocator<T> {
    max_allocated: AtomicUsize,
    freelist: Mutex<Vec<usize>>,
}

pub struct MeshHandle(usize);
```

Allocation is O(1): pop from the freelist or bump the counter. Lookup is O(1): index into an array. Clone is free: integers are `Copy`. The data structure is cache-friendly: all meshes live in contiguous memory.

And crucially, shaders can use these handles directly. A GPU shader can't dereference an Arc, but it can index into an array. Bindless rendering—where the GPU selects resources by index rather than explicit bindings—requires integer handles.

The cost is explicit lifetime management. An integer doesn't know when to free itself. You must tell the system when a resource is no longer needed. And if you keep using an old index after the resource has been freed and the slot reused, you'll access the wrong resource—a subtle, dangerous bug.

---

## Generation Counters: Catching Stale Handles

The use-after-free problem with integer indices has a standard solution: generation counters.

```rust
pub struct Handle<T> {
    index: u32,
    generation: u32,
}

struct Entry<T> {
    generation: u32,
    value: Option<T>,
}

impl<T> Pool<T> {
    pub fn get(&self, handle: Handle<T>) -> Option<&T> {
        let entry = self.entries.get(handle.index as usize)?;
        if entry.generation == handle.generation {
            entry.value.as_ref()
        } else {
            None  // Stale handle
        }
    }
}
```

When you allocate a resource, you pair it with the current generation of that slot. When you free the resource, you increment the slot's generation. A handle from the old allocation now fails the generation check—it returns `None` instead of the wrong resource.

This turns use-after-free from silent corruption into explicit failure. The overhead is minimal: one integer comparison per access. The safety guarantee isn't as strong as Arc (you get `None` instead of a compile-time error), but it's far better than nothing.

---

## Weak Reference Pools: Sharing Without Ownership

nannou's device pool uses an interesting variant: it stores `Weak` references rather than strong ones:

```rust
pub struct DeviceMap {
    map: Mutex<HashMap<DeviceMapKey, Weak<DeviceQueuePair>>>,
}
```

The pool doesn't keep devices alive. Windows hold `Arc<DeviceQueuePair>`—the strong references that determine lifetime. The pool merely enables sharing: when a new window requests a device with matching configuration, the pool upgrades its `Weak` to `Arc` and returns the shared device.

When all windows using a device close, their Arcs drop, and the device becomes unreachable. The pool's `Weak` can no longer upgrade. On the next cleanup pass, the dead entry removes itself.

This pattern elegantly separates sharing from ownership. The pool enables reuse without preventing cleanup. Resources live exactly as long as their actual users need them.

---

## Context Tracking: Handling the Ephemeral

Processing targets mobile and web, environments where GPU contexts can disappear unexpectedly. A context switch (app backgrounded, WebGL canvas resized) invalidates all GPU resources. Continuing to use them produces undefined behavior.

Processing handles this by tracking context identity:

```java
class VertexBuffer {
    int context;
    int glId;

    boolean contextIsOutdated() {
        return !pgl.contextIsCurrent(context);
    }
}
```

Every resource remembers which context created it. Before use, you check whether that context is still current. If not, the resource is invalid—dispose it, recreate if needed.

This pattern addresses a problem that wgpu abstracts away for desktop use. But the underlying lesson applies broadly: GPU resources exist in a context, and that context may not last forever.

---

## Matching Handle Design to Use Case

The research across frameworks reveals a consistent pattern: handle complexity should match resource volume and access patterns.

**Few resources, varied lifetimes**: Arc-wrapped handles. Device, queue, most textures. The reference counting overhead is negligible for tens or hundreds of resources. The automatic cleanup is worth its weight in gold.

**Many resources, predictable access**: Generation + index. Mesh vertices, instance data, particle positions. When you're managing thousands of small allocations and the GPU needs to index into them, dense arrays beat reference counting.

**Shared resources, uncertain lifetimes**: Weak reference pools. When you want to enable sharing without dictating when resources die, Weak provides exactly the right semantics.

**Transient resources, frequent recreation**: Don't bother with elaborate handle schemes. Bind groups in wgpu are cheap to create; many applications recreate them per-frame. The simplest handle is no handle at all.

---

## Lessons for the GPU Resource Pool

The handle research suggests a layered approach:

**Start with Arc for most resources.** Device, queue, buffers, textures—wrap them in Arc. The ergonomics are excellent, the safety is automatic, and the overhead is negligible for typical creative coding workloads.

**Add generation-counted indices for high-volume resources.** For particle systems with tens of thousands of particles, or instanced rendering with thousands of instances, integer handles with generation counters will serve better than Arc.

**Consider Weak for caches and pools.** For shader caches or texture pools, Weak references let the pool enable sharing without owning the resources.

**Don't over-engineer.** The simplest handle that meets your needs is the right choice. Complexity costs in maintenance, debugging, and cognitive load. Add sophistication only when profiling shows the need.

---

## Related Documents

- [per-framework/wgpu.md](per-framework/wgpu.md) — Arc-wrapped implementation
- [per-framework/rend3.md](per-framework/rend3.md) — Dense index + freelist
- [per-framework/nannou.md](per-framework/nannou.md) — Weak reference pooling
