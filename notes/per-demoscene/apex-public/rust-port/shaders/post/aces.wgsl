// aces.wgsl - ACES Filmic Tone Mapping
//
// Implements the Academy Color Encoding System (ACES) tone mapping curve.
// Combines Reference Rendering Transform (RRT) + Output Device Transform (ODT)
// for cinematic color response.
//
// Reference: [07-post-processing.md](../../07-post-processing.md#aces-tone-mapping)

// ============================================================================
// Constants
// ============================================================================

/// Input matrix: sRGB → AP0 (ACES2065-1)
const SRGB_TO_AP0: mat3x3<f32> = mat3x3<f32>(
    vec3<f32>(0.4397010, 0.0897923, 0.0175440),
    vec3<f32>(0.3829780, 0.8134230, 0.1115440),
    vec3<f32>(0.1773350, 0.0967616, 0.8707040),
);

/// Output matrix: AP1 → sRGB
const AP1_TO_SRGB: mat3x3<f32> = mat3x3<f32>(
    vec3<f32>( 1.7050510, -0.1302820, -0.0240327),
    vec3<f32>(-0.6217921,  1.1408070, -0.1289690),
    vec3<f32>(-0.0832589, -0.0105248,  1.1530020),
);

/// AP0 → AP1 conversion
const AP0_TO_AP1: mat3x3<f32> = mat3x3<f32>(
    vec3<f32>( 1.4514393, -0.0765538, -0.0083161),
    vec3<f32>(-0.2365107,  1.1762297, -0.0060324),
    vec3<f32>(-0.2149286, -0.1001640,  1.0143490),
);

// RRT parameters
const RRT_GLOW_GAIN: f32 = 0.05;
const RRT_GLOW_MID: f32 = 0.08;

// ============================================================================
// Bind Groups
// ============================================================================

struct PostParams {
    /// Exposure adjustment (default: 1.0)
    exposure: f32,
    /// Gamma correction (default: 2.2)
    gamma: f32,
    /// Saturation multiplier (default: 1.0)
    saturation: f32,
    padding: f32,
}

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var input_sampler: sampler;
@group(0) @binding(2) var<uniform> params: PostParams;

// ============================================================================
// Helper Functions
// ============================================================================

/// Compute luminance using Rec. 709 coefficients
fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

/// Glow module for highlight recovery
fn glow_fwd(y_in: f32) -> f32 {
    let y = y_in;
    var glow_value: f32;
    if y <= 2.0 / 3.0 * RRT_GLOW_MID {
        glow_value = RRT_GLOW_GAIN;
    } else if y >= 2.0 * RRT_GLOW_MID {
        glow_value = 0.0;
    } else {
        glow_value = RRT_GLOW_GAIN * (RRT_GLOW_MID / y - 0.5);
    }
    return glow_value;
}

/// Red modifier for saturated reds
fn red_modifier(rgb_in: vec3<f32>) -> vec3<f32> {
    let hue_shift = 0.03;
    let r = rgb_in.r;
    let g = rgb_in.g;
    let b = rgb_in.b;

    if r > g && r > b {
        let saturation = 1.0 - min(g, b) / r;
        let hue_offset = hue_shift * saturation * saturation;
        return vec3<f32>(r, g + hue_offset, b);
    }
    return rgb_in;
}

// ============================================================================
// ACES Tone Mapping
// ============================================================================

/// Simplified ACES RRT + ODT approximation
///
/// Based on Stephen Hill's fit: https://github.com/TheRealMJP/BakingLab
fn aces_approx(color: vec3<f32>) -> vec3<f32> {
    // Transform to AP1 working space
    var v = AP0_TO_AP1 * (SRGB_TO_AP0 * color);

    // Apply glow
    let glow = glow_fwd(luminance(v));
    v = v * (1.0 + glow);

    // Red modifier
    v = red_modifier(v);

    // Clamp negative values
    v = max(v, vec3<f32>(0.0));

    // Apply S-curve (RRT + ODT combined)
    // Approximation: (v * (a * v + b)) / (v * (c * v + d) + e)
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    v = (v * (a * v + b)) / (v * (c * v + d) + e);

    // Transform back to sRGB
    v = AP1_TO_SRGB * v;

    // Clamp to valid range
    return clamp(v, vec3<f32>(0.0), vec3<f32>(1.0));
}

/// Full ACES tone mapping with exposure and saturation controls
fn aces_tonemap(hdr_color: vec3<f32>, exposure: f32, saturation: f32) -> vec3<f32> {
    // Apply exposure
    var color = hdr_color * exposure;

    // Apply tone mapping
    color = aces_approx(color);

    // Apply saturation adjustment
    let luma = luminance(color);
    color = mix(vec3<f32>(luma), color, saturation);

    return color;
}

/// sRGB gamma encoding
fn linear_to_srgb(linear: vec3<f32>) -> vec3<f32> {
    let cutoff = vec3<f32>(0.0031308);
    let higher = 1.055 * pow(linear, vec3<f32>(1.0 / 2.4)) - 0.055;
    let lower = linear * 12.92;
    return select(higher, lower, linear < cutoff);
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
    let hdr = textureSample(input_texture, input_sampler, in.uv).rgb;

    // Apply ACES tone mapping with parameters
    let tonemapped = aces_tonemap(hdr, params.exposure, params.saturation);

    // Apply gamma correction (sRGB encoding)
    let gamma_corrected = linear_to_srgb(tonemapped);

    return vec4<f32>(gamma_corrected, 1.0);
}
