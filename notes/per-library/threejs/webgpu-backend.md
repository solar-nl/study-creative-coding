# Three.js WebGPU Backend

> WebGPU-specific implementation details

---

## Overview

`WebGPUBackend` implements the abstract `Backend` interface for WebGPU. It handles:

- Device initialization and context configuration
- Render pass creation and management
- Pipeline creation via `WebGPUPipelineUtils`
- Bind group creation via `WebGPUBindingUtils`
- Buffer management via `WebGPUAttributeUtils`
- Texture management via `WebGPUTextureUtils`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        WebGPUBackend                                 │
├─────────────────────────────────────────────────────────────────────┤
│  device: GPUDevice                                                   │
│  context: GPUCanvasContext                                          │
│  defaultRenderPassDescriptor: Object                                │
├─────────────────────────────────────────────────────────────────────┤
│  Utils:                                                              │
│  ├── utils: WebGPUUtils (general helpers)                           │
│  ├── attributeUtils: WebGPUAttributeUtils (vertex buffers)          │
│  ├── bindingUtils: WebGPUBindingUtils (bind groups)                 │
│  ├── pipelineUtils: WebGPUPipelineUtils (pipelines)                 │
│  └── textureUtils: WebGPUTextureUtils (textures)                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Initialization

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

### Context Configuration

```javascript
get context() {
    let context = canvasData.context;

    if (context === undefined) {
        context = canvas.getContext('webgpu');

        context.configure({
            device: this.device,
            format: this.utils.getPreferredCanvasFormat(),
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
            alphaMode: parameters.alpha ? 'premultiplied' : 'opaque',
            toneMapping: { mode: 'standard' }
        });
    }

    return context;
}
```

---

## Render Pass Management

### Begin Render

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
```

### Finish Render

```javascript
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

## Draw Commands

### Standard Draw

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
        const indexFormat = index.array.BYTES_PER_ELEMENT === 2 ? GPUIndexFormat.Uint16 : GPUIndexFormat.Uint32;
        currentPass.setIndexBuffer(indexData.buffer, indexFormat);
    }

    // Get draw parameters
    const { vertexCount, instanceCount, firstVertex, firstInstance } = renderObject.getDrawParameters();

    if (hasIndex) {
        currentPass.drawIndexed(vertexCount, instanceCount, firstVertex, 0, firstInstance);
    } else {
        currentPass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
    }
}
```

### Indirect Draw

```javascript
drawIndirect(renderObject, info) {
    const { currentPass } = this.get(renderObject.context);

    // ... setup pipeline and bindings same as draw() ...

    // Use indirect buffer for draw parameters
    const indirectBuffer = this.get(renderObject.getIndirect()).buffer;

    if (hasIndex) {
        currentPass.drawIndexedIndirect(indirectBuffer, 0);
    } else {
        currentPass.drawIndirect(indirectBuffer, 0);
    }
}
```

---

## Compute Pipeline

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

## Pipeline State Caching

`WebGPUPipelineUtils` caches active pipelines to avoid redundant setPipeline calls:

```javascript
class WebGPUPipelineUtils {
    _activePipelines = new WeakMap();

    setPipeline(pass, pipeline) {
        const currentPipeline = this._activePipelines.get(pass);

        if (currentPipeline !== pipeline) {
            pass.setPipeline(pipeline);
            this._activePipelines.set(pass, pipeline);
        }
    }
}
```

---

## Render Pass Descriptor Caching

```javascript
_getRenderPassDescriptor(renderContext, colorAttachmentsConfig = {}) {
    const renderTarget = renderContext.renderTarget;
    const renderTargetData = this.get(renderTarget);

    // Check if cached descriptors need rebuild
    let descriptors = renderTargetData.descriptors;
    if (descriptors === undefined ||
        renderTargetData.width !== renderTarget.width ||
        renderTargetData.height !== renderTarget.height) {

        descriptors = {};
        renderTargetData.descriptors = descriptors;
    }

    // Cache key from render context
    const cacheKey = renderContext.getCacheKey();
    let descriptorBase = descriptors[cacheKey];

    if (descriptorBase === undefined) {
        // Build texture views for color attachments
        const textureViews = [];
        for (const texture of renderContext.textures) {
            const textureData = this.get(texture);
            const view = textureData.texture.createView({...});
            textureViews.push({ view, resolveTarget, depthSlice });
        }

        // Build depth attachment
        if (renderContext.depth) {
            const depthTextureData = this.get(renderContext.depthTexture);
            descriptorBase.depthStencilView = depthTextureData.texture.createView();
        }

        descriptors[cacheKey] = descriptorBase;
    }

    // Apply dynamic properties (load/store ops, clear values)
    return { colorAttachments: [...], depthStencilAttachment: {...} };
}
```

---

## wgpu Implementation

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
    active_pipelines: HashMap<u64, wgpu::RenderPipeline>,
}

impl PipelineUtils {
    fn set_pipeline(&mut self, pass: &mut wgpu::RenderPass, pipeline: &wgpu::RenderPipeline) {
        let pipeline_id = pipeline.global_id().inner();

        if self.active_pipelines.get(&pass_id) != Some(pipeline_id) {
            pass.set_pipeline(pipeline);
            self.active_pipelines.insert(pass_id, pipeline_id);
        }
    }
}
```

---

## Key Patterns

### 1. Utils Composition

Backend delegates to specialized utility classes rather than having monolithic code:
- `WebGPUPipelineUtils` - Pipeline creation and state tracking
- `WebGPUBindingUtils` - Bind group layouts and groups
- `WebGPUAttributeUtils` - Vertex buffer configuration
- `WebGPUTextureUtils` - Texture and sampler management

### 2. DataMap Caching

Uses `DataMap` (WeakMap wrapper) for GPU resource caching:
```javascript
const textureData = this.get(texture);  // Get cached GPU texture
textureData.texture = device.createTexture(...);  // Store GPU resource
```

### 3. Redundant State Tracking

Pipeline utils tracks active pipeline per pass to skip redundant setPipeline calls.

### 4. Descriptor Caching

Render pass descriptors are cached by render context cache key to avoid rebuilding texture views every frame.

### 5. Async Initialization

Device initialization is async, handled via `init()` returning a Promise.

---

## Sources

- `libraries/threejs/src/renderers/webgpu/WebGPUBackend.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUPipelineUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUBindingUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUAttributeUtils.js`

---

*Next: [Pipeline & Bindings](pipeline-bindings.md)*
