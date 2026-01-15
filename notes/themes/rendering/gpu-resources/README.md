# GPU Resource Management Patterns

> How creative coding frameworks manage buffers, textures, and GPU state

---

## Overview

This directory documents GPU resource management patterns across creative coding frameworks. The research answers seven questions critical for designing Flux's resource pool:

1. **Resource Types**: What GPU resources need management?
2. **Handle Design**: How do frameworks represent GPU resources?
3. **Allocation Strategy**: When and how is GPU memory allocated?
4. **Cache Invalidation**: How do frameworks track what needs updating?
5. **Reclamation Timing**: When are resources freed?
6. **Thread Safety**: How is concurrent access managed?
7. **Command Batching**: How are GPU commands organized?

---

## Quick Comparison Tables

### Handle Design

| Framework | Handle Type | Cloning | Lifetime |
|-----------|-------------|---------|----------|
| **wgpu** | Arc-wrapped dispatch | Cheap (Arc::clone) | Ref-counted, drop frees |
| **nannou** | Weak + Arc DeviceQueuePair | Cheap | Auto-cleanup when windows close |
| **rend3** | Dense integer index + freelist | Zero-cost (Copy) | Explicit via instruction queue |
| **tixl** | Direct object reference | N/A (C#) | GC + IDisposable |
| **OpenRNDR** | Object with context tracking | N/A (Kotlin) | Session-based cleanup |
| **Three.js** | JavaScript object | Reference | Manual dispose() |
| **Cinder** | shared_ptr&lt;BufferObj&gt; | Ref-count | RAII destructor |
| **Processing** | Weak reference + GLResource | N/A (Java) | Context-validity check |

### Dirty Flag Approaches

| Framework | Dirty Mechanism | Granularity | Propagation |
|-----------|-----------------|-------------|-------------|
| **tixl** | Reference/Target integers | Per-slot | Recursive with dedup |
| **Three.js** | Version counter + ranges | Per-resource + byte ranges | None (pull-based) |
| **OpenRNDR** | Boolean + LRU forceSet | Per-resource | None |
| **rend3** | group_dirty flag | Per-manager | None |

### Allocation Strategies

| Framework | Buffer Strategy | Growth | Initial Size |
|-----------|-----------------|--------|--------------|
| **rend3** | Megabuffer + range allocator | Reallocate + copy | 32MB |
| **Processing** | Exponential (power of 2) | Double until fits | 256/512 elements |
| **Cinder** | Exact reallocation | Match requested size | Per-mesh |
| **wgpu** | Per-buffer allocation | N/A (no pooling) | Per-descriptor |

### Cache/Invalidation

| Framework | Cache Type | Eviction | Integration |
|-----------|------------|----------|-------------|
| **OpenRNDR** | LRU (1K capacity) | Oldest first | forceSet on dirty |
| **tixl** | Memory + disk (shaders) | N/A | DirtyFlag.IsDirty check |
| **Three.js** | Version comparison | Implicit (overwrite) | needsUpdate trigger |

### Thread Safety

| Framework | Resource Creation | Command Recording | Queue Submit |
|-----------|-------------------|-------------------|--------------|
| **wgpu** | Send + Sync | Parallel encoders | Needs coordination |
| **nannou** | Mutex on maps | Single-threaded | Single queue |
| **rend3** | Instruction queue | Not exposed | Internal |
| **OpenRNDR** | synchronized block | Single-threaded | Single-threaded |

---

## Key Patterns by Research Question

### Q1: Resource Types

All frameworks manage the same core resources:
- **Buffers**: Vertex, index, uniform/constant, storage
- **Textures**: 2D, cube, render targets
- **Shaders**: Compiled programs, modules
- **State objects**: Pipelines, bind groups, VAOs

### Q2: Handle Design

Three main approaches emerged:

| Approach | Example | Trade-offs |
|----------|---------|------------|
| **Arc-wrapped** | wgpu, nannou | Safe, slight overhead, implicit lifetime |
| **Dense index** | rend3 | Zero-cost lookup, explicit lifetime, freelist management |
| **Direct reference** | tixl, Three.js | Simple, relies on GC or manual cleanup |

**Recommendation for Flux**: Consider dense indices for high-volume resources (mesh vertices), Arc-wrapped for lower-volume resources (textures, shaders).

### Q3: Allocation Strategy

| Strategy | When to Use |
|----------|-------------|
| **Per-resource** | Low volume, varying sizes |
| **Megabuffer + suballoc** | High volume, frequent creation |
| **Exponential growth** | Unknown final size |
| **Exact allocation** | Known size, minimal waste |

**Recommendation for Flux**: Start with per-resource (simpler), add megabuffer for geometry if profiling shows creation overhead.

### Q4: Cache Invalidation

| Pattern | Complexity | Best For |
|---------|------------|----------|
| **Boolean dirty** | O(1) | Simple cases |
| **Version counter** | O(1) | Multiple consumers |
| **Reference/Target** | O(1) | Frame deduplication |
| **Update ranges** | O(n ranges) | Large buffers with small changes |

**Recommendation for Flux**: Use tixl-style reference/target for dirty flags (already planned), add Three.js-style update ranges for large dynamic geometry.

### Q5: Reclamation Timing

| Strategy | When to Free |
|----------|--------------|
| **Immediate** | On drop/dispose |
| **Deferred** | End of frame, poll() |
| **Session-based** | When session ends |
| **Instruction queue** | During render prep |

**Recommendation for Flux**: Deferred (during frame boundary) aligns with dirty flag processing.

### Q6: Thread Safety

| Concern | Solution |
|---------|----------|
| Device sharing | Device pooling (nannou) |
| Resource creation | Mutex or single-threaded |
| Command recording | Multiple encoders |
| Submission | Coordinate or single point |

**Recommendation for Flux**: Single-threaded initially, design for parallel command recording later.

### Q7: Command Batching

| Pattern | Framework | Benefit |
|---------|-----------|---------|
| **Instruction queue** | rend3 | Decouple API from GPU |
| **Encoder per thread** | wgpu | Parallel recording |
| **Update range merging** | Three.js WebGL | Reduce GPU commands |

**Recommendation for Flux**: Instruction queue pattern meshes well with dirty flag processing.

---

## Framework Deep Dives

| Document | Focus |
|----------|-------|
| [per-framework/wgpu.md](per-framework/wgpu.md) | Foundation patterns, Arc-wrapped handles, buffer mapping |
| [per-framework/nannou.md](per-framework/nannou.md) | Device pooling, Weak references |
| [per-framework/rend3.md](per-framework/rend3.md) | Managers pattern, megabuffers, instruction queue |
| [per-framework/tixl.md](per-framework/tixl.md) | Dirty flag system, shader caching |
| [per-framework/openrndr.md](per-framework/openrndr.md) | LRU cache, shadow buffers, sessions |
| [per-framework/threejs.md](per-framework/threejs.md) | Update ranges, version tracking |

---

## Flux Recommendations

Based on this research, recommended approaches for Flux:

### Handle Design
```rust
// Dense indices for high-volume resources
pub struct MeshHandle(u32);

// Arc-wrapped for lower-volume resources
pub struct TextureHandle(Arc<TextureInner>);
```

### Dirty Flag Integration
```rust
pub struct DirtyFlag {
    reference: u32,
    target: u32,
    invalidated_frame: u64,  // Prevents double-invalidation
}

impl DirtyFlag {
    pub fn is_dirty(&self) -> bool {
        self.reference != self.target
    }

    pub fn invalidate(&mut self, current_frame: u64) -> u32 {
        if self.invalidated_frame == current_frame {
            return self.target;
        }
        self.invalidated_frame = current_frame;
        self.target = self.target.wrapping_add(1);
        self.target
    }

    pub fn clear(&mut self) {
        self.reference = self.target;
    }
}
```

### Update Ranges for Large Buffers
```rust
pub struct DynamicBuffer {
    buffer: wgpu::Buffer,
    update_ranges: Vec<Range<u64>>,
}

impl DynamicBuffer {
    pub fn mark_range_dirty(&mut self, range: Range<u64>) {
        self.update_ranges.push(range);
    }

    pub fn upload_dirty_ranges(&mut self, queue: &wgpu::Queue) {
        // Optionally merge adjacent ranges first
        for range in self.update_ranges.drain(..) {
            queue.write_buffer(&self.buffer, range.start, &self.data[range]);
        }
    }
}
```

### Resource Pool Structure
```rust
pub struct ResourcePool {
    // Immediate dirty processing
    dirty_buffers: Vec<BufferHandle>,

    // Deferred operations (like rend3)
    pending_uploads: Vec<UploadOperation>,
    pending_deletes: Vec<DeleteOperation>,
}

impl ResourcePool {
    pub fn process_frame(&mut self, encoder: &mut wgpu::CommandEncoder) {
        // Process pending operations at frame boundary
        for op in self.pending_uploads.drain(..) {
            op.execute(encoder);
        }
        // Deferred deletes happen after GPU confirms completion
    }
}
```

---

## Open Questions

1. **Megabuffer sizing**: Should Flux start with megabuffers (like rend3's 32MB) or grow into them?
2. **Range merging**: Is the complexity of Three.js-style range merging worth it for wgpu backends?
3. **Session hierarchy**: Should Flux support OpenRNDR-style hierarchical sessions?
4. **Shadow buffers**: Are CPU-side shadows needed for Flux's use cases?

---

## Related Documents

- [../README.md](../README.md) - Rendering overview (draw call batching)
- [../instance-rendering.md](../instance-rendering.md) - Instance buffer patterns
- [../primitive-strategies.md](../primitive-strategies.md) - Tier-based routing
- [../../node-graphs/](../../node-graphs/) - Node graph dirty tracking context
