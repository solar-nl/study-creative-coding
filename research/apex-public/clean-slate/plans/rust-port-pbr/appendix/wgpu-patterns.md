# WGPU Patterns for PBR Rendering

Common patterns and best practices for implementing the Phoenix PBR pipeline in wgpu.

## Bind Group Organization

The pipeline uses 4 bind groups to balance update frequency with cache efficiency:

```rust
// Group 0: Scene-level data (once per frame)
// - View/projection matrices
// - Camera position
// - Light array
// - Resolution/time

// Group 1: Object-level data (once per draw call)
// - World matrix
// - Inverse transpose world matrix
// - Material parameters

// Group 2: Material textures (changes with material)
// - Albedo texture
// - Normal map
// - Metallic/roughness map

// Group 3: G-Buffer / Post-processing (render pass specific)
// - G-Buffer textures for lighting pass
// - Post-processing input textures
```

### Bind Group Layout Definitions

```rust
pub fn create_scene_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Scene Bind Group Layout"),
        entries: &[
            // SceneUniforms buffer
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: Some(std::num::NonZero::new(
                        std::mem::size_of::<SceneUniforms>() as u64
                    ).unwrap()),
                },
                count: None,
            },
        ],
    })
}

pub fn create_object_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Object Bind Group Layout"),
        entries: &[
            // ObjectUniforms buffer
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: Some(std::num::NonZero::new(
                        std::mem::size_of::<ObjectUniforms>() as u64
                    ).unwrap()),
                },
                count: None,
            },
        ],
    })
}

pub fn create_material_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Material Bind Group Layout"),
        entries: &[
            // Albedo texture
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Normal map
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Metallic/roughness map
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Material sampler
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
        ],
    })
}

pub fn create_gbuffer_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("G-Buffer Bind Group Layout"),
        entries: &[
            // RT0: Albedo + Metallic
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // RT1: Normal + Roughness
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Depth buffer
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Depth,
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Point sampler (for G-Buffer)
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::NonFiltering),
                count: None,
            },
        ],
    })
}
```

## Multi-Render-Target (MRT) Setup

### G-Buffer Texture Creation

```rust
pub struct GBuffer {
    pub rt0: wgpu::Texture,      // Albedo.rgb + Metallic.a
    pub rt0_view: wgpu::TextureView,
    pub rt1: wgpu::Texture,      // Normal.rgb + Roughness.a
    pub rt1_view: wgpu::TextureView,
    pub depth: wgpu::Texture,
    pub depth_view: wgpu::TextureView,
    pub width: u32,
    pub height: u32,
}

impl GBuffer {
    pub fn new(device: &wgpu::Device, width: u32, height: u32) -> Self {
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };

        // RT0: RGBA8 for albedo (sRGB) + metallic
        let rt0 = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer RT0 (Albedo+Metal)"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        // RT1: RGBA16Float for normal + roughness (high precision normals)
        let rt1 = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer RT1 (Normal+Rough)"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba16Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        // Depth: 32-bit float for precision and sampling
        let depth = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer Depth"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        let rt0_view = rt0.create_view(&wgpu::TextureViewDescriptor::default());
        let rt1_view = rt1.create_view(&wgpu::TextureViewDescriptor::default());
        let depth_view = depth.create_view(&wgpu::TextureViewDescriptor::default());

        Self {
            rt0, rt0_view,
            rt1, rt1_view,
            depth, depth_view,
            width, height,
        }
    }
}
```

### MRT Render Pass

```rust
pub fn begin_gbuffer_pass<'a>(
    encoder: &'a mut wgpu::CommandEncoder,
    gbuffer: &'a GBuffer,
) -> wgpu::RenderPass<'a> {
    encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("G-Buffer Pass"),
        color_attachments: &[
            // RT0: Albedo + Metallic
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.rt0_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            }),
            // RT1: Normal + Roughness
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.rt1_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: 0.5, g: 0.5, b: 1.0, a: 0.5, // Default normal up, medium roughness
                    }),
                    store: wgpu::StoreOp::Store,
                },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Clear(1.0),
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        timestamp_writes: None,
        occlusion_query_set: None,
    })
}
```

### MRT Pipeline State

```rust
pub fn create_gbuffer_pipeline(
    device: &wgpu::Device,
    layouts: &[&wgpu::BindGroupLayout],
    shader: &wgpu::ShaderModule,
) -> wgpu::RenderPipeline {
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("G-Buffer Pipeline Layout"),
        bind_group_layouts: layouts,
        push_constant_ranges: &[],
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("G-Buffer Pipeline"),
        layout: Some(&layout),
        vertex: wgpu::VertexState {
            module: shader,
            entry_point: Some("vs_main"),
            buffers: &[Vertex::desc()],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: shader,
            entry_point: Some("fs_main"),
            // Two render targets
            targets: &[
                // RT0: Albedo + Metallic
                Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None, // No blending for G-Buffer
                    write_mask: wgpu::ColorWrites::ALL,
                }),
                // RT1: Normal + Roughness
                Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba16Float,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                }),
            ],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            front_face: wgpu::FrontFace::Ccw,
            cull_mode: Some(wgpu::Face::Back),
            ..Default::default()
        },
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: true,
            depth_compare: wgpu::CompareFunction::Less,
            stencil: wgpu::StencilState::default(),
            bias: wgpu::DepthBiasState::default(),
        }),
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
        cache: None,
    })
}
```

## Full-Screen Triangle Technique

A single triangle covering the entire screen is more efficient than a quad (2 triangles):

```wgsl
// No vertex buffer needed - generate positions from vertex_index
@vertex
fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4<f32> {
    // Triangle covering clip space [-1, 3] x [-1, 3]
    // After clipping: exactly covers [-1, 1] x [-1, 1]
    let x = f32(vertex_index & 1u) * 4.0 - 1.0;
    let y = f32((vertex_index >> 1u) & 1u) * 4.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}
```

### Full-Screen Triangle with UV

```wgsl
struct FullscreenOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> FullscreenOutput {
    var out: FullscreenOutput;

    // Generate oversized triangle
    let x = f32(vertex_index & 1u) * 4.0 - 1.0;
    let y = f32((vertex_index >> 1u) & 1u) * 4.0 - 1.0;

    out.position = vec4<f32>(x, y, 0.0, 1.0);

    // UV: map [-1,1] clip space to [0,1] texture space
    // Note: flip Y for wgpu coordinate system
    out.uv = vec2<f32>(
        (x + 1.0) * 0.5,
        (1.0 - y) * 0.5  // Flip Y
    );

    return out;
}
```

### Rust Draw Call

```rust
// No vertex buffer binding needed
pass.draw(0..3, 0..1);  // 3 vertices, 1 instance
```

## Depth Buffer as Sampled Texture

WGPU allows depth textures to be both render attachments and sampled textures, but requires separate views:

```rust
pub struct DepthBuffer {
    texture: wgpu::Texture,
    render_view: wgpu::TextureView,  // For depth testing
    sample_view: wgpu::TextureView,  // For sampling in shaders
}

impl DepthBuffer {
    pub fn new(device: &wgpu::Device, width: u32, height: u32) -> Self {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Depth Buffer"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        // Both views can use default descriptor for Depth32Float
        let render_view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let sample_view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        Self { texture, render_view, sample_view }
    }
}
```

### Sampling Depth in WGSL

```wgsl
@group(0) @binding(0) var depth_texture: texture_depth_2d;
@group(0) @binding(1) var depth_sampler: sampler;

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    // Sample depth (returns f32, not vec4)
    let depth = textureSample(depth_texture, depth_sampler, uv);

    // Linearize depth for visualization
    let near = 0.1;
    let far = 100.0;
    let linear_depth = (2.0 * near) / (far + near - depth * (far - near));

    return vec4<f32>(linear_depth, linear_depth, linear_depth, 1.0);
}
```

## Pipeline Caching Patterns

### Pipeline Cache Structure

```rust
use std::collections::HashMap;

#[derive(Hash, Eq, PartialEq, Clone)]
pub struct PipelineKey {
    shader_id: u64,
    vertex_format: u64,
    blend_mode: BlendMode,
    depth_test: bool,
    depth_write: bool,
    cull_mode: Option<wgpu::Face>,
    target_formats: Vec<wgpu::TextureFormat>,
}

#[derive(Hash, Eq, PartialEq, Clone, Copy)]
pub enum BlendMode {
    Opaque,
    AlphaBlend,
    Additive,
    Multiply,
}

pub struct PipelineCache {
    device: Arc<wgpu::Device>,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
    layouts: HashMap<u64, wgpu::PipelineLayout>,
    shaders: HashMap<u64, wgpu::ShaderModule>,
}

impl PipelineCache {
    pub fn get_or_create(&mut self, key: &PipelineKey) -> &wgpu::RenderPipeline {
        if !self.cache.contains_key(key) {
            let pipeline = self.create_pipeline(key);
            self.cache.insert(key.clone(), pipeline);
        }
        self.cache.get(key).unwrap()
    }
}
```

### Blend State Presets

```rust
impl BlendMode {
    pub fn to_blend_state(&self) -> Option<wgpu::BlendState> {
        match self {
            BlendMode::Opaque => None,
            BlendMode::AlphaBlend => Some(wgpu::BlendState {
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
            BlendMode::Additive => Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::One,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent::REPLACE,
            }),
            BlendMode::Multiply => Some(wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::Dst,
                    dst_factor: wgpu::BlendFactor::Zero,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent::REPLACE,
            }),
        }
    }
}
```

## Post-Processing Ping-Pong

```rust
pub struct PostProcessTargets {
    ping: wgpu::Texture,
    pong: wgpu::Texture,
    ping_view: wgpu::TextureView,
    pong_view: wgpu::TextureView,
    current_is_ping: bool,
}

impl PostProcessTargets {
    pub fn new(device: &wgpu::Device, width: u32, height: u32) -> Self {
        let create_target = |label: &str| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba16Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                     | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            })
        };

        let ping = create_target("Post Process Ping");
        let pong = create_target("Post Process Pong");
        let ping_view = ping.create_view(&wgpu::TextureViewDescriptor::default());
        let pong_view = pong.create_view(&wgpu::TextureViewDescriptor::default());

        Self {
            ping, pong,
            ping_view, pong_view,
            current_is_ping: true,
        }
    }

    /// Get the current source (read) texture view
    pub fn source(&self) -> &wgpu::TextureView {
        if self.current_is_ping { &self.ping_view } else { &self.pong_view }
    }

    /// Get the current destination (write) texture view
    pub fn dest(&self) -> &wgpu::TextureView {
        if self.current_is_ping { &self.pong_view } else { &self.ping_view }
    }

    /// Swap source and destination
    pub fn swap(&mut self) {
        self.current_is_ping = !self.current_is_ping;
    }
}
```

### Post-Processing Chain

```rust
pub fn run_post_processing(
    encoder: &mut wgpu::CommandEncoder,
    targets: &mut PostProcessTargets,
    effects: &[&PostEffect],
    final_target: &wgpu::TextureView,
) {
    for (i, effect) in effects.iter().enumerate() {
        let is_last = i == effects.len() - 1;

        // Last effect writes to final target, others ping-pong
        let output = if is_last { final_target } else { targets.dest() };

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some(effect.name()),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: output,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            effect.render(&mut pass, targets.source());
        }

        if !is_last {
            targets.swap();
        }
    }
}
```

## Buffer Update Patterns

### Uniform Buffer Updates

```rust
pub struct UniformBuffer<T: Pod> {
    buffer: wgpu::Buffer,
    _marker: std::marker::PhantomData<T>,
}

impl<T: Pod + Zeroable> UniformBuffer<T> {
    pub fn new(device: &wgpu::Device, label: &str) -> Self {
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some(label),
            size: std::mem::size_of::<T>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Self { buffer, _marker: std::marker::PhantomData }
    }

    pub fn update(&self, queue: &wgpu::Queue, data: &T) {
        queue.write_buffer(&self.buffer, 0, bytemuck::bytes_of(data));
    }

    pub fn buffer(&self) -> &wgpu::Buffer {
        &self.buffer
    }
}

// Usage:
let scene_buffer = UniformBuffer::<SceneUniforms>::new(&device, "Scene Uniforms");
scene_buffer.update(&queue, &scene_data);
```

### Dynamic Offset Buffers

For per-object data with many objects, use dynamic offsets:

```rust
pub struct DynamicUniformBuffer<T: Pod> {
    buffer: wgpu::Buffer,
    alignment: u64,
    capacity: usize,
    _marker: std::marker::PhantomData<T>,
}

impl<T: Pod + Zeroable> DynamicUniformBuffer<T> {
    pub fn new(device: &wgpu::Device, capacity: usize) -> Self {
        // wgpu requires 256-byte alignment for dynamic offsets
        let alignment = 256u64;
        let stride = ((std::mem::size_of::<T>() as u64 + alignment - 1) / alignment) * alignment;

        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Dynamic Uniform Buffer"),
            size: stride * capacity as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self { buffer, alignment, capacity, _marker: std::marker::PhantomData }
    }

    pub fn offset_for(&self, index: usize) -> u32 {
        let stride = ((std::mem::size_of::<T>() as u64 + self.alignment - 1)
                     / self.alignment) * self.alignment;
        (stride * index as u64) as u32
    }

    pub fn update(&self, queue: &wgpu::Queue, index: usize, data: &T) {
        let stride = ((std::mem::size_of::<T>() as u64 + self.alignment - 1)
                     / self.alignment) * self.alignment;
        queue.write_buffer(&self.buffer, stride * index as u64, bytemuck::bytes_of(data));
    }
}

// Bind group layout with dynamic offset
wgpu::BindGroupLayoutEntry {
    binding: 0,
    visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
    ty: wgpu::BindingType::Buffer {
        ty: wgpu::BufferBindingType::Uniform,
        has_dynamic_offset: true,  // Enable dynamic offsets
        min_binding_size: Some(std::num::NonZero::new(
            std::mem::size_of::<ObjectUniforms>() as u64
        ).unwrap()),
    },
    count: None,
}

// Draw call with dynamic offset
pass.set_bind_group(1, &object_bind_group, &[dynamic_buffer.offset_for(object_index)]);
pass.draw_indexed(0..mesh.index_count, 0, 0..1);
```

## Vertex Format Definition

```rust
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct Vertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
    pub color: [f32; 4],
}

impl Vertex {
    pub fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                // Position
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                // Normal
                wgpu::VertexAttribute {
                    offset: 12,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                },
                // UV
                wgpu::VertexAttribute {
                    offset: 24,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32x2,
                },
                // Color
                wgpu::VertexAttribute {
                    offset: 32,
                    shader_location: 3,
                    format: wgpu::VertexFormat::Float32x4,
                },
            ],
        }
    }
}
```

## Sampler Presets

```rust
pub struct Samplers {
    pub linear_clamp: wgpu::Sampler,
    pub linear_wrap: wgpu::Sampler,
    pub nearest_clamp: wgpu::Sampler,
    pub shadow_compare: wgpu::Sampler,
}

impl Samplers {
    pub fn new(device: &wgpu::Device) -> Self {
        Self {
            linear_clamp: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("Linear Clamp"),
                address_mode_u: wgpu::AddressMode::ClampToEdge,
                address_mode_v: wgpu::AddressMode::ClampToEdge,
                address_mode_w: wgpu::AddressMode::ClampToEdge,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                mipmap_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
            linear_wrap: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("Linear Wrap"),
                address_mode_u: wgpu::AddressMode::Repeat,
                address_mode_v: wgpu::AddressMode::Repeat,
                address_mode_w: wgpu::AddressMode::Repeat,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                mipmap_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
            nearest_clamp: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("Nearest Clamp"),
                address_mode_u: wgpu::AddressMode::ClampToEdge,
                address_mode_v: wgpu::AddressMode::ClampToEdge,
                address_mode_w: wgpu::AddressMode::ClampToEdge,
                mag_filter: wgpu::FilterMode::Nearest,
                min_filter: wgpu::FilterMode::Nearest,
                mipmap_filter: wgpu::FilterMode::Nearest,
                ..Default::default()
            }),
            shadow_compare: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("Shadow Compare"),
                address_mode_u: wgpu::AddressMode::ClampToEdge,
                address_mode_v: wgpu::AddressMode::ClampToEdge,
                address_mode_w: wgpu::AddressMode::ClampToEdge,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                compare: Some(wgpu::CompareFunction::LessEqual),
                ..Default::default()
            }),
        }
    }
}
```

## Related Documents

- [01-data-structures.md](../01-data-structures.md) - Struct definitions
- [02-gbuffer-pass.md](../02-gbuffer-pass.md) - G-Buffer pipeline setup
- [03-deferred-lighting.md](../03-deferred-lighting.md) - Lighting pass configuration
- [07-post-processing.md](../07-post-processing.md) - Post-processing chain
