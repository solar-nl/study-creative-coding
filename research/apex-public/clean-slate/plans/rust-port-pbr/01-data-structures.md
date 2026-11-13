# Data Structures and Buffer Layouts

This document defines the Rust structs, GPU buffer layouts, bind group configurations, and vertex formats needed to implement the PBR pipeline in WGPU.

## Dependencies

```toml
[dependencies]
wgpu = "0.19"
bytemuck = { version = "1.14", features = ["derive"] }
glam = "0.25"  # or nalgebra, cgmath
```

## Uniform Buffers

### Scene Uniforms (Bind Group 0)

The scene buffer contains data shared across all objects in a render pass. Updated once per frame.

```rust
use bytemuck::{Pod, Zeroable};
use glam::{Mat4, Vec4};

/// Scene-level uniforms (bind group 0, binding 0)
/// Total size: 880 bytes (aligned to 16)
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct SceneUniforms {
    /// View matrix (64 bytes)
    pub view: Mat4,
    /// Projection matrix (64 bytes)
    pub projection: Mat4,
    /// Camera world position (16 bytes) - xyz used, w unused
    pub camera_position: Vec4,
    /// Light count (16 bytes) - x = active count, yzw unused
    pub light_count: Vec4,
    /// Light data array (512 bytes) - 8 lights × 64 bytes each
    pub lights: [LightData; 8],
    /// Resolution (16 bytes) - xy = size, zw = 1/size
    pub resolution: Vec4,
    /// Inverse view matrix (64 bytes)
    pub inverse_view: Mat4,
    /// Inverse projection matrix (64 bytes)
    pub inverse_projection: Mat4,
}

impl Default for SceneUniforms {
    fn default() -> Self {
        Self {
            view: Mat4::IDENTITY,
            projection: Mat4::IDENTITY,
            camera_position: Vec4::ZERO,
            light_count: Vec4::ZERO,
            lights: [LightData::default(); 8],
            resolution: Vec4::new(1920.0, 1080.0, 1.0/1920.0, 1.0/1080.0),
            inverse_view: Mat4::IDENTITY,
            inverse_projection: Mat4::IDENTITY,
        }
    }
}
```

### Light Data

Each light occupies 64 bytes (4 × `Vec4`). The format supports point, spot, and directional lights.

```rust
/// Per-light data (64 bytes)
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct LightData {
    /// Position (point/spot) or direction (directional)
    /// w = light type (0=point, 1=directional, 2=spot)
    pub position: Vec4,
    /// Ambient color (RGB) + shadow map width (A)
    pub ambient: Vec4,
    /// Diffuse color (RGB) + shadow map height (A)
    pub diffuse: Vec4,
    /// Specular color (RGB) + spot parameters (A)
    pub specular: Vec4,
}

impl Default for LightData {
    fn default() -> Self {
        Self {
            position: Vec4::ZERO,
            ambient: Vec4::ZERO,
            diffuse: Vec4::ZERO,
            specular: Vec4::ZERO,
        }
    }
}

impl LightData {
    /// Create a point light
    pub fn point(position: [f32; 3], color: [f32; 3], radius: f32) -> Self {
        Self {
            position: Vec4::new(position[0], position[1], position[2], 0.0),
            ambient: Vec4::new(0.0, 0.0, 0.0, 0.0),
            diffuse: Vec4::new(color[0], color[1], color[2], radius),
            specular: Vec4::new(color[0], color[1], color[2], 0.0),
        }
    }

    /// Create a directional light
    pub fn directional(direction: [f32; 3], color: [f32; 3]) -> Self {
        let dir = glam::Vec3::from(direction).normalize();
        Self {
            position: Vec4::new(dir.x, dir.y, dir.z, 1.0),
            ambient: Vec4::ZERO,
            diffuse: Vec4::new(color[0], color[1], color[2], 0.0),
            specular: Vec4::new(color[0], color[1], color[2], 0.0),
        }
    }
}
```

### Object Uniforms (Bind Group 1)

Per-draw-call data for each mesh instance.

```rust
/// Object-level uniforms (bind group 1, binding 0)
/// Total size: 144 bytes (aligned to 16)
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct ObjectUniforms {
    /// World matrix - transforms local to world space (64 bytes)
    pub world: Mat4,
    /// Inverse-transpose world matrix - for normal transformation (64 bytes)
    pub inverse_transpose_world: Mat4,
    /// Material parameters (16 bytes)
    /// x = roughness modifier, y = metalness modifier
    /// z = normal flip (>0.5 = flip), w = reserved
    pub material_params: Vec4,
}

impl ObjectUniforms {
    pub fn new(world: Mat4) -> Self {
        // Compute inverse-transpose for normal transformation
        let inverse_transpose = world.inverse().transpose();
        Self {
            world,
            inverse_transpose_world: inverse_transpose,
            material_params: Vec4::new(0.5, 0.5, 0.0, 0.0), // neutral modifiers
        }
    }

    /// Set material parameter modifiers
    /// Values: 0.0-0.498 = reduce, 0.5 = neutral, 0.502-1.0 = increase toward 1
    pub fn with_modifiers(mut self, roughness_mod: f32, metalness_mod: f32) -> Self {
        self.material_params.x = roughness_mod;
        self.material_params.y = metalness_mod;
        self
    }

    pub fn with_normal_flip(mut self, flip: bool) -> Self {
        self.material_params.z = if flip { 1.0 } else { 0.0 };
        self
    }
}
```

### Post-Processing Uniforms

```rust
/// Post-processing uniforms
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct PostProcessUniforms {
    /// Time, aspect ratio, resolution x, resolution y
    pub screen_params: Vec4,
    /// Effect-specific parameters (varies by effect)
    pub effect_params: Vec4,
    /// Additional effect parameters
    pub effect_params2: Vec4,
}
```

## Vertex Formats

### Standard Mesh Vertex

```rust
/// Standard PBR mesh vertex (48 bytes)
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct Vertex {
    /// Position in local/object space
    pub position: [f32; 3],
    /// Normal vector (normalized)
    pub normal: [f32; 3],
    /// Texture coordinates
    pub uv: [f32; 2],
    /// Vertex color (optional, often unused)
    pub color: [f32; 4],
}

impl Vertex {
    pub fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                // Position: location 0
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                // Normal: location 1
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                },
                // UV: location 2
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 6]>() as wgpu::BufferAddress,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32x2,
                },
                // Color: location 3
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 8]>() as wgpu::BufferAddress,
                    shader_location: 3,
                    format: wgpu::VertexFormat::Float32x4,
                },
            ],
        }
    }
}
```

### Full-Screen Triangle Vertex

For post-processing and deferred lighting passes, use a single triangle that covers the screen.

```rust
/// Generate full-screen triangle vertices
/// No vertex buffer needed - generate in vertex shader
pub fn fullscreen_triangle_shader() -> &'static str {
    r#"
    // Generates a full-screen triangle from vertex ID
    // Call with 3 vertices, no vertex buffer
    @vertex
    fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4<f32> {
        // Generate triangle that covers [-1,1] clip space
        let x = f32(i32(vertex_index) / 2) * 4.0 - 1.0;
        let y = f32(i32(vertex_index) % 2) * 4.0 - 1.0;
        return vec4<f32>(x, y, 0.0, 1.0);
    }
    "#
}
```

## WGSL Struct Definitions

These WGSL structs must match the Rust definitions byte-for-byte.

```wgsl
// common.wgsl - Shared struct definitions

struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    light_count: vec4<f32>,
    lights: array<LightData, 8>,
    resolution: vec4<f32>,
    inverse_view: mat4x4<f32>,
    inverse_projection: mat4x4<f32>,
}

struct LightData {
    position: vec4<f32>,
    ambient: vec4<f32>,
    diffuse: vec4<f32>,
    specular: vec4<f32>,
}

struct ObjectUniforms {
    world: mat4x4<f32>,
    inverse_transpose_world: mat4x4<f32>,
    material_params: vec4<f32>,
}

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
}
```

## Bind Group Layouts

### Group 0: Scene Data

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
                    min_binding_size: Some(
                        std::num::NonZeroU64::new(
                            std::mem::size_of::<SceneUniforms>() as u64
                        ).unwrap()
                    ),
                },
                count: None,
            },
            // Shadow map sampler
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Comparison),
                count: None,
            },
            // Shadow map texture
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
        ],
    })
}
```

### Group 1: Object Data

```rust
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
                    min_binding_size: Some(
                        std::num::NonZeroU64::new(
                            std::mem::size_of::<ObjectUniforms>() as u64
                        ).unwrap()
                    ),
                },
                count: None,
            },
        ],
    })
}
```

### Group 2: Material Textures

```rust
pub fn create_material_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Material Bind Group Layout"),
        entries: &[
            // Sampler (shared for both textures)
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Albedo texture (RGB = albedo, A = metalness)
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
            // Normal texture (RG = normal XY, A = roughness)
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
        ],
    })
}
```

### Group 3: G-Buffer (Lighting Pass)

```rust
pub fn create_gbuffer_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("G-Buffer Bind Group Layout"),
        entries: &[
            // Point sampler (no filtering for G-Buffer)
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::NonFiltering),
                count: None,
            },
            // RT0: Albedo + Metalness
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // RT1: Normal + Roughness
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Depth texture
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Depth,
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
        ],
    })
}
```

## G-Buffer Render Targets

### Texture Creation

```rust
pub struct GBuffer {
    pub albedo_metalness: wgpu::Texture,
    pub albedo_metalness_view: wgpu::TextureView,
    pub normal_roughness: wgpu::Texture,
    pub normal_roughness_view: wgpu::TextureView,
    pub depth: wgpu::Texture,
    pub depth_view: wgpu::TextureView,
}

impl GBuffer {
    pub fn new(device: &wgpu::Device, width: u32, height: u32) -> Self {
        // RT0: Albedo (RGB) + Metalness (A)
        let albedo_metalness = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer RT0: Albedo+Metalness"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        // RT1: Normal (RGB) + Roughness (A) - use float for signed normals
        let normal_roughness = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer RT1: Normal+Roughness"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba16Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        // Depth buffer - also used as texture for world position reconstruction
        let depth = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("G-Buffer Depth"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                 | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        let albedo_metalness_view = albedo_metalness.create_view(&Default::default());
        let normal_roughness_view = normal_roughness.create_view(&Default::default());
        let depth_view = depth.create_view(&Default::default());

        Self {
            albedo_metalness,
            albedo_metalness_view,
            normal_roughness,
            normal_roughness_view,
            depth,
            depth_view,
        }
    }

    pub fn resize(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        *self = Self::new(device, width, height);
    }
}
```

## Memory Layout Verification

Use this function to verify struct sizes match WGSL expectations:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_struct_sizes() {
        // SceneUniforms should be 880 bytes
        assert_eq!(std::mem::size_of::<SceneUniforms>(), 880);

        // LightData should be 64 bytes
        assert_eq!(std::mem::size_of::<LightData>(), 64);

        // ObjectUniforms should be 144 bytes
        assert_eq!(std::mem::size_of::<ObjectUniforms>(), 144);

        // Vertex should be 48 bytes
        assert_eq!(std::mem::size_of::<Vertex>(), 48);
    }

    #[test]
    fn verify_alignment() {
        // All structs should be 16-byte aligned for GPU
        assert_eq!(std::mem::align_of::<SceneUniforms>() % 16, 0);
        assert_eq!(std::mem::align_of::<ObjectUniforms>() % 16, 0);
    }
}
```

## Buffer Update Patterns

### Scene Buffer (Once Per Frame)

```rust
impl Renderer {
    pub fn update_scene(&mut self, queue: &wgpu::Queue, camera: &Camera, lights: &[Light]) {
        let mut scene = SceneUniforms::default();

        scene.view = camera.view_matrix();
        scene.projection = camera.projection_matrix();
        scene.camera_position = camera.position().extend(1.0);
        scene.inverse_view = scene.view.inverse();
        scene.inverse_projection = scene.projection.inverse();
        scene.resolution = Vec4::new(
            self.width as f32,
            self.height as f32,
            1.0 / self.width as f32,
            1.0 / self.height as f32,
        );

        scene.light_count.x = lights.len().min(8) as f32;
        for (i, light) in lights.iter().take(8).enumerate() {
            scene.lights[i] = light.to_light_data();
        }

        queue.write_buffer(&self.scene_buffer, 0, bytemuck::cast_slice(&[scene]));
    }
}
```

### Object Buffer (Per Draw Call)

```rust
impl Renderer {
    pub fn draw_mesh(&mut self,
        encoder: &mut wgpu::CommandEncoder,
        mesh: &Mesh,
        transform: Mat4,
        material_params: Vec4,
    ) {
        let object = ObjectUniforms {
            world: transform,
            inverse_transpose_world: transform.inverse().transpose(),
            material_params,
        };

        self.queue.write_buffer(
            &self.object_buffer,
            0,
            bytemuck::cast_slice(&[object])
        );

        // Issue draw call...
    }
}
```

## Related Documents

- [02-gbuffer-pass.md](02-gbuffer-pass.md) - Uses these structs in the G-Buffer shader
- [03-deferred-lighting.md](03-deferred-lighting.md) - Reads G-Buffer using these bind groups
- [appendix/wgpu-patterns.md](appendix/wgpu-patterns.md) - More bind group and pipeline patterns
