# PixiJS Encoder System

> The meticulous secretary who remembers everything so you don't have to

## Key Insight

> **Encoder system's core idea:** Track what GPU state is already bound (pipeline, buffers, bind groups) and skip redundant calls, turning 1000 identical state-sets into one.

---

## The Problem: Recording GPU Commands Without Repetition

Picture a court stenographer transcribing a trial. Every word matters, so they record everything. But imagine if the lawyer kept repeating the same phrase: "Let the record show, let the record show, let the record show..." A good stenographer would note it once, not three times.

GPU rendering faces a similar challenge. Every frame, your application issues potentially thousands of commands: set this pipeline, bind that buffer, draw these triangles. Many of these commands are redundant. If you just drew 50 sprites with the same texture, you've said "use this texture" 50 times when once would suffice.

WebGPU faithfully records every command you give it. It doesn't know that command number 47 is identical to command number 46. That's where PixiJS's encoder system comes in. It acts as a thoughtful secretary, tracking what's already been said to avoid cluttering the transcript with repetition.

---

## How to Think About Command Encoding

Think of the encoder as a secretary taking meeting notes. The meeting (render frame) has structure:

1. **Meeting opens** (renderStart) - Fresh notepad, new transcript
2. **Topic begins** (beginRenderPass) - Clear context, start recording this section
3. **Discussion happens** (draw calls) - Record only new information, skip "as I said before..."
4. **Topic ends** (finishRenderPass) - Close this section
5. **Meeting adjourns** (postrender) - Submit notes, declare meeting complete

The secretary's key skill? Remembering what was already recorded. If someone says "Set the pipeline to X" and X is already the current pipeline, the secretary simply nods rather than writing it down again.

---

## The Frame Lifecycle: A Meeting in Four Acts

Let's trace what happens during a single frame of rendering:

```
renderStart()
    |
    +---> Create CommandEncoder (fresh notepad)
          Create completion Promise (meeting tracker)

beginRenderPass(renderTarget)
    |
    +---> End previous pass if exists
    +---> Clear state cache (new section, reset context)
    +---> Begin new render pass

[Draw calls: setPipeline, setGeometry, setBindGroup, draw*]
    |
    +---> Each call checks cache before recording

finishRenderPass()
    |
    +---> End render pass encoder

postrender()
    |
    +---> Finish render pass
    +---> queue.submit([commandEncoder.finish()])
    +---> Resolve completion Promise (meeting adjourned)
```

The critical insight is the middle section: every draw call goes through a cache check. This is where redundant work gets filtered out.

---

## The Caching Strategy: Don't Repeat Yourself

Here's where it gets interesting. The encoder maintains a mental model of what the GPU currently has bound:

```typescript
class GpuEncoderSystem {
    // The secretary's memory
    // Note: Source uses Object.create(null) for prototype-free objects
    private _boundBindGroup: Record<number, BindGroup> = Object.create(null);
    private _boundVertexBuffer: Record<number, Buffer> = Object.create(null);
    private _boundIndexBuffer: Buffer;
    private _boundPipeline: GPURenderPipeline;
}
```

Every setter method follows the same pattern: check first, record only if different.

```typescript
setPipeline(pipeline: GPURenderPipeline) {
    if (this._boundPipeline === pipeline) return;  // "Already noted"
    this._boundPipeline = pipeline;
    this.renderPassEncoder.setPipeline(pipeline);
}

private _setVertexBuffer(index: number, buffer: Buffer) {
    if (this._boundVertexBuffer[index] === buffer) return;  // "Already noted"
    this._boundVertexBuffer[index] = buffer;
    this.renderPassEncoder.setVertexBuffer(
        index,
        this._renderer.buffer.updateBuffer(buffer)
    );
}

setBindGroup(index: number, bindGroup: BindGroup, program: GpuProgram) {
    if (this._boundBindGroup[index] === bindGroup) return;  // "Already noted"
    this._boundBindGroup[index] = bindGroup;

    // Touch for GC tracking (keep-alive signal)
    bindGroup._touch(this._renderer.gc.now, this._renderer.tick);

    const gpuBindGroup = this._renderer.bindGroup.getBindGroup(bindGroup, program, index);
    this.renderPassEncoder.setBindGroup(index, gpuBindGroup);
}
```

The pattern is simple but the payoff is substantial. Consider drawing 1000 sprites with the same texture. Without caching, that's 1000 bind group calls. With caching, it's exactly one. The secretary writes "using texture X" once and then just records "another sprite, another sprite, another sprite..."

### Why Bother? Isn't WebGPU Fast?

You might wonder: if WebGPU handles these commands, why does redundancy matter? Three reasons:

1. **CPU overhead** - Each API call involves parameter validation, even for no-ops
2. **Command buffer bloat** - Redundant commands still take space in the buffer
3. **Validation work** - The driver must check each command's validity

The encoder acts as a filter, catching obvious waste before it reaches the GPU.

---

## When the Secretary Gets Amnesia: Cache Clearing

Here's a crucial detail: the cache must be cleared at the start of each render pass.

```typescript
private _clearCache() {
    for (let i = 0; i < 16; i++) {
        this._boundBindGroup[i] = null;
        this._boundVertexBuffer[i] = null;
    }
    this._boundIndexBuffer = null;
    this._boundPipeline = null;
}

beginRenderPass(gpuRenderTarget: GpuRenderTarget) {
    this.endRenderPass();
    this._clearCache();  // Forget everything
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(gpuRenderTarget.descriptor);
}
```

Why the amnesia? Because WebGPU render passes don't inherit state. When you call `beginRenderPass()`, you get a fresh encoder with nothing bound. If the secretary's notes say "pipeline X is active" but the GPU's render pass is brand new, the notes are wrong. Stale cache entries would cause missed bindings and broken rendering.

Think of it like context switching in a conversation. When the meeting moves to a new topic, the chairman says "Let's reset - assume nothing from the previous discussion carries forward."

---

## Handling Geometry: The Interleaving Optimization

When setting up geometry for a draw call, the encoder does something clever:

```typescript
setGeometry(geometry: Geometry, program: GpuProgram) {
    // Get only the unique buffers needed
    const buffersToBind = this._renderer.pipeline.getBufferNamesToBind(geometry, program);

    for (const i in buffersToBind) {
        this._setVertexBuffer(
            parseInt(i, 10),
            geometry.attributes[buffersToBind[i]].buffer
        );
    }

    if (geometry.indexBuffer) {
        this._setIndexBuffer(geometry.indexBuffer);
    }
}
```

The key insight is `getBufferNamesToBind`. Modern geometry often uses interleaved layouts where multiple attributes share one buffer:

```
Interleaved Buffer Layout:
Buffer 0: [pos.x, pos.y, uv.u, uv.v, color] [pos.x, pos.y, uv.u, uv.v, color] ...
           ← vertex 0 →                       ← vertex 1 →

Without optimization: 3 setVertexBuffer calls (position, uv, color)
With optimization:    1 setVertexBuffer call (one buffer holds everything)
```

The naive approach would call `setVertexBuffer` for each attribute. But if position, UV, and color all live in the same buffer, that's three calls to bind the same thing. PixiJS deduplicates, binding each unique buffer exactly once.

---

## The High-Level Draw API: Convenience Built on Primitives

For most use cases, PixiJS provides a convenient `draw()` method that bundles the entire setup:

```typescript
draw(options: {
    geometry: Geometry;
    shader: Shader;
    state?: State;
    topology?: Topology;
    size?: number;
    start?: number;
    instanceCount?: number;
    skipSync?: boolean;
}) {
    const { geometry, shader, state, topology, size, start, instanceCount, skipSync } = options;

    // 1. Set pipeline (with caching)
    this.setPipelineFromGeometryProgramAndState(geometry, shader.gpuProgram, state, topology);

    // 2. Set geometry (vertex + index buffers, with caching)
    this.setGeometry(geometry, shader.gpuProgram);

    // 3. Set shader bind groups (uniforms, textures)
    this._setShaderBindGroups(shader, skipSync);

    // 4. Issue the actual draw call
    if (geometry.indexBuffer) {
        this.renderPassEncoder.drawIndexed(
            size || geometry.indexBuffer.data.length,
            instanceCount ?? geometry.instanceCount,
            start || 0
        );
    } else {
        this.renderPassEncoder.draw(
            size || geometry.getSize(),
            instanceCount ?? geometry.instanceCount,
            start || 0
        );
    }
}
```

This is convenient for general use, but the individual methods remain available for fine-grained control. The [batching system](./batching.md) uses these primitives directly to squeeze out maximum performance.

---

## Uniform Syncing: Keeping CPU and GPU in Agreement

Before bind groups can be set, any changed uniforms need to be uploaded to the GPU:

```typescript
private _setShaderBindGroups(shader: Shader, skipSync?: boolean) {
    for (const i in shader.groups) {
        const bindGroup = shader.groups[i] as BindGroup;

        if (!skipSync) {
            this._syncBindGroup(bindGroup);
        }

        this.setBindGroup(i as unknown as number, bindGroup, shader.gpuProgram);
    }
}

private _syncBindGroup(bindGroup: BindGroup) {
    for (const j in bindGroup.resources) {
        const resource = bindGroup.resources[j];

        if ((resource as UniformGroup).isUniformGroup) {
            this._renderer.ubo.updateUniformGroup(resource as UniformGroup);
        }
    }
}
```

The `skipSync` flag is an optimization escape hatch. During batched rendering, the system knows uniforms haven't changed and can skip the sync check entirely. This is another example of PixiJS trading convenience for performance when it matters.

---

## Frame Completion Tracking

Sometimes external code needs to know when a frame is truly done. PixiJS provides a Promise for this:

```typescript
public commandFinished: Promise<void>;
private _resolveCommandFinished: (value: void) => void;

renderStart(): void {
    this.commandFinished = new Promise((resolve) => {
        this._resolveCommandFinished = resolve;
    });
    this.commandEncoder = this._renderer.gpu.device.createCommandEncoder();
}

postrender() {
    this.finishRenderPass();
    this._gpu.device.queue.submit([this.commandEncoder.finish()]);
    this._resolveCommandFinished();  // Meeting adjourned
    this.commandEncoder = null;
}
```

This allows code like `await renderer.encoder.commandFinished` to synchronize with frame boundaries. Useful for screenshots, video capture, or coordination with external systems.

---

## Debug Support: The Restore Mechanism

Debugging GPU rendering is notoriously difficult. Sometimes you need to interrupt a render pass (say, to read back a texture for logging), then resume where you left off. PixiJS supports this with `restoreRenderPass`:

```typescript
restoreRenderPass() {
    // Get descriptor and start fresh pass first
    const descriptor = this._renderer.renderTarget.adaptor.getDescriptor(...);
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(descriptor);

    // Save the secretary's notes (before clearing)
    const boundPipeline = this._boundPipeline;
    const boundVertexBuffer = { ...this._boundVertexBuffer };
    const boundIndexBuffer = this._boundIndexBuffer;
    const boundBindGroup = { ...this._boundBindGroup };

    this._clearCache();

    // Restore viewport
    const viewport = this._renderer.renderTarget.viewport;
    this.renderPassEncoder.setViewport(viewport.x, viewport.y, viewport.width, viewport.height, 0, 1);

    // Replay all the bindings from saved notes
    this.setPipeline(boundPipeline);
    for (const i in boundVertexBuffer) {
        this._setVertexBuffer(i as unknown as number, boundVertexBuffer[i]);
    }
    for (const i in boundBindGroup) {
        this.setBindGroup(i as unknown as number, boundBindGroup[i], null);
    }
    this._setIndexBuffer(boundIndexBuffer);
}
```

It's like the secretary photocopying their notes, starting a new page, then transcribing everything back. Expensive, but invaluable when you need to peek at intermediate state.

---

## wgpu Implementation

Here's how you might implement the same encoder pattern in Rust with wgpu:

```rust
use std::collections::HashMap;

struct EncoderSystem {
    command_encoder: Option<wgpu::CommandEncoder>,
    render_pass: Option<wgpu::RenderPass<'static>>,

    // State cache - the secretary's memory
    bound_pipeline: Option<wgpu::RenderPipeline>,
    bound_bind_groups: HashMap<u32, wgpu::BindGroup>,
    bound_vertex_buffers: HashMap<u32, wgpu::Buffer>,
    bound_index_buffer: Option<wgpu::Buffer>,
}

impl EncoderSystem {
    fn render_start(&mut self, device: &wgpu::Device) {
        self.command_encoder = Some(device.create_command_encoder(&Default::default()));
    }

    fn begin_render_pass(&mut self, descriptor: &wgpu::RenderPassDescriptor) {
        self.end_render_pass();
        self.clear_cache();  // Amnesia time

        if let Some(encoder) = &mut self.command_encoder {
            // Note: Real implementation requires careful lifetime management
            self.render_pass = Some(encoder.begin_render_pass(descriptor));
        }
    }

    fn set_pipeline(&mut self, pipeline: &wgpu::RenderPipeline) {
        // Compare by ID, not deep equality
        if self.bound_pipeline.as_ref().map(|p| p.global_id()) == Some(pipeline.global_id()) {
            return;  // Already noted
        }

        self.bound_pipeline = Some(pipeline.clone());
        if let Some(pass) = &mut self.render_pass {
            pass.set_pipeline(pipeline);
        }
    }

    fn set_vertex_buffer(&mut self, slot: u32, buffer: &wgpu::Buffer) {
        if self.bound_vertex_buffers.get(&slot).map(|b| b.global_id()) == Some(buffer.global_id()) {
            return;
        }

        self.bound_vertex_buffers.insert(slot, buffer.clone());
        if let Some(pass) = &mut self.render_pass {
            pass.set_vertex_buffer(slot, buffer.slice(..));
        }
    }

    fn set_index_buffer(&mut self, buffer: &wgpu::Buffer, format: wgpu::IndexFormat) {
        if self.bound_index_buffer.as_ref().map(|b| b.global_id()) == Some(buffer.global_id()) {
            return;
        }

        self.bound_index_buffer = Some(buffer.clone());
        if let Some(pass) = &mut self.render_pass {
            pass.set_index_buffer(buffer.slice(..), format);
        }
    }

    fn set_bind_group(&mut self, index: u32, bind_group: &wgpu::BindGroup) {
        if self.bound_bind_groups.get(&index).map(|bg| bg.global_id()) == Some(bind_group.global_id()) {
            return;
        }

        self.bound_bind_groups.insert(index, bind_group.clone());
        if let Some(pass) = &mut self.render_pass {
            pass.set_bind_group(index, bind_group, &[]);
        }
    }

    fn draw_indexed(&mut self, indices: u32, instances: u32) {
        if let Some(pass) = &mut self.render_pass {
            pass.draw_indexed(0..indices, 0, 0..instances);
        }
    }

    fn end_render_pass(&mut self) {
        self.render_pass = None;  // Dropping ends the pass
    }

    fn submit(&mut self, queue: &wgpu::Queue) {
        self.end_render_pass();

        if let Some(encoder) = self.command_encoder.take() {
            queue.submit(std::iter::once(encoder.finish()));
        }
    }

    fn clear_cache(&mut self) {
        self.bound_pipeline = None;
        self.bound_bind_groups.clear();
        self.bound_vertex_buffers.clear();
        self.bound_index_buffer = None;
    }
}
```

Key differences from JavaScript:

- **Identity comparison**: wgpu objects provide `global_id()` for efficient identity checks
- **Lifetime management**: Rust's borrowing rules make render pass lifetimes tricky. The render pass borrows the command encoder mutably, so you cannot call other encoder methods while a render pass is active. The simplified example above uses `Option` and dropping to manage this, but real implementations often use scoped patterns or split the encoder into separate phases.
- **No garbage collection**: You manage resource lifetimes explicitly, so the "GC touch" pattern from PixiJS doesn't apply

---

## Key Patterns to Remember

### Identity, Not Equality

The cache compares object references, not contents:

```typescript
if (this._boundPipeline === pipeline) return;  // Same object?
```

This is fast and sufficient because pipelines and bind groups are typically cached elsewhere (see [Pipeline Caching](./pipeline-caching.md)). Two identical configurations should share the same object, not be separate but equal objects.

### Lazy Buffer Updates

Vertex buffers aren't uploaded until needed:

```typescript
this._renderer.buffer.updateBuffer(buffer)  // Upload if dirty
```

This deferred approach means CPU-side changes to buffer data don't immediately trigger GPU uploads. The upload happens exactly when the buffer is bound, and only if it's dirty.

### Per-Pass Cache Reset

Every new render pass requires clearing the cache. This isn't optional - it reflects the WebGPU reality that render passes start with a blank slate.

---

## Performance Impact

The encoder's state caching eliminates redundant work across the board:

| Operation | Without Cache | With Cache |
|-----------|---------------|------------|
| Same pipeline | N calls | 1 call |
| Same vertex buffer | N calls | 1 call |
| Same bind group | N calls | 1 call |
| 1000 batched sprites | ~3000 calls | ~10 calls |

The savings compound dramatically with batching. A thousand sprites sharing a texture atlas need exactly one texture bind, one pipeline set, and one vertex buffer bind. The secretary writes the setup once, then just tallies up the draws.

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/GpuEncoderSystem.ts`

---

*Next: [Bind Groups](./bind-groups.md) - How resources get packaged for shaders*
