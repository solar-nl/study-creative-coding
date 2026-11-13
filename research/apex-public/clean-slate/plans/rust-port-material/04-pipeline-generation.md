# Pipeline Generation

This document describes how material parameters translate to wgpu render pipelines.

## Pipeline Cache Strategy

Materials with identical pipeline state share the same `RenderPipeline`:

```
Material Instance A (z_mode=ReadWrite, blend=Opaque, cull=Back)
          │
          ├─→ PipelineKey { z_mode: ReadWrite, blend: Opaque, cull: Back }
          │            │
          │            ▼
          │    Pipeline Cache
          │       get_or_create(key)
          │            │
          │            ▼
          └─────→ Pipeline #1 ←─────┐
                                    │
Material Instance B (same state) ───┘

Material Instance C (blend=Additive) → PipelineKey { blend: Additive, ... }
          │
          └─────→ Pipeline #2 (different)
```

## Pipeline Cache Implementation

```rust
use std::collections::HashMap;

pub struct PipelineCache {
    device: Arc<wgpu::Device>,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,

    // Shared layouts
    pipeline_layout: wgpu::PipelineLayout,

    // Shader modules
    shaders: HashMap<u64, wgpu::ShaderModule>,
}

impl PipelineCache {
    pub fn new(
        device: Arc<wgpu::Device>,
        scene_layout: &wgpu::BindGroupLayout,
        object_layout: &wgpu::BindGroupLayout,
        material_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Material Pipeline Layout"),
            bind_group_layouts: &[
                scene_layout,    // @group(0)
                object_layout,   // @group(1)
                material_layout, // @group(2)
            ],
            push_constant_ranges: &[],
        });

        Self {
            device,
            cache: HashMap::new(),
            pipeline_layout,
            shaders: HashMap::new(),
        }
    }

    /// Get or create a pipeline for the given key.
    pub fn get_or_create(&mut self, key: &PipelineKey) -> &wgpu::RenderPipeline {
        if !self.cache.contains_key(key) {
            let pipeline = self.create_pipeline(key);
            self.cache.insert(key.clone(), pipeline);
        }
        self.cache.get(key).unwrap()
    }

    /// Create a new pipeline from a key.
    fn create_pipeline(&self, key: &PipelineKey) -> wgpu::RenderPipeline {
        // Get or load shader module
        let shader = self.shaders.get(&key.shader_id)
            .expect("Shader not loaded");

        // Build color targets
        let color_targets: Vec<Option<wgpu::ColorTargetState>> = key.color_formats
            .iter()
            .map(|&format| Some(wgpu::ColorTargetState {
                format,
                blend: key.blend_mode.to_wgpu(),
                write_mask: wgpu::ColorWrites::ALL,
            }))
            .collect();

        // Build depth/stencil state
        let depth_stencil = Some(wgpu::DepthStencilState {
            format: key.depth_format,
            depth_write_enabled: matches!(key.z_mode, ZMode::ReadWrite),
            depth_compare: if key.z_mode == ZMode::Disabled {
                wgpu::CompareFunction::Always
            } else {
                key.z_function.to_wgpu()
            },
            stencil: wgpu::StencilState::default(),
            bias: wgpu::DepthBiasState::default(),
        });

        // Build primitive state
        let primitive = wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            strip_index_format: None,
            front_face: wgpu::FrontFace::Ccw,
            cull_mode: key.cull_mode.to_wgpu(),
            polygon_mode: if key.wireframe {
                wgpu::PolygonMode::Line
            } else {
                wgpu::PolygonMode::Fill
            },
            unclipped_depth: false,
            conservative: false,
        };

        self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Material Pipeline"),
            layout: Some(&self.pipeline_layout),
            vertex: wgpu::VertexState {
                module: shader,
                entry_point: Some("vs_main"),
                buffers: &[Vertex::desc()],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: shader,
                entry_point: Some("fs_main"),
                targets: &color_targets,
                compilation_options: Default::default(),
            }),
            primitive,
            depth_stencil,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        })
    }

    /// Load a shader module.
    pub fn load_shader(&mut self, id: u64, source: &str) {
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Material Shader"),
            source: wgpu::ShaderSource::Wgsl(std::borrow::Cow::Borrowed(source)),
        });
        self.shaders.insert(id, module);
    }
}
```

## Blend State Generation

```rust
impl BlendMode {
    /// Convert to wgpu blend state with proper alpha handling.
    pub fn to_blend_state_full(&self) -> Option<wgpu::BlendState> {
        match *self {
            BlendMode::OPAQUE => None,

            BlendMode::ALPHA => Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::SrcAlpha,
                    dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                    operation: wgpu::BlendOperation::Add,
                },
            }),

            BlendMode::ADDITIVE => Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::One,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent::REPLACE,
            }),

            BlendMode::MULTIPLY => Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::Dst,
                    dst_factor: wgpu::BlendFactor::Zero,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent::REPLACE,
            }),

            _ => {
                // Generic decode
                Some(wgpu::BlendState {
                    color: wgpu::BlendComponent {
                        src_factor: self.src_factor(),
                        dst_factor: self.dst_factor(),
                        operation: wgpu::BlendOperation::Add,
                    },
                    alpha: wgpu::BlendComponent {
                        src_factor: wgpu::BlendFactor::One,
                        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                        operation: wgpu::BlendOperation::Add,
                    },
                })
            }
        }
    }
}
```

## Depth/Stencil State Generation

```rust
/// Build depth/stencil state from material parameters.
pub fn build_depth_stencil_state(
    z_mode: ZMode,
    z_function: ZFunction,
    depth_format: wgpu::TextureFormat,
) -> wgpu::DepthStencilState {
    wgpu::DepthStencilState {
        format: depth_format,

        // Depth write: only if ReadWrite mode
        depth_write_enabled: matches!(z_mode, ZMode::ReadWrite),

        // Depth compare: Always if disabled, otherwise use function
        depth_compare: match z_mode {
            ZMode::Disabled => wgpu::CompareFunction::Always,
            ZMode::ReadWrite | ZMode::ReadOnly => z_function.to_wgpu(),
        },

        // No stencil for basic materials
        stencil: wgpu::StencilState::default(),

        // No depth bias
        bias: wgpu::DepthBiasState::default(),
    }
}
```

## Multi-Render-Target Support

G-Buffer materials write to multiple render targets:

```rust
fn build_color_targets_gbuffer(blend: BlendMode) -> Vec<Option<wgpu::ColorTargetState>> {
    vec![
        // RT0: Albedo (sRGB) + Metalness
        Some(wgpu::ColorTargetState {
            format: wgpu::TextureFormat::Rgba8Unorm,
            blend: blend.to_wgpu(),
            write_mask: wgpu::ColorWrites::ALL,
        }),
        // RT1: Normal (linear) + Roughness
        Some(wgpu::ColorTargetState {
            format: wgpu::TextureFormat::Rgba16Float,
            blend: None,  // No blending for normals
            write_mask: wgpu::ColorWrites::ALL,
        }),
    ]
}

fn build_color_targets_lighting() -> Vec<Option<wgpu::ColorTargetState>> {
    vec![
        // Main RT: HDR color accumulation
        Some(wgpu::ColorTargetState {
            format: wgpu::TextureFormat::Rgba16Float,
            blend: Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::One,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent::REPLACE,
            }),
            write_mask: wgpu::ColorWrites::ALL,
        }),
    ]
}
```

## Render Instance Creation

```rust
/// A render-ready material instance.
pub struct RenderInstance {
    /// Pipeline to use
    pub pipeline: Arc<wgpu::RenderPipeline>,

    /// Material bind group
    pub bind_group: wgpu::BindGroup,

    /// Draw priority (lower = earlier)
    pub priority: i32,

    /// Mesh reference
    pub mesh_id: usize,
}

impl MaterialResolver {
    /// Create a render instance from a resolved material.
    pub fn create_render_instance(
        &self,
        resolved: &ResolvedMaterial,
        pipeline_cache: &mut PipelineCache,
        mesh_id: usize,
    ) -> RenderInstance {
        // Get or create pipeline
        let pipeline = pipeline_cache.get_or_create(&resolved.pipeline_key);

        // Create uniform buffer
        let uniforms = resolved.to_uniforms();
        let uniform_buffer = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Material Uniforms"),
            contents: bytemuck::bytes_of(&uniforms),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Create bind group
        let bind_group = self.create_bind_group(
            &self.device,
            &self.material_layout,
            &resolved.textures,
            &uniform_buffer,
        );

        RenderInstance {
            pipeline: Arc::new(pipeline.clone()),  // Or handle differently
            bind_group,
            priority: resolved.render_priority,
            mesh_id,
        }
    }
}
```

## Draw Call Batching

Sort render instances by pipeline to minimize state changes:

```rust
pub fn sort_render_instances(instances: &mut [RenderInstance]) {
    instances.sort_by(|a, b| {
        // Primary: priority
        match a.priority.cmp(&b.priority) {
            std::cmp::Ordering::Equal => {}
            other => return other,
        }

        // Secondary: pipeline pointer (batch same pipelines)
        let a_ptr = Arc::as_ptr(&a.pipeline) as usize;
        let b_ptr = Arc::as_ptr(&b.pipeline) as usize;
        a_ptr.cmp(&b_ptr)
    });
}

pub fn render_instances<'a>(
    pass: &mut wgpu::RenderPass<'a>,
    instances: &'a [RenderInstance],
    meshes: &'a [Mesh],
    scene_bind_group: &'a wgpu::BindGroup,
    object_bind_groups: &'a [wgpu::BindGroup],
) {
    let mut current_pipeline: Option<&wgpu::RenderPipeline> = None;

    // Bind scene (group 0) once
    pass.set_bind_group(0, scene_bind_group, &[]);

    for instance in instances {
        // Only rebind pipeline if changed
        let pipeline: &wgpu::RenderPipeline = &instance.pipeline;
        if current_pipeline.map_or(true, |p| !std::ptr::eq(p, pipeline)) {
            pass.set_pipeline(pipeline);
            current_pipeline = Some(pipeline);
        }

        // Bind object uniforms (group 1)
        pass.set_bind_group(1, &object_bind_groups[instance.mesh_id], &[]);

        // Bind material (group 2)
        pass.set_bind_group(2, &instance.bind_group, &[]);

        // Draw mesh
        let mesh = &meshes[instance.mesh_id];
        pass.set_vertex_buffer(0, mesh.vertex_buffer.slice(..));
        pass.set_index_buffer(mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..mesh.index_count, 0, 0..1);
    }
}
```

## Hot Reload Support

```rust
impl PipelineCache {
    /// Invalidate all cached pipelines (for hot reload).
    pub fn invalidate_all(&mut self) {
        self.cache.clear();
    }

    /// Invalidate pipelines using a specific shader.
    pub fn invalidate_shader(&mut self, shader_id: u64) {
        self.cache.retain(|key, _| key.shader_id != shader_id);
    }

    /// Reload a shader and invalidate affected pipelines.
    pub fn reload_shader(&mut self, id: u64, source: &str) {
        self.invalidate_shader(id);
        self.load_shader(id, source);
    }
}
```

## Related Documents

- [01-data-structures.md](01-data-structures.md) - PipelineKey definition
- [02-parameter-merging.md](02-parameter-merging.md) - How key is extracted
- [03-texture-binding.md](03-texture-binding.md) - Bind group creation
- [../rust-port-pbr/appendix/wgpu-patterns.md](../rust-port-pbr/appendix/wgpu-patterns.md) - WGPU patterns
