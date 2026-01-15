# Handle Design Patterns

> How frameworks represent GPU resources in application code

---

## The Problem

GPU resources live in GPU memory, but application code needs to reference them. The handle design determines:
- **Safety**: Can you use a freed resource?
- **Performance**: What's the lookup/access cost?
- **Semantics**: Does cloning share or copy?
- **Lifetime**: Who decides when to free?

---

## Pattern Catalog

### 1. Arc-Wrapped Handles (wgpu, nannou)

```rust
// wgpu pattern
pub struct Buffer {
    inner: dispatch::DispatchBuffer,  // Backend-specific
    map_context: Arc<Mutex<MapContext>>,
    size: BufferAddress,
    usage: BufferUsages,
}
```

**Characteristics:**
- Clone is cheap (`Arc::clone`)
- Resource freed when last handle drops
- Metadata stored alongside (avoids backend calls)
- Thread-safe sharing built-in

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Safe by default | Atomic ref-count overhead |
| Implicit cleanup | Can't force early cleanup |
| Easy sharing | Cycles need `Weak` |

### 2. Dense Integer Indices (rend3)

```rust
// rend3 pattern
pub struct HandleAllocator<T> {
    max_allocated: AtomicUsize,
    freelist: Mutex<Vec<usize>>,
}

pub struct MeshHandle(usize);  // Just an index
```

**Characteristics:**
- Clone is zero-cost (`Copy`)
- O(1) array lookup
- Explicit lifetime via instruction queue
- Freelist enables recycling

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Minimal overhead | Use-after-free possible |
| Cache-friendly | Explicit management required |
| GPU indexable | Generation needed for safety |

### 3. Weak Reference Pooling (nannou)

```rust
// nannou device map pattern
pub struct DeviceMap {
    map: Mutex<HashMap<DeviceMapKey, Weak<DeviceQueuePair>>>,
}
```

**Characteristics:**
- Pool doesn't keep resources alive
- `Weak::upgrade()` checks validity
- Auto-cleanup when owners drop
- Enables sharing without ownership

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Automatic cleanup | Upgrade check overhead |
| No ownership burden on pool | Can fail unexpectedly |
| Shared while alive | HashMap overhead |

### 4. Context-Tracked Objects (Processing)

```java
// Processing pattern
class VertexBuffer {
    int context;  // Context ID at creation
    int glId;     // GL buffer ID

    boolean contextIsOutdated() {
        return !pgl.contextIsCurrent(context);
    }
}
```

**Characteristics:**
- Context ID captured at creation
- Validity check before use
- Auto-dispose on context loss
- Prevents stale resource access

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Handles context switches | Check overhead |
| Auto-recovery | Silent recreation |
| Mobile-friendly | Verbose API |

---

## Comparison Matrix

| Aspect | Arc-Wrapped | Dense Index | Weak Pool | Context-Tracked |
|--------|-------------|-------------|-----------|-----------------|
| Clone cost | Atomic inc | Free (Copy) | Arc clone | Reference |
| Lookup cost | Immediate | Array index | HashMap + upgrade | Direct |
| Safety | Automatic | Generation check | Upgrade check | Context check |
| Sharing | Built-in | Manual | Built-in | Manual |
| Early free | Drop all refs | Explicit | Drop owners | Dispose |
| Thread-safe | Yes | Mutex on alloc | Yes | No |

---

## Hybrid Approaches

### Generation + Index (Recommended for Flux)

Combine dense indices with generation counters for safety:

```rust
pub struct Handle<T> {
    index: u32,
    generation: u32,
    _marker: PhantomData<T>,
}

pub struct Pool<T> {
    entries: Vec<Entry<T>>,
    freelist: Vec<u32>,
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

### Arc for Low-Volume + Index for High-Volume

```rust
// Textures: few, reference often
pub struct TextureHandle(Arc<TextureInner>);

// Mesh vertices: many, indexed access
pub struct MeshHandle {
    pool_id: u16,
    index: u32,
    generation: u16,
}
```

---

## Flux Recommendation

Based on Flux's requirements (node graph with dirty flags, wgpu backend):

| Resource Type | Recommended Handle | Rationale |
|---------------|-------------------|-----------|
| **Device/Queue** | Arc-wrapped | Few, shared, automatic cleanup |
| **Buffer** | Arc-wrapped | Moderate count, varied lifetimes |
| **Texture** | Arc-wrapped | Few, often shared between nodes |
| **Mesh data** | Generation + index | Many small allocations possible |
| **Bind groups** | Recreate per-frame | Cheap, depend on multiple resources |

Key insight from research: **match handle complexity to resource volume**. Few resources → simple Arc. Many resources → optimized indices.

---

## Related Documents

- [per-framework/wgpu.md](per-framework/wgpu.md) - Arc-wrapped implementation
- [per-framework/rend3.md](per-framework/rend3.md) - Dense index + freelist
- [per-framework/nannou.md](per-framework/nannou.md) - Weak reference pooling
