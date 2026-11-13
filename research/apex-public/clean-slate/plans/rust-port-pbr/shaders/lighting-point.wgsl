// lighting-point.wgsl - Deferred lighting for point, spot, and directional lights
//
// Reads G-Buffer and computes Cook-Torrance BRDF per light.
// Output is additively blended into HDR color buffer.

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;
const INV_PI: f32 = 0.31830988618;
const EPSILON: f32 = 0.0001;

// ============================================================================
// Bind Groups
// ============================================================================

// Group 0: Scene data
struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    light_count: vec4<f32>,
    // lights array not used - we pass per-light data separately
    @size(512) _lights_padding: u32, // 8 lights × 64 bytes
    resolution: vec4<f32>,
    inverse_view: mat4x4<f32>,
    inverse_projection: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> scene: SceneUniforms;

// Group 1: G-Buffer textures
@group(1) @binding(0) var gbuffer_sampler: sampler;
@group(1) @binding(1) var albedo_metalness_texture: texture_2d<f32>;  // RT0
@group(1) @binding(2) var normal_roughness_texture: texture_2d<f32>; // RT1
@group(1) @binding(3) var depth_texture: texture_2d<f32>;            // Depth

// Group 2: Per-light data
struct LightUniforms {
    position: vec4<f32>,    // xyz = position (point/spot) or direction (dir), w = type
    color: vec4<f32>,       // xyz = color, w = intensity
    params: vec4<f32>,      // x = radius, y = inner_angle, z = outer_angle, w = reserved
    direction: vec4<f32>,   // xyz = spot direction (normalized), w = reserved
}

@group(2) @binding(0) var<uniform> light: LightUniforms;

// ============================================================================
// Vertex Stage - Full-screen triangle
// ============================================================================

struct FullscreenOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_fullscreen(@builtin(vertex_index) vertex_index: u32) -> FullscreenOutput {
    var out: FullscreenOutput;

    // Generate a triangle that covers clip space [-1,1] × [-1,1]
    // Vertices: (-1,-1), (3,-1), (-1,3) - oversized to cover entire screen
    let x = f32(i32(vertex_index) / 2) * 4.0 - 1.0;
    let y = f32(i32(vertex_index) % 2) * 4.0 - 1.0;

    out.clip_position = vec4<f32>(x, y, 0.0, 1.0);

    // Convert to UV coordinates [0,1]
    // Note: Y is flipped for WGPU's top-left origin
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

/// Reconstruct world position from depth buffer
fn get_world_position(depth: f32, uv: vec2<f32>) -> vec3<f32> {
    // Convert UV [0,1] to NDC [-1,1]
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);

    // Build clip-space position (WGPU depth is [0,1])
    let clip_pos = vec4<f32>(ndc.x, ndc.y, depth, 1.0);

    // Unproject: clip -> view -> world
    let view_pos = scene.inverse_projection * clip_pos;
    let world_pos = scene.inverse_view * view_pos;

    return world_pos.xyz / world_pos.w;
}

// ============================================================================
// G-Buffer Unpacking
// ============================================================================

struct GBufferData {
    world_normal: vec3<f32>,
    diffuse_color: vec3<f32>,
    specular_color: vec3<f32>,
    roughness: f32,
}

fn unpack_gbuffer(pixel: vec2<i32>) -> GBufferData {
    var data: GBufferData;

    let t0 = textureLoad(albedo_metalness_texture, pixel, 0);
    let t1 = textureLoad(normal_roughness_texture, pixel, 0);

    let albedo = t0.rgb;
    let metalness = t0.a;

    data.world_normal = normalize(t1.xyz);
    data.roughness = max(t1.a, 0.04); // Minimum roughness to prevent singularities

    // Metalness workflow:
    // - Diffuse: metals absorb all light as specular, dielectrics diffuse their albedo
    // - Specular F0: metals reflect their albedo, dielectrics reflect ~4%
    data.diffuse_color = albedo * (1.0 - metalness);
    data.specular_color = mix(vec3<f32>(0.04), albedo, metalness);

    return data;
}

// ============================================================================
// BRDF Functions
// ============================================================================

/// GGX Normal Distribution Function
fn D_GGX(a2: f32, n_dot_h: f32) -> f32 {
    let d = (n_dot_h * a2 - n_dot_h) * n_dot_h + 1.0;
    return a2 / (PI * d * d);
}

/// Schlick Fresnel Approximation
fn F_Schlick(specular_color: vec3<f32>, v_dot_h: f32) -> vec3<f32> {
    let Fc = pow5(1.0 - v_dot_h);
    // Edge tint: brighter reflections at grazing angles
    return saturate(50.0 * specular_color.g) * Fc + (1.0 - Fc) * specular_color;
}

/// Smith-GGX Height-Correlated Visibility Function
fn Vis_SmithJointApprox(a2: f32, n_dot_v: f32, n_dot_l: f32) -> f32 {
    let a = sqrt(a2);
    let Vis_SmithV = n_dot_l * (n_dot_v * (1.0 - a) + a);
    let Vis_SmithL = n_dot_v * (n_dot_l * (1.0 - a) + a);
    return 0.5 / (Vis_SmithV + Vis_SmithL + EPSILON);
}

/// Combined Cook-Torrance Specular BRDF
fn SpecularGGX(roughness: f32, specular_color: vec3<f32>, n_dot_v: f32, n_dot_l: f32, n_dot_h: f32, v_dot_h: f32) -> vec3<f32> {
    // Roughness^4 for perceptually linear control
    let a2 = roughness * roughness * roughness * roughness;

    let D = D_GGX(a2, n_dot_h);
    let Vis = Vis_SmithJointApprox(a2, n_dot_v, n_dot_l);
    let F = F_Schlick(specular_color, v_dot_h);

    return (D * Vis) * F;
}

// ============================================================================
// Light Type Implementations
// ============================================================================

/// Point light contribution
fn evaluate_point_light(gbuffer: GBufferData, world_pos: vec3<f32>, V: vec3<f32>) -> vec3<f32> {
    // Vector from surface to light
    let to_light = light.position.xyz - world_pos;
    let distance_sq = dot(to_light, to_light);

    // Inverse-square attenuation with bias to prevent infinity at zero distance
    let falloff = 1.0 / (distance_sq + 1.0);

    // Normalize light direction
    let L = normalize(to_light);

    // Compute dot products
    let N = gbuffer.world_normal;
    let H = normalize(V + L);

    let n_dot_l = max(dot(N, L), 0.0);
    let n_dot_v = saturate(abs(dot(N, V)) + EPSILON);
    let n_dot_h = saturate(dot(N, H));
    let v_dot_h = saturate(dot(V, H));

    // Early exit if surface faces away from light
    if n_dot_l <= 0.0 {
        return vec3<f32>(0.0);
    }

    // Evaluate BRDF
    let diffuse = gbuffer.diffuse_color * INV_PI;
    let specular = SpecularGGX(gbuffer.roughness, gbuffer.specular_color, n_dot_v, n_dot_l, n_dot_h, v_dot_h);

    // Combine with light color and attenuation
    let radiance = light.color.rgb * light.color.w * falloff;
    return (diffuse + specular) * radiance * n_dot_l;
}

/// Spot light contribution
fn evaluate_spot_light(gbuffer: GBufferData, world_pos: vec3<f32>, V: vec3<f32>) -> vec3<f32> {
    // Vector from surface to light
    let to_light = light.position.xyz - world_pos;
    let distance_sq = dot(to_light, to_light);
    let falloff = 1.0 / (distance_sq + 1.0);

    let L = normalize(to_light);
    let N = gbuffer.world_normal;
    let H = normalize(V + L);

    let n_dot_l = max(dot(N, L), 0.0);
    if n_dot_l <= 0.0 {
        return vec3<f32>(0.0);
    }

    // Angular attenuation
    let spot_dir = normalize(light.direction.xyz);
    let cos_angle = dot(-L, spot_dir);
    let inner_angle = light.params.y; // Cosine of inner cone
    let outer_angle = light.params.z; // Cosine of outer cone
    let angular_atten = saturate((cos_angle - outer_angle) / (inner_angle - outer_angle + EPSILON));

    if angular_atten <= 0.0 {
        return vec3<f32>(0.0);
    }

    let n_dot_v = saturate(abs(dot(N, V)) + EPSILON);
    let n_dot_h = saturate(dot(N, H));
    let v_dot_h = saturate(dot(V, H));

    let diffuse = gbuffer.diffuse_color * INV_PI;
    let specular = SpecularGGX(gbuffer.roughness, gbuffer.specular_color, n_dot_v, n_dot_l, n_dot_h, v_dot_h);

    let radiance = light.color.rgb * light.color.w * falloff * angular_atten;
    return (diffuse + specular) * radiance * n_dot_l;
}

/// Directional light contribution
fn evaluate_directional_light(gbuffer: GBufferData, V: vec3<f32>) -> vec3<f32> {
    // Light direction is stored in position (normalized, pointing toward light)
    let L = normalize(-light.position.xyz);
    let N = gbuffer.world_normal;
    let H = normalize(V + L);

    let n_dot_l = max(dot(N, L), 0.0);
    if n_dot_l <= 0.0 {
        return vec3<f32>(0.0);
    }

    let n_dot_v = saturate(abs(dot(N, V)) + EPSILON);
    let n_dot_h = saturate(dot(N, H));
    let v_dot_h = saturate(dot(V, H));

    let diffuse = gbuffer.diffuse_color * INV_PI;
    let specular = SpecularGGX(gbuffer.roughness, gbuffer.specular_color, n_dot_v, n_dot_l, n_dot_h, v_dot_h);

    // No distance attenuation for directional lights
    let radiance = light.color.rgb * light.color.w;
    return (diffuse + specular) * radiance * n_dot_l;
}

// ============================================================================
// Fragment Shaders
// ============================================================================

@fragment
fn fs_point_light(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    // Sample depth and check for valid geometry
    let depth = textureLoad(depth_texture, pixel, 0).x;
    let normal = textureLoad(normal_roughness_texture, pixel, 0).xyz;

    // Skip if no geometry (background/sky)
    if length(normal) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    // Unpack G-Buffer
    let gbuffer = unpack_gbuffer(pixel);

    // Reconstruct world position
    let world_pos = get_world_position(depth, in.uv);

    // View direction (surface to camera)
    let V = normalize(scene.camera_position.xyz - world_pos);

    // Evaluate lighting
    let light_type = i32(light.position.w);
    var result: vec3<f32>;

    if light_type == 0 {
        result = evaluate_point_light(gbuffer, world_pos, V);
    } else if light_type == 1 {
        result = evaluate_directional_light(gbuffer, V);
    } else {
        result = evaluate_spot_light(gbuffer, world_pos, V);
    }

    return vec4<f32>(result, 1.0);
}

// Separate entry points for each light type (if preferred over branching)

@fragment
fn fs_directional_light(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    let depth = textureLoad(depth_texture, pixel, 0).x;
    let normal = textureLoad(normal_roughness_texture, pixel, 0).xyz;

    if length(normal) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    let gbuffer = unpack_gbuffer(pixel);
    let world_pos = get_world_position(depth, in.uv);
    let V = normalize(scene.camera_position.xyz - world_pos);

    let result = evaluate_directional_light(gbuffer, V);
    return vec4<f32>(result, 1.0);
}

@fragment
fn fs_spot_light(in: FullscreenOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<i32>(in.clip_position.xy);

    let depth = textureLoad(depth_texture, pixel, 0).x;
    let normal = textureLoad(normal_roughness_texture, pixel, 0).xyz;

    if length(normal) < 0.1 || depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    let gbuffer = unpack_gbuffer(pixel);
    let world_pos = get_world_position(depth, in.uv);
    let V = normalize(scene.camera_position.xyz - world_pos);

    let result = evaluate_spot_light(gbuffer, world_pos, V);
    return vec4<f32>(result, 1.0);
}
