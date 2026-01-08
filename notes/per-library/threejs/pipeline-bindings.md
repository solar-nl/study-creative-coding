# Three.js Pipeline & Bindings

> Pipeline caching and bind group management

---

## Overview

Three.js uses two main systems for GPU resource management:

1. **Pipelines** - Caches render/compute pipelines by render state
2. **Bindings** - Manages bind groups and resource updates

---

## Pipeline Caching

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Pipelines                                   │
├─────────────────────────────────────────────────────────────────────┤
│  caches: Map<cacheKey, Pipeline>       ─► Pipeline cache            │
│                                                                      │
│  programs:                                                           │
│    vertex: Map<shader, ProgrammableStage>                           │
│    fragment: Map<shader, ProgrammableStage>                         │
│    compute: Map<shader, ProgrammableStage>                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Get Pipeline for Render

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

### Cache Key Generation

```javascript
_getRenderCacheKey(renderObject, stageVertex, stageFragment) {
    const { material, geometry } = renderObject;

    // Combine multiple state factors into cache key
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

### Pipeline Creation (WebGPU)

```javascript
// WebGPUPipelineUtils.createRenderPipeline
createRenderPipeline(renderObject, promises) {
    const { object, material, geometry, pipeline } = renderObject;
    const { vertexProgram, fragmentProgram } = pipeline;
    const device = this.backend.device;

    // Build bind group layouts from bindings
    const bindGroupLayouts = [];
    for (const bindGroup of renderObject.getBindings()) {
        const bindingsData = this.backend.get(bindGroup);
        bindGroupLayouts.push(bindingsData.layout.layoutGPU);
    }

    // Build vertex buffer layouts
    const vertexBuffers = this.backend.attributeUtils.createShaderVertexBuffers(renderObject);

    // Build color target state
    const targets = [];
    const colorFormat = this.backend.utils.getCurrentColorFormat(renderObject.context);
    const blending = this._getBlending(material);

    targets.push({
        format: colorFormat,
        blend: blending,
        writeMask: this._getColorWriteMask(material)
    });

    // Build depth/stencil state
    let depthStencil = undefined;
    if (renderObject.context.depth) {
        depthStencil = {
            format: this.backend.utils.getDepthStencilFormat(renderObject.context),
            depthWriteEnabled: material.depthWrite,
            depthCompare: this._getDepthCompare(material),
            stencilFront: this._getStencilState(material),
            stencilBack: this._getStencilState(material),
        };
    }

    // Create pipeline descriptor
    const descriptor = {
        label: `renderPipeline_${material.name || material.type}`,
        layout: device.createPipelineLayout({ bindGroupLayouts }),
        vertex: {
            module: this.backend.get(vertexProgram).module,
            entryPoint: 'main',
            buffers: vertexBuffers
        },
        fragment: {
            module: this.backend.get(fragmentProgram).module,
            entryPoint: 'main',
            targets
        },
        primitive: {
            topology: this._getPrimitiveTopology(object),
            cullMode: this._getCullMode(material),
            frontFace: 'ccw'
        },
        depthStencil,
        multisample: {
            count: this._getSampleCount(renderObject.context)
        }
    };

    // Create pipeline (async if promises provided)
    if (promises !== null) {
        promises.push(device.createRenderPipelineAsync(descriptor));
    } else {
        return device.createRenderPipeline(descriptor);
    }
}
```

---

## Bindings System

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Bindings                                    │
├─────────────────────────────────────────────────────────────────────┤
│  getForRender(renderObject)    ─► Get/create bind groups            │
│  updateForRender(renderObject) ─► Update uniform data               │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         BindGroup                                    │
├─────────────────────────────────────────────────────────────────────┤
│  bindings: [                                                         │
│    UniformBuffer { buffer, uniforms: [...] }                        │
│    SampledTexture { texture, style }                                │
│    Sampler { texture }                                               │
│    StorageBuffer { buffer, access }                                 │
│  ]                                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Get Bindings for Render

```javascript
getForRender(renderObject) {
    const bindings = renderObject.getBindings();

    for (const bindGroup of bindings) {
        const groupData = this.get(bindGroup);

        if (groupData.bindGroup === undefined) {
            // Initialize binding resources
            this._init(bindGroup);

            // Create GPU bind group
            this.backend.createBindings(bindGroup, bindings, 0);

            groupData.bindGroup = bindGroup;
        }
    }

    return bindings;
}
```

### Initialize Bindings

```javascript
_init(bindGroup) {
    for (const binding of bindGroup.bindings) {
        if (binding.isSampledTexture) {
            // Initialize texture
            this.textures.updateTexture(binding.texture);
        } else if (binding.isStorageBuffer) {
            // Initialize storage buffer
            const attribute = binding.attribute;
            this.attributes.update(attribute, AttributeType.STORAGE);
        }
    }
}
```

### Update Bindings

```javascript
updateForRender(renderObject) {
    this._updateBindings(this.getForRender(renderObject));
}

_updateBindings(bindings) {
    for (const bindGroup of bindings) {
        this._update(bindGroup, bindings);
    }
}

_update(bindGroup, bindings) {
    let needsBindGroupRefresh = false;

    for (const binding of bindGroup.bindings) {
        if (binding.isUniformBuffer) {
            // Update uniform buffer data
            const updated = binding.update();
            if (updated) {
                this.backend.updateBinding(binding);
            }
        } else if (binding.isSampledTexture) {
            // Update texture if changed
            const texture = binding.texture;
            if (texture.isVideoTexture) {
                this.textures.updateTexture(texture);
            }

            // Check if texture changed (requires bind group rebuild)
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

---

## WebGPU Bind Group Creation

```javascript
// WebGPUBindingUtils.createBindings
createBindings(bindGroup, bindings, index) {
    const device = this.backend.device;

    // Create bind group layout
    const entries = [];
    for (let i = 0; i < bindGroup.bindings.length; i++) {
        const binding = bindGroup.bindings[i];

        if (binding.isUniformBuffer || binding.isStorageBuffer) {
            entries.push({
                binding: i,
                visibility: binding.visibility,
                buffer: {
                    type: binding.isStorageBuffer ? 'storage' : 'uniform'
                }
            });
        } else if (binding.isSampledTexture) {
            entries.push({
                binding: i,
                visibility: binding.visibility,
                texture: {
                    sampleType: this._getSampleType(binding.texture),
                    viewDimension: this._getViewDimension(binding.texture)
                }
            });
        } else if (binding.isSampler) {
            entries.push({
                binding: i,
                visibility: binding.visibility,
                sampler: {
                    type: this._getSamplerType(binding.texture)
                }
            });
        }
    }

    const layout = device.createBindGroupLayout({ entries });

    // Create bind group
    const groupEntries = [];
    for (let i = 0; i < bindGroup.bindings.length; i++) {
        const binding = bindGroup.bindings[i];

        if (binding.isUniformBuffer) {
            groupEntries.push({
                binding: i,
                resource: { buffer: this.backend.get(binding).buffer }
            });
        } else if (binding.isSampledTexture) {
            groupEntries.push({
                binding: i,
                resource: this.backend.get(binding.texture).texture.createView()
            });
        } else if (binding.isSampler) {
            groupEntries.push({
                binding: i,
                resource: this.backend.get(binding.texture).sampler
            });
        }
    }

    const group = device.createBindGroup({ layout, entries: groupEntries });

    // Store in data map
    const bindingsData = this.backend.get(bindGroup);
    bindingsData.layout = { layoutGPU: layout };
    bindingsData.group = group;
}
```

---

## wgpu Implementation

```rust
/// Pipeline cache
struct Pipelines {
    render_cache: HashMap<String, Arc<wgpu::RenderPipeline>>,
    compute_cache: HashMap<String, Arc<wgpu::ComputePipeline>>,

    // Shader module cache
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

/// Bindings management
struct Bindings {
    bind_group_cache: HashMap<u64, wgpu::BindGroup>,
    layout_cache: HashMap<u64, wgpu::BindGroupLayout>,
}

impl Bindings {
    fn get_for_render(
        &mut self,
        device: &wgpu::Device,
        render_object: &RenderObject,
    ) -> Vec<wgpu::BindGroup> {
        render_object.binding_groups.iter().map(|group| {
            let group_id = group.id();

            self.bind_group_cache.entry(group_id).or_insert_with(|| {
                self.create_bind_group(device, group)
            }).clone()
        }).collect()
    }

    fn create_bind_group(
        &mut self,
        device: &wgpu::Device,
        group: &BindGroup,
    ) -> wgpu::BindGroup {
        // Create layout entries
        let layout_entries: Vec<_> = group.bindings.iter().enumerate()
            .map(|(i, binding)| {
                wgpu::BindGroupLayoutEntry {
                    binding: i as u32,
                    visibility: binding.visibility,
                    ty: binding.binding_type(),
                    count: None,
                }
            })
            .collect();

        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &layout_entries,
        });

        // Create bind group entries
        let entries: Vec<_> = group.bindings.iter().enumerate()
            .map(|(i, binding)| {
                wgpu::BindGroupEntry {
                    binding: i as u32,
                    resource: binding.as_binding_resource(),
                }
            })
            .collect();

        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &layout,
            entries: &entries,
        })
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

---

## Key Patterns

### 1. String-Based Cache Keys

Three.js generates string cache keys by concatenating render state values. This is simple but may have performance overhead compared to numeric keys.

### 2. Reference Counting

Pipelines and programs track usage counts for potential cleanup:
```javascript
pipeline.usedTimes++;
if (pipeline.usedTimes === 0) this._releasePipeline(pipeline);
```

### 3. Lazy Creation

Resources are created on first access, not upfront:
```javascript
if (groupData.bindGroup === undefined) {
    this.backend.createBindings(bindGroup, bindings, 0);
}
```

### 4. Bind Group Refresh

When textures change, entire bind groups are recreated (WebGPU bind groups are immutable):
```javascript
if (needsBindGroupRefresh) {
    this.backend.updateBindings(bindGroup, bindings, 0);
}
```

### 5. Async Pipeline Compilation

For `compileAsync()`, pipelines use `createRenderPipelineAsync()` to avoid blocking.

---

## Sources

- `libraries/threejs/src/renderers/common/Pipelines.js`
- `libraries/threejs/src/renderers/common/Bindings.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUPipelineUtils.js`
- `libraries/threejs/src/renderers/webgpu/utils/WebGPUBindingUtils.js`

---

*Next: [Node System (TSL)](node-system.md)*
