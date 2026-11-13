// ssao.wgsl - Screen-Space Ambient Occlusion
//
// Implements SSAO using a golden angle spiral sampling pattern.
// Samples depth around each pixel to estimate local occlusion.
//
// Reference: [07-post-processing.md](../../07-post-processing.md#ssao)

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;

/// Golden angle in radians (137.5 degrees)
const GOLDEN_ANGLE: f32 = 2.39996323;

/// Number of samples per pixel
const SAMPLE_COUNT: i32 = 16;

// ============================================================================
// Bind Groups
// ============================================================================

struct SsaoParams {
    /// Sample radius in world units
    radius: f32,
    /// Occlusion power/intensity
    intensity: f32,
    /// Bias to prevent self-occlusion
    bias: f32,
    /// Falloff distance
    falloff: f32,
    /// Camera near plane
    near_plane: f32,
    /// Camera far plane
    far_plane: f32,
    /// Texel size (1/width, 1/height)
    texel_size: vec2<f32>,
}

struct CameraUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    inverse_view: mat4x4<f32>,
    inverse_projection: mat4x4<f32>,
}

@group(0) @binding(0) var depth_texture: texture_depth_2d;
@group(0) @binding(1) var normal_texture: texture_2d<f32>;
@group(0) @binding(2) var noise_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var<uniform> params: SsaoParams;
@group(0) @binding(5) var<uniform> camera: CameraUniforms;

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert depth buffer value to linear depth
fn linearize_depth(depth: f32) -> f32 {
    let near = params.near_plane;
    let far = params.far_plane;
    return (2.0 * near * far) / (far + near - depth * (far - near));
}

/// Reconstruct view-space position from UV and depth
fn reconstruct_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    // NDC coordinates
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
    let clip = vec4<f32>(ndc, depth, 1.0);

    // Unproject to view space
    let view_pos = camera.inverse_projection * clip;
    return view_pos.xyz / view_pos.w;
}

/// Generate golden angle spiral sample direction
fn golden_spiral_sample(index: i32, random_rotation: f32) -> vec2<f32> {
    let angle = f32(index) * GOLDEN_ANGLE + random_rotation;
    let radius = sqrt(f32(index) + 0.5) / sqrt(f32(SAMPLE_COUNT));
    return vec2<f32>(cos(angle), sin(angle)) * radius;
}

/// Construct a rotation matrix from normal
fn create_tbn(normal: vec3<f32>, noise: vec2<f32>) -> mat3x3<f32> {
    // Create tangent from noise
    var tangent = vec3<f32>(noise.x, noise.y, 0.0);
    tangent = normalize(tangent - normal * dot(tangent, normal));
    let bitangent = cross(normal, tangent);

    return mat3x3<f32>(tangent, bitangent, normal);
}

// ============================================================================
// SSAO Implementation
// ============================================================================

/// Calculate ambient occlusion for a single pixel
fn calculate_ssao(uv: vec2<f32>) -> f32 {
    // Sample depth and reconstruct position
    let depth_raw = textureSample(depth_texture, texture_sampler, uv);

    // Skip sky pixels
    if depth_raw >= 1.0 {
        return 1.0;
    }

    let view_pos = reconstruct_position(uv, depth_raw);
    let linear_depth = linearize_depth(depth_raw);

    // Sample normal (assumed to be in world space, convert to view)
    let world_normal = textureSample(normal_texture, texture_sampler, uv).rgb * 2.0 - 1.0;
    let view_normal = normalize((camera.view * vec4<f32>(world_normal, 0.0)).xyz);

    // Sample noise for rotation
    let noise_scale = vec2<f32>(f32(textureDimensions(depth_texture).x) / 4.0,
                                 f32(textureDimensions(depth_texture).y) / 4.0);
    let noise = textureSample(noise_texture, texture_sampler, uv * noise_scale).xy * 2.0 - 1.0;

    // Build TBN matrix
    let tbn = create_tbn(view_normal, noise);

    // Scale radius by depth (closer = smaller radius in screen space)
    let radius_scale = params.radius / linear_depth;

    var occlusion = 0.0;

    // Sample hemisphere
    for (var i: i32 = 0; i < SAMPLE_COUNT; i = i + 1) {
        // Generate sample direction in tangent space
        let spiral = golden_spiral_sample(i, noise.x * TAU);
        let hemisphere_offset = vec3<f32>(spiral.x, spiral.y, 0.5 + 0.5 * f32(i) / f32(SAMPLE_COUNT));

        // Transform to view space
        let sample_dir = tbn * normalize(hemisphere_offset);
        let sample_pos = view_pos + sample_dir * params.radius;

        // Project to screen space
        let clip_pos = camera.projection * vec4<f32>(sample_pos, 1.0);
        let ndc = clip_pos.xy / clip_pos.w;
        let sample_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);

        // Sample depth at projected position
        let sample_depth_raw = textureSample(depth_texture, texture_sampler, sample_uv);
        let sample_view_pos = reconstruct_position(sample_uv, sample_depth_raw);

        // Range check - occlusion falls off with distance
        let range_check = smoothstep(0.0, 1.0, params.radius / abs(view_pos.z - sample_view_pos.z));

        // Occlusion test
        let depth_diff = sample_view_pos.z - sample_pos.z;
        if depth_diff > params.bias && depth_diff < params.falloff {
            occlusion += range_check;
        }
    }

    // Normalize and invert
    let ao = 1.0 - (occlusion / f32(SAMPLE_COUNT)) * params.intensity;
    return clamp(ao, 0.0, 1.0);
}

/// Simplified SSAO without normal buffer (depth-only)
fn calculate_ssao_depth_only(uv: vec2<f32>) -> f32 {
    let depth_raw = textureSample(depth_texture, texture_sampler, uv);

    if depth_raw >= 1.0 {
        return 1.0;
    }

    let view_pos = reconstruct_position(uv, depth_raw);
    let linear_depth = linearize_depth(depth_raw);

    // Estimate normal from depth derivatives
    let depth_dx = textureSample(depth_texture, texture_sampler, uv + vec2<f32>(params.texel_size.x, 0.0));
    let depth_dy = textureSample(depth_texture, texture_sampler, uv + vec2<f32>(0.0, params.texel_size.y));

    let pos_dx = reconstruct_position(uv + vec2<f32>(params.texel_size.x, 0.0), depth_dx);
    let pos_dy = reconstruct_position(uv + vec2<f32>(0.0, params.texel_size.y), depth_dy);

    let view_normal = normalize(cross(pos_dx - view_pos, pos_dy - view_pos));

    // Random rotation from pixel position
    let pixel = vec2<i32>(uv * vec2<f32>(textureDimensions(depth_texture)));
    let noise_angle = f32((pixel.x * 73 + pixel.y * 179) % 256) / 256.0 * TAU;

    var occlusion = 0.0;

    for (var i: i32 = 0; i < SAMPLE_COUNT; i = i + 1) {
        let spiral = golden_spiral_sample(i, noise_angle);
        let offset_uv = uv + spiral * params.radius / linear_depth;

        let sample_depth = textureSample(depth_texture, texture_sampler, offset_uv);
        let sample_pos = reconstruct_position(offset_uv, sample_depth);

        let diff = sample_pos - view_pos;
        let dist = length(diff);
        let angle_factor = max(dot(normalize(diff), view_normal), 0.0);

        let range_check = smoothstep(params.falloff, 0.0, dist);
        occlusion += angle_factor * range_check * step(params.bias, dist);
    }

    return 1.0 - (occlusion / f32(SAMPLE_COUNT)) * params.intensity;
}

// ============================================================================
// Blur Pass (for denoising SSAO)
// ============================================================================

/// Edge-preserving blur for SSAO
fn blur_ssao(uv: vec2<f32>, ao_texture: texture_2d<f32>) -> f32 {
    let center_depth = textureSample(depth_texture, texture_sampler, uv);
    let center_ao = textureSample(ao_texture, texture_sampler, uv).r;

    var sum = center_ao;
    var weight_sum = 1.0;

    // 4×4 blur kernel
    for (var x: i32 = -2; x <= 2; x = x + 1) {
        for (var y: i32 = -2; y <= 2; y = y + 1) {
            if x == 0 && y == 0 {
                continue;
            }

            let offset = vec2<f32>(f32(x), f32(y)) * params.texel_size;
            let sample_depth = textureSample(depth_texture, texture_sampler, uv + offset);
            let sample_ao = textureSample(ao_texture, texture_sampler, uv + offset).r;

            // Depth-aware weight (preserve edges)
            let depth_diff = abs(linearize_depth(center_depth) - linearize_depth(sample_depth));
            let weight = exp(-depth_diff * 10.0);

            sum += sample_ao * weight;
            weight_sum += weight;
        }
    }

    return sum / weight_sum;
}

// ============================================================================
// Main Shader
// ============================================================================

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    let x = f32(vertex_index & 1u) * 4.0 - 1.0;
    let y = f32((vertex_index >> 1u) & 1u) * 4.0 - 1.0;
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>((x + 1.0) * 0.5, (1.0 - y) * 0.5);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let ao = calculate_ssao(in.uv);
    return vec4<f32>(ao, ao, ao, 1.0);
}

/// Alternative entry point using depth-only estimation
@fragment
fn fs_depth_only(in: VertexOutput) -> @location(0) vec4<f32> {
    let ao = calculate_ssao_depth_only(in.uv);
    return vec4<f32>(ao, ao, ao, 1.0);
}
