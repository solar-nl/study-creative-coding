# Reclamation Timing

> When should GPU resources be freed?

---

## The Problem

GPU resources can't always be freed immediately when application code is done with them:
- In-flight commands may reference the resource
- Other handles may still exist
- The GPU may be asynchronously using it

When and how to free matters for memory pressure, correctness, and complexity.

---

## Pattern Catalog

### 1. Immediate Drop (wgpu default)

```rust
// Resource freed when last Arc drops
{
    let buffer = device.create_buffer(&desc);
    // ... use buffer ...
}  // Buffer dropped here
```

**How wgpu handles it**: The drop schedules cleanup, but actual GPU memory reclamation is deferred until `device.poll()` confirms no in-flight commands reference it.

**Characteristics:**
- Simple user model
- wgpu handles safety internally
- Memory may not be immediately available

### 2. Explicit Destroy (wgpu option)

```rust
// Force early cleanup
buffer.destroy();  // Marks for immediate destruction
// Further use will panic/error
```

**Characteristics:**
- Explicit intent
- Memory freed sooner
- Risk of use-after-destroy

**Use case**: Known resource lifetime, memory-constrained.

### 3. Instruction Queue Deletion (rend3)

```rust
// rend3 pattern - deletion is an instruction
pub enum InstructionKind {
    DeleteMesh { handle: RawMeshHandle },
    DeleteTexture { handle: RawTextureHandle },
    // ...
}

// On handle drop:
let destroy_fn = move |handle| {
    renderer.instructions.push(handle.into_delete_instruction());
};
```

**Characteristics:**
- Deletion batched with other work
- Processed at frame boundary
- Safe: can't delete while in use

**Trade-off**: Memory lingers until next frame.

### 4. Session-Based Cleanup (OpenRNDR)

```kotlin
// OpenRNDR pattern
class Session {
    val colorBuffers = mutableSetOf<ColorBuffer>()
    val vertexBuffers = mutableSetOf<VertexBuffer>()
    // ...

    fun end() {
        colorBuffers.forEach { it.destroy() }
        colorBuffers.clear()
        // ...
    }
}

// Usage
val session = Session.active
val buffer = device.createBuffer(...)  // Auto-tracked
// ...
session.end()  // All resources destroyed
```

**Characteristics:**
- Resources grouped by lifetime
- Single cleanup point
- Hierarchical (parent ends → children end)

**Use case**: Scene/level boundaries, cleanup-on-exit.

### 5. Weak Reference Auto-Cleanup (nannou)

```rust
// nannou pattern
struct DeviceMap {
    map: Mutex<HashMap<Key, Weak<Device>>>,
}

// Cleanup pass
fn clear_inactive(&self) {
    self.map.lock().retain(|_, weak| weak.upgrade().is_some());
}
```

**Characteristics:**
- Pool doesn't prevent cleanup
- Resources freed when owners drop
- Periodic cleanup removes stale entries

**Use case**: Shared resources, automatic management.

### 6. Context Validity Check (Processing)

```java
// Processing pattern
boolean contextIsOutdated() {
    boolean outdated = !pgl.contextIsCurrent(context);
    if (outdated) {
        dispose();  // Auto-cleanup
    }
    return outdated;
}
```

**Characteristics:**
- Detect context loss (mobile, WebGL)
- Auto-dispose invalid resources
- Recreate on demand

**Use case**: Mobile apps, context-switching environments.

---

## Comparison Matrix

| Pattern | Timing | Safety | Memory Efficiency | Complexity |
|---------|--------|--------|-------------------|------------|
| Immediate drop | ASAP | wgpu-managed | Best | Simple |
| Explicit destroy | Immediate | User responsibility | Best | Simple |
| Instruction queue | Frame boundary | Automatic | Good | Medium |
| Session-based | Session end | Automatic | Variable | Medium |
| Weak auto-cleanup | Periodic | Automatic | Good | Simple |
| Context check | On access | Automatic | N/A | Medium |

---

## Timing Considerations

### GPU In-Flight Safety

The GPU executes asynchronously. When you "delete" a resource:

```
CPU: delete(buffer)
GPU: ... still using buffer in queued commands ...
```

**Solutions:**
1. **Reference counting**: Track in-flight references (wgpu does this)
2. **Frame delay**: Delete resources from N frames ago
3. **Fence-based**: Delete after GPU signals completion

### Memory Pressure

When memory is tight:
- **Aggressive**: Explicit destroy, don't wait for drop
- **Normal**: Drop-based, let wgpu handle timing
- **Lazy**: Session-based, bulk cleanup later

### Determinism

For debugging/profiling:
- **Deterministic**: Delete at fixed points (frame boundary)
- **Non-deterministic**: Drop whenever last reference goes

---

## Flux Recommendation

### Primary: Drop-Based with Frame Boundary Processing

```rust
pub struct ResourcePool {
    // Resources pending deletion (queued during frame)
    pending_deletes: Vec<ResourceId>,

    // Deletion happens at frame boundary
    delete_delay_frames: usize,  // Default: 2 (safe for double-buffering)
    frame_delete_queues: VecDeque<Vec<ResourceId>>,
}

impl ResourcePool {
    pub fn mark_for_delete(&mut self, id: ResourceId) {
        self.pending_deletes.push(id);
    }

    pub fn process_frame_end(&mut self) {
        // Queue current frame's deletes
        let this_frame = std::mem::take(&mut self.pending_deletes);
        self.frame_delete_queues.push_back(this_frame);

        // Process deletes from N frames ago (safe now)
        if self.frame_delete_queues.len() > self.delete_delay_frames {
            let safe_to_delete = self.frame_delete_queues.pop_front().unwrap();
            for id in safe_to_delete {
                self.actually_delete(id);
            }
        }
    }
}
```

### Secondary: Session Grouping (Optional)

For clear lifetime boundaries:

```rust
pub struct ResourceSession {
    id: SessionId,
    parent: Option<SessionId>,
    resources: HashSet<ResourceId>,
}

impl ResourceSession {
    pub fn end(self, pool: &mut ResourcePool) {
        for id in self.resources {
            pool.mark_for_delete(id);
        }
    }
}
```

### Integration with Dirty Flags

```rust
impl ResourcePool {
    pub fn process_frame(&mut self, encoder: &mut CommandEncoder) {
        // 1. Process dirty flags → uploads
        self.process_dirty_resources(encoder);

        // 2. Execute render
        // ...

        // 3. Process deletions (after GPU work queued)
        self.process_frame_end();
    }
}
```

---

## Related Documents

- [per-framework/wgpu.md](per-framework/wgpu.md) - Drop-based cleanup
- [per-framework/rend3.md](per-framework/rend3.md) - Instruction queue deletion
- [per-framework/openrndr.md](per-framework/openrndr.md) - Session-based cleanup
- [per-framework/nannou.md](per-framework/nannou.md) - Weak reference pattern
