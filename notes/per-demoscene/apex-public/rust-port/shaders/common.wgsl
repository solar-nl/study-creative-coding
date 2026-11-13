// common.wgsl - Shared BRDF functions, transforms, and utilities
//
// This file contains the core PBR building blocks used across multiple shaders.
// Import into other shaders or copy the functions you need.

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;
const INV_PI: f32 = 0.31830988618;
const EPSILON: f32 = 0.0001;

// ============================================================================
// Shared Struct Definitions
// ============================================================================

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
    position: vec4<f32>,   // xyz = position/direction, w = type
    ambient: vec4<f32>,    // xyz = ambient color, w = shadow width
    diffuse: vec4<f32>,    // xyz = diffuse color, w = radius/shadow height
    specular: vec4<f32>,   // xyz = specular color, w = spot params
}

struct ObjectUniforms {
    world: mat4x4<f32>,
    inverse_transpose_world: mat4x4<f32>,
    material_params: vec4<f32>,
}

/// BRDF evaluation context - caches dot products to avoid redundant computation
struct BrdfContext {
    n_dot_v: f32,   // Normal · View
    n_dot_l: f32,   // Normal · Light
    n_dot_h: f32,   // Normal · Half
    v_dot_h: f32,   // View · Half
    v_dot_l: f32,   // View · Light
}

/// G-Buffer data unpacked for lighting
struct GBufferData {
    world_normal: vec3<f32>,
    diffuse_color: vec3<f32>,
    specular_color: vec3<f32>,
    roughness: f32,
}

// ============================================================================
// Math Utilities
// ============================================================================

fn square(x: f32) -> f32 {
    return x * x;
}

fn pow4(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2;
}

fn pow5(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2 * x;
}

// ============================================================================
// BRDF Context Initialization
// ============================================================================

/// Initialize BRDF context from normal, view, and light directions
fn init_brdf_context(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>) -> BrdfContext {
    var ctx: BrdfContext;

    // Half vector between view and light
    let H = normalize(V + L);

    ctx.n_dot_l = dot(N, L);
    ctx.n_dot_v = dot(N, V);
    ctx.n_dot_h = saturate(dot(N, H));
    ctx.v_dot_h = saturate(dot(V, H));
    ctx.v_dot_l = dot(V, L);

    return ctx;
}

// ============================================================================
// Distribution Functions (D)
// ============================================================================

/// GGX/Trowbridge-Reitz normal distribution function
/// Models the statistical distribution of microfacet orientations
///
/// a2: roughness squared (alpha^2)
/// n_dot_h: dot product of normal and half-vector
fn D_GGX(a2: f32, n_dot_h: f32) -> f32 {
    // GGX formula: a2 / (PI * ((NoH^2 * (a2 - 1) + 1)^2))
    // Rearranged for numerical stability
    let d = (n_dot_h * a2 - n_dot_h) * n_dot_h + 1.0;
    return a2 / (PI * d * d);
}

// ============================================================================
// Fresnel Functions (F)
// ============================================================================

/// Schlick's approximation for Fresnel reflectance
/// At normal incidence (v_dot_h = 1), returns specular_color
/// At grazing angles (v_dot_h → 0), approaches 1.0 (total reflection)
///
/// specular_color: F0 (base reflectivity at normal incidence)
/// v_dot_h: dot product of view and half-vector
fn F_Schlick(specular_color: vec3<f32>, v_dot_h: f32) -> vec3<f32> {
    let Fc = pow5(1.0 - v_dot_h);
    // Edge tint enhancement using green channel as brightness proxy
    // Produces slightly brighter reflections at grazing angles for dielectrics
    return saturate(50.0 * specular_color.g) * Fc + (1.0 - Fc) * specular_color;
}

/// Simplified Schlick Fresnel (single value)
fn F_Schlick_scalar(f0: f32, v_dot_h: f32) -> f32 {
    return f0 + (1.0 - f0) * pow5(1.0 - v_dot_h);
}

// ============================================================================
// Geometry/Visibility Functions (G)
// ============================================================================

/// Smith-GGX height-correlated visibility function (approximation)
/// Accounts for microfacet shadowing and masking
/// From Epic Games' UE4 PBR implementation
///
/// a2: roughness squared
/// n_dot_v: Normal · View
/// n_dot_l: Normal · Light
fn Vis_SmithJointApprox(a2: f32, n_dot_v: f32, n_dot_l: f32) -> f32 {
    let a = sqrt(a2);
    let Vis_SmithV = n_dot_l * (n_dot_v * (1.0 - a) + a);
    let Vis_SmithL = n_dot_v * (n_dot_l * (1.0 - a) + a);
    return 0.5 / (Vis_SmithV + Vis_SmithL + EPSILON);
}

// ============================================================================
// Combined BRDF Functions
// ============================================================================

/// Cook-Torrance specular BRDF with GGX distribution
/// Returns specular contribution color
fn SpecularGGX(roughness: f32, specular_color: vec3<f32>, ctx: BrdfContext, n_dot_l: f32) -> vec3<f32> {
    // Convert roughness to alpha squared (perceptual linearization)
    // roughness -> roughness^2 -> (roughness^2)^2
    let a2 = pow4(roughness);

    let D = D_GGX(a2, ctx.n_dot_h);
    let Vis = Vis_SmithJointApprox(a2, ctx.n_dot_v, n_dot_l);
    let F = F_Schlick(specular_color, ctx.v_dot_h);

    return (D * Vis) * F;
}

/// Lambertian diffuse BRDF
/// Returns diffuse contribution (energy-conserving with PI division)
fn DiffuseLambert(diffuse_color: vec3<f32>) -> vec3<f32> {
    return diffuse_color * INV_PI;
}

// ============================================================================
// G-Buffer Utilities
// ============================================================================

/// Reconstruct world position from depth buffer
/// depth: raw depth buffer value [0,1]
/// uv: screen-space UV coordinates [0,1]
fn get_world_position(depth: f32, uv: vec2<f32>, inverse_proj: mat4x4<f32>, inverse_view: mat4x4<f32>) -> vec3<f32> {
    // Convert UV [0,1] to NDC [-1,1]
    let ndc = uv * 2.0 - 1.0;

    // Build clip-space position (note: WGPU depth is [0,1])
    let clip_pos = vec4<f32>(ndc.x, ndc.y, depth, 1.0);

    // Unproject through inverse matrices
    let view_pos = inverse_proj * clip_pos;
    let world_pos = inverse_view * view_pos;

    // Perspective divide
    return world_pos.xyz / world_pos.w;
}

/// Unpack G-Buffer data to BRDF-ready format
fn unpack_gbuffer(albedo_metalness: vec4<f32>, normal_roughness: vec4<f32>) -> GBufferData {
    var data: GBufferData;

    let albedo = albedo_metalness.rgb;
    let metalness = albedo_metalness.a;

    data.world_normal = normalize(normal_roughness.xyz);
    data.roughness = max(normal_roughness.a, 0.04); // Clamp minimum roughness

    // Metalness workflow:
    // - Diffuse: metals have no diffuse, dielectrics have full albedo
    // - Specular: metals reflect their albedo, dielectrics have ~4% reflectance
    data.diffuse_color = albedo * (1.0 - metalness);
    data.specular_color = mix(vec3<f32>(0.04), albedo, metalness);

    return data;
}

// ============================================================================
// Normal Mapping Utilities
// ============================================================================

/// Perturb normal using derivative-based tangent reconstruction
/// Eliminates need for per-vertex tangent data
fn perturb_normal(N: vec3<f32>, world_pos: vec3<f32>, uv: vec2<f32>, normal_map: vec3<f32>) -> vec3<f32> {
    // Screen-space derivatives
    let dp1 = dpdx(world_pos);
    let dp2 = dpdy(world_pos);
    let duv1 = dpdx(uv);
    let duv2 = dpdy(uv);

    // Solve for tangent frame
    let dp2perp = cross(dp2, N);
    let dp1perp = cross(N, dp1);
    let T = dp2perp * duv1.x + dp1perp * duv2.x;
    let B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Scale-invariant normalization
    let invmax = inverseSqrt(max(dot(T, T), dot(B, B)));
    let TBN = mat3x3<f32>(T * invmax, B * invmax, N);

    // Handle missing normal map
    var map = normal_map;
    if dot(map, map) == 0.0 {
        map = vec3<f32>(0.5, 0.5, 1.0);
    }

    // Convert [0,1] to [-1,1] and transform
    map = map * 2.0 - 1.0;
    return normalize(TBN * map);
}

/// Apply bidirectional material modifier
/// modifier < 0.5: reduce value (multiply)
/// modifier = 0.5: unchanged
/// modifier > 0.5: increase toward 1.0 (lerp)
fn apply_modifier(value: f32, modifier: f32) -> f32 {
    let mid = 127.0 / 255.0;
    if modifier <= mid {
        return value * modifier / mid;
    } else {
        return mix(value, 1.0, (modifier - mid) / (128.0 / 255.0));
    }
}

// ============================================================================
// Light Attenuation
// ============================================================================

/// Point light distance attenuation with inverse-square falloff
fn point_light_attenuation(distance_sq: f32) -> f32 {
    return 1.0 / (distance_sq + 1.0);
}

/// Spot light angular attenuation
/// light_dir: direction from light to surface (normalized)
/// spot_dir: light's pointing direction (normalized)
/// inner_angle: cosine of inner cone angle (full intensity)
/// outer_angle: cosine of outer cone angle (zero intensity)
fn spot_light_attenuation(light_dir: vec3<f32>, spot_dir: vec3<f32>, inner_angle: f32, outer_angle: f32) -> f32 {
    let cos_angle = dot(light_dir, spot_dir);
    return saturate((cos_angle - outer_angle) / (inner_angle - outer_angle + EPSILON));
}

// ============================================================================
// Area Light Utilities
// ============================================================================

/// Sphere horizon clipping for accurate sphere light irradiance
/// Handles the case where part of the sphere is below the surface horizon
fn sphere_horizon_cos_wrap(n_dot_l: f32, sin_alpha_sq: f32) -> f32 {
    let sin_alpha = sqrt(sin_alpha_sq);

    if n_dot_l < sin_alpha {
        let clamped_n_dot_l = max(n_dot_l, -sin_alpha);

        // Accurate sphere irradiance formula
        let cos_beta = clamped_n_dot_l;
        let sin_beta = sqrt(1.0 - cos_beta * cos_beta);
        let tan_beta = sin_beta / (cos_beta + EPSILON);

        let x = sqrt(1.0 / sin_alpha_sq - 1.0);
        let y = -x / tan_beta;
        let z = sin_beta * sqrt(max(1.0 - y * y, 0.0));

        let result = clamped_n_dot_l * acos(clamp(y, -1.0, 1.0)) - x * z + atan2(z, x) / sin_alpha_sq;
        return saturate(result * INV_PI);
    }

    return saturate(n_dot_l);
}

// ============================================================================
// Color Utilities
// ============================================================================

/// Convert linear RGB to sRGB
fn linear_to_srgb(color: vec3<f32>) -> vec3<f32> {
    let cutoff = color < vec3<f32>(0.0031308);
    let higher = vec3<f32>(1.055) * pow(color, vec3<f32>(1.0/2.4)) - vec3<f32>(0.055);
    let lower = color * vec3<f32>(12.92);
    return select(higher, lower, cutoff);
}

/// Convert sRGB to linear RGB
fn srgb_to_linear(color: vec3<f32>) -> vec3<f32> {
    let cutoff = color < vec3<f32>(0.04045);
    let higher = pow((color + vec3<f32>(0.055)) / vec3<f32>(1.055), vec3<f32>(2.4));
    let lower = color / vec3<f32>(12.92);
    return select(higher, lower, cutoff);
}

/// Luminance from RGB (Rec. 709)
fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}
