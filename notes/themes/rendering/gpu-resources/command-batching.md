# Command Batching Patterns

> How frameworks organize GPU commands for efficient submission

---

## The Problem

GPU commands aren't executed immediately - they're recorded into command buffers, then submitted. How you organize recording affects:
- **Parallelism**: Can multiple threads record?
- **Overhead**: How many submit calls?
- **Latency**: When does work start executing?
- **Ordering**: What dependencies exist?

---

## Pattern Catalog

### 1. Single Encoder Per Frame (Basic)

```rust
// wgpu basic pattern
let mut encoder = device.create_command_encoder(&Default::default());

// Record all work
{
    let mut pass = encoder.begin_render_pass(&desc);
    pass.set_pipeline(&pipeline);
    pass.draw(..);
}

// Single submit
queue.submit(Some(encoder.finish()));
```

**Characteristics:**
- Simple mental model
- Single-threaded recording
- All work in one submit

**Use case**: Simple applications, prototypes.

### 2. Instruction Queue (rend3)

```rust
// rend3 pattern
pub enum InstructionKind {
    AddTexture2D { handle, internal_texture, cmd_buf },
    AddMaterial { handle, fill_invoke },
    DeleteMesh { handle },
    // ...
}

// User code queues instructions
renderer.add_texture(texture_data);  // Returns handle immediately
renderer.add_mesh(mesh_data);        // Handle valid now

// Later, during render:
fn process_instructions(&mut self) {
    for instruction in self.instructions.drain(..) {
        match instruction {
            AddTexture2D { handle, texture, cmd_buf } => {
                self.texture_manager.fill(handle, texture);
                if let Some(buf) = cmd_buf {
                    pending_commands.push(buf);
                }
            }
            // ...
        }
    }
}
```

**Characteristics:**
- Decouples user API from GPU work
- Handles valid before GPU work completes
- Batches operations
- Deferred deletion (safe for in-flight)

**Use case**: Complex renderers, many resources.

### 3. Multiple Encoders (Parallel Recording)

```rust
// Parallel command recording
let encoders: Vec<CommandEncoder> = (0..thread_count)
    .map(|_| device.create_command_encoder(&Default::default()))
    .collect();

// Each thread records to its own encoder
thread_pool.scope(|s| {
    for (encoder, work_chunk) in encoders.iter_mut().zip(work_chunks) {
        s.spawn(move || {
            for item in work_chunk {
                record_draw_commands(encoder, item);
            }
        });
    }
});

// Collect and submit all
let command_buffers: Vec<_> = encoders.into_iter()
    .map(|e| e.finish())
    .collect();
queue.submit(command_buffers);
```

**Characteristics:**
- Parallel command recording
- Single batched submit
- Order within encoder preserved
- Order across encoders: undefined (unless you order the Vec)

**Use case**: Large scenes, CPU-bound recording.

### 4. Update Range Batching (Three.js)

```javascript
// Three.js WebGL pattern
// Sort ranges to find merge opportunities
updateRanges.sort((a, b) => a.start - b.start);

// Merge adjacent/overlapping
for (let i = 1; i < updateRanges.length; i++) {
    const curr = updateRanges[i];
    const prev = updateRanges[mergedIdx];

    if (curr.start <= prev.start + prev.count) {
        // Merge
        prev.count = Math.max(prev.count, curr.start + curr.count - prev.start);
    } else {
        // Keep separate
        mergedIdx++;
        updateRanges[mergedIdx] = curr;
    }
}

// Upload merged ranges
for (const range of mergedRanges) {
    gl.bufferSubData(target, range.start, data.subarray(range.start, range.start + range.count));
}
```

**Characteristics:**
- Reduces individual GPU commands
- Trades CPU work for fewer driver calls
- Particularly valuable for WebGL (high driver overhead)

**Use case**: Many small buffer updates.

### 5. Render Graph (Advanced)

```rust
// Conceptual render graph
struct RenderGraph {
    passes: Vec<Pass>,
    resources: HashMap<ResourceId, ResourceDesc>,
}

impl RenderGraph {
    fn compile(&self) -> CompiledGraph {
        // Analyze dependencies
        // Reorder for optimal barriers
        // Merge compatible passes
        // Allocate transient resources
    }

    fn execute(&self, compiled: &CompiledGraph, encoder: &mut CommandEncoder) {
        for pass in compiled.ordered_passes() {
            pass.execute(encoder);
        }
    }
}
```

**Characteristics:**
- Explicit resource dependencies
- Automatic barrier insertion
- Pass reordering for efficiency
- Transient resource aliasing

**Use case**: Complex rendering pipelines, advanced optimization.

---

## Comparison Matrix

| Pattern | Parallelism | Complexity | Optimization | Use Case |
|---------|-------------|------------|--------------|----------|
| Single encoder | None | Simple | None | Prototypes |
| Instruction queue | Queue access | Medium | Batching | Production |
| Multiple encoders | Recording | Medium | Parallel | Large scenes |
| Range batching | N/A | Medium | Merge ops | Many updates |
| Render graph | Full | High | Maximum | AAA quality |

---

## Integration with Dirty Flags

### The Pattern

Dirty flags and command batching work together:

```rust
// During frame update
fn prepare_frame(&mut self) {
    // 1. Process dirty flags → collect what needs uploading
    let dirty_buffers: Vec<_> = self.buffers.iter()
        .filter(|b| b.dirty_flag.is_dirty())
        .collect();

    // 2. Batch uploads into commands
    for buffer in dirty_buffers {
        self.pending_uploads.push(UploadCommand {
            buffer: buffer.handle,
            data: buffer.staged_data.clone(),
        });
        buffer.dirty_flag.clear();
    }
}

fn record_commands(&mut self, encoder: &mut CommandEncoder) {
    // 3. Execute batched uploads
    for upload in self.pending_uploads.drain(..) {
        encoder.copy_buffer_to_buffer(..);
    }

    // 4. Record render passes
    // ...
}
```

Key insight: **dirty flags identify work, command batching organizes it**.

---

## Flux Recommendation

### Phase 1: Single Encoder + Deferred Operations

```rust
pub struct FrameContext {
    encoder: wgpu::CommandEncoder,
    pending_uploads: Vec<BufferUpload>,
    pending_deletes: Vec<ResourceId>,
}

impl FrameContext {
    pub fn process_dirty_resources(&mut self, pool: &mut ResourcePool) {
        for buffer in pool.dirty_buffers() {
            self.pending_uploads.push(BufferUpload {
                handle: buffer.handle,
                data: buffer.staged_data(),
            });
        }
    }

    pub fn finish(self, queue: &wgpu::Queue) -> wgpu::CommandBuffer {
        // Execute uploads
        for upload in self.pending_uploads {
            queue.write_buffer(&upload.buffer, 0, &upload.data);
        }

        // Schedule deferred deletes (after GPU confirms completion)
        self.schedule_deletes();

        self.encoder.finish()
    }
}
```

### Phase 2: Instruction Queue (if needed)

Add rend3-style instruction queue if:
- Resources created during render
- Need handle validity before GPU work
- Complex multi-frame dependencies

### Consider for Future: Render Graph

If Flux grows to support complex multi-pass rendering, a render graph would enable:
- Automatic barrier insertion
- Transient resource allocation
- Pass reordering

But this adds significant complexity - defer until proven necessary.

---

## Related Documents

- [per-framework/rend3.md](per-framework/rend3.md) - Instruction queue details
- [per-framework/threejs.md](per-framework/threejs.md) - Range batching details
- [per-framework/wgpu.md](per-framework/wgpu.md) - Encoder patterns
