# PixiJS WebGPU Renderer Architecture

> System composition and render loop analysis

---

## System Composition

The `WebGPURenderer` composes 12+ specialized systems, each handling a specific responsibility:

```typescript
// From WebGPURenderer.ts
const DefaultWebGPUSystems = [
    ...SharedSystems,      // Common systems (shared with WebGL)
    GpuUboSystem,          // Uniform buffer objects
    GpuEncoderSystem,      // Command encoder management
    GpuDeviceSystem,       // WebGPU device & extensions
    GpuLimitsSystem,       // GPU capability limits
    GpuBufferSystem,       // Buffer allocation & sync
    GpuTextureSystem,      // Texture resource management
    GpuRenderTargetSystem, // Render target binding
    GpuShaderSystem,       // WGSL shader compilation
    GpuStateSystem,        // Pipeline state (blend, depth, stencil)
    PipelineSystem,        // Pipeline caching & creation
    GpuColorMaskSystem,    // Color masking
    GpuStencilSystem,      // Stencil buffer ops
    BindGroupSystem,       // Bind group management
];
```

### wgpu Mapping

| PixiJS System | wgpu Equivalent | Responsibility |
|---------------|-----------------|----------------|
| `GpuEncoderSystem` | `CommandEncoder`, `RenderPass` | Command recording |
| `GpuDeviceSystem` | `Device`, `Adapter` | GPU initialization |
| `GpuBufferSystem` | `Buffer` management | Vertex/index/uniform buffers |
| `GpuTextureSystem` | `Texture`, `TextureView` | Texture resources |
| `PipelineSystem` | `RenderPipeline` cache | Pipeline state management |
| `BindGroupSystem` | `BindGroup`, `BindGroupLayout` | Resource binding |
| `GpuShaderSystem` | `ShaderModule` | WGSL compilation |
| `GpuStateSystem` | Pipeline descriptor fields | Blend, depth, stencil |

---

## Render Pipes and Adaptors

Beyond systems, PixiJS uses **pipes** and **adaptors** to handle specific renderable types:

```typescript
const DefaultWebGPUPipes = [...SharedRenderPipes, GpuUniformBatchPipe];
const DefaultWebGPUAdapters = [GpuBatchAdaptor, GpuMeshAdapter, GpuGraphicsAdaptor];
```

### Pipe vs Adaptor

- **Pipe**: Converts scene objects into instructions (platform-agnostic logic)
- **Adaptor**: Executes instructions on specific backend (WebGPU-specific)

```
Scene Object ──► Pipe ──► Instruction ──► Adaptor ──► GPU Commands
                 │                         │
              Shared                  Platform-specific
              (WebGL/WebGPU)         (WebGPU only)
```

---

## GpuEncoderSystem Deep Dive

The encoder system wraps WebGPU command encoding with state caching:

```typescript
// GpuEncoderSystem.ts - Key state
class GpuEncoderSystem {
    commandEncoder: GPUCommandEncoder;
    renderPassEncoder: GPURenderPassEncoder;

    // State caching to skip redundant calls
    private _boundBindGroup: Record<number, BindGroup> = {};
    private _boundVertexBuffer: Record<number, Buffer> = {};
    private _boundIndexBuffer: Buffer;
    private _boundPipeline: GPURenderPipeline;
}
```

### Render Loop Lifecycle

```typescript
// 1. Start frame - create command encoder
renderStart(): void {
    this.commandEncoder = device.createCommandEncoder();
}

// 2. Begin render pass
beginRenderPass(gpuRenderTarget: GpuRenderTarget) {
    this.endRenderPass();  // End previous if exists
    this._clearCache();    // Reset state tracking
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(descriptor);
}

// 3. Draw calls (with state caching)
setPipeline(pipeline: GPURenderPipeline) {
    if (this._boundPipeline === pipeline) return;  // Skip if same
    this._boundPipeline = pipeline;
    this.renderPassEncoder.setPipeline(pipeline);
}

setBindGroup(index: number, bindGroup: BindGroup, program: GpuProgram) {
    if (this._boundBindGroup[index] === bindGroup) return;  // Skip if same
    this._boundBindGroup[index] = bindGroup;
    this.renderPassEncoder.setBindGroup(index, gpuBindGroup);
}

// 4. End frame - submit to queue
postrender() {
    this.finishRenderPass();
    this._gpu.device.queue.submit([this.commandEncoder.finish()]);
}
```

### wgpu Equivalent

```rust
// Rust/wgpu equivalent of the render loop
fn render(&mut self, view: &wgpu::TextureView) {
    // 1. Create command encoder
    let mut encoder = self.device.create_command_encoder(&Default::default());

    // 2. Begin render pass
    let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                store: wgpu::StoreOp::Store,
            },
        })],
        ..Default::default()
    });

    // 3. Draw calls
    render_pass.set_pipeline(&self.pipeline);
    render_pass.set_bind_group(0, &self.bind_group, &[]);
    render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
    render_pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint16);
    render_pass.draw_indexed(0..self.num_indices, 0, 0..1);

    drop(render_pass);  // End render pass

    // 4. Submit
    self.queue.submit(std::iter::once(encoder.finish()));
}
```

---

## State Caching Pattern

PixiJS aggressively caches GPU state to minimize redundant calls:

```typescript
// Before setting any state, check if it's already set
private _setVertexBuffer(index: number, buffer: Buffer) {
    if (this._boundVertexBuffer[index] === buffer) return;  // SKIP

    this._boundVertexBuffer[index] = buffer;
    this.renderPassEncoder.setVertexBuffer(
        index,
        this._renderer.buffer.updateBuffer(buffer)
    );
}
```

### Why This Matters

WebGPU/wgpu calls have overhead. While the GPU doesn't re-process identical state, the CPU still:
1. Validates parameters
2. Records commands to the command buffer
3. Manages internal tracking

By skipping redundant calls, PixiJS reduces:
- CPU overhead
- Command buffer size
- Validation work

### wgpu Implementation

```rust
struct StateCache {
    bound_pipeline: Option<wgpu::RenderPipeline>,
    bound_bind_groups: [Option<wgpu::BindGroup>; 4],
    bound_vertex_buffers: [Option<wgpu::Buffer>; 8],
    bound_index_buffer: Option<wgpu::Buffer>,
}

impl StateCache {
    fn set_pipeline(&mut self, pass: &mut wgpu::RenderPass, pipeline: &wgpu::RenderPipeline) {
        // Compare by pointer/id, not deep equality
        if self.bound_pipeline.as_ref().map(|p| p.global_id()) != Some(pipeline.global_id()) {
            pass.set_pipeline(pipeline);
            self.bound_pipeline = Some(pipeline.clone());
        }
    }

    fn clear(&mut self) {
        self.bound_pipeline = None;
        self.bound_bind_groups = Default::default();
        self.bound_vertex_buffers = Default::default();
        self.bound_index_buffer = None;
    }
}
```

---

## Instruction-Based Rendering

PixiJS doesn't render immediately. It builds an **InstructionSet** first:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Phase 1: Build Instructions                                         │
│                                                                      │
│  traverse(scene) ──► pipes.addRenderable() ──► instructionSet.add() │
│                                                                      │
│  Result: [Batch, Batch, Graphics, Batch, RenderGroup, ...]          │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Phase 2: Execute Instructions                                       │
│                                                                      │
│  for instruction in instructionSet:                                 │
│      adaptor = getAdaptor(instruction.renderPipeId)                 │
│      adaptor.execute(instruction)                                   │
│                                                                      │
│  Result: GPU commands recorded to renderPassEncoder                 │
└─────────────────────────────────────────────────────────────────────┘
```

### Benefits

1. **Sorting**: Instructions can be sorted by state to minimize changes
2. **Batching**: Multiple elements can be merged before execution
3. **Deferred Upload**: Geometry is uploaded once, after all batches are known
4. **Debugging**: Instruction list can be inspected before execution

### Instruction Types

```typescript
interface Instruction {
    renderPipeId: string;  // Which pipe handles this
    // ... instruction-specific data
}

// Batch instruction
class Batch implements Instruction {
    renderPipeId = 'batch';
    start: number;          // Index offset
    size: number;           // Index count
    textures: BatchTextureArray;
    blendMode: BLEND_MODES;
    topology: Topology;
    gpuBindGroup: GPUBindGroup;
}

// Graphics instruction (non-batchable)
class Graphics implements Instruction {
    renderPipeId = 'graphics';
    context: GraphicsContext;
    // ... graphics-specific data
}
```

---

## System Communication

Systems communicate through the renderer instance:

```typescript
class GpuEncoderSystem {
    constructor(renderer: WebGPURenderer) {
        this._renderer = renderer;
    }

    setGeometry(geometry: Geometry, program: GpuProgram) {
        // Access other systems through renderer
        const buffersToBind = this._renderer.pipeline.getBufferNamesToBind(...);

        for (const i in buffersToBind) {
            const buffer = geometry.attributes[buffersToBind[i]].buffer;
            const gpuBuffer = this._renderer.buffer.updateBuffer(buffer);
            this.renderPassEncoder.setVertexBuffer(i, gpuBuffer);
        }
    }
}
```

### System Dependency Graph

```
GpuEncoderSystem
    ├─► PipelineSystem (get pipeline)
    ├─► GpuBufferSystem (update buffers)
    ├─► BindGroupSystem (get bind groups)
    └─► GpuUboSystem (update uniforms)

PipelineSystem
    ├─► GpuShaderSystem (get shader modules)
    └─► GpuStateSystem (get state configuration)

BindGroupSystem
    ├─► GpuTextureSystem (get texture views)
    └─► GpuBufferSystem (get uniform buffers)
```

---

## Extension System

PixiJS uses an extension pattern for registering systems:

```typescript
extensions.handleByNamedList(ExtensionType.WebGPUSystem, systems);
extensions.handleByNamedList(ExtensionType.WebGPUPipes, renderPipes);
extensions.handleByNamedList(ExtensionType.WebGPUPipesAdaptor, renderPipeAdaptors);

extensions.add(...DefaultWebGPUSystems, ...DefaultWebGPUPipes, ...DefaultWebGPUAdapters);
```

This allows:
- Adding custom systems without modifying core code
- Removing unused systems for smaller bundles
- Plugin architecture for extensions

---

## Key Takeaways for wgpu

1. **System Composition**: Break renderer into focused systems (encoder, pipeline, buffer, texture, etc.)

2. **State Caching**: Track bound state to skip redundant GPU calls

3. **Instruction Pattern**: Build instruction list first, execute second - enables sorting and batching

4. **Adaptor Pattern**: Separate platform-agnostic logic (pipes) from platform-specific execution (adaptors)

5. **Lazy Updates**: Only upload/update GPU resources when actually needed (dirty flags)

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/WebGPURenderer.ts`
- `libraries/pixijs/src/rendering/renderers/gpu/GpuEncoderSystem.ts`
- `libraries/pixijs/src/rendering/renderers/shared/system/AbstractRenderer.ts`

---

*Next: [Batching Strategy](batching.md)*
