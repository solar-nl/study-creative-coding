# rend3: Production-Scale Resource Management

> How do you manage thousands of meshes and textures efficiently?

---

## A Different Scale

nannou optimizes for creative coding: hundreds of resources, rapid iteration, simplicity over performance. rend3 targets a different audience: games and visualizations with thousands of meshes, textures, and materials. At that scale, patterns that work fine for hundreds become bottlenecks for thousands.

The question guiding this exploration: *what changes when resource counts grow by two orders of magnitude?*

---

## Dense Integer Handles

### The Allocation Problem

wgpu's Arc-wrapped handles work beautifully for moderate resource counts. But Arc has overhead:
- Atomic reference count increments on clone
- Atomic decrements on drop
- Memory for the control block alongside the data

For a particle system with 100,000 particles, each with a position buffer handle, that overhead adds up. And you can't use Arc handles for GPU-side indexing—shaders need integers, not pointers.

### rend3's Solution: Indices and Freelists

```rust
pub(crate) struct HandleAllocator<T>
where
    RawResourceHandle<T>: DeletableRawResourceHandle,
{
    max_allocated: AtomicUsize,
    freelist: Mutex<Vec<usize>>,
    _phantom: PhantomData<T>,
}
```

A handle is just an integer—an index into an array. Allocation either pops from the freelist or bumps the counter:

```rust
pub fn allocate(&self, renderer: &Arc<Renderer>) -> ResourceHandle<T> {
    let maybe_idx = self.freelist.lock().pop();
    let idx = maybe_idx.unwrap_or_else(|| {
        self.max_allocated.fetch_add(1, Ordering::Relaxed)
    });

    // ... create handle with destroy callback ...
    ResourceHandle::new(destroy_fn, idx)
}
```

When a handle is freed, its index returns to the freelist:

```rust
pub fn deallocate(&self, handle: RawResourceHandle<T>) {
    self.freelist.lock().push(handle.idx);
}
```

### Why This Matters

Dense indices enable:
- **O(1) allocation** (pop from freelist or bump counter)
- **O(1) lookup** (array index)
- **O(1) deallocation** (push to freelist)
- **Cache-friendly storage** (contiguous array)
- **GPU compatibility** (shaders can index by integer)

The tradeoff: explicit lifetime management. Unlike Arc, an index doesn't automatically free when unused. rend3 handles this through its instruction queue.

---

## The Megabuffer Pattern

### The Problem

Creating GPU buffers has overhead. Each `device.create_buffer()` involves driver calls, memory allocation, and internal bookkeeping. For a scene with 10,000 meshes, that's 10,000+ buffer creations—potentially hundreds of milliseconds.

### rend3's Solution: One Big Buffer

```rust
/// Pre-allocated mesh data. 32MB.
pub const STARTING_MESH_DATA: u64 = 1 << 25;

pub struct BufferState {
    pub buffer: Arc<Buffer>,
    pub allocator: RangeAllocator<u64>,
    pub encoder: CommandEncoder,
    pub wait_group: Arc<WaitGroup>,
}
```

Instead of thousands of small buffers, rend3 allocates one 32MB buffer and suballocates regions:

```rust
pub fn add(&self, device: &Device, mesh: Mesh) -> Result<InternalMesh, MeshCreationError> {
    let mut buffer_state = self.buffer_state.lock();

    // Allocate range for vertex attributes
    for attribute in &mesh.attributes {
        let range = self.allocate_range_impl(device, buffer_state, attribute.bytes())?;
        upload.add(range.start, attribute.untyped_data());
        vertex_attribute_ranges.push((*attribute.id(), range));
    }

    // Allocate range for indices
    let index_range = self.allocate_range_impl(device, buffer_state, index_count * 4)?;
    upload.add(index_range.start, bytemuck::cast_slice(&mesh.indices));

    // ... staging and upload ...
}
```

The `RangeAllocator` (from the `range-alloc` crate) tracks free regions within the megabuffer. Allocation finds a suitable free region; deallocation returns the region to the pool.

### The Tradeoffs

Megabuffers trade complexity for performance:
- **Pro:** Fewer buffer creations (one vs thousands)
- **Pro:** Better cache locality (all mesh data contiguous)
- **Pro:** Enables bindless rendering (one buffer binding for all meshes)
- **Con:** Fragmentation (freed regions may not be reusable)
- **Con:** Growth requires copy (reallocate + copy everything)
- **Con:** More complex debugging (offsets instead of separate buffers)

For rend3's target—games with thousands of meshes—the tradeoff is worthwhile. For simpler applications, it's unnecessary complexity.

---

## The Instruction Queue

### The Problem

User code and GPU execution are asynchronous. When you call `renderer.add_mesh()`, should the GPU upload happen immediately? What if you're in the middle of rendering? What if the mesh data comes from a loading thread?

And what about deletion? If you delete a mesh while the GPU is drawing it, disaster follows.

### rend3's Solution: Deferred Operations

```rust
pub enum InstructionKind {
    AddSkeleton { handle, skeleton },
    AddTexture2D { handle, internal_texture, cmd_buf },
    AddTextureCube { handle, internal_texture, cmd_buf },
    AddMaterial { handle, fill_invoke },
    AddObject { handle, ... },
    DeleteMesh { handle },
    DeleteTexture { handle },
    // ...
}
```

User API calls don't directly modify GPU state. They queue instructions:

```rust
// User code
let handle = renderer.add_mesh(mesh_data);  // Returns immediately
// Handle is valid now, even though GPU upload hasn't happened

// During render (internal)
fn process_instructions(&mut self) {
    for instruction in self.instructions.drain(..) {
        match instruction {
            AddTexture2D { handle, texture, cmd_buf } => {
                self.texture_manager.fill(handle, texture);
                if let Some(buf) = cmd_buf {
                    pending_commands.push(buf);
                }
            }
            DeleteMesh { handle } => {
                // Safe to delete now—we're between frames
                self.mesh_manager.remove(handle);
            }
            // ...
        }
    }
}
```

### Why This Pattern Works

The instruction queue provides:
- **Immediate handle validity.** User code gets handles right away; GPU work happens later.
- **Safe deletion.** Resources delete between frames, after GPU work completes.
- **Batching.** Multiple operations queue up and execute together.
- **Decoupling.** User code doesn't need to know about GPU timing.

This pattern appears in Werkkzeug4 (as "prep cards" in the kitchen brigade analogy), in game engines (as command buffers or work queues), and anywhere GPU work must be orchestrated carefully.

---

## Bindless Textures

### The Problem

Traditional rendering binds textures one at a time. Draw call 1 binds texture A, draws. Draw call 2 binds texture B, draws. Each bind has overhead; with thousands of textures, binding becomes a bottleneck.

### rend3's Solution: Texture Arrays

```rust
pub const STARTING_2D_TEXTURES: usize = 1 << 8;  // 256
pub const MAX_TEXTURE_COUNT: u32 = 1 << 17;      // 131,072

pub struct TextureManager<T> {
    layout: ProfileData<(), Arc<BindGroupLayout>>,
    group: ProfileData<(), Arc<BindGroup>>,
    group_dirty: ProfileData<(), bool>,

    null_view: TextureView,
    data: Vec<Option<InternalTexture>>,
    // ...
}
```

All textures live in one array. Materials reference textures by index. The shader samples from the array using the index. One bind serves all textures.

### The Null Texture Trick

What happens when a slot is empty? The array must have valid texture views in every slot, or the bind group is invalid.

rend3 uses a null texture—a 1x1 placeholder (typically black or magenta):

```rust
let null_view = create_null_tex_view(device, dimension);
```

Empty slots point to the null texture. If a shader accidentally samples an invalid index, it gets the placeholder, not a crash. This is defensive programming for GPU code, where debugging is hard.

### Dirty Tracking for Bind Groups

```rust
group_dirty: ProfileData<(), bool>,
```

When textures change, the bind group needs rebuilding. But rebuilding is expensive. The dirty flag enables lazy rebuilding:

```rust
// Only rebuild when needed
if self.group_dirty {
    self.group = create_bind_group(&self.data);
    self.group_dirty = false;
}
```

This is a simple dirty flag—just a boolean. For texture management, that's sufficient; the alternative (version counters or per-texture tracking) isn't worth the complexity.

---

## Wait Groups: Staging Synchronization

### The Problem

Staging buffers (CPU-visible buffers for uploading to GPU-only buffers) must stay valid until the GPU copy completes. But you want to release the lock on shared state as early as possible for parallelism.

### rend3's Solution

```rust
pub wait_group: Arc<WaitGroup>,

// In add():
let staging_guard = buffer_state.wait_group.increment();
drop(buffer_state_guard);  // Release lock early

// Write to staging buffer (outside lock)
upload.stage();
drop(staging_guard);  // Signal completion
```

The wait group tracks outstanding staging operations. Before queue submission, the renderer waits for all staging to complete:

```rust
wait_group.wait();  // Ensure all staging is done
queue.submit(...);
```

This allows staging writes to happen in parallel while ensuring they complete before submission. It's a synchronization primitive tailored to GPU upload patterns.

---

## Lessons for the GPU Resource Pool

rend3's patterns are designed for scale that creative coding may not initially need. But they're worth understanding:

**Dense indices when volume demands.** When managing thousands of resources, integer handles beat Arc. But start with Arc; switch if profiling shows the need.

**Megabuffers for geometry.** For dynamic mesh editing or particle systems, suballocation will matter. But defer until there's a use case.

**Instruction queues mesh with dirty flags.** Both are about deferring work: dirty flags mark what changed, instructions describe what to do. Process both at frame boundaries.

**Null fallbacks for safety.** When a resource might be missing (texture not loaded yet, slot freed), a null placeholder prevents crashes. Defensive programming for GPU code.

**Lazy bind group rebuild.** Don't rebuild every frame. Track when things change; rebuild only then.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `rend3/src/managers/handle_alloc.rs` | 15-47 | HandleAllocator with freelist |
| `rend3/src/managers/mesh.rs` | 26-121 | MeshManager and megabuffer |
| `rend3/src/managers/texture.rs` | 18-96 | TextureManager and bindless |
| `rend3/src/instruction.rs` | 29-54 | InstructionKind enum |

---

## Related Documents

- [wgpu.md](wgpu.md) — The underlying API
- [nannou.md](nannou.md) — Simpler creative coding approach
- [../allocation-strategies.md](../allocation-strategies.md) — When to use which strategy
- [../command-batching.md](../command-batching.md) — Instruction queue details
