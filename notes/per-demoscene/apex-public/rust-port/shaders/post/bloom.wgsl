// bloom.wgsl - Multi-Pass Bloom Effect
//
// Implements a 7-pass bloom pipeline:
// 1. Threshold extraction (bright pixels only)
// 2-4. Horizontal blur at multiple resolutions
// 5-7. Vertical blur and combine
//
// Reference: [07-post-processing.md](../../07-post-processing.md#bloom)

// ============================================================================
// Constants
// ============================================================================

/// Gaussian weights for 13-tap kernel (σ ≈ 4.0)
const BLUR_WEIGHTS: array<f32, 7> = array<f32, 7>(
    0.227027, 0.194596, 0.121621, 0.054054, 0.016216, 0.003243, 0.000486
);

const KERNEL_RADIUS: i32 = 6;

// ============================================================================
// Bind Groups
// ============================================================================

struct BloomParams {
    /// Brightness threshold for bloom extraction (default: 1.0)
    threshold: f32,
    /// Soft knee for threshold (default: 0.5)
    knee: f32,
    /// Bloom intensity multiplier (default: 1.0)
    intensity: f32,
    /// Texel size for current mip level
    texel_size_x: f32,
    texel_size_y: f32,
    /// Pass type: 0=threshold, 1=horizontal, 2=vertical, 3=combine
    pass_type: u32,
    padding: vec2<f32>,
}

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var input_sampler: sampler;
@group(0) @binding(2) var<uniform> params: BloomParams;

// For combine pass
@group(0) @binding(3) var bloom_texture: texture_2d<f32>;

// ============================================================================
// Helper Functions
// ============================================================================

/// Compute luminance
fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

/// Soft threshold function
///
/// Returns a smooth transition around the threshold value.
/// knee controls the softness of the transition.
fn soft_threshold(color: vec3<f32>, threshold: f32, knee: f32) -> vec3<f32> {
    let luma = luminance(color);

    // Knee curve parameters
    let knee_start = threshold - knee;
    let knee_end = threshold + knee;

    if luma < knee_start {
        return vec3<f32>(0.0);
    } else if luma < threshold {
        // Smooth interpolation in knee region
        let t = (luma - knee_start) / (knee * 2.0);
        let curve = t * t;
        return color * curve;
    } else {
        // Full contribution above threshold
        return color;
    }
}

/// Quadratic threshold curve (alternative)
fn quad_threshold(color: vec3<f32>, threshold: f32, knee: f32) -> vec3<f32> {
    let brightness = max(max(color.r, color.g), color.b);
    let soft = brightness - threshold + knee;
    let soft_clamped = clamp(soft, 0.0, 2.0 * knee);
    let soft_squared = soft_clamped * soft_clamped;
    let contribution = soft_squared / (4.0 * knee + 0.00001);

    var response = max(brightness - threshold, contribution);
    response = response / max(brightness, 0.00001);

    return color * response;
}

// ============================================================================
// Blur Functions
// ============================================================================

/// 13-tap Gaussian blur (horizontal)
fn blur_horizontal(uv: vec2<f32>) -> vec3<f32> {
    let texel = vec2<f32>(params.texel_size_x, 0.0);
    var color = textureSample(input_texture, input_sampler, uv).rgb * BLUR_WEIGHTS[0];

    for (var i: i32 = 1; i <= KERNEL_RADIUS; i = i + 1) {
        let offset = texel * f32(i);
        color += textureSample(input_texture, input_sampler, uv + offset).rgb * BLUR_WEIGHTS[i];
        color += textureSample(input_texture, input_sampler, uv - offset).rgb * BLUR_WEIGHTS[i];
    }

    return color;
}

/// 13-tap Gaussian blur (vertical)
fn blur_vertical(uv: vec2<f32>) -> vec3<f32> {
    let texel = vec2<f32>(0.0, params.texel_size_y);
    var color = textureSample(input_texture, input_sampler, uv).rgb * BLUR_WEIGHTS[0];

    for (var i: i32 = 1; i <= KERNEL_RADIUS; i = i + 1) {
        let offset = texel * f32(i);
        color += textureSample(input_texture, input_sampler, uv + offset).rgb * BLUR_WEIGHTS[i];
        color += textureSample(input_texture, input_sampler, uv - offset).rgb * BLUR_WEIGHTS[i];
    }

    return color;
}

/// Dual-filter downsampling for efficient blur
fn downsample_box(uv: vec2<f32>) -> vec3<f32> {
    let texel = vec2<f32>(params.texel_size_x, params.texel_size_y);

    // 4-tap box filter
    var color = textureSample(input_texture, input_sampler, uv + texel * vec2<f32>(-0.5, -0.5)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>( 0.5, -0.5)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>(-0.5,  0.5)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>( 0.5,  0.5)).rgb;

    return color * 0.25;
}

/// Kawase blur (single pass, adjustable radius via texel_size)
fn kawase_blur(uv: vec2<f32>) -> vec3<f32> {
    let texel = vec2<f32>(params.texel_size_x, params.texel_size_y);

    var color = textureSample(input_texture, input_sampler, uv).rgb * 4.0;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>(-1.0, -1.0)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>( 1.0, -1.0)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>(-1.0,  1.0)).rgb;
    color += textureSample(input_texture, input_sampler, uv + texel * vec2<f32>( 1.0,  1.0)).rgb;

    return color / 8.0;
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
    var color: vec3<f32>;

    switch params.pass_type {
        case 0u: {
            // Threshold pass - extract bright pixels
            let input = textureSample(input_texture, input_sampler, in.uv).rgb;
            color = quad_threshold(input, params.threshold, params.knee);
        }
        case 1u: {
            // Horizontal blur
            color = blur_horizontal(in.uv);
        }
        case 2u: {
            // Vertical blur
            color = blur_vertical(in.uv);
        }
        case 3u: {
            // Combine pass - add bloom to original
            let original = textureSample(input_texture, input_sampler, in.uv).rgb;
            let bloom = textureSample(bloom_texture, input_sampler, in.uv).rgb;
            color = original + bloom * params.intensity;
        }
        default: {
            color = textureSample(input_texture, input_sampler, in.uv).rgb;
        }
    }

    return vec4<f32>(color, 1.0);
}

// ============================================================================
// Separate Entry Points (Alternative Structure)
// ============================================================================

@fragment
fn fs_threshold(in: VertexOutput) -> @location(0) vec4<f32> {
    let input = textureSample(input_texture, input_sampler, in.uv).rgb;
    let color = quad_threshold(input, params.threshold, params.knee);
    return vec4<f32>(color, 1.0);
}

@fragment
fn fs_blur_h(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(blur_horizontal(in.uv), 1.0);
}

@fragment
fn fs_blur_v(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(blur_vertical(in.uv), 1.0);
}

@fragment
fn fs_combine(in: VertexOutput) -> @location(0) vec4<f32> {
    let original = textureSample(input_texture, input_sampler, in.uv).rgb;
    let bloom = textureSample(bloom_texture, input_sampler, in.uv).rgb;
    let color = original + bloom * params.intensity;
    return vec4<f32>(color, 1.0);
}
