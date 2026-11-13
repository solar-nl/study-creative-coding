# Mixed Rendering: Forward + Deferred Hybrid

Mixed rendering combines forward and deferred shading in a single geometry pass. It's used for materials that need forward lighting calculations (emissive surfaces, special effects) while still writing to the G-Buffer for other surfaces to reflect them correctly.

## When to Use Mixed Rendering

| Material Type | Pure Deferred | Mixed Rendering |
|---------------|---------------|-----------------|
| Standard PBR | ✓ | |
| Emissive surfaces | | ✓ |
| Alpha cutout (foliage) | | ✓ |
| Subsurface scattering | | ✓ |
| Transparent with refraction | | ✓ |
| Custom lighting models | | ✓ |

## Architecture

Mixed rendering outputs to three render targets simultaneously:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Mixed Rendering Pass                                                 │
│                                                                      │
│   Vertex Shader                                                      │
│        ↓                                                             │
│   Fragment Shader                                                    │
│        ├──→ RT0 (location 0): Lit color (emissive + forward light) │
│        ├──→ RT1 (location 1): Albedo.RGB + Metalness.A              │
│        └──→ RT2 (location 2): Normal.RGB + Roughness.A              │
│                                                                      │
│   The deferred lighting pass later adds to RT0 based on RT1/RT2    │
└─────────────────────────────────────────────────────────────────────┘
```

## Pipeline Configuration

```rust
pub fn create_mixed_pipeline(
    device: &wgpu::Device,
    scene_layout: &wgpu::BindGroupLayout,
    object_layout: &wgpu::BindGroupLayout,
    material_layout: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Mixed Rendering Shader"),
        source: wgpu::ShaderSource::Wgsl(include_str!("shaders/mixed.wgsl").into()),
    });

    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Mixed Pipeline Layout"),
        bind_group_layouts: &[scene_layout, object_layout, material_layout],
        push_constant_ranges: &[],
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Mixed Rendering Pipeline"),
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
                // RT0: Lit color (HDR)
                Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba16Float,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                }),
                // RT1: Albedo + Metalness
                Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                }),
                // RT2: Normal + Roughness
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

## Render Pass Configuration

```rust
pub fn render_mixed_pass(
    encoder: &mut wgpu::CommandEncoder,
    hdr_view: &wgpu::TextureView,
    gbuffer: &GBuffer,
    // ... bind groups and meshes
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Mixed Rendering Pass"),
        color_attachments: &[
            // RT0: HDR color output
            Some(wgpu::RenderPassColorAttachment {
                view: hdr_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load, // Preserve previous content
                    store: wgpu::StoreOp::Store,
                },
            }),
            // RT1: G-Buffer albedo+metalness
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metalness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            }),
            // RT2: G-Buffer normal+roughness
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Load, // Use existing depth
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        timestamp_writes: None,
        occlusion_query_set: None,
    });

    // ... draw calls
}
```

## Mixed Rendering Shader

```wgsl
// mixed.wgsl - Forward+deferred hybrid rendering
//
// Computes forward lighting (emissive + lights) while also writing G-Buffer data.
// Used for emissive materials that need to glow while participating in reflections.

// Include common definitions (SceneUniforms, LightData, BRDF functions)
// ... (import from common.wgsl)

// ============================================================================
// Bind Groups
// ============================================================================

@group(0) @binding(0) var<uniform> scene: SceneUniforms;

struct MixedMaterialUniforms {
    world: mat4x4<f32>,
    inverse_transpose_world: mat4x4<f32>,
    material_params: vec4<f32>,    // x=roughness_mod, y=metalness_mod, z=normal_flip
    emissive_params: vec4<f32>,    // xyz=emissive_color, w=emissive_strength
    shadow_params: vec4<f32>,      // x=shadow_softness, y=alpha_cutoff
}

@group(1) @binding(0) var<uniform> material: MixedMaterialUniforms;

@group(2) @binding(0) var material_sampler: sampler;
@group(2) @binding(1) var albedo_texture: texture_2d<f32>;
@group(2) @binding(2) var normal_texture: texture_2d<f32>;
@group(2) @binding(3) var emissive_texture: texture_2d<f32>;  // RGB=emissive, A=mask

// Shadow map (optional)
@group(2) @binding(4) var shadow_sampler: sampler_comparison;
@group(2) @binding(5) var shadow_map: texture_depth_2d;

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
    @location(3) light_space_position: vec4<f32>,  // For shadow sampling
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    let world_pos = material.world * vec4<f32>(in.position, 1.0);
    out.world_position = world_pos.xyz;
    out.world_normal = (material.inverse_transpose_world * vec4<f32>(in.normal, 0.0)).xyz;

    let view_pos = scene.view * world_pos;
    out.clip_position = scene.projection * view_pos;
    out.uv = in.uv;

    // Compute light-space position for shadow mapping
    // (Assumes light matrices are stored in scene uniforms)
    // out.light_space_position = light_projection * light_view * world_pos;

    return out;
}

// ============================================================================
// Fragment Stage
// ============================================================================

struct FragmentOutput {
    @location(0) lit_color: vec4<f32>,        // HDR color (emissive + forward lighting)
    @location(1) albedo_metalness: vec4<f32>, // G-Buffer RT0
    @location(2) normal_roughness: vec4<f32>, // G-Buffer RT1
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    var out: FragmentOutput;

    // Sample textures
    let albedo_sample = textureSample(albedo_texture, material_sampler, in.uv);
    let normal_sample = textureSample(normal_texture, material_sampler, in.uv);
    let emissive_sample = textureSample(emissive_texture, material_sampler, in.uv);

    // Alpha cutout using emissive alpha channel
    if emissive_sample.a < material.shadow_params.y {
        discard;
    }

    // Normal mapping
    var N = normalize(in.world_normal);
    if material.material_params.z > 0.5 {
        N = -N;
    }
    let perturbed_normal = perturb_normal(N, in.world_position, in.uv, normal_sample.xyz);

    // Material properties
    let roughness = apply_modifier(normal_sample.w, material.material_params.x);
    let metalness = apply_modifier(albedo_sample.w, material.material_params.y);
    let albedo = albedo_sample.rgb;

    // Compute F0 for specular
    let f0 = mix(vec3<f32>(0.04), albedo, metalness);
    let diffuse_color = albedo * (1.0 - metalness);
    let specular_color = f0;

    // View direction
    let V = normalize(scene.camera_position.xyz - in.world_position);

    // Initialize lit color with emissive contribution
    var lit_color = emissive_sample.rgb * material.emissive_params.xyz * material.emissive_params.w;

    // Forward lighting loop
    let light_count = i32(scene.light_count.x);
    for (var i: i32 = 0; i < light_count; i = i + 1) {
        let light = scene.lights[i];

        // Compute light direction and attenuation based on light type
        var L: vec3<f32>;
        var attenuation: f32;

        let light_type = i32(light.position.w);
        if light_type == 1 {
            // Directional light
            L = normalize(-light.position.xyz);
            attenuation = 1.0;
        } else {
            // Point/spot light
            let to_light = light.position.xyz - in.world_position;
            let dist_sq = dot(to_light, to_light);
            L = normalize(to_light);
            attenuation = 1.0 / (dist_sq + 1.0);
        }

        // BRDF evaluation
        let H = normalize(V + L);
        let n_dot_l = max(dot(perturbed_normal, L), 0.0);
        let n_dot_v = saturate(abs(dot(perturbed_normal, V)) + 0.0001);
        let n_dot_h = saturate(dot(perturbed_normal, H));
        let v_dot_h = saturate(dot(V, H));

        if n_dot_l > 0.0 {
            let a2 = roughness * roughness * roughness * roughness;
            let D = D_GGX(a2, n_dot_h);
            let Vis = Vis_SmithJointApprox(a2, n_dot_v, n_dot_l);
            let F = F_Schlick(specular_color, v_dot_h);

            let diffuse = diffuse_color * INV_PI;
            let specular = (D * Vis) * F;

            let radiance = light.diffuse.rgb * attenuation;
            lit_color += (diffuse + specular) * radiance * n_dot_l;
        }
    }

    // Write outputs
    out.lit_color = vec4<f32>(lit_color, 1.0);
    out.albedo_metalness = vec4<f32>(albedo, metalness);
    out.normal_roughness = vec4<f32>(perturbed_normal, roughness);

    return out;
}

// Include BRDF helper functions (same as common.wgsl)
const PI: f32 = 3.14159265359;
const INV_PI: f32 = 0.31830988618;

fn pow5(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2 * x;
}

fn D_GGX(a2: f32, n_dot_h: f32) -> f32 {
    let d = (n_dot_h * a2 - n_dot_h) * n_dot_h + 1.0;
    return a2 / (PI * d * d);
}

fn F_Schlick(specular_color: vec3<f32>, v_dot_h: f32) -> vec3<f32> {
    let Fc = pow5(1.0 - v_dot_h);
    return saturate(50.0 * specular_color.g) * Fc + (1.0 - Fc) * specular_color;
}

fn Vis_SmithJointApprox(a2: f32, n_dot_v: f32, n_dot_l: f32) -> f32 {
    let a = sqrt(a2);
    let Vis_SmithV = n_dot_l * (n_dot_v * (1.0 - a) + a);
    let Vis_SmithL = n_dot_v * (n_dot_l * (1.0 - a) + a);
    return 0.5 / (Vis_SmithV + Vis_SmithL + 0.0001);
}

fn apply_modifier(value: f32, modifier: f32) -> f32 {
    let mid = 127.0 / 255.0;
    if modifier <= mid {
        return value * modifier / mid;
    } else {
        return mix(value, 1.0, (modifier - mid) / (128.0 / 255.0));
    }
}

fn perturb_normal(N: vec3<f32>, world_pos: vec3<f32>, uv: vec2<f32>, normal_map: vec3<f32>) -> vec3<f32> {
    let dp1 = dpdx(world_pos);
    let dp2 = dpdy(world_pos);
    let duv1 = dpdx(uv);
    let duv2 = dpdy(uv);

    let dp2perp = cross(dp2, N);
    let dp1perp = cross(N, dp1);
    let T = dp2perp * duv1.x + dp1perp * duv2.x;
    let B = dp2perp * duv1.y + dp1perp * duv2.y;

    let invmax = inverseSqrt(max(dot(T, T), dot(B, B)));
    let TBN = mat3x3<f32>(T * invmax, B * invmax, N);

    var map = normal_map;
    if dot(map, map) == 0.0 {
        map = vec3<f32>(0.5, 0.5, 1.0);
    }
    map = map * 2.0 - 1.0;
    return normalize(TBN * map);
}
```

## Rendering Order

Mixed rendering objects should be rendered **after** the pure G-Buffer pass:

```
1. G-Buffer Pass (pure deferred materials)
   - Writes to RT0, RT1, Depth
   - HDR buffer is not touched yet

2. Mixed Rendering Pass (emissive materials)
   - Loads existing G-Buffer (preserves pure deferred data)
   - Writes lit color to HDR + updates G-Buffer where geometry exists

3. Deferred Lighting Pass
   - Reads G-Buffer (includes both pure deferred and mixed materials)
   - Additively lights to HDR buffer
   - Now mixed materials participate in reflections via their G-Buffer data
```

## Use Cases

### Emissive Materials

Surfaces that glow (neon lights, screens, lava):
- Forward lighting computes self-illumination immediately
- G-Buffer data enables other surfaces to reflect the emissive color

### Alpha Cutout

Foliage, fences, hair:
- `discard` statement removes fragments based on alpha
- Remaining fragments write to G-Buffer normally

### Custom Lighting Models

Skin (subsurface scattering), car paint (clearcoat):
- Forward pass computes special lighting
- G-Buffer stores base material properties

## Related Documents

- [02-gbuffer-pass.md](02-gbuffer-pass.md) - Pure G-Buffer generation
- [03-deferred-lighting.md](03-deferred-lighting.md) - Deferred lighting that uses mixed output
- [06-shadow-mapping.md](06-shadow-mapping.md) - Shadow integration in forward loop
