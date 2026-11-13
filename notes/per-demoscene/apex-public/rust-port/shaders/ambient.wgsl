// ambient.wgsl - IBL ambient lighting pass
//
// Adds image-based lighting contribution to the scene.
// This simplified implementation uses a constant ambient color rather than
// a full environment map, but the Fresnel-based energy balance is preserved.

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;
const INV_PI: f32 = 0.31830988618;

// ============================================================================
// Bind Groups
// ============================================================================

// Group 0: Scene data
struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    light_count: vec4<f32>,
    @size(512) _lights_padding: u32,
    resolution: vec4<f32>,
    inverse_view: mat4x4<f32>,
    inverse_projection: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> scene: SceneUniforms;

// Group 1: G-Buffer textures
@group(1) @binding(0) var gbuffer_sampler: sampler;
@group(1) @binding(1) var albedo_metalness_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_roughness_texture: texture_2d<f32>;
@group(1) @binding(3) var depth_texture: texture_2d<f32>;

// Group 2: Ambient parameters
struct AmbientUniforms {
    color: vec4<f32>,      // xyz = ambient color, w = intensity
    sky_color: vec4<f32>,  // xyz = sky color for hemisphere lighting (optional)
    ground_color: vec4<f32>, // xyz = ground color for hemisphere lighting (optional)
}

@group(2) @binding(0) var<uniform> ambient: AmbientUniforms;

// ============================================================================
// Vertex Stage
// ============================================================================

struct FullscreenOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> FullscreenOutput {
    var out: FullscreenOutput;

    let x = f32(i32(vertex_index) / 2) * 4.0 - 1.0;
    let y = f32(i32(vertex_index) % 2) * 4.0 - 1.0;

    out.clip_position = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>((x + 1.0) * 0.5, (1.0 - y) * 0.5);

    return out;
}

// ============================================================================
// Utility Functions
// ============================================================================

fn pow5(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2 * x;
}

fn get_world_position(depth: f32, uv: vec2<f32>) -> vec3<f32> {
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
    let clip_pos = vec4<f32>(ndc.x, ndc.y, depth, 1.0);
    let view_pos = scene.inverse_projection * clip_pos;
    let world_pos = scene.inverse_view * view_pos;
    return world_pos.xyz / world_pos.w;
}

// ============================================================================
// Fresnel Functions
// ============================================================================

/// Schlick Fresnel for ambient calculation
fn fresnel_schlick(cos_theta: f32, f0: vec3<f32>) -> vec3<f32> {
    return f0 + (vec3<f32>(1.0) - f0) * pow5(1.0 - cos_theta);
}

/// Roughness-adjusted Fresnel for IBL
/// Reduces Fresnel at grazing angles for rough surfaces
fn fresnel_schlick_roughness(cos_theta: f32, f0: vec3<f32>, roughness: f32) -> vec3<f32> {
    let smooth = vec3<f32>(1.0 - roughness);
    return f0 + (max(smooth, f0) - f0) * pow5(1.0 - cos_theta);
}

// ============================================================================
// Ambient Lighting
// ============================================================================

/// Simplified diffuse IBL using constant ambient color
/// Uses Fresnel to balance energy between diffuse and specular
fn diffuse_ibl(N: vec3<f32>, V: vec3<f32>, f0: vec3<f32>, albedo: vec3<f32>, metallic: f32, roughness: f32) -> vec3<f32> {
    let n_dot_v = max(dot(N, V), 0.0);

    // Fresnel term determines how much energy goes to specular reflection
    let F = fresnel_schlick_roughness(n_dot_v, f0, roughness);

    // Energy not reflected is available for diffuse
    // Metals have no diffuse component
    let kD = (vec3<f32>(1.0) - F) * (1.0 - metallic);

    // Apply ambient color
    let ambient_color = ambient.color.rgb * ambient.color.w;

    return kD * ambient_color * albedo * INV_PI;
}

/// Hemisphere ambient lighting (sky + ground)
/// Provides subtle variation based on normal direction
fn hemisphere_ambient(N: vec3<f32>, albedo: vec3<f32>, metallic: f32) -> vec3<f32> {
    // Interpolate between ground and sky based on normal.y
    let sky_weight = N.y * 0.5 + 0.5; // Map [-1,1] to [0,1]
    let hemisphere_color = mix(ambient.ground_color.rgb, ambient.sky_color.rgb, sky_weight);

    // Apply metallic darkening (metals don't have diffuse ambient)
    return hemisphere_color * albedo * (1.0 - metallic) * INV_PI;
}

// ============================================================================
// Fragment Shaders
// ============================================================================

/// Simple constant ambient
@fragment
fn fs_ambient_simple(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    // Sample G-Buffer
    let t0 = textureLoad(albedo_metalness_texture, pixel, 0);
    let t1 = textureLoad(normal_roughness_texture, pixel, 0);
    let depth = textureLoad(depth_texture, pixel, 0).x;

    // Skip background
    if length(t1.xyz) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    let albedo = t0.rgb;
    let metalness = t0.a;
    let normal = normalize(t1.xyz);
    let roughness = max(t1.a, 0.04);

    // Get world position and view direction
    let world_pos = get_world_position(depth, in.uv);
    let V = normalize(scene.camera_position.xyz - world_pos);

    // Compute F0
    let f0 = mix(vec3<f32>(0.04), albedo, metalness);

    // Calculate diffuse IBL contribution
    let result = diffuse_ibl(normal, V, f0, albedo, metalness, roughness);

    return vec4<f32>(result, 1.0);
}

/// Hemisphere ambient with sky/ground variation
@fragment
fn fs_ambient_hemisphere(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    let t0 = textureLoad(albedo_metalness_texture, pixel, 0);
    let t1 = textureLoad(normal_roughness_texture, pixel, 0);
    let depth = textureLoad(depth_texture, pixel, 0).x;

    if length(t1.xyz) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    let albedo = t0.rgb;
    let metalness = t0.a;
    let normal = normalize(t1.xyz);
    let roughness = max(t1.a, 0.04);

    let world_pos = get_world_position(depth, in.uv);
    let V = normalize(scene.camera_position.xyz - world_pos);

    let f0 = mix(vec3<f32>(0.04), albedo, metalness);

    // Combine Fresnel-based diffuse with hemisphere variation
    let n_dot_v = max(dot(normal, V), 0.0);
    let F = fresnel_schlick_roughness(n_dot_v, f0, roughness);
    let kD = (vec3<f32>(1.0) - F) * (1.0 - metalness);

    // Hemisphere color based on normal direction
    let sky_weight = normal.y * 0.5 + 0.5;
    let hemisphere_color = mix(
        ambient.ground_color.rgb * ambient.ground_color.w,
        ambient.sky_color.rgb * ambient.sky_color.w,
        sky_weight
    );

    let result = kD * hemisphere_color * albedo * INV_PI;

    return vec4<f32>(result, 1.0);
}

/// Full ambient with both constant and hemisphere components
@fragment
fn fs_ambient_full(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    let t0 = textureLoad(albedo_metalness_texture, pixel, 0);
    let t1 = textureLoad(normal_roughness_texture, pixel, 0);
    let depth = textureLoad(depth_texture, pixel, 0).x;

    if length(t1.xyz) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    let albedo = t0.rgb;
    let metalness = t0.a;
    let normal = normalize(t1.xyz);
    let roughness = max(t1.a, 0.04);

    let world_pos = get_world_position(depth, in.uv);
    let V = normalize(scene.camera_position.xyz - world_pos);

    let f0 = mix(vec3<f32>(0.04), albedo, metalness);
    let n_dot_v = max(dot(normal, V), 0.0);
    let F = fresnel_schlick_roughness(n_dot_v, f0, roughness);
    let kD = (vec3<f32>(1.0) - F) * (1.0 - metalness);

    // Constant ambient contribution
    let constant_ambient = ambient.color.rgb * ambient.color.w;

    // Hemisphere variation
    let sky_weight = normal.y * 0.5 + 0.5;
    let hemisphere_ambient = mix(
        ambient.ground_color.rgb * ambient.ground_color.w,
        ambient.sky_color.rgb * ambient.sky_color.w,
        sky_weight
    );

    // Combine: constant provides base, hemisphere adds variation
    let combined_ambient = constant_ambient + hemisphere_ambient;
    let result = kD * combined_ambient * albedo * INV_PI;

    return vec4<f32>(result, 1.0);
}
