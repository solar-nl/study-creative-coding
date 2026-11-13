# G-Buffer Pass

The G-Buffer pass renders all opaque geometry to multiple render targets, storing material properties for later deferred lighting. This is the foundation of the deferred rendering pipeline.

## G-Buffer Layout

| Target | Format | RGB Channels | Alpha Channel | Range |
|--------|--------|--------------|---------------|-------|
| RT0 | Rgba8Unorm | Albedo color | Metalness | [0,1] |
| RT1 | Rgba16Float | World normal (signed) | Roughness | [-1,1] / [0,1] |
| Depth | Depth32Float | Scene depth | - | [0,1] |

### Why These Formats?

- **Rgba8Unorm for RT0**: Albedo and metalness are perceptual values in [0,1]. 8-bit provides sufficient precision.
- **Rgba16Float for RT1**: World normals require signed values and benefit from higher precision for smooth shading. The extra precision also helps roughness gradients.
- **Depth32Float**: Maximum depth precision. Also sampled as a texture for world position reconstruction.

## Pipeline Configuration

```rust
pub fn create_gbuffer_pipeline(
    device: &wgpu::Device,
    scene_layout: &wgpu::BindGroupLayout,
    object_layout: &wgpu::BindGroupLayout,
    material_layout: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("G-Buffer Shader"),
        source: wgpu::ShaderSource::Wgsl(include_str!("shaders/gbuffer.wgsl").into()),
    });

    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("G-Buffer Pipeline Layout"),
        bind_group_layouts: &[scene_layout, object_layout, material_layout],
        push_constant_ranges: &[],
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("G-Buffer Pipeline"),
        layout: Some(&layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs_main"),
            buffers: &[Vertex::desc()],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs_main"),
            targets: &[
                // RT0: Albedo + Metalness
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
            strip_index_format: None,
            front_face: wgpu::FrontFace::Ccw,
            cull_mode: Some(wgpu::Face::Back), // Standard back-face culling
            polygon_mode: wgpu::PolygonMode::Fill,
            unclipped_depth: false,
            conservative: false,
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

## Render Pass Execution

```rust
pub fn render_gbuffer_pass(
    encoder: &mut wgpu::CommandEncoder,
    gbuffer: &GBuffer,
    scene_bind_group: &wgpu::BindGroup,
    meshes: &[(Mesh, wgpu::BindGroup, wgpu::BindGroup)], // mesh, object_bg, material_bg
    pipeline: &wgpu::RenderPipeline,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("G-Buffer Pass"),
        color_attachments: &[
            // RT0: Albedo + Metalness
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metalness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            }),
            // RT1: Normal + Roughness
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    // Clear to (0,0,0,0) - invalid normal signals "no geometry"
                    load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
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
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, scene_bind_group, &[]);

    for (mesh, object_bind_group, material_bind_group) in meshes {
        pass.set_bind_group(1, object_bind_group, &[]);
        pass.set_bind_group(2, material_bind_group, &[]);
        pass.set_vertex_buffer(0, mesh.vertex_buffer.slice(..));
        pass.set_index_buffer(mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..mesh.index_count, 0, 0..1);
    }
}
```

## G-Buffer Shader (WGSL)

The complete `gbuffer.wgsl` shader with detailed annotations:

```wgsl
// gbuffer.wgsl - G-Buffer generation for deferred PBR rendering
//
// Writes material properties to multiple render targets:
//   RT0: Albedo.RGB + Metalness.A
//   RT1: WorldNormal.RGB + Roughness.A

// ============================================================================
// Bind Groups
// ============================================================================

// Group 0: Scene data (per-frame)
struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    light_count: vec4<f32>,
    // lights array omitted - not used in G-Buffer pass
}
@group(0) @binding(0) var<uniform> scene: SceneUniforms;

// Group 1: Object data (per-draw)
struct ObjectUniforms {
    world: mat4x4<f32>,
    inverse_transpose_world: mat4x4<f32>,
    material_params: vec4<f32>, // x=roughness_mod, y=metalness_mod, z=normal_flip
}
@group(1) @binding(0) var<uniform> object: ObjectUniforms;

// Group 2: Material textures
@group(2) @binding(0) var material_sampler: sampler;
@group(2) @binding(1) var albedo_texture: texture_2d<f32>;   // RGB=albedo, A=metalness
@group(2) @binding(2) var normal_texture: texture_2d<f32>;  // RGB=normal, A=roughness

// ============================================================================
// Vertex Stage
// ============================================================================

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

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    // Transform position to world space
    let world_pos = object.world * vec4<f32>(in.position, 1.0);
    out.world_position = world_pos.xyz;

    // Transform normal using inverse-transpose matrix
    // This handles non-uniform scaling correctly
    out.world_normal = (object.inverse_transpose_world * vec4<f32>(in.normal, 0.0)).xyz;

    // Project to clip space: world -> view -> clip
    let view_pos = scene.view * world_pos;
    out.clip_position = scene.projection * view_pos;

    // Pass through UVs
    out.uv = in.uv;

    return out;
}

// ============================================================================
// Fragment Stage
// ============================================================================

struct FragmentOutput {
    @location(0) albedo_metalness: vec4<f32>,  // RT0
    @location(1) normal_roughness: vec4<f32>,  // RT1
}

/// Perturb normal using derivative-based tangent reconstruction
/// This technique computes the tangent frame from screen-space derivatives,
/// eliminating the need for pre-computed per-vertex tangents.
///
/// Reference: Christian Schüler, "Followup: Normal Mapping Without Precomputed Tangents"
/// http://www.thetenthplanet.de/archives/1180
fn perturb_normal(N: vec3<f32>, world_pos: vec3<f32>, uv: vec2<f32>, normal_map: vec3<f32>) -> vec3<f32> {
    // Screen-space derivatives of world position and UVs
    let dp1 = dpdx(world_pos);  // d(world_pos)/d(screen_x)
    let dp2 = dpdy(world_pos);  // d(world_pos)/d(screen_y)
    let duv1 = dpdx(uv);        // d(uv)/d(screen_x)
    let duv2 = dpdy(uv);        // d(uv)/d(screen_y)

    // Solve the linear system for tangent and bitangent
    // These vectors are orthogonal to N and span the tangent plane
    let dp2perp = cross(dp2, N);
    let dp1perp = cross(N, dp1);
    let T = dp2perp * duv1.x + dp1perp * duv2.x;
    let B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Construct scale-invariant tangent frame
    let invmax = inverseSqrt(max(dot(T, T), dot(B, B)));
    let TBN = mat3x3<f32>(
        T * invmax,
        B * invmax,
        N
    );

    // Handle missing normal map (sample is black)
    var map = normal_map;
    if dot(map, map) == 0.0 {
        map = vec3<f32>(0.5, 0.5, 1.0);
    }

    // Convert from [0,1] to [-1,1] range and transform
    map = map * 2.0 - 1.0;
    return normalize(TBN * map);
}

/// Apply bidirectional material modifier
/// modifier in [0, 0.498]: multiply/reduce the value
/// modifier = 0.5 (127/255): pass through unchanged
/// modifier in [0.502, 1.0]: lerp toward 1.0/increase the value
fn apply_modifier(value: f32, modifier: f32) -> f32 {
    let mid = 127.0 / 255.0;
    if modifier <= mid {
        // Reduce: multiply by (modifier / mid)
        return value * modifier / mid;
    } else {
        // Increase: lerp toward 1.0
        return mix(value, 1.0, (modifier - mid) / (128.0 / 255.0));
    }
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    var out: FragmentOutput;

    // Sample material textures
    let albedo_sample = textureSample(albedo_texture, material_sampler, in.uv);
    let normal_sample = textureSample(normal_texture, material_sampler, in.uv);

    // Normalize interpolated normal (may be denormalized after rasterization)
    var N = normalize(in.world_normal);

    // Apply normal flip if requested (for double-sided materials)
    if object.material_params.z > 0.5 {
        N = -N;
    }

    // Perturb normal with normal map
    let perturbed_normal = perturb_normal(N, in.world_position, in.uv, normal_sample.xyz);

    // Apply material modifiers to roughness and metalness
    let roughness = apply_modifier(normal_sample.w, object.material_params.x);
    let metalness = apply_modifier(albedo_sample.w, object.material_params.y);

    // Write to G-Buffer
    out.albedo_metalness = vec4<f32>(albedo_sample.xyz, metalness);
    out.normal_roughness = vec4<f32>(perturbed_normal, roughness);

    return out;
}
```

## Key Implementation Details

### Derivative-Based Tangent Reconstruction

The `perturb_normal` function reconstructs the tangent frame from screen-space derivatives, eliminating per-vertex tangent storage:

1. `dpdx(world_pos)` gives the rate of change of world position across the screen horizontally
2. `dpdy(world_pos)` gives the rate of change vertically
3. Combined with UV derivatives, these solve for tangent (T) and bitangent (B) vectors
4. The resulting TBN matrix transforms normal map vectors to world space

**Trade-off**: Costs extra ALU per pixel but saves vertex memory and simplifies mesh processing. Essential for procedural geometry where tangents aren't pre-computed.

### Material Modifiers

The `apply_modifier` function enables artists to adjust texture values bidirectionally:

```
modifier = 0.0   → value × 0    = 0
modifier = 0.25  → value × 0.5  = reduced
modifier = 0.5   → value × 1    = unchanged
modifier = 0.75  → lerp(value, 1, 0.5)
modifier = 1.0   → lerp(value, 1, 1) = 1
```

This packs both "reduce" and "increase" into a single [0,1] parameter.

### G-Buffer Clear Values

- **RT0**: Clear to black (0,0,0,0) - no albedo, no metalness
- **RT1**: Clear to (0,0,0,0) - zero-length normal signals "no geometry here"
- **Depth**: Clear to 1.0 (far plane)

The lighting pass can detect unlit pixels by checking if `length(normal) < 0.5`.

## Alpha Cutout Support

For materials with alpha masking (foliage, fences), add a discard based on alpha:

```wgsl
@fragment
fn fs_main_with_cutout(in: VertexOutput) -> FragmentOutput {
    let albedo_sample = textureSample(albedo_texture, material_sampler, in.uv);

    // Alpha cutout - discard fragments below threshold
    if albedo_sample.a < 0.5 {
        discard;
    }

    // ... rest of shader
}
```

Create a separate pipeline for cutout materials, or use a uniform to control the threshold.

## Debugging G-Buffer Output

Visualize G-Buffer contents by rendering them to screen:

```wgsl
// Debug shader to visualize G-Buffer
@fragment
fn fs_debug_gbuffer(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let albedo = textureSample(rt0_texture, point_sampler, uv);
    let normal = textureSample(rt1_texture, point_sampler, uv);

    // Visualize options (uncomment one):

    // Albedo
    // return vec4<f32>(albedo.rgb, 1.0);

    // Metalness
    // return vec4<f32>(vec3<f32>(albedo.a), 1.0);

    // Normal (remap from [-1,1] to [0,1])
    // return vec4<f32>(normal.xyz * 0.5 + 0.5, 1.0);

    // Roughness
    return vec4<f32>(vec3<f32>(normal.a), 1.0);
}
```

## Common Issues

### Normals Look Wrong

1. **Inverse-transpose missing**: Non-uniform scaling distorts normals without the inverse-transpose matrix
2. **Handedness mismatch**: Check if normal map uses DirectX (Y-up green) or OpenGL (Y-down green) convention
3. **Normalization**: Ensure normals are normalized after interpolation and before TBN construction

### Material Parameters Not Working

1. **Modifier math**: Verify the midpoint (127/255 ≈ 0.498) calculation
2. **Texture format**: Ensure alpha channel is readable (some formats strip alpha)

### G-Buffer Looks Correct But Lighting Is Wrong

1. **World position reconstruction**: Verify inverse matrices are correct
2. **Coordinate system**: WGPU Y-flip may differ from source engine
3. **Normal range**: Ensure normals write as signed values (use Rgba16Float, not Rgba8Unorm for RT1)

## Related Documents

- [01-data-structures.md](01-data-structures.md) - Struct definitions used here
- [03-deferred-lighting.md](03-deferred-lighting.md) - How the G-Buffer is consumed
- [shaders/gbuffer.wgsl](shaders/gbuffer.wgsl) - Standalone shader file
