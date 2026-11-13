// gbuffer.wgsl - G-Buffer generation for deferred PBR rendering
//
// Writes material properties to multiple render targets:
//   @location(0) RT0: Albedo.RGB + Metalness.A
//   @location(1) RT1: WorldNormal.RGB + Roughness.A
//
// Requires depth buffer bound for depth testing.

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;

// ============================================================================
// Bind Groups
// ============================================================================

// Group 0: Scene data (per-frame)
struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    // Additional fields from common.wgsl omitted - not used in G-Buffer pass
}

@group(0) @binding(0) var<uniform> scene: SceneUniforms;

// Group 1: Object data (per-draw)
struct ObjectUniforms {
    world: mat4x4<f32>,
    inverse_transpose_world: mat4x4<f32>,
    material_params: vec4<f32>, // x=roughness_mod, y=metalness_mod, z=normal_flip, w=reserved
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
    // Critical for non-uniform scaling - preserves perpendicularity to surface
    out.world_normal = (object.inverse_transpose_world * vec4<f32>(in.normal, 0.0)).xyz;

    // Project to clip space: world -> view -> clip
    let view_pos = scene.view * world_pos;
    out.clip_position = scene.projection * view_pos;

    // Pass through UVs
    out.uv = in.uv;

    return out;
}

// ============================================================================
// Fragment Utilities
// ============================================================================

/// Perturb normal using derivative-based tangent reconstruction
/// Computes tangent frame from screen-space derivatives, eliminating
/// the need for pre-computed per-vertex tangents.
///
/// N: interpolated vertex normal (normalized)
/// world_pos: world-space position
/// uv: texture coordinates
/// normal_map: sampled normal map value [0,1]
fn perturb_normal(N: vec3<f32>, world_pos: vec3<f32>, uv: vec2<f32>, normal_map: vec3<f32>) -> vec3<f32> {
    // Screen-space derivatives of world position and UVs
    // dpdx = rate of change along screen X axis
    // dpdy = rate of change along screen Y axis
    let dp1 = dpdx(world_pos);
    let dp2 = dpdy(world_pos);
    let duv1 = dpdx(uv);
    let duv2 = dpdy(uv);

    // Solve for tangent and bitangent vectors
    // These span the plane perpendicular to N
    let dp2perp = cross(dp2, N);
    let dp1perp = cross(N, dp1);
    let T = dp2perp * duv1.x + dp1perp * duv2.x;
    let B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Construct scale-invariant tangent frame
    let invmax = inverseSqrt(max(dot(T, T), dot(B, B)));
    let TBN = mat3x3<f32>(
        T * invmax,  // Tangent
        B * invmax,  // Bitangent
        N            // Normal
    );

    // Handle missing/black normal map
    var map = normal_map;
    if dot(map, map) == 0.0 {
        // Default to flat normal (pointing up in tangent space)
        map = vec3<f32>(0.5, 0.5, 1.0);
    }

    // Convert from [0,1] texture range to [-1,1] vector range
    map = map * 2.0 - 1.0;

    // Transform from tangent space to world space
    return normalize(TBN * map);
}

/// Apply bidirectional material modifier
/// Allows artists to adjust texture values up or down:
///   modifier in [0, 0.498]: multiply/reduce (0 = zero, 0.5 = unchanged)
///   modifier in [0.502, 1.0]: lerp toward 1 (0.5 = unchanged, 1.0 = full)
fn apply_modifier(value: f32, modifier: f32) -> f32 {
    let mid = 127.0 / 255.0; // ~0.498

    if modifier <= mid {
        // Reduce: multiply by (modifier / mid)
        // modifier=0 → 0, modifier=mid → value
        return value * modifier / mid;
    } else {
        // Increase: lerp toward 1.0
        // modifier=mid → value, modifier=1 → 1
        return mix(value, 1.0, (modifier - mid) / (128.0 / 255.0));
    }
}

// ============================================================================
// Fragment Stage
// ============================================================================

struct FragmentOutput {
    @location(0) albedo_metalness: vec4<f32>,  // RT0
    @location(1) normal_roughness: vec4<f32>,  // RT1
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    var out: FragmentOutput;

    // Sample material textures
    let albedo_sample = textureSample(albedo_texture, material_sampler, in.uv);
    let normal_sample = textureSample(normal_texture, material_sampler, in.uv);

    // Normalize interpolated normal (may become denormalized after rasterization)
    var N = normalize(in.world_normal);

    // Optional normal flip for double-sided materials
    // material_params.z > 0.5 indicates flip requested
    if object.material_params.z > 0.5 {
        N = -N;
    }

    // Perturb normal with normal map
    let perturbed_normal = perturb_normal(N, in.world_position, in.uv, normal_sample.xyz);

    // Apply material modifiers
    // x = roughness modifier, y = metalness modifier
    let roughness = apply_modifier(normal_sample.w, object.material_params.x);
    let metalness = apply_modifier(albedo_sample.w, object.material_params.y);

    // Write to G-Buffer
    // RT0: Albedo color in RGB, metalness in A
    out.albedo_metalness = vec4<f32>(albedo_sample.xyz, metalness);

    // RT1: World normal in RGB (signed, requires float format), roughness in A
    out.normal_roughness = vec4<f32>(perturbed_normal, roughness);

    return out;
}

// ============================================================================
// Alpha Cutout Variant
// ============================================================================

/// Fragment shader variant with alpha cutout support
/// Use for foliage, fences, and other masked geometry
@fragment
fn fs_main_cutout(in: VertexOutput) -> FragmentOutput {
    var out: FragmentOutput;

    let albedo_sample = textureSample(albedo_texture, material_sampler, in.uv);

    // Alpha cutout - discard fragments below threshold
    // Uses a fixed 0.5 threshold; could be made configurable via uniform
    if albedo_sample.a < 0.5 {
        discard;
    }

    let normal_sample = textureSample(normal_texture, material_sampler, in.uv);

    var N = normalize(in.world_normal);
    if object.material_params.z > 0.5 {
        N = -N;
    }

    let perturbed_normal = perturb_normal(N, in.world_position, in.uv, normal_sample.xyz);

    let roughness = apply_modifier(normal_sample.w, object.material_params.x);
    // For cutout materials, use albedo.a for cutout, metalness from separate channel
    // This example assumes metalness is stored elsewhere or defaulted
    let metalness = apply_modifier(0.0, object.material_params.y);

    out.albedo_metalness = vec4<f32>(albedo_sample.xyz, metalness);
    out.normal_roughness = vec4<f32>(perturbed_normal, roughness);

    return out;
}
