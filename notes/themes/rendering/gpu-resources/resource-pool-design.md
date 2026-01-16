# GPU Resource Pool: Design Synthesis

> Synthesizing patterns from nine frameworks into a reusable component

---

## The Story So Far

We studied nine frameworks—wgpu, nannou, rend3, tixl, OpenRNDR, Three.js, Cinder, Processing, and Farbrausch's Werkkzeug/Altona—each with battle-tested solutions to GPU resource management. They span languages (Rust, Kotlin, JavaScript, C++, Java, C#), audiences (creative coders, game developers, demoscene artists, web developers), and scales (hundreds of resources to tens of thousands).

Despite their differences, consistent patterns emerged. The same problems recur; the same solutions appear in different guises. What follows is a distillation: the patterns that matter most for a GPU Resource Pool component, presented not as abstract theory but as concrete design recommendations.

The GPU Resource Pool is a framework-level component that any part of the system can use—the node graph (Flux), the renderer, procedural generators, or user code. It abstracts wgpu's resource management into patterns optimized for creative coding workflows.

---

## Dirty Flags: The tixl Pattern

For tracking what needs uploading, tixl's reference/target pattern with frame deduplication is the clear choice:

```rust
pub struct DirtyFlag {
    reference: u32,
    target: u32,
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

    pub fn is_dirty(&self) -> bool {
        self.reference != self.target
    }

    pub fn invalidate(&mut self, current_frame: u64) -> u32 {
        if self.invalidated_frame == current_frame {
            return self.target;  // Already invalidated this frame
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

This pattern handles the common cases:
- **Diamond dependencies**: Multiple paths to the same resource don't multiply invalidation
- **Independent tracking**: Multiple consumers can check staleness independently
- **Debugging information**: The difference between target and reference tells you how far behind you are

### Integration Example

```rust
pub struct TrackedResource<T> {
    value: T,
    dirty_flag: DirtyFlag,
}

impl<T> TrackedResource<T> {
    pub fn set(&mut self, value: T, frame: u64) {
        self.value = value;
        self.dirty_flag.invalidate(frame);
    }

    pub fn update_if_dirty(&mut self, frame: u64, compute: impl FnOnce() -> T) {
        if self.dirty_flag.is_dirty() {
            self.value = compute();
            self.dirty_flag.clear();
        }
    }
}
```

---

## Update Ranges: When Precision Matters

For large buffers with sparse updates—particle positions, instance transforms, dynamic geometry—track which portions changed:

```rust
pub struct TrackedBuffer {
    buffer: wgpu::Buffer,
    data: Vec<u8>,
    dirty_ranges: Vec<Range<u64>>,
    dirty_flag: DirtyFlag,
}

impl TrackedBuffer {
    pub fn write(&mut self, offset: u64, data: &[u8], frame: u64) {
        let end = offset + data.len() as u64;
        self.data[offset as usize..end as usize].copy_from_slice(data);
        self.dirty_ranges.push(offset..end);
        self.dirty_flag.invalidate(frame);
    }

    pub fn flush(&mut self, queue: &wgpu::Queue) {
        if !self.dirty_flag.is_dirty() {
            return;
        }

        // Optional: merge adjacent ranges
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
}
```

### When to Use Update Ranges

| Buffer Type | Use Update Ranges? |
|-------------|-------------------|
| Uniform buffers (<256 bytes) | No — upload entire buffer |
| Transform arrays (100-1000 elements) | Maybe — profile first |
| Vertex buffers (>10K vertices) | Yes — if sparse updates |
| Instance data (>1K instances) | Yes — common use case |

The overhead of tracking ranges isn't worth it for small buffers. For large buffers with localized changes, the bandwidth savings are substantial.

---

## The Pool Structure

The resource pool follows the natural frame rhythm: collect dirty resources, batch uploads, process deletions at boundaries.

```rust
pub struct GpuResourcePool {
    buffers: Vec<Option<BufferEntry>>,
    textures: Vec<Option<TextureEntry>>,

    buffer_freelist: Vec<u32>,
    texture_freelist: Vec<u32>,

    pending_uploads: Vec<UploadOp>,
    pending_deletes: VecDeque<Vec<ResourceId>>,

    current_frame: u64,
    delete_delay_frames: usize,  // Default: 2
}

struct BufferEntry {
    buffer: wgpu::Buffer,
    dirty_flag: DirtyFlag,
    staged_data: Option<Vec<u8>>,
}
```

### Frame Processing

```rust
impl GpuResourcePool {
    pub fn begin_frame(&mut self) {
        self.current_frame += 1;
    }

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

        // Process tracked buffers with dirty flags
        for entry in self.buffers.iter_mut().flatten() {
            if entry.dirty_flag.is_dirty() {
                if let Some(staged) = &entry.staged_data {
                    queue.write_buffer(&entry.buffer, 0, staged);
                    entry.dirty_flag.clear();
                }
            }
        }
    }

    pub fn process_deletions(&mut self) {
        // Queue this frame's deletes
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
}
```

---

## Handle Design: Match Complexity to Volume

Start simple. Add sophistication only when measurements demand it.

```rust
// For most resources: opaque handles with generation checks
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct BufferHandle {
    index: u32,
    generation: u16,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct TextureHandle {
    index: u32,
    generation: u16,
}
```

| Resource Type | Recommended Handle | Rationale |
|---------------|-------------------|-----------|
| Device/Queue | Arc-wrapped | Few, shared, automatic cleanup |
| Buffers | Generation + index | Moderate count, varied lifetimes |
| Textures | Generation + index | Few, often shared between components |
| Mesh data | Generation + index | Many small allocations possible |
| Bind groups | Recreate per-frame | Cheap, depend on multiple resources |

---

## Shader Caching: Two Levels

Shaders are expensive to compile. Cache at two levels:

```rust
pub struct ShaderCache {
    memory_cache: HashMap<u64, wgpu::ShaderModule>,
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

            // Cache to disk (async)
            self.save_to_disk(hash, &module);

            module
        })
    }
}
```

Hot shaders stay in memory. Cold shaders load from disk. First-time compilations hit the compiler, but results persist across sessions.

---

## Implementation Phases

### Phase 1: Foundation

The minimum viable resource pool:

- DirtyFlag struct with frame deduplication
- Basic GpuResourcePool with generation-checked handles
- Single-encoder command recording
- Drop-based cleanup with 2-frame delay

This is enough for simple creative coding. It handles the common cases correctly and safely.

### Phase 2: Optimization

Add when profiling shows need:

- Update range tracking for large buffers
- Shader caching (memory + disk)
- Range merging for many small updates

Don't add these preemptively. Measure first, optimize second.

### Phase 3: Scale

For complex scenes or high-performance requirements:

- Megabuffer + range allocator for geometry
- Parallel command recording
- Render graph for multi-pass pipelines

These are substantial complexity investments. Defer until the simpler approaches prove insufficient.

---

## Principles to Remember

**Dirty tracking is universal.** Every framework we studied tracks what changed. The mechanism varies—boolean flags, version counters, reference/target pairs—but the need is constant.

**Deferred operations are common.** Batch work, process at boundaries. User code operates with handles; GPU work happens at frame end.

**Granularity matters.** Coarse flags for most resources, fine-grained ranges for large dynamic buffers. Match tracking granularity to update patterns.

**Simplicity first.** Start with per-resource allocation and single-threaded rendering. Add megabuffers, parallelism, or render graphs only when profiling shows the need.

**Safety over speed.** For creative coding, memory is abundant and debugging use-after-free is painful. Err toward conservative reclamation, generous delays, and automatic cleanup.

The frameworks we studied evolved these patterns through years of real-world use. They're not arbitrary—they're the solutions that survived contact with actual applications.

---

## Related Documents

- [README.md](README.md) — Overview of the research
- [per-framework/](per-framework/) — Deep dives into each framework
- [cache-invalidation.md](cache-invalidation.md) — Dirty flag patterns in detail
- [handle-designs.md](handle-designs.md) — Handle pattern catalog
- [charging-vs-shadows.md](charging-vs-shadows.md) — CPU-GPU data flow patterns
