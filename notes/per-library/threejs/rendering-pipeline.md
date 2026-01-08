# Three.js WebGPU Rendering Pipeline

> Scene graph to GPU commands via the WebGPU backend

---

## Overview

Three.js uses a **retained-mode** rendering model where:
1. You build a scene graph of objects
2. Call `renderer.render(scene, camera)` each frame
3. The renderer handles all GPU operations

The WebGPU renderer shares most logic with WebGL via the `Renderer` base class, with backend-specific code isolated in `WebGPUBackend`.

---

## Render Call Flow

```
renderer.render(scene, camera)
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  1. PREPARATION PHASE                                                │
├─────────────────────────────────────────────────────────────────────┤
│  scene.updateMatrixWorld()     ─► Update all world matrices         │
│  camera.updateMatrixWorld()    ─► Camera transform + projection     │
│  frustum.setFromProjection()   ─► Build frustum for culling         │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  2. SCENE TRAVERSAL                                                  │
├─────────────────────────────────────────────────────────────────────┤
│  For each object in scene:                                          │
│    if (!frustum.containsPoint(object)) skip;   ─► Culling           │
│    renderList.push(object, geometry, material, depth)               │
│                                                                      │
│  Sort renderList:                                                    │
│    opaqueList: front-to-back (by depth)                             │
│    transparentList: back-to-front (by depth)                        │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  3. BEGIN RENDER                                                     │
├─────────────────────────────────────────────────────────────────────┤
│  backend.beginRender(renderContext)                                 │
│    ├─► commandEncoder = device.createCommandEncoder()               │
│    ├─► Build render pass descriptor (attachments, clear values)     │
│    └─► currentPass = encoder.beginRenderPass(descriptor)            │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  4. DRAW PHASE                                                       │
├─────────────────────────────────────────────────────────────────────┤
│  For each item in opaqueList + transparentList:                     │
│    │                                                                 │
│    ├─► renderObject = getRenderObject(item)                         │
│    │     └─► Bundles: object, material, geometry, camera, lights    │
│    │                                                                 │
│    ├─► pipeline = pipelines.getForRender(renderObject)              │
│    │     └─► Cache lookup or create new pipeline                    │
│    │                                                                 │
│    ├─► bindings.updateForRender(renderObject)                       │
│    │     └─► Update uniform buffers, bind textures                  │
│    │                                                                 │
│    └─► backend.draw(renderObject)                                   │
│          ├─► pass.setPipeline(pipeline)                             │
│          ├─► pass.setBindGroup(0, bindGroup)                        │
│          ├─► pass.setVertexBuffer(0, vertexBuffer)                  │
│          └─► pass.drawIndexed(indexCount, instanceCount)            │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  5. FINISH RENDER                                                    │
├─────────────────────────────────────────────────────────────────────┤
│  backend.finishRender(renderContext)                                │
│    ├─► currentPass.end()                                            │
│    └─► device.queue.submit([encoder.finish()])                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## RenderObject

The `RenderObject` bundles all state needed for a single draw call:

```javascript
class RenderObject {
    constructor(nodes, geometries, renderer, object, material, scene, camera, lightsNode, renderContext, clippingContext) {
        this.object = object;           // The 3D object (Mesh, Line, etc.)
        this.material = material;        // Material instance
        this.geometry = object.geometry; // BufferGeometry
        this.scene = scene;             // Scene reference
        this.camera = camera;           // Camera for this draw
        this.lightsNode = lightsNode;   // Lighting configuration
        this.context = renderContext;   // Render pass context
        this.clippingContext = clippingContext;

        // Cached state
        this.pipeline = null;           // RenderPipeline reference
        this.bindings = null;           // BindGroup array
        this.nodeBuilderState = null;   // Compiled shader state
    }

    // Generate unique cache key
    getCacheKey() {
        // Combines: material, geometry layout, render context, lights
        return this._cacheKey || this._generateCacheKey();
    }

    // Get compiled bindings (uniforms, textures, samplers)
    getBindings() {
        return this.bindings || this._createBindings();
    }
}
```

### Why RenderObject?

1. **Caching**: Pipeline lookup uses RenderObject as cache key
2. **State bundling**: All draw state in one place
3. **Reuse**: Same RenderObject used across frames if unchanged
4. **Invalidation**: Version tracking for automatic updates

---

## Render List Sorting

### Opaque Objects (Front-to-Back)

Sorted by depth from camera, closest first:

```javascript
function painterSortStable(a, b) {
    // Group by render order
    if (a.groupOrder !== b.groupOrder) return a.groupOrder - b.groupOrder;

    // Then by render order
    if (a.renderOrder !== b.renderOrder) return a.renderOrder - b.renderOrder;

    // Then by material (minimize state changes)
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;

    // Then by depth (front-to-back for early-Z)
    if (a.z !== b.z) return a.z - b.z;

    // Finally by object id for stability
    return a.id - b.id;
}
```

**Why front-to-back?** Early depth rejection—fragments behind already-drawn geometry are discarded before fragment shader runs.

### Transparent Objects (Back-to-Front)

Sorted by depth, furthest first:

```javascript
function reversePainterSortStable(a, b) {
    // ... same grouping as opaque ...

    // Then by depth (back-to-front for correct blending)
    if (a.z !== b.z) return b.z - a.z;

    return a.id - b.id;
}
```

**Why back-to-front?** Alpha blending requires drawing distant objects first so closer objects blend on top.

---

## RenderContext

Encapsulates render pass configuration:

```javascript
class RenderContext {
    constructor() {
        this.id = _id++;

        // Render target
        this.renderTarget = null;        // null = canvas
        this.textures = null;            // Color attachments
        this.depthTexture = null;        // Depth attachment

        // Clear configuration
        this.clearColor = true;
        this.clearDepth = true;
        this.clearStencil = true;
        this.clearColorValue = { r: 0, g: 0, b: 0, a: 1 };
        this.clearDepthValue = 1;
        this.clearStencilValue = 0;

        // Viewport/scissor
        this.viewport = false;
        this.viewportValue = { x: 0, y: 0, width: 0, height: 0, minDepth: 0, maxDepth: 1 };
        this.scissor = false;
        this.scissorValue = { x: 0, y: 0, width: 0, height: 0 };

        // Sampling
        this.depth = true;
        this.stencil = false;
    }

    getCacheKey() {
        // Generate key for render pass descriptor caching
        return `${this.depth}_${this.stencil}_${this.clearColor}_...`;
    }
}
```

---

## wgpu Implementation

```rust
/// Render loop equivalent
fn render(&mut self, scene: &Scene, camera: &Camera) {
    // 1. Update transforms
    scene.update_world_matrices();
    camera.update_matrices();

    // 2. Build render lists
    let frustum = Frustum::from_matrix(&camera.projection_view_matrix());
    let (opaque_list, transparent_list) = self.build_render_lists(scene, &frustum);

    // 3. Begin render
    let mut encoder = self.device.create_command_encoder(&Default::default());

    let render_pass_desc = wgpu::RenderPassDescriptor {
        label: Some("main_pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &self.surface_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &self.depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Clear(1.0),
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    };

    let mut render_pass = encoder.begin_render_pass(&render_pass_desc);

    // 4. Draw phase
    for item in opaque_list.iter().chain(transparent_list.iter()) {
        let render_object = self.get_render_object(item);
        let pipeline = self.pipelines.get_for_render(&render_object);
        let bind_groups = self.bindings.get_for_render(&render_object);

        render_pass.set_pipeline(pipeline);
        for (i, bind_group) in bind_groups.iter().enumerate() {
            render_pass.set_bind_group(i as u32, bind_group, &[]);
        }
        render_pass.set_vertex_buffer(0, render_object.vertex_buffer.slice(..));
        render_pass.set_index_buffer(
            render_object.index_buffer.slice(..),
            wgpu::IndexFormat::Uint32
        );
        render_pass.draw_indexed(0..render_object.index_count, 0, 0..1);
    }

    drop(render_pass);

    // 5. Submit
    self.queue.submit(std::iter::once(encoder.finish()));
}

/// RenderObject equivalent
struct RenderObject {
    object_id: u64,
    material_id: u64,
    geometry: Arc<Geometry>,
    pipeline: Option<Arc<wgpu::RenderPipeline>>,
    bind_groups: Vec<wgpu::BindGroup>,

    // Cached buffers
    vertex_buffer: wgpu::Buffer,
    index_buffer: wgpu::Buffer,
    index_count: u32,

    // Cache key for pipeline lookup
    cache_key: u64,
}

impl RenderObject {
    fn get_cache_key(&self) -> u64 {
        // Hash: material + geometry layout + render context
        let mut hasher = DefaultHasher::new();
        self.material_id.hash(&mut hasher);
        self.geometry.layout_key().hash(&mut hasher);
        // ... more state ...
        hasher.finish()
    }
}
```

---

## Render Bundles

WebGPU supports pre-recording draw commands as "render bundles" for replay:

```javascript
// Three.js render bundle support
class RenderBundles {
    get(renderContext, renderObjects) {
        const bundleEncoder = device.createRenderBundleEncoder({
            colorFormats: [renderContext.colorFormat],
            depthStencilFormat: renderContext.depthFormat,
            sampleCount: renderContext.sampleCount,
        });

        // Record draws into bundle
        for (const renderObject of renderObjects) {
            this.backend.drawBundle(bundleEncoder, renderObject);
        }

        return bundleEncoder.finish();
    }
}

// Later, in render pass:
renderPass.executeBundles([bundle]);
```

**Benefits**:
- Reduced CPU overhead for static scenes
- Commands validated once, replayed many times

---

## Key Insights

### 1. Scene Graph + Render Lists

Three.js separates scene structure from render order. The scene graph defines object hierarchy, while render lists define draw order.

### 2. RenderObject as Central Abstraction

All per-draw state flows through RenderObject, making caching and invalidation straightforward.

### 3. Context-Aware Rendering

Same object can produce different RenderObjects for different contexts (main pass vs shadow pass vs reflection).

### 4. Lazy Resource Creation

Pipelines, bind groups, and GPU resources are created on-demand and cached for reuse.

### 5. Backend Isolation

All WebGPU-specific code is in `WebGPUBackend`, making the core renderer backend-agnostic.

---

## Sources

- `libraries/threejs/src/renderers/common/Renderer.js`
- `libraries/threejs/src/renderers/common/RenderObject.js`
- `libraries/threejs/src/renderers/common/RenderList.js`
- `libraries/threejs/src/renderers/common/RenderContext.js`
- `libraries/threejs/src/renderers/webgpu/WebGPUBackend.js`

---

*Next: [WebGPU Backend](webgpu-backend.md)*
