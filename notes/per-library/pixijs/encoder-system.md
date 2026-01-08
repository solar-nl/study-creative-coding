# PixiJS Encoder System

> Command encoding with aggressive state caching

---

## Overview

The `GpuEncoderSystem` is PixiJS's wrapper around WebGPU's command encoding. It manages the full render loop lifecycle while caching all GPU state to skip redundant calls.

---

## Frame Lifecycle

```
renderStart()
    │
    └─► Create CommandEncoder
        Create completion Promise

beginRenderPass(renderTarget)
    │
    ├─► End previous pass if exists
    ├─► Clear state cache
    └─► Begin new render pass

[Draw calls via setPipeline, setGeometry, setBindGroup, draw*]
    │
    └─► Each call checks cache before GPU call

finishRenderPass()
    │
    └─► End render pass encoder

postrender()
    │
    ├─► Finish render pass
    ├─► queue.submit([commandEncoder.finish()])
    └─► Resolve completion Promise
```

---

## State Caching

The encoder caches all bound state to avoid redundant GPU calls:

```typescript
class GpuEncoderSystem {
    // Cached state
    private _boundBindGroup: Record<number, BindGroup> = {};
    private _boundVertexBuffer: Record<number, Buffer> = {};
    private _boundIndexBuffer: Buffer;
    private _boundPipeline: GPURenderPipeline;

    // Every setter checks cache first
    setPipeline(pipeline: GPURenderPipeline) {
        if (this._boundPipeline === pipeline) return;  // SKIP
        this._boundPipeline = pipeline;
        this.renderPassEncoder.setPipeline(pipeline);
    }

    private _setVertexBuffer(index: number, buffer: Buffer) {
        if (this._boundVertexBuffer[index] === buffer) return;  // SKIP
        this._boundVertexBuffer[index] = buffer;
        this.renderPassEncoder.setVertexBuffer(
            index,
            this._renderer.buffer.updateBuffer(buffer)
        );
    }

    private _setIndexBuffer(buffer: Buffer) {
        if (this._boundIndexBuffer === buffer) return;  // SKIP
        this._boundIndexBuffer = buffer;
        const indexFormat = buffer.data.BYTES_PER_ELEMENT === 2 ? 'uint16' : 'uint32';
        this.renderPassEncoder.setIndexBuffer(
            this._renderer.buffer.updateBuffer(buffer),
            indexFormat
        );
    }

    setBindGroup(index: number, bindGroup: BindGroup, program: GpuProgram) {
        if (this._boundBindGroup[index] === bindGroup) return;  // SKIP
        this._boundBindGroup[index] = bindGroup;

        // Touch for GC tracking
        bindGroup._touch(this._renderer.gc.now, this._renderer.tick);

        const gpuBindGroup = this._renderer.bindGroup.getBindGroup(bindGroup, program, index);
        this.renderPassEncoder.setBindGroup(index, gpuBindGroup);
    }
}
```

### Why Cache?

WebGPU/wgpu calls have overhead even when setting the same state:
- Parameter validation
- Command buffer recording
- Internal state tracking

By caching, PixiJS avoids:
1. CPU overhead of redundant calls
2. Larger command buffers
3. Unnecessary validation work

---

## Cache Clearing

The cache is cleared when starting a new render pass:

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
    this._clearCache();  // Reset all cached state
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(gpuRenderTarget.descriptor);
}
```

This is necessary because:
1. WebGPU render passes don't inherit state from previous passes
2. A new `GPURenderPassEncoder` has no bound resources
3. The cache must match the actual GPU state

---

## Geometry Binding

The `setGeometry` method handles vertex and index buffer binding with interleaving optimization:

```typescript
setGeometry(geometry: Geometry, program: GpuProgram) {
    // Only bind unique buffers (handles interleaved attributes)
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

### Interleaving Optimization

When geometry has interleaved attributes (multiple attributes in one buffer), `getBufferNamesToBind` returns only unique buffers:

```
Interleaved Layout:
Buffer 0: [pos.x, pos.y, uv.u, uv.v, color] [pos.x, pos.y, uv.u, uv.v, color] ...

Without optimization: 3 setVertexBuffer calls (once per attribute)
With optimization: 1 setVertexBuffer call (once per unique buffer)
```

---

## High-Level Draw API

The `draw()` method is a convenience that handles the full draw call setup:

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

    // 1. Set pipeline (handles caching internally)
    this.setPipelineFromGeometryProgramAndState(geometry, shader.gpuProgram, state, topology);

    // 2. Set geometry (vertex + index buffers)
    this.setGeometry(geometry, shader.gpuProgram);

    // 3. Set shader bind groups (uniforms, textures)
    this._setShaderBindGroups(shader, skipSync);

    // 4. Issue draw call
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

---

## Uniform Syncing

Before setting bind groups, uniforms are synced to their GPU buffers:

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

The `skipSync` flag is an optimization for batched rendering where uniforms are known to be unchanged.

---

## Completion Tracking

PixiJS tracks frame completion via a Promise:

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
    this._resolveCommandFinished();  // Signal frame complete
    this.commandEncoder = null;
}
```

This allows external code to `await renderer.encoder.commandFinished` to synchronize with frame completion.

---

## Debug Support: Restore Render Pass

For debugging (e.g., logging textures mid-frame), PixiJS can restore a render pass:

```typescript
restoreRenderPass() {
    // Save current state
    const boundPipeline = this._boundPipeline;
    const boundVertexBuffer = { ...this._boundVertexBuffer };
    const boundIndexBuffer = this._boundIndexBuffer;
    const boundBindGroup = { ...this._boundBindGroup };

    // Clear and restart pass
    const descriptor = this._renderer.renderTarget.adaptor.getDescriptor(...);
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(descriptor);
    this._clearCache();

    // Restore viewport
    const viewport = this._renderer.renderTarget.viewport;
    this.renderPassEncoder.setViewport(viewport.x, viewport.y, viewport.width, viewport.height, 0, 1);

    // Reinstate all state
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

---

## wgpu Implementation

```rust
use std::collections::HashMap;

struct EncoderSystem {
    command_encoder: Option<wgpu::CommandEncoder>,
    render_pass: Option<wgpu::RenderPass<'static>>,

    // State cache
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
        self.clear_cache();

        if let Some(encoder) = &mut self.command_encoder {
            // Note: In real code, render_pass lifetime is tricky
            // This is simplified for illustration
            self.render_pass = Some(encoder.begin_render_pass(descriptor));
        }
    }

    fn set_pipeline(&mut self, pipeline: &wgpu::RenderPipeline) {
        // Check by ID comparison
        if self.bound_pipeline.as_ref().map(|p| p.global_id()) == Some(pipeline.global_id()) {
            return;  // Skip redundant call
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

    fn draw_indexed(&mut self, indices: u32, instances: u32, first_index: u32) {
        if let Some(pass) = &mut self.render_pass {
            pass.draw_indexed(0..indices, 0, 0..instances);
        }
    }

    fn end_render_pass(&mut self) {
        self.render_pass = None;  // Drop ends the pass
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

---

## Key Patterns

### 1. Identity Comparison for Caching

PixiJS compares object references, not deep equality:

```typescript
if (this._boundPipeline === pipeline) return;  // Reference comparison
```

In Rust/wgpu, use `global_id()` for similar identity checks:

```rust
if self.bound_pipeline.as_ref().map(|p| p.global_id()) == Some(pipeline.global_id()) {
    return;
}
```

### 2. Lazy Buffer Updates

The encoder calls `buffer.updateBuffer()` which lazily uploads CPU data to GPU:

```typescript
this.renderPassEncoder.setVertexBuffer(
    index,
    this._renderer.buffer.updateBuffer(buffer)  // Upload if dirty
);
```

### 3. Per-Pass Cache Reset

Every new render pass requires clearing the cache because WebGPU render passes don't inherit state.

### 4. High-Level Convenience

The `draw()` method bundles common operations but individual methods remain available for fine-grained control (used by the batch adaptor).

---

## Performance Impact

State caching eliminates redundant calls across:

| Operation | Without Cache | With Cache |
|-----------|---------------|------------|
| Same pipeline | N calls | 1 call |
| Same vertex buffer | N calls | 1 call |
| Same bind group | N calls | 1 call |
| Batched sprites | 1000 calls | ~10 calls |

The savings compound with batching—a batch of 1000 sprites with the same texture needs only 1 bind group call.

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/GpuEncoderSystem.ts`

---

*Next: [Bind Groups](bind-groups.md)*
