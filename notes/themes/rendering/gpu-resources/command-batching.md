# Command Batching: Organizing Work for the GPU

> GPU commands aren't executed immediately. How you organize them determines efficiency.

---

## The Recording Model

When you call `draw()` or `copy_buffer()`, the work doesn't happen immediately. Instead, commands are recorded into a buffer, then submitted to the GPU as a batch. The GPU executes the batch asynchronously while your CPU code moves on to the next frame.

This separation—recording versus execution—is fundamental to modern GPU APIs. It enables the driver to optimize command order, batch state changes, and keep the GPU fed with work. But it also means you have choices about how to organize your recording.

The question guiding this exploration: *what patterns organize commands effectively?*

---

## Single Encoder Per Frame: The Simple Path

The simplest approach: one command encoder records all work for the frame.

```rust
let mut encoder = device.create_command_encoder(&Default::default());

{
    let mut pass = encoder.begin_render_pass(&desc);
    pass.set_pipeline(&pipeline);
    pass.draw(..);
}

queue.submit(Some(encoder.finish()));
```

Create encoder, record everything, submit. The mental model is straightforward: commands go into the encoder in order, and the GPU executes them in that order.

For simple applications, this is ideal. One encoder, one submit, no synchronization concerns. The overhead is minimal, and clarity is maximal.

The limitation emerges with complexity. If you want to record commands on multiple threads, a single encoder serializes them. If you want to split work between systems that don't know about each other, sharing an encoder creates coupling.

---

## Multiple Encoders: Parallel Recording

wgpu allows multiple encoders to be created simultaneously:

```rust
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

Each thread gets its own encoder. Recording happens in parallel, limited only by CPU cores. At submission time, you collect all finished command buffers and submit them together.

The benefits scale with scene complexity. Recording draw calls involves per-object computation: culling, sorting, binding setup. For large scenes, this work can dominate CPU time. Parallelizing it across cores yields proportional speedups.

The coordination cost is collecting the finished buffers and ensuring proper ordering. Within each encoder, order is preserved. Across encoders, order in the submit call determines execution order—or the GPU may reorder within command buffers for efficiency.

---

## The Instruction Queue: Decoupling User and GPU

rend3 interposes a queue between user API calls and GPU work:

```rust
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
                pending_commands.push(cmd_buf);
            }
            // ...
        }
    }
}
```

When you call `add_texture()`, it doesn't upload to the GPU immediately. It queues an instruction and returns a handle. The handle is valid immediately—you can use it to set up materials, even though the GPU upload hasn't happened yet.

During the render phase, the queue drains. Instructions are processed in order. GPU work happens in batches. Deletions are safe because they're processed after the GPU confirms completion of in-flight work.

This pattern decouples user-facing API from GPU timing. User code operates with handles; GPU work happens at frame boundaries. The queue provides a natural batching point where the system can optimize: merge similar operations, reorder for cache efficiency, defer deletions safely.

---

## Update Range Batching

Three.js optimizes buffer uploads by merging adjacent update ranges:

```javascript
// Sort ranges to find merge opportunities
updateRanges.sort((a, b) => a.start - b.start);

// Merge overlapping/adjacent ranges
for (let i = 1; i < updateRanges.length; i++) {
    const curr = updateRanges[i];
    const prev = updateRanges[mergedIdx];

    if (curr.start <= prev.start + prev.count) {
        prev.count = Math.max(prev.count, curr.start + curr.count - prev.start);
    } else {
        mergedIdx++;
        updateRanges[mergedIdx] = curr;
    }
}

// Upload merged ranges
for (const range of mergedRanges) {
    gl.bufferSubData(target, range.start, data.subarray(range));
}
```

Each `bufferSubData` call has driver overhead. Three small calls cost more than one larger call covering the same bytes. By sorting ranges and merging those that overlap or are adjacent, Three.js reduces the number of GPU commands.

This optimization matters more for older APIs where per-call overhead is higher. WebGPU's `queue.writeBuffer` is cheaper per-call than WebGL's `bufferSubData`, so merging helps less. But the pattern remains valuable when many small updates accumulate.

---

## Integration with Dirty Flags

Command batching and dirty flags work together naturally:

```rust
fn prepare_frame(&mut self) {
    // Dirty flags identify what needs uploading
    let dirty_buffers: Vec<_> = self.buffers.iter()
        .filter(|b| b.dirty_flag.is_dirty())
        .collect();

    // Batch uploads into commands
    for buffer in dirty_buffers {
        self.pending_uploads.push(UploadCommand {
            buffer: buffer.handle,
            data: buffer.staged_data.clone(),
        });
        buffer.dirty_flag.clear();
    }
}

fn record_commands(&mut self, encoder: &mut CommandEncoder) {
    // Execute batched uploads
    for upload in self.pending_uploads.drain(..) {
        encoder.copy_buffer_to_buffer(..);
    }

    // Record render passes
    // ...
}
```

Dirty flags identify work. Command batching organizes it. The frame rhythm ties them together: check dirty flags, collect work, record commands, submit, clear flags.

This is the natural shape of a frame in a dirty-flag-driven system. Dirty tracking answers "what changed?" Command batching answers "how do we tell the GPU?"

---

## Render Graphs: The Complex Frontier

For sophisticated rendering pipelines, render graphs explicit dependencies between passes:

```rust
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

The graph describes what each pass reads and writes. The compiler analyzes dependencies, inserts synchronization barriers where needed, reorders passes for efficiency, and allocates temporary resources that multiple passes can share.

This is powerful but complex. Render graphs shine for multi-pass rendering: shadow maps, deferred shading, post-processing chains. For simple applications, they're unnecessary overhead.

---

## Lessons for Flux

The command batching research suggests a progression:

**Start with single encoder per frame.** It's simple, it works, and most creative coding doesn't need more. One encoder, one submit, done.

**Add deferred operations early.** Even without a full instruction queue, deferring deletions until frame boundaries prevents use-after-free. This costs little and prevents a class of bugs.

**Consider instruction queue for complex resource management.** If resources are created and destroyed dynamically, if handles need to be valid before GPU work completes, the instruction queue pattern pays off.

**Defer render graphs until proven necessary.** They add substantial complexity. For creative coding's typical one-pass rendering, they're overkill. Add them only when multi-pass pipelines become common.

**Let dirty flags drive batching.** The natural rhythm is: check dirty flags → collect work → record commands → submit. Don't fight this flow; embrace it.

---

## Related Documents

- [per-framework/rend3.md](per-framework/rend3.md) — Instruction queue details
- [per-framework/threejs.md](per-framework/threejs.md) — Range batching details
- [per-framework/wgpu.md](per-framework/wgpu.md) — Encoder patterns
