# PixiJS WebGPU Renderer Architecture

> How 12+ specialized systems collaborate to turn a scene graph into GPU commands

## Key Insight

> **Architecture's core idea:** A renderer is a composition of autonomous systems (encoder, pipeline, buffer, texture) that each own one responsibility, communicating through a shared renderer instance rather than being one monolithic class.

---

## The Problem: A Renderer Is Not One Thing

Rendering looks simple from the outside: take a scene, draw it. But inside, a modern WebGPU renderer juggles dozens of responsibilities simultaneously. It needs to compile shaders, manage textures, allocate buffers, cache pipelines, record commands, track state, batch sprites, handle different primitive types, manage render targets, and coordinate it all without redundant work.

The naive approach would be one massive `Renderer` class with methods for everything. That path leads to a 10,000-line file where every change risks breaking something unrelated. PixiJS takes a different approach: composition over complexity.

---

## The Mental Model: A Film Production Studio

Think of the PixiJS renderer as a film studio producing a movie (your frame). The studio does not have one person doing everything. Instead, it has specialized departments that coordinate:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    FILM STUDIO (WebGPURenderer)                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  DEPARTMENT HEADS (Systems)                                          │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │  Director   │ │ Cinemato-   │ │   Props     │ │  Wardrobe   │   │
│  │ (Encoder)   │ │ graphy      │ │ (Buffers)   │ │ (Textures)  │   │
│  │             │ │ (Pipeline)  │ │             │ │             │   │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │   Lighting  │ │   Script    │ │   Effects   │ │  Equipment  │   │
│  │  (State)    │ │ (Shaders)   │ │  (Bind      │ │  (Device)   │   │
│  │             │ │             │ │   Groups)   │ │             │   │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │
│                                                                      │
│  PRODUCTION ASSISTANTS (Pipes)                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Scene Breakdown → Shot Lists → Sequences → Final Cut        │    │
│  │  (Graphics Pipe)   (Batcher)   (Instructions) (Adaptors)     │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Each department is autonomous: the props department (GpuBufferSystem) does not need to know about wardrobe (GpuTextureSystem). But when the director (GpuEncoderSystem) calls "action," they all coordinate to produce a shot.

The key insight: no single system understands the whole picture. Each one handles a slice of responsibility, and the renderer orchestrates them through a shared interface.

---

## System Composition: The 12+ Specialists

PixiJS composes its renderer from specialized systems, each owning one responsibility:

```typescript
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

Why this granularity? Consider what happens when you need to optimize buffer uploads. In a monolithic renderer, you would be hunting through thousands of lines. With systems, you open `GpuBufferSystem.ts` and everything buffer-related is right there. Systems are independently testable, replaceable, and comprehensible.

### How Systems Map to [wgpu](https://github.com/gfx-rs/wgpu)

If you are building a [wgpu](https://github.com/gfx-rs/wgpu) renderer, here is how these responsibilities translate:

| PixiJS System | [wgpu](https://github.com/gfx-rs/wgpu) Equivalent | What It Manages |
|---------------|-----------------|-----------------|
| `GpuEncoderSystem` | `CommandEncoder`, `RenderPass` | Recording GPU commands |
| `GpuDeviceSystem` | `Device`, `Adapter` | GPU initialization |
| `GpuBufferSystem` | `Buffer` management | Vertex, index, uniform buffers |
| `GpuTextureSystem` | `Texture`, `TextureView` | Texture resources |
| `PipelineSystem` | `RenderPipeline` cache | State combinations |
| `BindGroupSystem` | `BindGroup`, `BindGroupLayout` | Resource binding |
| `GpuShaderSystem` | `ShaderModule` | WGSL compilation |
| `GpuStateSystem` | Pipeline descriptor fields | Blend, depth, stencil |

The boundaries are almost identical because they reflect natural divisions in the GPU API itself.

---

## The Two-Phase Render: Pipes and Adaptors

Systems handle resources. But how does a `Sprite` or `Graphics` object become GPU commands? PixiJS introduces a second layer: **pipes** and **adaptors**.

Think of it like a restaurant kitchen:

- **Pipe**: The recipe. Takes raw ingredients (scene objects), produces instructions (what to cook)
- **Adaptor**: The cook. Takes instructions, operates the equipment (GPU)

```
Scene Object ──► Pipe ──► Instruction ──► Adaptor ──► GPU Commands
                 │                         │
              Shared                  Platform-specific
              (Works for WebGL too)  (WebGPU only)
```

This separation means PixiJS shares batching logic between WebGL and WebGPU renderers. The `BatcherPipe` figures out which sprites can be combined. Whether that batch executes via WebGL draw calls or WebGPU command encoding is the adaptor's job.

```typescript
// Platform-agnostic pipes
const DefaultWebGPUPipes = [...SharedRenderPipes, GpuUniformBatchPipe];

// Platform-specific execution
const DefaultWebGPUAdapters = [GpuBatchAdaptor, GpuMeshAdapter, GpuGraphicsAdaptor];
```

---

## Instruction-Based Rendering: Build First, Execute Second

Here is where it gets interesting. PixiJS does not render immediately when you traverse the scene. Instead, it builds an **InstructionSet** first:

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

You might wonder: why not just render directly during traversal? The deferred approach unlocks several optimizations:

1. **Sorting**: Instructions can be reordered to minimize state changes
2. **Batching**: Multiple elements merge before execution
3. **Deferred Upload**: Geometry uploads once, after all batches are known
4. **Debugging**: The instruction list can be inspected before any GPU work

Each instruction knows which pipe handles it (simplified for illustration; see source for full interface):

```typescript
interface Instruction {
    renderPipeId: string;  // Which adaptor executes this
    // ... instruction-specific data
}

class Batch implements Instruction {
    renderPipeId = 'batch';
    start: number;           // Index offset
    size: number;            // Index count
    textures: BatchTextureArray;
    blendMode: BLEND_MODES;
    topology: Topology;
}
```

---

## The Render Loop: A Frame's Journey

Let us trace what happens when you call `renderer.render(scene)`:

```
render(scene)
    │
    ├─► prerender         Setup frame
    ├─► renderStart       Create CommandEncoder
    │
    ├─► render            Build InstructionSet
    │   │
    │   ├─► Traverse scene graph
    │   ├─► Pipes add renderables to batchers
    │   ├─► Batchers accumulate geometry
    │   └─► Break batches → Batch instructions
    │
    ├─► renderEnd         Execute instructions
    │   │
    │   ├─► For each Batch:
    │   │   ├─► setGeometry()
    │   │   ├─► setPipeline()
    │   │   ├─► setBindGroup()
    │   │   └─► drawIndexed()
    │   │
    │   └─► End render pass
    │
    └─► postrender        queue.submit()
```

In summary: (1) `prerender` initializes the frame, (2) `renderStart` creates the command encoder, (3) `render` traverses the scene and builds the instruction set via pipes and batchers, (4) `renderEnd` executes each instruction through its adaptor, recording draw calls, and (5) `postrender` submits the command buffer to the GPU queue.

The encoder system orchestrates this lifecycle:

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

// 3. Draw calls (with state caching - more on this below)
setPipeline(pipeline: GPURenderPipeline) {
    if (this._boundPipeline === pipeline) return;  // Skip if same
    this._boundPipeline = pipeline;
    this.renderPassEncoder.setPipeline(pipeline);
}

// 4. End frame - submit to queue
postrender() {
    this.finishRenderPass();
    this._gpu.device.queue.submit([this.commandEncoder.finish()]);
}
```

### The [wgpu](https://github.com/gfx-rs/wgpu) Equivalent

The same flow in Rust:

```rust
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

## State Caching: Skipping Redundant Work

Here is a pattern you will see throughout PixiJS: aggressive state caching. Before setting any GPU state, check if it is already set:

```typescript
private _setVertexBuffer(index: number, buffer: Buffer) {
    if (this._boundVertexBuffer[index] === buffer) return;  // SKIP

    this._boundVertexBuffer[index] = buffer;
    this.renderPassEncoder.setVertexBuffer(
        index,
        this._renderer.buffer.updateBuffer(buffer)
    );
}
```

You might wonder: does the GPU not already skip redundant state changes? Not exactly. While the GPU will not re-process identical state, the CPU still:

1. Validates parameters
2. Records commands to the command buffer
3. Manages internal tracking

By caching at the application level, PixiJS reduces CPU overhead, command buffer size, and validation work. With batched sprites, this compounds dramatically: 1000 sprites with the same texture need only 1 bind group call instead of 1000.

The [wgpu](https://github.com/gfx-rs/wgpu) implementation follows the same pattern:

```rust
struct StateCache {
    bound_pipeline: Option<wgpu::RenderPipeline>,
    bound_bind_groups: [Option<wgpu::BindGroup>; 4],
    bound_vertex_buffers: [Option<wgpu::Buffer>; 8],
    bound_index_buffer: Option<wgpu::Buffer>,
}

impl StateCache {
    fn set_pipeline(&mut self, pass: &mut wgpu::RenderPass, pipeline: &wgpu::RenderPipeline) {
        // Compare by ID, not deep equality
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

The cache clears at the start of each render pass because WebGPU passes do not inherit state from previous passes.

---

## System Communication: Reaching Across Departments

Systems need to talk to each other. How does the encoder system get a buffer from the buffer system? Through the renderer instance:

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

The dependency graph looks like this:

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

This is not ideal from a dependency-injection perspective, but it keeps the API ergonomic. Each system has a clear owner (the renderer) and can reach its collaborators through that owner.

---

## Extensibility: The Plugin Architecture

PixiJS uses an extension pattern for registering systems:

```typescript
extensions.handleByNamedList(ExtensionType.WebGPUSystem, systems);
extensions.handleByNamedList(ExtensionType.WebGPUPipes, renderPipes);
extensions.handleByNamedList(ExtensionType.WebGPUPipesAdaptor, renderPipeAdaptors);

extensions.add(...DefaultWebGPUSystems, ...DefaultWebGPUPipes, ...DefaultWebGPUAdapters);
```

This enables:

- **Custom systems**: Add your own without modifying core code
- **Tree shaking**: Remove unused systems for smaller bundles
- **Plugin architecture**: Third-party extensions can register cleanly

---

## Key Takeaways for [wgpu](https://github.com/gfx-rs/wgpu)

If you are building a Rust/[wgpu](https://github.com/gfx-rs/wgpu) renderer inspired by PixiJS, focus on these patterns:

1. **System Composition** - Break your renderer into focused systems (encoder, pipeline, buffer, texture, etc.). Each system owns one responsibility.

2. **State Caching** - Track bound state to skip redundant GPU calls. Compare by ID, not deep equality.

3. **Instruction Pattern** - Build an instruction list first, execute second. This enables sorting and batching optimizations.

4. **Adaptor Pattern** - Separate platform-agnostic logic (what to render) from platform-specific execution (how to render).

5. **Lazy Updates** - Only upload or update GPU resources when actually needed. Use dirty flags.

For deeper dives into specific systems, see:

- [Batching Strategy](./batching.md) - How sprites merge into single draw calls
- [Pipeline Caching](./pipeline-caching.md) - Two-tier caching for pipeline reuse
- [Encoder System](./encoder-system.md) - Command recording with state caching
- [Bind Groups](./bind-groups.md) - Resource binding and FNV-1a hashing

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/WebGPURenderer.ts`
- `libraries/pixijs/src/rendering/renderers/gpu/GpuEncoderSystem.ts`
- `libraries/pixijs/src/rendering/renderers/shared/system/AbstractRenderer.ts`

---

*Next: [Batching Strategy](./batching.md)*
