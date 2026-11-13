// shadow-pass.wgsl - Depth-only shadow map generation
//
// Renders scene geometry from the light's perspective, writing only depth.
// No fragment shader needed - the rasterizer writes depth automatically.
//
// Reference: [06-shadow-mapping.md](../06-shadow-mapping.md)

// ============================================================================
// Bind Groups
// ============================================================================

/// Shadow pass uniforms (light-space matrices)
struct ShadowUniforms {
    /// Light view matrix (world → light space)
    light_view: mat4x4<f32>,
    /// Light projection matrix (orthographic for directional, perspective for spot)
    light_projection: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> shadow: ShadowUniforms;

/// Per-object transform
struct ObjectUniforms {
    /// Object world matrix
    world: mat4x4<f32>,
    /// Inverse transpose world matrix (unused in shadow pass)
    inverse_transpose_world: mat4x4<f32>,
    /// Material parameters (unused in shadow pass)
    material_params: vec4<f32>,
}

@group(1) @binding(0) var<uniform> object: ObjectUniforms;

// ============================================================================
// Vertex Stage
// ============================================================================

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,    // Unused but included for vertex format compatibility
    @location(2) uv: vec2<f32>,        // Unused
    @location(3) color: vec4<f32>,     // Unused
}

/// Shadow pass vertex shader
///
/// Transforms vertices to light clip space for depth rendering.
/// Returns only position - no interpolated data needed.
@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4<f32> {
    let world_pos = object.world * vec4<f32>(in.position, 1.0);
    let light_space = shadow.light_projection * shadow.light_view * world_pos;
    return light_space;
}

// No fragment shader - depth-only rendering
// The hardware depth buffer is written automatically by the rasterizer.
// This is achieved in wgpu by setting `fragment: None` in the pipeline descriptor.

// ============================================================================
// Shadow Sampling Functions (for lighting shaders)
// ============================================================================
// These functions are included here for reference but should be imported
// into lighting shaders via common.wgsl or a dedicated shadow module.

/// Basic shadow test with single sample
fn sample_shadow_basic(
    shadow_map: texture_depth_2d,
    shadow_sampler: sampler_comparison,
    light_space_pos: vec4<f32>,
) -> f32 {
    // Perspective divide
    let shadow_coords = light_space_pos.xyz / light_space_pos.w;

    // NDC [-1,1] to UV [0,1]
    let uv = shadow_coords.xy * 0.5 + 0.5;

    // Flip Y for WGPU coordinate system (top-left origin)
    let shadow_uv = vec2<f32>(uv.x, 1.0 - uv.y);

    // Reject samples outside shadow map bounds
    if any(shadow_uv < vec2<f32>(0.0)) || any(shadow_uv > vec2<f32>(1.0)) {
        return 1.0;  // Outside shadow frustum = lit
    }

    // Comparison sampler returns 1.0 if depth <= reference, 0.0 otherwise
    return textureSampleCompare(shadow_map, shadow_sampler, shadow_uv, shadow_coords.z);
}

/// PCF shadow with 5×5 kernel for soft edges
fn sample_shadow_pcf(
    shadow_map: texture_depth_2d,
    shadow_sampler: sampler_comparison,
    light_space_pos: vec4<f32>,
    shadow_map_size: f32,
    softness: f32,
) -> f32 {
    let shadow_coords = light_space_pos.xyz / light_space_pos.w;
    let uv = shadow_coords.xy * 0.5 + 0.5;
    let shadow_uv = vec2<f32>(uv.x, 1.0 - uv.y);

    if any(shadow_uv < vec2<f32>(0.0)) || any(shadow_uv > vec2<f32>(1.0)) {
        return 1.0;
    }

    let texel_size = 1.0 / shadow_map_size;
    var shadow: f32 = 0.0;

    // 5×5 PCF kernel (25 samples)
    for (var x: i32 = -2; x <= 2; x = x + 1) {
        for (var y: i32 = -2; y <= 2; y = y + 1) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel_size * softness;
            shadow += textureSampleCompare(
                shadow_map,
                shadow_sampler,
                shadow_uv + offset,
                shadow_coords.z
            );
        }
    }

    return shadow / 25.0;
}

/// Shadow with normal-based bias to reduce acne on steep surfaces
fn sample_shadow_biased(
    shadow_map: texture_depth_2d,
    shadow_sampler: sampler_comparison,
    light_space_pos: vec4<f32>,
    world_normal: vec3<f32>,
    light_direction: vec3<f32>,
    shadow_map_size: f32,
) -> f32 {
    // Compute slope-based bias
    let n_dot_l = max(dot(world_normal, light_direction), 0.0);
    let bias = max(0.001 * (1.0 - n_dot_l), 0.0001);

    let shadow_coords = light_space_pos.xyz / light_space_pos.w;
    let biased_depth = shadow_coords.z - bias;

    let uv = shadow_coords.xy * 0.5 + 0.5;
    let shadow_uv = vec2<f32>(uv.x, 1.0 - uv.y);

    if any(shadow_uv < vec2<f32>(0.0)) || any(shadow_uv > vec2<f32>(1.0)) {
        return 1.0;
    }

    let texel_size = 1.0 / shadow_map_size;
    var shadow: f32 = 0.0;

    // 3×3 PCF kernel (9 samples) - smaller for biased version
    for (var x: i32 = -1; x <= 1; x = x + 1) {
        for (var y: i32 = -1; y <= 1; y = y + 1) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel_size;
            shadow += textureSampleCompare(
                shadow_map,
                shadow_sampler,
                shadow_uv + offset,
                biased_depth
            );
        }
    }

    return shadow / 9.0;
}
