# Arc vs. Index Handles: Two Approaches to GPU Resource References

> At what point does reference counting overhead matter, and when is a simple integer the better choice?

---

## The Core Tension

GPU resources present a fundamental design problem: how do you safely refer to something that lives in a separate device's memory? You cannot have a raw pointer to GPU data the way you might to heap memory. What you hold is always indirect—a handle that lets you ask the driver to operate on the real resource.

Two dominant patterns have emerged. Reference-counted handles (Arc in Rust, shared_ptr in C++) provide automatic lifetime management and safe sharing. Dense integer indices provide raw speed and GPU compatibility. Neither is universally better; each excels in different conditions.

The tension isn't academic. wgpu chose Arc-wrapped handles for safety and ergonomics. rend3, building atop wgpu, chose integer indices for performance at scale. Both are correct—for their contexts. Understanding when to use which pattern matters for any GPU resource management system.

The question isn't which pattern to adopt, but where the boundary lies between them in a given system.

---

## Pattern A: Arc-Wrapped Handles

### Context: wgpu's Philosophy

wgpu's design philosophy prioritizes safety through abstraction. The library wraps every GPU resource in a structure that manages lifetime automatically. Clone a buffer handle, and you get another reference to the same underlying resource. Drop all handles, and the resource eventually frees. The programmer never calls an explicit delete.

This approach inherits from Rust's ownership model. The compiler cannot track GPU memory the way it tracks heap allocations—GPU operations happen asynchronously, and resources may be in use by commands submitted long ago. Arc provides the runtime equivalent: guaranteed cleanup when (and only when) all references disappear.

### How It Works

Open `wgpu/src/api/buffer.rs` and you find this structure:

```rust
pub struct Buffer {
    inner: dispatch::DispatchBuffer,
    map_context: Arc<Mutex<MapContext>>,
    size: BufferAddress,
    usage: BufferUsages,
}
```

The `Buffer` type is not the GPU buffer itself. It is a handle containing a reference to backend-specific data (`inner`), some tracking state for buffer mapping (`map_context`), and cached metadata (`size`, `usage`). Both `Buffer` and `Device` derive `Clone`. The reference counting happens inside the dispatch layer.

When you clone a buffer handle, you increment an atomic counter. When you drop a handle, you decrement that counter. When the counter reaches zero, wgpu schedules the resource for cleanup—not immediately, but when it is safe to do so.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Arc Reference Flow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   buffer_a: Buffer                                              │
│       │                                                         │
│       │ clone()                                                 │
│       ▼                                                         │
│   buffer_b: Buffer ──────┐                                      │
│                          │                                      │
│                          ▼                                      │
│               ┌─────────────────────┐                           │
│               │  Arc<DispatchData>  │  refcount: 2              │
│               │  ─────────────────  │                           │
│               │  GPU Buffer Handle  │                           │
│               │  Mapping State      │                           │
│               │  Cached Metadata    │                           │
│               └─────────────────────┘                           │
│                          │                                      │
│   drop(buffer_a)         │                                      │
│       │                  ▼                                      │
│       │         refcount: 1                                     │
│       │                                                         │
│   drop(buffer_b)                                                │
│       │                                                         │
│       ▼                                                         │
│   refcount: 0  ──────►  Resource scheduled for cleanup          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### When It Excels

Arc-wrapped handles shine in several conditions:

- **Shared resources with unpredictable lifetimes.** When multiple systems reference the same texture or buffer and you cannot know which will finish last, Arc tracks this automatically.

- **Moderate resource counts.** For hundreds of resources—typical in creative coding—the atomic operations add negligible overhead. The cost of one atomic increment is dwarfed by any GPU operation.

- **Thread-safe sharing.** Arc is Send + Sync. Pass handles between threads without additional synchronization. The reference counting is already atomic.

- **Simplicity in ownership.** No explicit delete calls. No tracking of who owns what. Resources clean themselves up when genuinely unused.

- **Integration with Rust idioms.** Arc composes naturally with other Rust patterns. Store in collections, return from functions, capture in closures—everything works as expected.

---

## Pattern B: Dense Integer Indices

### Context: rend3's Need for Scale

rend3 targets a different audience than wgpu's general-purpose abstraction. Games and visualizations may have thousands of meshes, tens of thousands of instances, hundreds of thousands of particles. At that scale, patterns that work fine for hundreds become measurable bottlenecks.

More critically, shaders cannot dereference an Arc. Bindless rendering—where the GPU selects resources by index rather than explicit bindings—requires handles that the GPU can understand. An integer is exactly what the GPU needs.

### How It Works

rend3's handle allocator manages a pool of indices:

```rust
pub struct HandleAllocator<T> {
    max_allocated: AtomicUsize,
    freelist: Mutex<Vec<usize>>,
    _phantom: PhantomData<T>,
}

pub fn allocate(&self) -> ResourceHandle<T> {
    let idx = self.freelist.lock().pop()
        .unwrap_or_else(|| self.max_allocated.fetch_add(1, Ordering::Relaxed));
    ResourceHandle::new(idx)
}

pub fn deallocate(&self, handle: RawResourceHandle<T>) {
    self.freelist.lock().push(handle.idx);
}
```

A handle is just a number. Allocation either pops from the freelist (reusing a previously freed index) or bumps a counter (extending into new territory). Deallocation pushes the index back onto the freelist. Both operations are O(1).

Resources live in a contiguous array. Looking up resource N means indexing `array[N]`. No pointer chasing, no cache misses from scattered allocations.

```
┌─────────────────────────────────────────────────────────────────┐
│                  Index + Freelist Flow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Initial state:                                                │
│   ┌────────────────────────────────────────────┐                │
│   │ Resources: [A] [B] [C] [D] [ ] [ ] [ ] [ ] │                │
│   │ Indices:    0   1   2   3                  │                │
│   │ max_allocated: 4                           │                │
│   │ freelist: []                               │                │
│   └────────────────────────────────────────────┘                │
│                                                                 │
│   deallocate(1):  // Free resource B                            │
│   ┌────────────────────────────────────────────┐                │
│   │ Resources: [A] [-] [C] [D] [ ] [ ] [ ] [ ] │                │
│   │ freelist: [1]                              │                │
│   └────────────────────────────────────────────┘                │
│                                                                 │
│   allocate():     // Returns index 1 (from freelist)            │
│   ┌────────────────────────────────────────────┐                │
│   │ Resources: [A] [E] [C] [D] [ ] [ ] [ ] [ ] │                │
│   │ freelist: []                               │                │
│   └────────────────────────────────────────────┘                │
│                                                                 │
│   allocate():     // Returns index 4 (bumps counter)            │
│   ┌────────────────────────────────────────────┐                │
│   │ Resources: [A] [E] [C] [D] [F] [ ] [ ] [ ] │                │
│   │ max_allocated: 5                           │                │
│   │ freelist: []                               │                │
│   └────────────────────────────────────────────┘                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### When It Excels

Dense integer indices prove superior in specific conditions:

- **High resource volume.** When managing tens of thousands of resources, the per-clone and per-drop overhead of Arc accumulates. Integer handles are Copy—no overhead at all.

- **GPU-side indexing.** Shaders can index into arrays. Bindless rendering becomes possible. Material systems can store texture indices directly.

- **Cache-friendly access patterns.** Contiguous arrays mean sequential access hits cache. Scattered Arc allocations may not.

- **Predictable memory layout.** You know exactly where resource N lives. Debugging and profiling are simpler.

- **Bulk operations.** Iterate over all resources by walking an array. No need to traverse reference graphs.

---

## Side-by-Side Comparison

| Dimension | Arc-Wrapped Handles | Dense Integer Indices |
|-----------|--------------------|-----------------------|
| Overhead per clone | Atomic increment | Zero (Copy) |
| Overhead per lookup | Pointer dereference | Array index |
| Thread safety | Built-in (Arc is Sync) | Requires external sync |
| GPU compatibility | Cannot use directly | Shader-indexable |
| Use-after-free protection | Automatic (lifetime) | Requires generation counters |
| Memory layout | Scattered allocations | Contiguous array |
| Best for | Shared resources, <1K count | High volume, GPU indexing |

---

## Combining the Patterns

### The Hybrid Approach

Real systems rarely use one pattern exclusively. The patterns complement each other: Arc for heavyweight resources with complex sharing, indices for lightweight resources in high volume.

Consider a renderer with these resources:
- 1 Device
- 1 Queue
- 50 Textures
- 200 Materials
- 5,000 Mesh instances
- 100,000 Particles

Arc makes sense for Device, Queue, and Textures. These are heavyweight resources with complex creation, uncertain lifetimes, and moderate counts. The reference counting overhead is negligible.

Indices make sense for mesh instances and particles. These are lightweight, numerous, and often GPU-indexed. Arc overhead for 100,000 clones per frame would be measurable.

Materials sit at the boundary. 200 is not a lot, but materials are often GPU-indexed for bindless rendering. The choice depends on access patterns.

### A Hybrid Implementation

```rust
/// Arc for heavyweight, shared resources
pub struct TextureCache {
    textures: HashMap<TextureId, Arc<Texture>>,
}

impl TextureCache {
    pub fn get(&self, id: TextureId) -> Option<Arc<Texture>> {
        self.textures.get(&id).cloned()
    }
}

/// Index + generation for high-volume resources
pub struct ParticlePool {
    particles: Vec<ParticleEntry>,
    freelist: Vec<u32>,
}

struct ParticleEntry {
    generation: u32,
    data: Option<ParticleData>,
}

pub struct ParticleHandle {
    index: u32,
    generation: u32,
}

impl ParticlePool {
    pub fn spawn(&mut self, data: ParticleData) -> ParticleHandle {
        let index = self.freelist.pop().unwrap_or_else(|| {
            let idx = self.particles.len() as u32;
            self.particles.push(ParticleEntry { generation: 0, data: None });
            idx
        });

        let entry = &mut self.particles[index as usize];
        entry.data = Some(data);

        ParticleHandle { index, generation: entry.generation }
    }

    pub fn despawn(&mut self, handle: ParticleHandle) {
        if let Some(entry) = self.particles.get_mut(handle.index as usize) {
            if entry.generation == handle.generation {
                entry.generation = entry.generation.wrapping_add(1);
                entry.data = None;
                self.freelist.push(handle.index);
            }
        }
    }

    pub fn get(&self, handle: ParticleHandle) -> Option<&ParticleData> {
        let entry = self.particles.get(handle.index as usize)?;
        if entry.generation == handle.generation {
            entry.data.as_ref()
        } else {
            None  // Stale handle—particle was despawned and slot reused
        }
    }
}
```

### The Threshold

When does the switch from Arc to indices make sense? Based on the studied frameworks, a rough threshold emerges around 10,000 resources of a given type.

Below 1,000: Arc is almost certainly fine. The overhead is unmeasurable against any real workload.

1,000 to 10,000: Profile before deciding. For infrequently-cloned resources, Arc is still fine. For resources cloned every frame, indices may help.

Above 10,000: Indices are likely worth the complexity. At 100,000 particles with handles cloned for GPU upload each frame, Arc overhead becomes noticeable.

The threshold varies with access patterns. Resources cloned once and held for many frames have different characteristics than resources cloned every frame.

---

## Implications for the GPU Resource Pool

### Start with Arc for Core Resources

For buffers, textures, bind groups, and pipelines, Arc-wrapped handles are the right starting point. Creative coding typically involves hundreds of these resources, not thousands. The ergonomic benefits—automatic cleanup, safe sharing, thread compatibility—outweigh the tiny overhead.

```rust
pub struct Buffer {
    inner: Arc<BufferInner>,
}

impl Clone for Buffer {
    fn clone(&self) -> Self {
        Buffer { inner: Arc::clone(&self.inner) }
    }
}
```

This is what wgpu does, and for good reason. Until profiling shows otherwise, follow their lead.

### Add Generation-Indexed Pools for Particle Systems

When the resource pool supports particle systems, instanced rendering with thousands of instances, or procedural mesh generation with many small meshes, add a generation-indexed pool as a specialized subsystem.

```rust
pub struct InstancePool<T> {
    entries: Vec<InstanceEntry<T>>,
    freelist: Vec<u32>,
}

struct InstanceEntry<T> {
    generation: u32,
    value: Option<T>,
}

pub struct InstanceHandle<T> {
    index: u32,
    generation: u32,
    _marker: PhantomData<T>,
}

impl<T> InstancePool<T> {
    pub fn get(&self, handle: InstanceHandle<T>) -> Option<&T> {
        let entry = self.entries.get(handle.index as usize)?;
        if entry.generation == handle.generation {
            entry.value.as_ref()
        } else {
            None
        }
    }
}
```

Generation counters are essential. Without them, index reuse leads to silent corruption—a freed particle's handle accidentally references a newly spawned one. Generation counters turn this from undefined behavior into explicit failure (returning `None`).

### Consider the Hybrid for Materials and Meshes

Materials and meshes sit in the middle ground. A typical scene might have hundreds to low thousands. Arc works fine ergonomically, but these resources are often GPU-indexed for bindless rendering.

One approach: use Arc externally but maintain a parallel index-based registry for GPU access.

```rust
pub struct MaterialRegistry {
    // External API uses Arc handles
    materials: Vec<Arc<Material>>,
    // GPU-side index equals position in vec
    // Shader samples material_data[material_index]
}

impl MaterialRegistry {
    pub fn add(&mut self, material: Material) -> (Arc<Material>, MaterialIndex) {
        let arc = Arc::new(material);
        let index = MaterialIndex(self.materials.len() as u32);
        self.materials.push(Arc::clone(&arc));
        (arc, index)
    }
}
```

User code works with Arc for convenience. The registry maintains a dense array for GPU indexing. Both views exist simultaneously.

### When to Switch Patterns

Switch from Arc to indices when these conditions align:

1. **Measured overhead.** Profile shows significant time in reference counting operations.
2. **High volume.** Resource count exceeds 10,000 for frequently-cloned types.
3. **GPU indexing needed.** Shaders must select resources by index.
4. **Predictable lifetimes.** You can determine when resources die without reference counting.

Do not switch preemptively. The complexity cost of manual lifetime management is real. Arc's safety is worth keeping until you have evidence it costs too much.

---

## Conclusion

Arc-wrapped handles and dense integer indices represent two points on a tradeoff curve. Arc prioritizes safety, ergonomics, and simplicity; indices prioritize raw performance and GPU compatibility. Neither is universally superior.

The studied frameworks demonstrate this clearly. wgpu chose Arc because safety and portability matter more than marginal performance for a general-purpose GPU abstraction. rend3 chose indices because games with thousands of meshes need that marginal performance.

For a GPU Resource Pool targeting creative coding, start with Arc. It is the simpler choice, and creative coding workloads rarely stress the boundaries. Add generation-indexed pools as specialized subsystems when particle systems, massive instancing, or bindless rendering enter the picture.

The boundary between patterns is not fixed. It depends on workload, access patterns, and what the profiler reveals. Design the system to accommodate both, and let measurement guide which pattern dominates.

---

## Related Documents

- [per-framework/wgpu.md](per-framework/wgpu.md) — Arc-wrapped implementation details
- [per-framework/rend3.md](per-framework/rend3.md) — Dense index and freelist patterns
- [per-framework/nannou.md](per-framework/nannou.md) — Weak reference pooling for devices
- [handle-designs.md](handle-designs.md) — Broader survey of handle patterns
