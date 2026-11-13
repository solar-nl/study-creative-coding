// dof.wgsl - Depth of Field Effect
//
// Implements a disc-based blur weighted by Circle of Confusion (CoC).
// Uses a 16-sample Poisson disc pattern for the blur kernel.
//
// Reference: [07-post-processing.md](../../07-post-processing.md#depth-of-field)

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;

/// 16-sample Poisson disc pattern
/// Pre-computed points distributed to minimize clustering
const POISSON_DISC: array<vec2<f32>, 16> = array<vec2<f32>, 16>(
    vec2<f32>(-0.94201624, -0.39906216),
    vec2<f32>( 0.94558609, -0.76890725),
    vec2<f32>(-0.09418410, -0.92938870),
    vec2<f32>( 0.34495938,  0.29387760),
    vec2<f32>(-0.91588581,  0.45771432),
    vec2<f32>(-0.81544232, -0.87912464),
    vec2<f32>(-0.38277543,  0.27676845),
    vec2<f32>( 0.97484398,  0.75648379),
    vec2<f32>( 0.44323325, -0.97511554),
    vec2<f32>( 0.53742981, -0.47373420),
    vec2<f32>(-0.26496911, -0.41893023),
    vec2<f32>( 0.79197514,  0.19090188),
    vec2<f32>(-0.24188840,  0.99706507),
    vec2<f32>(-0.81409955,  0.91437590),
    vec2<f32>( 0.19984126,  0.78641367),
    vec2<f32>( 0.14383161, -0.14100790),
);

// ============================================================================
// Bind Groups
// ============================================================================

struct DofParams {
    /// Focus distance in world units
    focus_distance: f32,
    /// Focus range (depth of field width)
    focus_range: f32,
    /// Near blur start (relative to focus)
    near_blur: f32,
    /// Far blur start (relative to focus)
    far_blur: f32,
    /// Maximum blur radius in pixels
    max_blur: f32,
    /// Camera near plane
    near_plane: f32,
    /// Camera far plane
    far_plane: f32,
    padding: f32,
}

@group(0) @binding(0) var color_texture: texture_2d<f32>;
@group(0) @binding(1) var depth_texture: texture_depth_2d;
@group(0) @binding(2) var texture_sampler: sampler;
@group(0) @binding(3) var<uniform> params: DofParams;

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert depth buffer value to linear depth
fn linearize_depth(depth: f32, near: f32, far: f32) -> f32 {
    return (2.0 * near * far) / (far + near - depth * (far - near));
}

/// Calculate Circle of Confusion (CoC) from linear depth
///
/// Returns signed CoC: negative for near blur, positive for far blur
fn calculate_coc(linear_depth: f32) -> f32 {
    let focus = params.focus_distance;
    let range = params.focus_range;

    // Distance from focus plane
    let delta = linear_depth - focus;

    var coc: f32;
    if delta < 0.0 {
        // Near field (in front of focus)
        coc = -smoothstep(0.0, -params.near_blur, delta);
    } else {
        // Far field (behind focus)
        coc = smoothstep(0.0, params.far_blur, delta);
    }

    return coc * params.max_blur;
}

/// Alternative CoC calculation using thin lens model
fn calculate_coc_physical(
    linear_depth: f32,
    focus_dist: f32,
    aperture: f32,
    focal_length: f32,
) -> f32 {
    // Thin lens equation: CoC = |A * f * (S - D) / (D * (S - f))|
    // A = aperture diameter
    // f = focal length
    // S = focus distance
    // D = depth
    let a = aperture;
    let f = focal_length;
    let s = focus_dist;
    let d = linear_depth;

    let coc = abs(a * f * (s - d) / (d * (s - f)));
    return min(coc, params.max_blur);
}

// ============================================================================
// Blur Functions
// ============================================================================

/// Poisson disc blur with CoC weighting
fn poisson_blur(uv: vec2<f32>, coc: f32, texel_size: vec2<f32>) -> vec3<f32> {
    if abs(coc) < 0.5 {
        // Skip blur for in-focus pixels
        return textureSample(color_texture, texture_sampler, uv).rgb;
    }

    var color = vec3<f32>(0.0);
    var weight_sum = 0.0;

    // Sample radius based on CoC
    let radius = abs(coc);

    for (var i: i32 = 0; i < 16; i = i + 1) {
        let offset = POISSON_DISC[i] * radius * texel_size;
        let sample_uv = uv + offset;

        // Sample color and depth at offset
        let sample_color = textureSample(color_texture, texture_sampler, sample_uv).rgb;
        let sample_depth_raw = textureSample(depth_texture, texture_sampler, sample_uv);
        let sample_depth = linearize_depth(sample_depth_raw, params.near_plane, params.far_plane);
        let sample_coc = calculate_coc(sample_depth);

        // Weight based on CoC comparison
        // Larger CoC samples contribute more (prevents sharp edges bleeding)
        let weight = select(1.0, abs(sample_coc) / radius, abs(sample_coc) < radius);

        color += sample_color * weight;
        weight_sum += weight;
    }

    return color / max(weight_sum, 0.0001);
}

/// Separable blur for performance (first pass)
fn blur_horizontal(uv: vec2<f32>, coc: f32, texel_size: f32) -> vec4<f32> {
    if abs(coc) < 0.5 {
        let color = textureSample(color_texture, texture_sampler, uv).rgb;
        return vec4<f32>(color, coc);
    }

    var color = vec3<f32>(0.0);
    var coc_sum = 0.0;
    var weight_sum = 0.0;

    let radius = abs(coc);
    let samples = 9;

    for (var i: i32 = -4; i <= 4; i = i + 1) {
        let offset = vec2<f32>(f32(i) * texel_size * radius / 4.0, 0.0);
        let sample_uv = uv + offset;

        let sample_color = textureSample(color_texture, texture_sampler, sample_uv).rgb;
        let sample_depth_raw = textureSample(depth_texture, texture_sampler, sample_uv);
        let sample_depth = linearize_depth(sample_depth_raw, params.near_plane, params.far_plane);
        let sample_coc = calculate_coc(sample_depth);

        // Gaussian weight
        let t = f32(i) / 4.0;
        let weight = exp(-t * t * 2.0);

        color += sample_color * weight;
        coc_sum += sample_coc * weight;
        weight_sum += weight;
    }

    return vec4<f32>(color / weight_sum, coc_sum / weight_sum);
}

/// Separable blur (second pass - vertical)
fn blur_vertical(uv: vec2<f32>, coc: f32, texel_size: f32) -> vec3<f32> {
    if abs(coc) < 0.5 {
        return textureSample(color_texture, texture_sampler, uv).rgb;
    }

    var color = vec3<f32>(0.0);
    var weight_sum = 0.0;

    let radius = abs(coc);

    for (var i: i32 = -4; i <= 4; i = i + 1) {
        let offset = vec2<f32>(0.0, f32(i) * texel_size * radius / 4.0);
        let sample_color = textureSample(color_texture, texture_sampler, uv + offset).rgb;

        let t = f32(i) / 4.0;
        let weight = exp(-t * t * 2.0);

        color += sample_color * weight;
        weight_sum += weight;
    }

    return color / weight_sum;
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
    // Get texel size from texture dimensions
    let dims = textureDimensions(color_texture);
    let texel_size = vec2<f32>(1.0 / f32(dims.x), 1.0 / f32(dims.y));

    // Sample depth and calculate CoC
    let depth_raw = textureSample(depth_texture, texture_sampler, in.uv);
    let linear_depth = linearize_depth(depth_raw, params.near_plane, params.far_plane);
    let coc = calculate_coc(linear_depth);

    // Apply blur based on CoC
    let blurred = poisson_blur(in.uv, coc, texel_size);

    return vec4<f32>(blurred, 1.0);
}

/// Alternative: CoC calculation pass (for multi-pass DoF)
@fragment
fn fs_coc(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(color_texture, texture_sampler, in.uv).rgb;
    let depth_raw = textureSample(depth_texture, texture_sampler, in.uv);
    let linear_depth = linearize_depth(depth_raw, params.near_plane, params.far_plane);
    let coc = calculate_coc(linear_depth);

    // Store color.rgb and CoC in alpha
    return vec4<f32>(color, coc / params.max_blur);
}
