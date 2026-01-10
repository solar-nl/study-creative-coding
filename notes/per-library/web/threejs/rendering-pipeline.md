# [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) WebGPU Rendering Pipeline

> How a million-polygon scene becomes 60 draw calls per second

## Key Insight

> **Rendering Pipeline's core idea:** Separate what exists (scene graph), what to draw (sorted render lists), and how to draw it (cached RenderObjects)—so each layer can be optimized independently.

---

## The Problem: From Scene Graph to GPU Commands

Picture this: you have a complex 3D scene with hundreds of objects. Some are transparent, some are opaque. Some share the same material, some do not. Some are behind the camera and should not be drawn at all. How do you turn this tangled graph of objects into an efficient sequence of GPU draw commands?

This is the core challenge the rendering pipeline solves. You cannot just iterate through objects and draw them in any order. Transparent objects must be drawn back-to-front for correct blending. Opaque objects should be drawn front-to-back for early depth rejection. Objects that share the same material should be grouped to minimize expensive state changes. Objects outside the camera's view should be skipped entirely.

A naive approach would be recalculating everything every frame: walk the entire scene graph, check every object against the frustum, sort the survivors, create fresh GPU resources. This would crush your frame rate.

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) solves this through a layered system that separates concerns cleanly: the scene graph describes what exists, render lists describe what to draw and in what order, and RenderObjects bundle all the state needed for each draw call. Understanding these three layers is key to understanding the whole pipeline.

---

## The Mental Model: A Theater Production

Think of the rendering pipeline like staging a theater production:

**The Script (Scene Graph)** — Your scene graph is the script. It describes all the actors (objects), their positions, and their relationships. But the script alone does not tell you who should be on stage at any moment.

**The Blocking Notes (Render Lists)** — These are the director's notes that say "In this scene, Actor A enters first, then B, then C." The render lists take your scene graph and produce an ordered sequence: first all opaque objects (sorted front-to-back), then all transparent objects (sorted back-to-front).

**The Actor's Packet (RenderObject)** — Each actor gets a packet containing everything they need for their moment on stage: their costume (material), their props (geometry), their lighting cues (lights), and their marks (transforms). This is the RenderObject. It bundles all per-draw state in one place.

**The Stage Manager (Backend)** — Finally, the stage manager (WebGPU backend) translates those packets into actual stage actions: "Dim the lights, move the spotlight, cue the actor." These are the raw GPU commands.

The beauty of this separation is that each layer can be optimized independently. The scene graph can be modified between frames. The render lists are rebuilt quickly because they just reference existing objects. The RenderObjects cache expensive GPU resources and only update what changed. The backend issues minimal GPU commands by tracking redundant state.

---

## How It Works: From render() to GPU

Each frame flows through five phases:

```
renderer.render(scene, camera)
         │
         ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│   1. PREPARE     │───▶│   2. TRAVERSE    │───▶│   3. BEGIN       │
│  Update matrices │    │ Cull + sort into │    │ Create encoder + │
│  Build frustum   │    │   render lists   │    │   render pass    │
└──────────────────┘    └──────────────────┘    └──────────────────┘
                                                         │
         ┌───────────────────────────────────────────────┘
         ▼
┌──────────────────┐    ┌──────────────────┐
│     4. DRAW      │───▶│    5. FINISH     │
│ For each object: │    │  End pass +      │
│ pipeline→bind→   │    │  submit commands │
│ draw             │    │                  │
└──────────────────┘    └──────────────────┘
```

### Phase 1: Preparation

Before any rendering can happen, the pipeline needs to know where everything is. World matrices are updated by traversing the scene graph—each object's local transform combines with its parent's to produce world coordinates. The camera's matrices (view and projection) are computed. From these, a frustum is built—the camera's visible pyramid in world space.

### Phase 2: Scene Traversal and Sorting

Now comes the filtering. The pipeline walks every object in the scene and asks: "Is this object inside the camera's frustum?" Objects that fail this test are culled—they will not consume any GPU resources this frame.

Surviving objects are split into two lists: opaque and transparent. Why the separation? Because depth testing and alpha blending have opposite sorting requirements.

**Opaque objects are sorted front-to-back.** When you draw the closest object first, its depth values get written to the depth buffer. When you try to draw a farther object behind it, the GPU can reject those fragments early—before running the expensive fragment shader. This is called early-Z rejection, and it can save enormous amounts of work.

**Transparent objects are sorted back-to-front.** Alpha blending is an order-dependent operation: the color of a transparent object depends on what is already in the framebuffer behind it. If you draw a nearby glass pane before the distant landscape, the blending math comes out wrong.

Within each category, objects are further grouped by material to minimize state changes—switching pipelines is expensive.

### Phase 3: Begin Render Pass

The backend takes over. It creates a command encoder, which is essentially a buffer for recording GPU commands. It configures the render pass: which textures to draw into, whether to clear them, what the clear color should be. The render pass begins.

### Phase 4: Draw Phase

Now the pipeline iterates through both lists (opaque first, then transparent) and issues draw commands. For each item:

1. **Get or create a RenderObject** — This bundles the object, material, geometry, camera, and lights into one unit
2. **Get or create a pipeline** — The render pipeline is looked up by a cache key; if none exists, one is created
3. **Update bindings** — Uniform buffers are written with current transform matrices, material properties, and light data; textures are bound
4. **Issue draw command** — Set the pipeline, bind groups, vertex buffers, and call `drawIndexed()`

### Phase 5: Finish Render

The render pass is ended. The command encoder is finished, producing a command buffer. That buffer is submitted to the GPU queue for execution. The frame is done.

### Render Flow State Table

| Stage | Input | Transform | Output |
|-------|-------|-----------|--------|
| 1. Prepare | Scene graph + camera | Update world matrices, compute frustum | View/projection matrices, frustum planes |
| 2. Traverse | All scene objects | Frustum cull, split opaque/transparent, sort by depth + material | Sorted render lists (front-to-back opaque, back-to-front transparent) |
| 3. Begin | Render lists | Create command encoder, configure render pass | Active render pass with clear operations |
| 4. Draw | Sorted list items | Get/create RenderObject, bind pipeline + resources, issue draw calls | GPU commands recorded to encoder |
| 5. Finish | Completed encoder | End render pass, submit command buffer to queue | Frame submitted for GPU execution |

---

## Concrete Example: Drawing a Single Mesh

Let us trace exactly what happens when you render a single `Mesh` with a `MeshStandardMaterial`:

1. **Matrix update** — The mesh's world matrix is computed. If it is a child of another object, that parent's transform is incorporated.

2. **Frustum test** — The mesh's bounding sphere is tested against the frustum. Assuming it passes, the mesh is added to the opaque list (standard materials are opaque by default).

3. **RenderObject creation** — The pipeline asks: "Do I have a RenderObject for this mesh+material+camera+lights combination?" If not, one is created. The RenderObject stores:
   - Reference to the mesh
   - Reference to the material
   - Reference to the geometry
   - Camera matrices
   - Lighting configuration
   - Render context (target, clear settings)

4. **Shader compilation** — The node system (TSL) compiles the material's node graph into WGSL vertex and fragment shaders. These are cached by the shader code itself.

5. **Pipeline lookup** — A cache key is generated from: shader IDs, blend mode, depth settings, geometry layout, render context. If no pipeline exists for this key, one is created.

6. **Binding update** — The uniform buffer is updated with the mesh's model matrix, the camera's view-projection matrix, material properties (color, roughness, metalness), and light data.

7. **Draw** — `pass.setPipeline(pipeline)`, `pass.setBindGroup(0, bindGroup)`, `pass.setVertexBuffer(0, vertices)`, `pass.setIndexBuffer(indices)`, `pass.drawIndexed(indexCount)`.

The key insight: most of this work (RenderObject creation, shader compilation, pipeline creation) happens only once. On subsequent frames, everything is cached. Only the binding update—writing the current matrices to uniform buffers—happens every frame.

---

## Code Deep Dive: RenderObject

The `RenderObject` is the central abstraction that makes caching possible. Here is its structure:

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

### Why This Bundling Matters

The RenderObject pattern solves several problems at once:

**Caching** — The cache key combines all the factors that affect GPU pipeline state. Same material but different geometry layout? Different pipeline. Same everything but different render target format? Different pipeline. The key ensures you get the right cached pipeline.

**State locality** — Everything needed for a draw call is in one place. The backend does not need to reach into the scene graph or material system—all the answers are in the RenderObject.

**Frame-to-frame reuse** — If nothing about an object changes, its RenderObject persists across frames. The expensive work (shader compilation, pipeline creation) is amortized over many frames.

**Multi-context rendering** — The same mesh can produce different RenderObjects for different contexts. Rendering to the main canvas uses one RenderObject. Rendering to a shadow map uses another. Reflection probes use a third. The context-specific state stays isolated.

---

## Render List Sorting: The Details

The sorting logic is more nuanced than simple depth comparison. Here is the actual sorting function for opaque objects:

```javascript
function painterSortStable(a, b) {
    // Group by render order
    if (a.groupOrder !== b.groupOrder) return a.groupOrder - b.groupOrder;

    // Then by explicit render order
    if (a.renderOrder !== b.renderOrder) return a.renderOrder - b.renderOrder;

    // Then by material (minimize state changes)
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;

    // Then by depth (front-to-back for early-Z)
    if (a.z !== b.z) return a.z - b.z;

    // Finally by object id for stability
    return a.id - b.id;
}
```

Notice the priorities: explicit render order overrides everything, then material grouping (to reduce pipeline switches), and only then depth. The final object ID comparison ensures the sort is stable—objects at the same depth will not flicker between frames.

For transparent objects, the depth comparison is reversed:

```javascript
function reversePainterSortStable(a, b) {
    // ... same grouping as opaque ...

    // Then by depth (back-to-front for correct blending)
    if (a.z !== b.z) return b.z - a.z;

    return a.id - b.id;
}
```

---

## RenderContext: Configuring the Render Pass

The `RenderContext` encapsulates everything about where you are rendering and how to set it up:

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

This separation means the same renderer can handle wildly different targets—the main canvas, a shadow map, a post-processing ping-pong buffer—with the same code path.

---

## [wgpu](https://github.com/gfx-rs/wgpu) Implementation

Here is how these concepts translate to Rust and [wgpu](https://github.com/gfx-rs/wgpu):

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

The [wgpu](https://github.com/gfx-rs/wgpu) code follows the same phases: prepare matrices, build sorted lists, begin pass, draw loop, submit. The main differences are syntactic—Rust's ownership model means you manage encoder and pass lifetimes explicitly.

---

## Render Bundles: Pre-Recording for Static Scenes

WebGPU offers render bundles—a way to pre-record draw commands and replay them later:

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

The benefit? Reduced CPU overhead for static scenes. The draw commands are validated once when you create the bundle, then replayed many times without re-validation. This is particularly useful for backgrounds, static environment geometry, or UI elements that do not change frame-to-frame.

---

## Edge Cases and Gotchas

### Pipeline Explosion

WebGPU pipelines are immutable and encode most render state. A scene with 50 materials and 3 render passes (main, shadow, reflection) could produce 150+ pipelines. [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) mitigates this through aggressive caching via `RenderObject.getCacheKey()`, but complex scenes can still hit pipeline creation costs on first frame.

### The Transparency Sorting Problem

Sorting transparent objects back-to-front sounds simple, but it falls apart with intersecting geometry. If two transparent objects pass through each other, there is no correct draw order—some pixels of A are in front of B, and some pixels of B are in front of A.

The common workarounds are order-independent transparency (OIT) techniques, which [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) does not implement in its core pipeline. For most scenes, careful art direction (avoiding intersecting transparent objects) is the pragmatic solution.

### Bind Group Immutability

In WebGPU, bind groups are immutable. If a texture changes (like video frames or dynamically generated content), you must create a new bind group. [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) handles this automatically in `_update()` by detecting when a texture's underlying GPU texture has changed.

### Depth Buffer Precision

Front-to-back sorting for opaque objects improves performance but does not help with Z-fighting—the visual artifact when two surfaces are nearly coplanar. That is a depth buffer precision issue, addressed through careful near/far plane setup and sometimes logarithmic depth.

---

## [wgpu](https://github.com/gfx-rs/wgpu) Considerations

### Lifetime Management

The biggest difference when porting to [wgpu](https://github.com/gfx-rs/wgpu) is lifetime management. In JavaScript, the garbage collector handles cleanup. In Rust, you need to explicitly manage when resources are dropped.

RenderObjects and their cached GPU resources need careful thought: When can a pipeline be dropped? When is a RenderObject stale? [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) uses reference counting (`usedTimes`) and periodic cleanup passes. In Rust, you might use `Arc` for shared ownership or explicit invalidation signals.

### Command Encoder Scopes

[wgpu](https://github.com/gfx-rs/wgpu)'s command encoder and render pass have strict lifetime constraints. You cannot hold a mutable reference to the render pass while also accessing the encoder. [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) sidesteps this in JavaScript, but in Rust, you will often need to structure code around these borrowing rules.

### Pipeline Layout Explicit vs Automatic

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) derives bind group layouts from material bindings, then creates explicit pipeline layouts. In [wgpu](https://github.com/gfx-rs/wgpu), you can use auto-layout (`layout: None`) for simple cases, but explicit layouts give you control over bind group compatibility across pipelines.

---

## Key Insights

### 1. Scene Graph and Render Lists Are Separate Concerns

The scene graph describes hierarchy and spatial relationships. Render lists describe draw order and are rebuilt each frame. This separation means you can modify the scene graph freely without worrying about rendering—the render list building pass will sort it out.

### 2. RenderObject Is the Cache Key

All per-draw state flows through RenderObject. If you need to cache something related to drawing, associate it with a RenderObject. If you need to invalidate something, the RenderObject's version tracking handles it.

### 3. Lazy Resource Creation Scales

Pipelines, bind groups, and buffers are created on first use, not upfront. This means startup is fast (no precompilation of every possible state combination) and memory use is proportional to what you actually render.

### 4. Backend Isolation Enables Portability

All WebGPU-specific code is in `WebGPUBackend`. The core `Renderer` class does not know or care whether it is talking to WebGPU or WebGL. This pattern makes it relatively straightforward to add new backends or port to different platforms.

---

## Next Steps

- **[WebGPU Backend](webgpu-backend.md)** — Deep dive into `WebGPUBackend` and the util classes
- **[Pipeline & Bindings](pipeline-bindings.md)** — How pipelines are cached and bind groups managed
- **[Node System (TSL)](node-system.md)** — How materials compile to WGSL

---

## Sources

- `libraries/threejs/src/renderers/common/Renderer.js`
- `libraries/threejs/src/renderers/common/RenderObject.js`
- `libraries/threejs/src/renderers/common/RenderList.js`
- `libraries/threejs/src/renderers/common/RenderContext.js`
- `libraries/threejs/src/renderers/webgpu/WebGPUBackend.js`
