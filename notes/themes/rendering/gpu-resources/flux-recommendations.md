# Flux GPU Resource Pool: Implementation Recommendations

> Synthesized recommendations from cross-framework research

---

## Executive Summary

Based on studying wgpu, nannou, rend3, tixl, OpenRNDR, Three.js, Cinder, and Processing, here are the recommended patterns for Flux's GPU resource pool:

| Concern | Recommendation | Inspired By |
|---------|----------------|-------------|
| **Handle design** | Arc-wrapped for most, dense indices if needed | wgpu, rend3 |
| **Dirty tracking** | Reference/Target with frame deduplication | tixl |
| **Partial updates** | Update range tracking for large buffers | Three.js |
| **Allocation** | Per-resource initially, megabuffer if needed | wgpu → rend3 |
| **Reclamation** | Drop-based with 2-frame delay | wgpu + rend3 |
| **Command batching** | Single encoder + deferred operations | wgpu + rend3 |

---

## 1. Dirty Flag Integration

### Core Implementation

Adopt tixl's reference/target pattern with frame-based deduplication:

```rust
/// Frame-aware dirty flag that prevents double-invalidation
pub struct DirtyFlag {
    /// Last known clean state
    reference: u32,
    /// Current dirty state (incremented on invalidation)
    target: u32,
    /// Frame when last invalidated (prevents double-invalidation)
    invalidated_frame: u64,
}

impl DirtyFlag {
    pub const fn new() -> Self {
        Self {
            reference: 0,
            target: 1,  // Start dirty
            invalidated_frame: 0,
        }
    }

    /// Returns true if this flag needs processing
    #[inline]
    pub fn is_dirty(&self) -> bool {
        self.reference != self.target
    }

    /// Mark as dirty. Returns target value for propagation.
    /// Safe to call multiple times per frame.
    pub fn invalidate(&mut self, current_frame: u64) -> u32 {
        if self.invalidated_frame == current_frame {
            return self.target;  // Already invalidated this frame
        }
        self.invalidated_frame = current_frame;
        self.target = self.target.wrapping_add(1);
        self.target
    }

    /// Mark as clean after processing
    pub fn clear(&mut self) {
        self.reference = self.target;
    }
}
```

### Integration with Node Graph

```rust
pub struct Slot<T> {
    value: T,
    dirty_flag: DirtyFlag,
    connections: Vec<SlotId>,
}

impl<T> Slot<T> {
    pub fn set(&mut self, value: T, frame: u64) {
        self.value = value;
        self.dirty_flag.invalidate(frame);
        // Propagate to connected slots handled by graph
    }

    pub fn update(&mut self, frame: u64, compute: impl FnOnce() -> T) {
        if self.dirty_flag.is_dirty() {
            self.value = compute();
            self.dirty_flag.clear();
        }
    }
}
```

---

## 2. Update Range Tracking

### For Large Dynamic Buffers

Adopt Three.js pattern for buffers where only portions change:

```rust
/// Buffer with tracked dirty regions
pub struct TrackedBuffer {
    buffer: wgpu::Buffer,
    data: Vec<u8>,
    dirty_ranges: Vec<Range<u64>>,
    dirty_flag: DirtyFlag,  // Coarse "anything changed" flag
}

impl TrackedBuffer {
    /// Write data at offset, tracking the dirty range
    pub fn write(&mut self, offset: u64, data: &[u8], frame: u64) {
        let end = offset + data.len() as u64;
        self.data[offset as usize..end as usize].copy_from_slice(data);
        self.dirty_ranges.push(offset..end);
        self.dirty_flag.invalidate(frame);
    }

    /// Upload only dirty regions to GPU
    pub fn flush(&mut self, queue: &wgpu::Queue) {
        if !self.dirty_flag.is_dirty() {
            return;
        }

        // Optional: merge adjacent ranges (Three.js WebGL pattern)
        self.merge_adjacent_ranges();

        for range in self.dirty_ranges.drain(..) {
            queue.write_buffer(
                &self.buffer,
                range.start,
                &self.data[range.start as usize..range.end as usize],
            );
        }

        self.dirty_flag.clear();
    }

    fn merge_adjacent_ranges(&mut self) {
        if self.dirty_ranges.len() <= 1 {
            return;
        }

        self.dirty_ranges.sort_by_key(|r| r.start);

        let mut merged = Vec::with_capacity(self.dirty_ranges.len());
        let mut current = self.dirty_ranges[0].clone();

        for range in self.dirty_ranges.iter().skip(1) {
            if range.start <= current.end {
                // Overlapping or adjacent - merge
                current.end = current.end.max(range.end);
            } else {
                // Gap - keep separate
                merged.push(current);
                current = range.clone();
            }
        }
        merged.push(current);

        self.dirty_ranges = merged;
    }
}
```

### When to Use

| Buffer Type | Use Update Ranges? |
|-------------|-------------------|
| Uniform buffers (<256 bytes) | No - upload whole buffer |
| Transform arrays (100-1000 elements) | Maybe - profile first |
| Vertex buffers (>10K vertices) | Yes - if sparse updates |
| Instance data (>1K instances) | Yes - common use case |

---

## 3. Resource Pool Structure

### Core Design

```rust
pub struct ResourcePool {
    // Resources
    buffers: Vec<Option<BufferEntry>>,
    textures: Vec<Option<TextureEntry>>,

    // Freelists for handle recycling (rend3 pattern)
    buffer_freelist: Vec<u32>,
    texture_freelist: Vec<u32>,

    // Deferred operations (rend3 instruction queue, simplified)
    pending_uploads: Vec<UploadOp>,
    pending_deletes: VecDeque<Vec<ResourceId>>,

    // Frame tracking
    current_frame: u64,
    delete_delay_frames: usize,  // Default: 2
}

struct BufferEntry {
    buffer: wgpu::Buffer,
    dirty_flag: DirtyFlag,
    staged_data: Option<Vec<u8>>,  // For CPU-side staging
}

struct TextureEntry {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    dirty_flag: DirtyFlag,
}
```

### Handle Types

```rust
/// Opaque handle to a buffer in the pool
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct BufferHandle {
    index: u32,
    generation: u16,  // For use-after-free detection
}

/// Opaque handle to a texture in the pool
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct TextureHandle {
    index: u32,
    generation: u16,
}
```

### Frame Processing

```rust
impl ResourcePool {
    /// Called at start of frame
    pub fn begin_frame(&mut self) {
        self.current_frame += 1;
        DirtyFlag::increment_global_ticks();  // If using global tick counter
    }

    /// Upload dirty resources to GPU
    pub fn process_uploads(&mut self, queue: &wgpu::Queue) {
        // Process pending upload operations
        for op in self.pending_uploads.drain(..) {
            match op {
                UploadOp::Buffer { handle, data } => {
                    if let Some(entry) = self.get_buffer_mut(handle) {
                        queue.write_buffer(&entry.buffer, 0, &data);
                        entry.dirty_flag.clear();
                    }
                }
                UploadOp::Texture { handle, data, layout } => {
                    // ... texture upload
                }
            }
        }

        // Process tracked buffers with dirty ranges
        for entry in self.buffers.iter_mut().flatten() {
            if entry.dirty_flag.is_dirty() {
                if let Some(staged) = &entry.staged_data {
                    queue.write_buffer(&entry.buffer, 0, staged);
                    entry.dirty_flag.clear();
                }
            }
        }
    }

    /// Process deferred deletions (call after submit)
    pub fn process_deletions(&mut self) {
        // Queue this frame's deletions
        let this_frame = std::mem::take(&mut self.pending_deletes_this_frame);
        self.pending_deletes.push_back(this_frame);

        // Delete resources from N frames ago (now safe)
        if self.pending_deletes.len() > self.delete_delay_frames {
            let safe_to_delete = self.pending_deletes.pop_front().unwrap();
            for id in safe_to_delete {
                self.actually_delete(id);
            }
        }
    }

    /// Mark resource for deferred deletion
    pub fn delete(&mut self, handle: impl Into<ResourceId>) {
        self.pending_deletes_this_frame.push(handle.into());
    }
}
```

---

## 4. Shader Caching

### Two-Level Cache (tixl pattern)

```rust
pub struct ShaderCache {
    // In-memory: hash → compiled module
    memory_cache: HashMap<u64, wgpu::ShaderModule>,

    // Disk: hash → spirv/wgsl bytes (optional)
    disk_cache_dir: Option<PathBuf>,
}

impl ShaderCache {
    pub fn get_or_compile(
        &mut self,
        device: &wgpu::Device,
        source: &str,
        dirty: bool,
    ) -> &wgpu::ShaderModule {
        let hash = self.hash_source(source);

        // Force recompile if dirty
        if dirty {
            self.memory_cache.remove(&hash);
        }

        self.memory_cache.entry(hash).or_insert_with(|| {
            // Try disk cache first
            if let Some(bytes) = self.load_from_disk(hash) {
                return device.create_shader_module(ShaderModuleDescriptor {
                    source: ShaderSource::SpirV(bytes.into()),
                    ..Default::default()
                });
            }

            // Compile from source
            let module = device.create_shader_module(ShaderModuleDescriptor {
                source: ShaderSource::Wgsl(source.into()),
                ..Default::default()
            });

            // Cache to disk (async, fire-and-forget)
            self.save_to_disk(hash, &module);

            module
        })
    }
}
```

---

## 5. Thread Safety Considerations

### Phase 1: Single-Threaded

Start simple - all GPU work on one thread:

```rust
pub struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pool: ResourcePool,
    // All on main thread
}
```

### Phase 2: Parallel Command Recording (if needed)

Design for future parallel recording without major refactoring:

```rust
pub struct ParallelRenderer {
    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    pool: Arc<Mutex<ResourcePool>>,
}

impl ParallelRenderer {
    pub fn record_parallel<F, R>(&self, chunks: Vec<F>) -> Vec<wgpu::CommandBuffer>
    where
        F: FnOnce(&wgpu::Device) -> wgpu::CommandBuffer + Send,
    {
        chunks.into_par_iter()
            .map(|f| f(&self.device))
            .collect()
    }
}
```

---

## 6. Open Questions for Prototyping

These questions should be resolved through prototyping:

### Megabuffer Threshold
- At what mesh count does megabuffer become worthwhile?
- Start with 100+ meshes as threshold

### Range Merging Value
- Is Three.js-style merging worth it for wgpu?
- wgpu's `queue.writeBuffer` may be cheap enough to skip merging

### Bind Group Caching
- Should Flux cache bind groups or recreate per-frame?
- Profile both approaches with typical node graphs

### Shader Hot-Reload
- How to integrate shader dirty flags with hot reload?
- Consider file watcher → dirty flag integration

---

## 7. Implementation Phases

### Phase 1: Foundation
- [ ] DirtyFlag struct with frame deduplication
- [ ] Basic ResourcePool with Arc-wrapped resources
- [ ] Single-encoder command recording
- [ ] Drop-based cleanup with 2-frame delay

### Phase 2: Optimization
- [ ] Update range tracking for large buffers
- [ ] Shader caching (memory + disk)
- [ ] Dense index handles for high-volume resources

### Phase 3: Advanced (if needed)
- [ ] Megabuffer + range allocator
- [ ] Parallel command recording
- [ ] Render graph for complex passes

---

## Summary

The research across 8 frameworks reveals consistent patterns:

1. **Dirty tracking is universal** - every framework tracks what changed
2. **Deferred operations are common** - batch work, process at boundaries
3. **Granularity matters** - coarse flags + fine ranges for different cases
4. **Simplicity first** - start simple, optimize based on profiling

Flux should adopt the tixl dirty flag system (already planned) and integrate it with a resource pool inspired by rend3's instruction queue and Three.js's update ranges. Start simple, measure, and add complexity only where profiling shows benefit.
