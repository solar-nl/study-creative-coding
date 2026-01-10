# [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) Pipeline & Bindings

> Why render the same pipeline twice when you could compile it once and remember?

## Key Insight

> **Pipeline Caching's core idea:** Generate a cache key from all render state (shaders, blending, depth settings), then reuse the same GPU pipeline for every draw call with matching state.

---

## The Problem: GPU Resource Creation Is Expensive

Every draw call in WebGPU needs two things: a **pipeline** that tells the GPU *how* to draw (shaders, blending, depth testing), and **bind groups** that tell it *what* to draw with (uniforms, textures, samplers). The problem? Creating these is expensive.

A render pipeline involves compiling shaders, validating state combinations, and allocating internal GPU structures. On some drivers, this can take milliseconds. When you are trying to render at 60fps, you have about 16 milliseconds *total*. Burning several of those on pipeline creation is catastrophic.

Bind groups are cheaper to create, but they are also immutable. Change a texture? You need a whole new bind group. Update a uniform value? That is fine, but swapping the underlying buffer means rebuilding.

The naive approach would be creating these resources fresh every draw call. Your frame rate would collapse. A slightly less naive approach would be creating them once per object. But what if two objects share the same material, geometry layout, and render state? You have created two identical pipelines.

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) solves this through two caching systems that work together: **Pipelines** for GPU pipeline state, and **Bindings** for resource groups. Understanding how they cooperate is key to understanding why the renderer can handle complex scenes at interactive frame rates.

---

## The Mental Model: A Restaurant Kitchen

Think of rendering like a busy restaurant kitchen:

**Pipelines are recipes.** When an order comes in for Chicken Parmesan, the chef does not invent the recipe on the spot. The recipe exists already, indexed by dish name. If ten tables order Chicken Parmesan, they all use the same recipe. The recipe describes *how* to cook: what pan to use, what temperature, what order of operations. In GPU terms: what shaders to run, what blending mode, what depth function.

**The cache key is the order.** "Chicken Parmesan, gluten-free pasta, extra crispy" uniquely identifies a recipe variant. Similarly, a pipeline cache key combines all the state that affects the GPU pipeline: shader IDs, transparency, blending mode, depth settings, geometry layout. Same key means same pipeline.

**Bind groups are ingredient trays.** For each dish being prepared, someone assembles a tray with all the ingredients: the chicken, the sauce, the cheese. The chef grabs the tray and starts cooking. In GPU terms, the bind group bundles all the resources for a draw call: uniform buffers with matrices, textures with image data, samplers with filtering settings.

**Uniform buffers are bowls on the tray.** The bowl itself (the buffer) stays on the tray, but you can update the contents (the data) without rebuilding the whole tray. That is why uniform updates are cheap but texture swaps require a new bind group.

The beauty of this system is that most work happens once. The first time you draw an object with a specific state combination, the kitchen creates the recipe and assembles the tray. On subsequent frames, everything is ready. The only per-frame work is updating bowl contents: new model matrices, new time uniforms.

---

## How Pipeline Caching Works

The pipeline cache has a simple structure: a map from cache keys to pipelines, plus three additional maps for shader programs (vertex, fragment, compute). The shader maps exist because different pipelines might share the same shaders.

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Pipelines                                   │
├─────────────────────────────────────────────────────────────────────┤
│  caches: Map<cacheKey, Pipeline>       → Pipeline cache             │
│                                                                      │
│  programs:                                                           │
│    vertex: Map<shader, ProgrammableStage>                           │
│    fragment: Map<shader, ProgrammableStage>                         │
│    compute: Map<shader, ProgrammableStage>                          │
└─────────────────────────────────────────────────────────────────────┘
```

When rendering an object, the system follows this sequence:

1. Generate shader code from the material's node graph
2. Look up or create the vertex program
3. Look up or create the fragment program
4. Generate a cache key from *all* render state
5. Look up or create the pipeline

The cache key combines everything that affects the GPU pipeline into a single string:

```javascript
_getRenderCacheKey(renderObject, stageVertex, stageFragment) {
    const { material, geometry } = renderObject;

    return [
        stageVertex.id,
        stageFragment.id,
        material.transparent,
        material.blending,
        material.side,
        material.depthWrite,
        material.depthTest,
        material.depthFunc,
        material.stencilWrite,
        material.stencilFunc,
        geometry.id,
        renderObject.context.getCacheKey(),
        renderObject.clippingContext?.cacheKey || ''
    ].join(',');
}
```

Notice what is in there: shader IDs (same shaders means potentially same pipeline), material properties that affect GPU state (blending, depth testing, stencil), geometry ID (different vertex layouts need different pipelines), and render context (different render targets might have different formats).

---

## Tracing a Pipeline Cache Lookup

Let us trace exactly what happens when you call `getForRender()` for a mesh with a standard material:

**Frame 1, first draw of this mesh:**

1. The system checks if this RenderObject needs a pipeline update (it does, there is none)
2. The node builder compiles the material into vertex and fragment WGSL
3. `this.programs.vertex.get(vertexShader)` returns `undefined` — never seen this shader
4. A new `ProgrammableStage` is created, `backend.createProgram()` compiles it
5. Same happens for the fragment shader
6. `_getRenderCacheKey()` generates something like `"12,45,false,1,0,true,true,3,false,0,77,ctx_0_d24s8,"`
7. `this.caches.get(cacheKey)` returns `undefined` — never seen this state combo
8. `_getRenderPipeline()` creates a new pipeline, stores it in the cache
9. Usage counts are incremented: `pipeline.usedTimes++`

**Frame 2 and beyond:**

1. The system checks if this RenderObject needs a pipeline update (it does not)
2. `data.pipeline` is returned immediately

**Frame N, you change the material's blending mode:**

1. The system checks if this RenderObject needs a pipeline update (it does, material version changed)
2. Previous pipeline's usage count is decremented
3. Shaders are the same, so programs are looked up successfully
4. But the cache key is different now (blending changed)
5. A new pipeline is created for the new state combination
6. The old pipeline remains in the cache in case something else still uses it

---

## How Bindings Work

While pipelines describe *how* to draw, bind groups describe *what resources* to use. The bindings system manages the lifecycle of these resources and their groupings.

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Bindings                                    │
├─────────────────────────────────────────────────────────────────────┤
│  getForRender(renderObject)    → Get/create bind groups             │
│  updateForRender(renderObject) → Update uniform data                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         BindGroup                                    │
├─────────────────────────────────────────────────────────────────────┤
│  bindings: [                                                         │
│    UniformBuffer { buffer, uniforms: [...] }                        │
│    SampledTexture { texture, style }                                │
│    Sampler { texture }                                              │
│    StorageBuffer { buffer, access }                                 │
│  ]                                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

The key insight is that bind groups are immutable in WebGPU. Once created, you cannot swap out a texture. This means the bindings system must detect when resources change and rebuild the bind group:

```javascript
_update(bindGroup, bindings) {
    let needsBindGroupRefresh = false;

    for (const binding of bindGroup.bindings) {
        if (binding.isUniformBuffer) {
            // Update uniform buffer data - cheap, just writes bytes
            const updated = binding.update();
            if (updated) {
                this.backend.updateBinding(binding);
            }
        } else if (binding.isSampledTexture) {
            // Check if texture changed - expensive if yes
            const textureData = this.backend.get(binding.texture);
            if (textureData.texture !== binding._texture) {
                needsBindGroupRefresh = true;
            }
        }
    }

    if (needsBindGroupRefresh) {
        // Recreate bind group with new resources
        this.backend.updateBindings(bindGroup, bindings, 0);
    }
}
```

This is why uniform updates (camera matrices every frame, time uniforms) are fast. The bind group stays the same. Only the buffer contents change. But swapping a texture triggers a full rebuild.

---

## Code Deep Dive: Pipeline Creation

Here is the full `getForRender` implementation:

```javascript
getForRender(renderObject, promises = null) {
    const data = this.get(renderObject);

    if (this._needsRenderUpdate(renderObject)) {
        const previousPipeline = data.pipeline;

        // Decrement usage counts
        if (previousPipeline) {
            previousPipeline.usedTimes--;
            previousPipeline.vertexProgram.usedTimes--;
            previousPipeline.fragmentProgram.usedTimes--;
        }

        // Get shader code from node builder
        const nodeBuilderState = renderObject.getNodeBuilderState();
        const name = renderObject.material?.name || '';

        // Get or create vertex program
        let stageVertex = this.programs.vertex.get(nodeBuilderState.vertexShader);
        if (stageVertex === undefined) {
            stageVertex = new ProgrammableStage(nodeBuilderState.vertexShader, 'vertex', name);
            this.programs.vertex.set(nodeBuilderState.vertexShader, stageVertex);
            this.backend.createProgram(stageVertex);
        }

        // Get or create fragment program
        let stageFragment = this.programs.fragment.get(nodeBuilderState.fragmentShader);
        if (stageFragment === undefined) {
            stageFragment = new ProgrammableStage(nodeBuilderState.fragmentShader, 'fragment', name);
            this.programs.fragment.set(nodeBuilderState.fragmentShader, stageFragment);
            this.backend.createProgram(stageFragment);
        }

        // Get or create pipeline
        const cacheKey = this._getRenderCacheKey(renderObject, stageVertex, stageFragment);
        let pipeline = this.caches.get(cacheKey);

        if (pipeline === undefined) {
            pipeline = this._getRenderPipeline(renderObject, stageVertex, stageFragment, cacheKey, promises);
        }

        // Track usage
        pipeline.usedTimes++;
        stageVertex.usedTimes++;
        stageFragment.usedTimes++;

        data.pipeline = pipeline;
    }

    return data.pipeline;
}
```

---

## Key Patterns

### String-Based Cache Keys

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) generates string cache keys by concatenating render state values:

```javascript
return [stageVertex.id, stageFragment.id, material.transparent, ...].join(',');
```

Simple and debuggable. The trade-off is performance — string operations are slower than numeric hashing. For most scenes this is fine.

### Reference Counting

Pipelines and programs track usage counts for potential cleanup:

```javascript
pipeline.usedTimes++;
if (pipeline.usedTimes === 0) this._releasePipeline(pipeline);
```

This prevents unbounded memory growth in scenes with dynamic content.

### Lazy Creation

Resources are created on first access, not upfront. This keeps startup fast and memory proportional to what you actually render.

### Async Pipeline Compilation

For `compileAsync()`, pipelines use `createRenderPipelineAsync()` to avoid blocking the main thread during loading.

---

## Edge Cases and Gotchas

### Pipeline Explosion

A scene with 50 materials and 3 render passes (main, shadow, reflection) could produce 150+ pipelines. Each unique combination needs its own pipeline.

**Mitigation:** Minimize material variations, share materials where possible, use instancing.

### Bind Group Immutability

When textures change (video frames, procedural generation), entire bind groups are recreated.

**Mitigation:** Structure bindings so frequently-changing resources are in separate bind groups from stable ones.

### Cache Key Collisions

String cache keys could theoretically collide. In practice, [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) uses unique IDs and explicit separators, making this extremely unlikely.

---

## [wgpu](https://github.com/gfx-rs/wgpu) Implementation

Here is how these concepts translate to Rust:

```rust
struct Pipelines {
    render_cache: HashMap<String, Arc<wgpu::RenderPipeline>>,
    compute_cache: HashMap<String, Arc<wgpu::ComputePipeline>>,

    vertex_programs: HashMap<String, wgpu::ShaderModule>,
    fragment_programs: HashMap<String, wgpu::ShaderModule>,
    compute_programs: HashMap<String, wgpu::ShaderModule>,
}

impl Pipelines {
    fn get_for_render(
        &mut self,
        device: &wgpu::Device,
        render_object: &RenderObject,
    ) -> Arc<wgpu::RenderPipeline> {
        let cache_key = Self::render_cache_key(render_object);

        self.render_cache.entry(cache_key).or_insert_with(|| {
            Arc::new(self.create_render_pipeline(device, render_object))
        }).clone()
    }

    fn render_cache_key(render_object: &RenderObject) -> String {
        format!(
            "{},{},{},{},{},{},{}",
            render_object.vertex_shader_id,
            render_object.fragment_shader_id,
            render_object.material.transparent,
            render_object.material.blend_mode as u32,
            render_object.material.cull_mode as u32,
            render_object.geometry.layout_key,
            render_object.context.cache_key()
        )
    }

    fn create_render_pipeline(
        &self,
        device: &wgpu::Device,
        render_object: &RenderObject,
    ) -> wgpu::RenderPipeline {
        let vertex_module = self.vertex_programs.get(&render_object.vertex_shader_id).unwrap();
        let fragment_module = self.fragment_programs.get(&render_object.fragment_shader_id).unwrap();

        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("render_pipeline"),
            layout: Some(&render_object.pipeline_layout),
            vertex: wgpu::VertexState {
                module: vertex_module,
                entry_point: Some("main"),
                buffers: &render_object.vertex_buffer_layouts,
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: fragment_module,
                entry_point: Some("main"),
                targets: &render_object.color_targets,
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: render_object.primitive_topology,
                cull_mode: render_object.material.cull_mode,
                front_face: wgpu::FrontFace::Ccw,
                ..Default::default()
            },
            depth_stencil: render_object.depth_stencil_state.clone(),
            multisample: wgpu::MultisampleState {
                count: render_object.context.sample_count,
                ..Default::default()
            },
            multiview: None,
            cache: None,
        })
    }
}

struct Bindings {
    bind_group_cache: HashMap<u64, wgpu::BindGroup>,
    layout_cache: HashMap<u64, wgpu::BindGroupLayout>,
}

impl Bindings {
    fn get_for_render(
        &mut self,
        device: &wgpu::Device,
        render_object: &RenderObject,
    ) -> Vec<&wgpu::BindGroup> {
        render_object.binding_groups.iter().map(|group| {
            let group_id = group.id();
            self.bind_group_cache.entry(group_id).or_insert_with(|| {
                self.create_bind_group(device, group)
            })
        }).collect()
    }

    fn update_for_render(&mut self, render_object: &mut RenderObject, queue: &wgpu::Queue) {
        for group in &mut render_object.binding_groups {
            for binding in &mut group.bindings {
                if let BindingType::UniformBuffer(ref mut buffer) = binding.binding_type {
                    if buffer.is_dirty() {
                        queue.write_buffer(&buffer.gpu_buffer, 0, buffer.data());
                        buffer.mark_clean();
                    }
                }
            }
        }
    }
}
```

### Key [wgpu](https://github.com/gfx-rs/wgpu) Differences

**Ownership model:** `Arc<RenderPipeline>` allows shared ownership across the cache and render objects.

**Hash maps:** Consider using `FxHashMap` for performance-critical paths.

**Layout caching:** You would likely want to cache bind group layouts separately and reuse them.

---

## Next Steps

- **[Node System (TSL)](node-system.md)** — How materials become the shaders that pipelines reference
- **[WebGPU Backend](webgpu-backend.md)** — How the backend issues draw commands using cached resources
- **[Rendering Pipeline](rendering-pipeline.md)** — Where pipeline and binding lookups fit in the render loop

---

## Sources

- `libraries/threejs/src/renderers/common/Pipelines.js`
- `libraries/threejs/src/renderers/common/Bindings.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUPipelineUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUBindingUtils.js`
