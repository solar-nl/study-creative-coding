# Babylon.js WebGPU Engine

> How Babylon.js wraps WebGPU's explicit API into a production-ready engine

---

## The Problem: Two GPUs, One API

Babylon.js was built on WebGL. Developers learned its patterns, wrote materials, built applications. Then WebGPU arrived — faster, more explicit, fundamentally different in how you talk to the GPU.

The challenge: how do you add WebGPU support without breaking everything? How do you let the same application run on both APIs? And how do you hide WebGPU's complexity while still benefiting from its performance?

Babylon's answer is the `WebGPUEngine` class — a drop-in replacement for the WebGL `Engine` that translates Babylon's API into WebGPU commands. Same application code, different GPU backend.

---

## The Mental Model: A Translator with a Cache

Think of WebGPUEngine as an interpreter at a diplomatic summit.

The Babylon.js API speaks one language: "Set this uniform. Bind this texture. Draw these triangles." It's immediate, stateful, like giving orders.

WebGPU speaks a different language: "Here's a command buffer. It contains render passes. Each pass uses pre-compiled pipelines and immutable bind groups." It's deferred, explicit, like writing detailed instructions.

The WebGPUEngine translates between them. And because WebGPU is picky about preparation (pipelines and bind groups are expensive to create), the translator maintains extensive caches. When Babylon says "draw with material X," the engine checks: "Do I have a pipeline for X cached? Do I have the bind groups ready?"

The cache makes all the difference. First frame is slow (building pipelines). Subsequent frames are fast (reusing everything).

---

## Engine Initialization

Before you can render anything, the WebGPU engine must acquire GPU access.

### Async Startup

Unlike WebGL (synchronous context creation), WebGPU requires async initialization:

```typescript
const engine = new WebGPUEngine(canvas);
await engine.initAsync();  // Required!

// Now you can create scenes and render
const scene = new Scene(engine);
```

### Inside initAsync()

The `initAsync()` method (line 649 in `webgpuEngine.ts`) performs several steps:

**1. Request Adapter:**

```typescript
// webgpuEngine.ts, line 655
const adapter = await navigator.gpu.requestAdapter(this._options);
```

The adapter represents a physical GPU. You can request specific features or power preferences.

**2. Query Features:**

```typescript
// webgpuEngine.ts, lines 663-666
for (const feature of adapter.features) {
    this._adapterSupportedExtensions.push(feature);
}
```

Babylon checks what the adapter supports: float textures, depth clamping, timestamp queries, etc.

**3. Request Device:**

```typescript
// webgpuEngine.ts, line 699
this._device = await adapter.requestDevice(deviceDescriptor);
```

The device is your interface to the GPU. All resources are created through it.

**4. Setup Error Handling:**

```typescript
// webgpuEngine.ts, lines 712-728
this._device.addEventListener("uncapturederror", (event) => {
    console.error("WebGPU uncaptured error:", event.error);
});
```

WebGPU errors are asynchronous. The engine sets up listeners to catch them.

**5. Create Command Encoders:**

```typescript
// webgpuEngine.ts, lines 784-785
this._uploadEncoder = this._device.createCommandEncoder(this._uploadEncoderDescriptor);
this._renderEncoder = this._device.createCommandEncoder(this._renderEncoderDescriptor);
```

Babylon uses two encoders: one for upload operations (texture/buffer data), one for render commands.

**6. Initialize Managers:**

```typescript
// webgpuEngine.ts, lines 786-809
this._bufferManager = new WebGPUBufferManager(this);
this._cacheSampler = new WebGPUCacheSampler(this);
this._cacheRenderPipeline = new WebGPUCacheRenderPipelineTree(this);
this._textureManager = new WebGPUTextureManager(this);
```

These managers handle resource lifecycle and caching.

---

## Command Encoding Model

WebGPU uses deferred command submission. You record commands into encoders, then submit them all at once.

### Two Encoders

Babylon separates upload and render commands:

```
┌─────────────────────────────────────────┐
│           Frame Timeline                 │
├─────────────────────────────────────────┤
│  Upload Encoder                          │
│  ├── copyBufferToBuffer (dynamic data)  │
│  ├── copyBufferToTexture (texture data) │
│  └── ... upload operations              │
├─────────────────────────────────────────┤
│  Render Encoder                          │
│  ├── beginRenderPass (main view)        │
│  │   ├── setPipeline                    │
│  │   ├── setBindGroup                   │
│  │   └── draw / drawIndexed             │
│  └── endRenderPass                      │
└─────────────────────────────────────────┘
                    │
                    ▼
        device.queue.submit([uploadBuffer, renderBuffer])
```

Why separate them? Uploads must complete before rendering can use the data. By separating, Babylon ensures correct ordering.

### Frame Submission

At the end of each frame, `flushFramebuffer()` (line 3090) submits everything:

```typescript
public flushFramebuffer(): void {
    this._endCurrentRenderPass();

    // Finish both encoders into command buffers
    this._commandBuffers[0] = this._uploadEncoder.finish();
    this._commandBuffers[1] = this._renderEncoder.finish();

    // Submit to GPU
    this._device.queue.submit(this._commandBuffers);

    // Create fresh encoders for next frame
    this._uploadEncoder = this._device.createCommandEncoder(this._uploadEncoderDescriptor);
    this._renderEncoder = this._device.createCommandEncoder(this._renderEncoderDescriptor);
}
```

---

## Render Pass Management

WebGPU requires explicit render passes. You can't just issue draw calls — they must happen inside a pass.

### Pass Wrappers

Babylon tracks render pass state with wrapper objects:

```typescript
// webgpuEngine.ts, lines 329-343
private _mainRenderPassWrapper: IWebGPURenderPassWrapper = {
    renderPassDescriptor: null,
    colorAttachmentViewDescriptor: null,
    depthAttachmentViewDescriptor: null,
    colorAttachmentGPUTextures: [],
    depthTextureFormat: undefined,
};

private _rttRenderPassWrapper: IWebGPURenderPassWrapper = {
    // Same structure for render-to-texture
};
```

### Starting the Main Pass

When rendering to the canvas, `_startMainRenderPass()` (line 3312) initializes the pass:

```typescript
private _startMainRenderPass(): void {
    // Update clear values
    this._mainRenderPassWrapper.renderPassDescriptor.colorAttachments[0].clearValue = {
        r: this._clearColor.r,
        g: this._clearColor.g,
        b: this._clearColor.b,
        a: this._clearColor.a
    };

    // Get swap chain texture
    const swapChainTexture = this._context.getCurrentTexture();
    this._mainRenderPassWrapper.colorAttachmentGPUTextures[0] = swapChainTexture;

    // Handle MSAA resolve
    if (this._options.antialias) {
        colorAttachment.resolveTarget = swapChainTexture.createView();
    }

    // Begin the pass
    this._currentRenderPass = this._renderEncoder.beginRenderPass(
        this._mainRenderPassWrapper.renderPassDescriptor
    );
}
```

### Render Target Passes

For shadow maps, reflections, or post-processing, `_startRenderTargetRenderPass()` (line 3119) handles:

- Multi-render-target (MRT) configurations
- MSAA with automatic resolve
- 3D texture slices via `depthSlice`
- Separate depth/stencil formats

### Lazy Pass Creation

Babylon creates passes on-demand:

```typescript
// webgpuEngine.ts, line 1268-1277
public _getCurrentRenderPass(): GPURenderPassEncoder {
    if (!this._currentRenderPass) {
        if (this._currentRenderTarget) {
            this._startRenderTargetRenderPass();
        } else {
            this._startMainRenderPass();
        }
    }
    return this._currentRenderPass;
}
```

This lets Babylon's stateful API (set render target, then draw) work with WebGPU's pass-based model.

---

## Pipeline Caching

Creating render pipelines is expensive. They involve shader compilation and GPU state validation. Babylon caches them aggressively.

### The Pipeline Cache

The `WebGPUCacheRenderPipeline` class (in `webgpuCacheRenderPipeline.ts`) manages the cache.

**State Positions:**

```typescript
// webgpuCacheRenderPipeline.ts, lines 18-36
enum StatePosition {
    StencilReadMask = 0,
    StencilWriteMask = 1,
    DepthBias = 2,
    DepthBiasSlope = 3,
    DepthStencilState = 4,
    // ... 14+ categories
    RasterizationState = 6,
    ColorStates = 7,
    ShaderStage = 11,
    VertexState = 13,
}
```

Each state category contributes to a cache key. Same material with different blend modes = different pipeline.

### Pipeline Retrieval

When drawing, `getRenderPipeline()` (line 197) checks the cache:

```typescript
public getRenderPipeline(fillMode: number, effect: Effect,
                        sampleCount: number, textureState: number): GPURenderPipeline {
    // Fast path: nothing changed since last draw
    if (!this._isDirty) {
        NumCacheHitWithoutHash++;
        return this._currentRenderPipeline;
    }

    // Hash-based lookup in tree cache
    const pipeline = this._pipelineCache.get(this._getRenderPipelineKey());
    if (pipeline) {
        NumCacheHitWithHash++;
        return pipeline;
    }

    // Cache miss: create new pipeline
    NumCacheMiss++;
    return this._createRenderPipeline();
}
```

The cache uses a tree structure where each branch represents a state category. This enables efficient lookup without hashing all state into one key.

### Cache Statistics

Babylon tracks cache performance:

- `NumCacheHitWithoutHash` — Same pipeline as last draw (fastest)
- `NumCacheHitWithHash` — Found in cache tree
- `NumCacheMiss` — Had to create a new pipeline

Monitor these to identify state thrashing.

---

## Bind Group Caching

Bind groups bundle resources (uniforms, textures) for shaders. Like pipelines, they're cached.

### The Bind Group Cache

`WebGPUCacheBindGroups` (in `webgpuCacheBindGroups.ts`) uses a similar tree structure:

```typescript
// webgpuCacheBindGroups.ts, line 98-243
public getBindGroups(drawContext, materialContext, effect) {
    // Quick path: context is clean
    if (!drawContext.isDirty(materialContext.updateId)) {
        return drawContext.bindGroups;
    }

    // Tree navigation by resource IDs
    node = this._cache;
    for (const buffer of buffers) {
        node = node.values[buffer.uniqueId + BufferIdStart];
    }
    for (const sampler of samplers) {
        node = node.values[sampler.hashCode];
    }
    for (const texture of textures) {
        node = node.values[texture.uniqueId + TextureIdStart];
    }

    // Found or create bind groups
    if (node.bindGroups) {
        return node.bindGroups;
    }
    return this._createBindGroups(node, drawContext, materialContext);
}
```

### Resource ID Offsets

To prevent collisions in the tree:

```typescript
const BufferIdStart = 2^20;   // line 16
const TextureIdStart = 2^35;  // line 24
```

Buffer ID 5 becomes key 1,048,581. Texture ID 5 becomes key 34,359,738,373. No overlaps.

---

## Material and Draw Contexts

Babylon tracks per-material and per-draw state with context objects.

### Material Context

`WebGPUMaterialContext` (in `webgpuMaterialContext.ts`) tracks resources for a material:

```typescript
class WebGPUMaterialContext {
    samplers: Map<string, { sampler: GPUSampler; hashCode: number }>;
    textures: Map<string, { texture: GPUTexture; ... }>;
    textureState: number;  // Bitfield for float/depth textures
    updateId: number;      // Incremented on changes
}
```

The `textureState` bitfield matters because float and depth textures require different sampler filtering. The bind group layout depends on this.

### Draw Context

`WebGPUDrawContext` (in `webgpuDrawContext.ts`) tracks per-draw state:

```typescript
class WebGPUDrawContext {
    bindGroups: GPUBindGroup[];      // Cached for this draw
    fastBundle: GPURenderBundle;     // Pre-recorded commands
    indirectDrawBuffer: GPUBuffer;   // For indirect drawing
    buffers: Map<string, GPUBuffer>; // Uniform buffers
}
```

The `fastBundle` enables render bundle optimization — pre-recording draw commands for static objects.

### Dirty Checking

Both contexts track whether their cached data is valid:

```typescript
// webgpuDrawContext.ts, lines 56-67
public isDirty(materialContextUpdateId: number): boolean {
    return this._isDirty || this._materialContextUpdateId !== materialContextUpdateId;
}
```

When a texture changes, the material context's `updateId` increments. All draw contexts using that material must rebuild their bind groups.

---

## Buffer Management

`WebGPUBufferManager` (in `webgpuBufferManager.ts`) handles buffer creation and updates.

### Creating Buffers

```typescript
// webgpuBufferManager.ts, line 42-52
public createRawBuffer(size: number, usage: GPUBufferUsageFlags,
                       mapped = false, label?: string): GPUBuffer {
    // Ensure 4-byte alignment
    size = (size + 3) & ~3;

    return this._device.createBuffer({
        size,
        usage,
        mappedAtCreation: mapped,
        label
    });
}
```

Note the alignment: WebGPU requires buffer sizes to be multiples of 4 bytes.

### Updating Data

For uniform buffers, data is written directly:

```typescript
// webgpuBufferManager.ts, line 72-76
public setRawData(buffer: GPUBuffer, data: ArrayBufferView,
                  dstOffset = 0, srcOffset = 0, byteLength?: number): void {
    this._device.queue.writeBuffer(buffer, dstOffset,
                                   data.buffer, data.byteOffset + srcOffset, byteLength);
}
```

This is faster than mapping/unmapping for small, frequent updates.

---

## Shader Processing

WebGPU uses WGSL (WebGPU Shading Language), not GLSL. Babylon handles this.

### GLSL to WGSL

Materials written in GLSL are transpiled:

```
GLSL Source → ShaderProcessor → WGSL Output
```

The `WebGPUShaderProcessor` (in `webgpuShaderProcessor.ts`) handles:

- Type mapping (vec4 → vec4<f32>)
- Uniform buffer layout
- Sampler/texture descriptors
- Entry point generation

### Native WGSL

Node Materials can compile directly to WGSL, skipping transpilation:

```typescript
// nodeMaterial.shaderLanguage === ShaderLanguage.WGSL
```

The Node Material build state generates WGSL-specific syntax:

```typescript
// nodeMaterialBuildState.ts, line 165
`@fragment fn main(input: FragmentInputs) -> FragmentOutputs`
```

---

## WebGL/WebGPU Differences

The WebGPUEngine must bridge fundamental API differences:

| WebGL Pattern | WebGPU Pattern |
|---------------|----------------|
| Immediate draw calls | Command buffers submitted at end |
| Global state machine | Explicit pipeline objects |
| Mutable resources | Immutable bind groups |
| Synchronous context | Async device acquisition |
| Auto clear in pass | Clear values in pass descriptor |
| GLSL shaders | WGSL shaders (or transpiled) |
| gl.uniform*() | Bind group entries |
| gl.bindTexture() | Bind group entries |
| gl.bindVertexArray() | Pipeline vertex state |

Babylon abstracts these differences so application code works on both backends.

---

## Performance Considerations

### Pipeline State

Minimize pipeline switches by sorting draw calls:

```
Good: [A, A, A, B, B, B, C, C]  // 3 pipeline changes
Bad:  [A, B, C, A, B, C, A, B]  // 7 pipeline changes
```

### Bind Group Reuse

Share bind groups when possible:

- View/projection matrices → one bind group per camera
- Material parameters → one bind group per material
- Model matrix → one bind group per object (or use instancing)

### Command Encoding

Prefer indirect draws and render bundles for static content:

```typescript
// Record once, replay many times
const bundle = device.createRenderBundle(descriptor);
bundle.setPipeline(pipeline);
bundle.setBindGroup(0, bindGroup);
bundle.draw(vertexCount, instanceCount);

// In render pass
renderPass.executeBundles([bundle]);
```

---

## [wgpu](https://github.com/gfx-rs/wgpu) Mapping

Babylon's WebGPU implementation maps directly to [wgpu](https://github.com/gfx-rs/wgpu):

| Babylon WebGPU | [wgpu](https://github.com/gfx-rs/wgpu) Equivalent |
|----------------|-----------------|
| WebGPUEngine | Device + Queue wrapper |
| _renderEncoder | CommandEncoder |
| _currentRenderPass | RenderPass |
| WebGPUCacheRenderPipeline | Pipeline cache (your implementation) |
| WebGPUCacheBindGroups | Bind group cache (your implementation) |
| WebGPUMaterialContext | Material state tracking |
| WebGPUDrawContext | Per-draw state |
| WebGPUBufferManager | Buffer utilities |

A [wgpu](https://github.com/gfx-rs/wgpu) implementation would have similar structures:

```rust
struct WgpuEngine {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline_cache: PipelineCache,
    bind_group_cache: BindGroupCache,
}

impl WgpuEngine {
    fn flush_frame(&mut self) {
        let command_buffer = self.encoder.take().unwrap().finish();
        self.queue.submit(std::iter::once(command_buffer));
    }
}
```

---

## Key Source Files

| Purpose | File | Key Lines |
|---------|------|-----------|
| Main engine | `Engines/webgpuEngine.ts` | Class at 213, initAsync at 649 |
| Thin base | `Engines/thinWebGPUEngine.ts` | Line 20 |
| Pipeline cache | `WebGPU/webgpuCacheRenderPipeline.ts` | Class at 82 |
| Bind group cache | `WebGPU/webgpuCacheBindGroups.ts` | Class at 36 |
| Material context | `WebGPU/webgpuMaterialContext.ts` | Class at 25 |
| Draw context | `WebGPU/webgpuDrawContext.ts` | Class at 14 |
| Buffer manager | `WebGPU/webgpuBufferManager.ts` | Class at 13 |
| Shader processor | `WebGPU/webgpuShaderProcessor.ts` | Line 10 |
| Pipeline context | `WebGPU/webgpuPipelineContext.ts` | Class at 20 |

All paths relative to: `packages/dev/core/src/`

---

## Next Steps

With WebGPU internals understood:

- **[Node Materials](node-materials.md)** — How shaders are compiled for WebGPU
- **[API Design](api-design.md)** — How Babylon's TypeScript API enables backend abstraction
