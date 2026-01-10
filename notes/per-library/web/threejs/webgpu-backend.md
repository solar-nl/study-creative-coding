# [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) WebGPU Backend

> The translator that speaks GPU fluently so you don't have to

## Key Insight

> **WebGPU Backend's core idea:** Translate high-level renderer intentions ("draw this mesh") into precise GPU commands (encoders, passes, bind groups) while hiding all the low-level machinery.

---

## The Problem: Two Languages That Don't Understand Each Other

Here is the challenge: [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) speaks in abstractions. "Draw this mesh with that material." "Clear the screen to black." "Update this texture." These are high-level commands that make sense to humans building 3D applications.

WebGPU speaks in something entirely different. It wants command encoders, render pass descriptors, bind groups, pipeline layouts, and buffer slices. It demands exact specifications for every attachment, every format, every load and store operation.

Without a translator, you would face a tedious, error-prone task every single frame: manually converting your scene description into dozens of low-level GPU commands. Every mesh would require you to set up vertex buffers, index buffers, bind groups, and pipelines by hand. Every texture change would force you to rebuild bind groups. Every render target switch would mean reconfiguring pass descriptors.

The `WebGPUBackend` exists to be that translator. It takes the renderer's high-level intentions and converts them into the precise dialect that WebGPU understands, while hiding the machinery involved.

---

## The Mental Model: An Embassy Between Two Nations

Think of `WebGPUBackend` as an embassy. On one side, you have [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) — a nation that speaks in objects, materials, and scenes. On the other side, you have WebGPU — a nation that speaks in buffers, passes, and command queues.

The embassy (backend) handles all diplomatic communication:

- When [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) says "initialize everything," the embassy negotiates with the GPU adapter, requests a device with the right features, and sets up the canvas context
- When [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) says "start drawing," the embassy prepares the command encoder and begins a render pass with properly configured attachments
- When [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) says "draw this object," the embassy sets the pipeline, binds resources, configures vertex buffers, and issues the actual draw command
- When [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) says "finish up," the embassy ends the pass, submits the command buffer, and handles any post-processing like mipmap generation

The embassy also maintains a staff of specialists — the utility classes — each expert in one area:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        WebGPUBackend (The Embassy)                   │
├─────────────────────────────────────────────────────────────────────┤
│  device: GPUDevice           (connection to the GPU nation)          │
│  context: GPUCanvasContext   (the display window)                    │
├─────────────────────────────────────────────────────────────────────┤
│  Specialists:                                                        │
│  ├── attributeUtils    (vertex buffer expert)                        │
│  ├── bindingUtils      (resource binding expert)                     │
│  ├── pipelineUtils     (render pipeline expert)                      │
│  └── textureUtils      (texture and sampler expert)                  │
└─────────────────────────────────────────────────────────────────────┘
```

This delegation pattern keeps the backend manageable. Instead of one massive class handling everything, each specialist focuses on its domain while the backend coordinates.

---

## How It Works: The Backend's Lifecycle

The backend's work happens in distinct phases. Understanding this flow is key to understanding the whole system.

### Phase 1: Initialization — Establishing the Connection

Before any rendering, the backend must establish communication with the GPU. This happens asynchronously because GPU hardware negotiation takes time:

1. **Request an adapter** — Ask the browser which GPU to use, with preferences like "give me the high-performance one" or "I need compatibility mode"
2. **Inventory capabilities** — Check which features the adapter supports. WebGPU has many optional features (like shader-f16 or texture-compression-bc), and we want all the ones available
3. **Request a device** — Get a logical device from the adapter with the features we need
4. **Handle device loss** — GPUs can disappear (driver crash, power management, display disconnect). The backend registers a handler so the application can respond gracefully

### Phase 2: Begin Render — Preparing the Stage

When the renderer calls `beginRender()`, the backend prepares everything for drawing:

1. **Choose the right descriptor** — Is this rendering to the canvas or to a render target? Each needs different attachments
2. **Configure clear operations** — Should we clear the color buffer? The depth buffer? What values?
3. **Create the command encoder** — This is our recording device for GPU commands
4. **Begin the render pass** — Start recording with all our configuration
5. **Set the viewport** — If specified, constrain where drawing happens

### Phase 3: Draw — The Main Event

For each object that needs drawing, the backend performs a precise sequence:

1. **Set the pipeline** — But only if it changed from the last draw
2. **Set bind groups** — Uniforms, textures, samplers go here
3. **Set vertex buffers** — Position, normal, UV data
4. **Set index buffer** — If the geometry is indexed
5. **Issue the draw command** — `drawIndexed()` or `draw()` with the right counts

### Phase 4: Finish Render — Submitting the Work

When all drawing is done:

1. **Execute render bundles** — If any pre-recorded command bundles exist, play them
2. **End the render pass** — Stop recording
3. **Submit to queue** — Send the finished command buffer to the GPU for execution
4. **Post-process** — Generate mipmaps for textures that need them

---

## Concrete Example: Tracing a Draw Call

Let us trace exactly what happens when `backend.draw()` is called for a mesh with a standard material. This is the critical path that runs thousands of times per frame in a complex scene.

**Setup:** We have a RenderObject containing a mesh, its material, geometry, camera, and lights. The render pass is already active.

**Step 1: Get the GPU pipeline**

The backend asks: "What pipeline does this render object need?" The pipelineUtils checks its cache using a key built from shader IDs, blend mode, depth settings, and other state. If cached, return immediately. If not cached, create a new pipeline (expensive!).

**Step 2: Set pipeline (with redundancy check)**

Before calling `pass.setPipeline()`, the backend checks: "Is this the same pipeline as the last draw call?" If yes, skip the call entirely. If no, call `setPipeline()` and remember this pipeline.

This optimization matters. In a scene with many objects sharing materials, consecutive draws often use the same pipeline. Skipping redundant state changes saves measurable time.

**Step 3: Bind resources**

For each bind group (typically 0-2), get the GPU bind group from the binding cache and call `pass.setBindGroup(index, bindGroup)`. Bind groups contain uniforms (transform matrices, material properties), textures, and samplers.

**Step 4: Set vertex buffers**

For each vertex attribute (position, normal, uv, etc.), get the GPU buffer from the attribute cache and call `pass.setVertexBuffer(slot, buffer)`.

**Step 5: Set index buffer (if indexed geometry)**

Get the GPU index buffer, determine format (Uint16 for small meshes, Uint32 for large), and call `pass.setIndexBuffer(buffer, format)`.

**Step 6: Issue the draw command**

If indexed: `pass.drawIndexed(indexCount, instanceCount, firstIndex, 0, firstInstance)`. Otherwise: `pass.draw(vertexCount, instanceCount, firstVertex, firstInstance)`.

And that is one draw call. Multiply by hundreds or thousands per frame, and you see why every optimization matters.

---

## Code Deep Dive: The Draw Method

Now that you understand what is happening conceptually, here is the actual implementation:

```javascript
draw(renderObject, info) {
    const { object, context, pipeline } = renderObject;
    const bindings = renderObject.getBindings();
    const renderContextData = this.get(context);
    const { currentPass, encoder } = renderContextData;

    const contextData = this.get(context);
    const pipelineGPU = this.get(pipeline).pipeline;

    // Set pipeline (with redundant call check)
    this.pipelineUtils.setPipeline(currentPass, pipelineGPU);

    // Set bind groups
    for (let i = 0, l = bindings.length; i < l; i++) {
        const bindGroup = bindings[i];
        const bindingsData = this.get(bindGroup);
        currentPass.setBindGroup(i, bindingsData.group);
    }

    // Set vertex buffers
    const vertexBuffers = renderObject.getVertexBuffers();
    for (let i = 0; i < vertexBuffers.length; i++) {
        const buffer = this.get(vertexBuffers[i]).buffer;
        currentPass.setVertexBuffer(i, buffer);
    }

    // Set index buffer and draw
    const index = renderObject.getIndex();
    const hasIndex = index !== null;

    if (hasIndex) {
        const indexData = this.get(index);
        const indexFormat = index.array.BYTES_PER_ELEMENT === 2
            ? GPUIndexFormat.Uint16
            : GPUIndexFormat.Uint32;
        currentPass.setIndexBuffer(indexData.buffer, indexFormat);
    }

    // Get draw parameters
    const { vertexCount, instanceCount, firstVertex, firstInstance } =
        renderObject.getDrawParameters();

    if (hasIndex) {
        currentPass.drawIndexed(vertexCount, instanceCount, firstVertex, 0, firstInstance);
    } else {
        currentPass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
    }
}
```

Notice the pattern: `this.get(something)` returns cached GPU resources. This is the `DataMap` pattern — a WeakMap wrapper that associates [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) objects with their GPU counterparts.

---

## Initialization Code

Here is how the backend establishes the GPU connection:

```javascript
async init(renderer) {
    await super.init(renderer);

    // Request adapter
    const adapterOptions = {
        powerPreference: parameters.powerPreference,
        featureLevel: parameters.compatibilityMode ? 'compatibility' : undefined
    };
    const adapter = await navigator.gpu.requestAdapter(adapterOptions);

    // Collect supported features
    const features = Object.values(GPUFeatureName);
    const supportedFeatures = features.filter(name => adapter.features.has(name));

    // Request device with all supported features
    const deviceDescriptor = {
        requiredFeatures: supportedFeatures,
        requiredLimits: parameters.requiredLimits
    };
    this.device = await adapter.requestDevice(deviceDescriptor);

    // Handle device loss
    this.device.lost.then((info) => {
        if (info.reason === 'destroyed') return;
        renderer.onDeviceLost({
            api: 'WebGPU',
            message: info.message || 'Unknown reason',
            reason: info.reason || null
        });
    });
}
```

---

## Render Pass Management

The backend carefully manages render passes to handle both canvas rendering and render-to-texture:

```javascript
beginRender(renderContext) {
    const device = this.device;

    // Build render pass descriptor
    let descriptor;
    if (renderContext.textures === null) {
        descriptor = this._getDefaultRenderPassDescriptor();
    } else {
        descriptor = this._getRenderPassDescriptor(renderContext, { loadOp: GPULoadOp.Load });
    }

    // Configure clear operations
    if (renderContext.clearColor) {
        descriptor.colorAttachments[0].clearValue = renderContext.clearColorValue;
        descriptor.colorAttachments[0].loadOp = GPULoadOp.Clear;
    }

    if (renderContext.clearDepth && descriptor.depthStencilAttachment) {
        descriptor.depthStencilAttachment.depthClearValue = renderContext.clearDepthValue;
        descriptor.depthStencilAttachment.depthLoadOp = GPULoadOp.Clear;
    }

    // Create command encoder and begin pass
    const encoder = device.createCommandEncoder();
    const currentPass = encoder.beginRenderPass(descriptor);

    // Set viewport if specified
    if (renderContext.viewport) {
        const { x, y, width, height, minDepth, maxDepth } = renderContext.viewportValue;
        currentPass.setViewport(x, y, width, height, minDepth, maxDepth);
    }

    // Store in render context data
    renderContextData.encoder = encoder;
    renderContextData.currentPass = currentPass;
}

finishRender(renderContext) {
    const renderContextData = this.get(renderContext);

    // Execute render bundles if any
    if (renderContextData.renderBundles.length > 0) {
        renderContextData.currentPass.executeBundles(renderContextData.renderBundles);
    }

    // End render pass
    renderContextData.currentPass.end();

    // Submit command buffer
    this.device.queue.submit([renderContextData.encoder.finish()]);

    // Generate mipmaps if needed
    if (renderContext.textures !== null) {
        for (const texture of renderContext.textures) {
            if (texture.generateMipmaps === true) {
                this.textureUtils.generateMipmaps(texture);
            }
        }
    }
}
```

---

## Compute Pipeline Support

The backend also handles compute workloads:

```javascript
beginCompute(computeGroup) {
    const encoder = this.device.createCommandEncoder();
    this.get(computeGroup).encoder = encoder;
}

compute(computeGroup, computeNode, bindings, pipeline) {
    const encoder = this.get(computeGroup).encoder;
    const computePass = encoder.beginComputePass();

    // Set pipeline
    const pipelineGPU = this.get(pipeline).pipeline;
    computePass.setPipeline(pipelineGPU);

    // Set bind groups
    for (let i = 0; i < bindings.length; i++) {
        const bindGroup = bindings[i];
        const bindingsData = this.get(bindGroup);
        computePass.setBindGroup(i, bindingsData.group);
    }

    // Dispatch workgroups
    const { workgroupCount } = computeNode;
    computePass.dispatchWorkgroups(workgroupCount.x, workgroupCount.y, workgroupCount.z);

    computePass.end();
}

finishCompute(computeGroup) {
    const encoder = this.get(computeGroup).encoder;
    this.device.queue.submit([encoder.finish()]);
}
```

---

## [wgpu](https://github.com/gfx-rs/wgpu) Implementation

Here is how these concepts translate to Rust and [wgpu](https://github.com/gfx-rs/wgpu):

```rust
struct WebGPUBackend {
    device: wgpu::Device,
    queue: wgpu::Queue,

    // Utils
    pipeline_utils: PipelineUtils,
    binding_utils: BindingUtils,
    attribute_utils: AttributeUtils,
    texture_utils: TextureUtils,

    // Per-context data
    context_data: HashMap<u64, RenderContextData>,
}

struct RenderContextData {
    encoder: Option<wgpu::CommandEncoder>,
    render_pass: Option<wgpu::RenderPass<'static>>,
    render_bundles: Vec<wgpu::RenderBundle>,
}

impl WebGPUBackend {
    fn begin_render(&mut self, context: &RenderContext) {
        let encoder = self.device.create_command_encoder(&Default::default());

        let descriptor = self.build_render_pass_descriptor(context);

        let context_data = self.context_data.entry(context.id).or_default();
        context_data.encoder = Some(encoder);

        // Note: Actual render pass created per-frame due to lifetime constraints
    }

    fn draw(&mut self, render_object: &RenderObject) {
        let context_data = self.context_data.get_mut(&render_object.context_id).unwrap();
        let pass = context_data.render_pass.as_mut().unwrap();

        // Set pipeline (cached)
        self.pipeline_utils.set_pipeline(pass, &render_object.pipeline);

        // Set bind groups
        for (i, bind_group) in render_object.bind_groups.iter().enumerate() {
            pass.set_bind_group(i as u32, bind_group, &[]);
        }

        // Set vertex buffers
        for (i, buffer) in render_object.vertex_buffers.iter().enumerate() {
            pass.set_vertex_buffer(i as u32, buffer.slice(..));
        }

        // Draw
        if let Some(index_buffer) = &render_object.index_buffer {
            pass.set_index_buffer(index_buffer.slice(..), render_object.index_format);
            pass.draw_indexed(
                0..render_object.index_count,
                0,
                0..render_object.instance_count
            );
        } else {
            pass.draw(
                0..render_object.vertex_count,
                0..render_object.instance_count
            );
        }
    }

    fn finish_render(&mut self, context: &RenderContext) {
        let context_data = self.context_data.get_mut(&context.id).unwrap();

        // Execute bundles
        if !context_data.render_bundles.is_empty() {
            let pass = context_data.render_pass.as_mut().unwrap();
            pass.execute_bundles(&context_data.render_bundles);
        }

        // End pass and submit
        context_data.render_pass = None;
        if let Some(encoder) = context_data.encoder.take() {
            self.queue.submit(std::iter::once(encoder.finish()));
        }
    }
}

struct PipelineUtils {
    active_pipelines: HashMap<u64, Arc<wgpu::RenderPipeline>>,
}

impl PipelineUtils {
    fn set_pipeline(&mut self, pass: &mut wgpu::RenderPass, pipeline: &wgpu::RenderPipeline) {
        // Track active pipeline to skip redundant calls
        pass.set_pipeline(pipeline);
    }
}
```

### [wgpu](https://github.com/gfx-rs/wgpu)-Specific Considerations

**Lifetime management** is the biggest difference. In JavaScript, the garbage collector handles cleanup. In Rust, you must explicitly manage when resources are dropped. The `RenderContextData` struct shows one approach: store the encoder and pass as `Option` types, taking ownership when needed.

**Render pass lifetimes** in [wgpu](https://github.com/gfx-rs/wgpu) are strict. You cannot hold a mutable reference to the render pass while also accessing the encoder. This forces different code structure than JavaScript.

---

## Edge Cases and Gotchas

### Device Loss

GPUs can be lost at any time — driver crashes, system sleep, display disconnection. Applications should handle this by either recreating resources or gracefully degrading.

### Context Configuration

The canvas context needs careful configuration. The `COPY_SRC` usage is easily forgotten but essential if you ever want to read pixels back.

### Feature Detection

Not all WebGPU features are available everywhere. The backend requests all supported features rather than assuming availability.

---

## Key Patterns

### 1. Utility Composition

The backend delegates to specialized classes rather than becoming monolithic.

### 2. DataMap Caching

WeakMap wrapper associates [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) objects with GPU resources. Automatic cleanup when source objects are collected.

### 3. Redundant State Tracking

Pipeline utils track active pipeline per render pass to skip redundant `setPipeline()` calls.

### 4. Async Initialization

Device initialization is asynchronous, handled via `init()` returning a Promise.

---

## Next Steps

- **[Pipeline & Bindings](pipeline-bindings.md)** — How pipelines are cached and bind groups managed
- **[Node System (TSL)](node-system.md)** — How materials compile to WGSL shaders

---

## Sources

- `libraries/threejs/src/renderers/webgpu/WebGPUBackend.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUPipelineUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUBindingUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUAttributeUtils.js`
