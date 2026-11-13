// effects.wgsl - Miscellaneous Post-Processing Effects
//
// Contains: Film grain, Sharpen, Chromatic aberration, Vignette
// These are typically lightweight effects applied near the end of the chain.
//
// Reference: [07-post-processing.md](../../07-post-processing.md)

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;

// ============================================================================
// Bind Groups
// ============================================================================

struct EffectsParams {
    /// Time for animated effects (seconds)
    time: f32,
    /// Film grain intensity (0-1)
    grain_intensity: f32,
    /// Sharpen strength (0-2)
    sharpen_strength: f32,
    /// Chromatic aberration intensity (0-1)
    chromatic_intensity: f32,
    /// Vignette intensity (0-1)
    vignette_intensity: f32,
    /// Vignette radius (0-1, where 1 = corners)
    vignette_radius: f32,
    /// Texel size
    texel_size: vec2<f32>,
}

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var input_sampler: sampler;
@group(0) @binding(2) var<uniform> params: EffectsParams;

// ============================================================================
// Noise Functions
// ============================================================================

/// 3D noise hash function
fn hash3(p: vec3<f32>) -> f32 {
    var p3 = fract(p * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Simple 2D noise
fn noise2d(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);

    let a = hash3(vec3<f32>(i, 0.0));
    let b = hash3(vec3<f32>(i + vec2<f32>(1.0, 0.0), 0.0));
    let c = hash3(vec3<f32>(i + vec2<f32>(0.0, 1.0), 0.0));
    let d = hash3(vec3<f32>(i + vec2<f32>(1.0, 1.0), 0.0));

    let u = f * f * (3.0 - 2.0 * f);

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// 3D noise for animated grain
fn noise3d(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);

    let u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(mix(hash3(i + vec3<f32>(0.0, 0.0, 0.0)),
                hash3(i + vec3<f32>(1.0, 0.0, 0.0)), u.x),
            mix(hash3(i + vec3<f32>(0.0, 1.0, 0.0)),
                hash3(i + vec3<f32>(1.0, 1.0, 0.0)), u.x), u.y),
        mix(mix(hash3(i + vec3<f32>(0.0, 0.0, 1.0)),
                hash3(i + vec3<f32>(1.0, 0.0, 1.0)), u.x),
            mix(hash3(i + vec3<f32>(0.0, 1.0, 1.0)),
                hash3(i + vec3<f32>(1.0, 1.0, 1.0)), u.x), u.y),
        u.z
    );
}

// ============================================================================
// Film Grain
// ============================================================================

/// Apply film grain to color
fn apply_grain(color: vec3<f32>, uv: vec2<f32>, intensity: f32, time: f32) -> vec3<f32> {
    // Scale UV for grain frequency
    let grain_uv = uv * 1000.0;

    // Animated 3D noise using time
    let noise = noise3d(vec3<f32>(grain_uv, time * 60.0));

    // Center noise around 0 and scale
    let grain = (noise - 0.5) * intensity;

    // Apply grain (multiplicative for realistic look)
    let luminance = dot(color, vec3<f32>(0.299, 0.587, 0.114));
    let grain_amount = mix(1.0, 0.5, luminance); // Less grain in bright areas

    return color + color * grain * grain_amount;
}

/// Alternative: additive grain (simpler)
fn apply_grain_additive(color: vec3<f32>, uv: vec2<f32>, intensity: f32, time: f32) -> vec3<f32> {
    let grain_uv = uv * 800.0;
    let noise = noise3d(vec3<f32>(grain_uv, time * 30.0));
    let grain = (noise - 0.5) * 2.0 * intensity;
    return color + vec3<f32>(grain);
}

// ============================================================================
// Sharpen (Laplacian)
// ============================================================================

/// Sharpen using Laplacian filter
fn apply_sharpen(uv: vec2<f32>, strength: f32) -> vec3<f32> {
    let texel = params.texel_size;

    // Sample center and 4 neighbors
    let center = textureSample(input_texture, input_sampler, uv).rgb;
    let north = textureSample(input_texture, input_sampler, uv + vec2<f32>(0.0, -texel.y)).rgb;
    let south = textureSample(input_texture, input_sampler, uv + vec2<f32>(0.0, texel.y)).rgb;
    let east = textureSample(input_texture, input_sampler, uv + vec2<f32>(texel.x, 0.0)).rgb;
    let west = textureSample(input_texture, input_sampler, uv + vec2<f32>(-texel.x, 0.0)).rgb;

    // Laplacian: center * 4 - neighbors
    let laplacian = center * 4.0 - (north + south + east + west);

    // Blend original with sharpened
    return center + laplacian * strength;
}

/// Unsharp mask (alternative sharpen)
fn apply_unsharp_mask(uv: vec2<f32>, strength: f32) -> vec3<f32> {
    let texel = params.texel_size;

    // Box blur for comparison
    var blur = vec3<f32>(0.0);
    for (var x: i32 = -1; x <= 1; x = x + 1) {
        for (var y: i32 = -1; y <= 1; y = y + 1) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel;
            blur += textureSample(input_texture, input_sampler, uv + offset).rgb;
        }
    }
    blur /= 9.0;

    let original = textureSample(input_texture, input_sampler, uv).rgb;
    let detail = original - blur;

    return original + detail * strength;
}

// ============================================================================
// Chromatic Aberration
// ============================================================================

/// Apply radial chromatic aberration
fn apply_chromatic_aberration(uv: vec2<f32>, intensity: f32) -> vec3<f32> {
    // Distance from center
    let center = vec2<f32>(0.5, 0.5);
    let offset = uv - center;
    let dist = length(offset);

    // Aberration increases with distance from center (quadratic)
    let aberration = intensity * dist * dist * 0.1;

    // Offset each channel differently
    let uv_r = center + offset * (1.0 + aberration);
    let uv_g = uv; // Green stays centered
    let uv_b = center + offset * (1.0 - aberration);

    // Sample each channel
    let r = textureSample(input_texture, input_sampler, uv_r).r;
    let g = textureSample(input_texture, input_sampler, uv_g).g;
    let b = textureSample(input_texture, input_sampler, uv_b).b;

    return vec3<f32>(r, g, b);
}

/// Directional chromatic aberration (horizontal)
fn apply_chromatic_aberration_directional(uv: vec2<f32>, intensity: f32) -> vec3<f32> {
    let aberration = intensity * 0.01;

    let r = textureSample(input_texture, input_sampler, uv + vec2<f32>(aberration, 0.0)).r;
    let g = textureSample(input_texture, input_sampler, uv).g;
    let b = textureSample(input_texture, input_sampler, uv - vec2<f32>(aberration, 0.0)).b;

    return vec3<f32>(r, g, b);
}

// ============================================================================
// Vignette
// ============================================================================

/// Apply circular vignette
fn apply_vignette(color: vec3<f32>, uv: vec2<f32>, intensity: f32, radius: f32) -> vec3<f32> {
    let center = vec2<f32>(0.5, 0.5);
    let dist = length(uv - center);

    // Smooth falloff from radius to corners
    let vignette = smoothstep(radius, radius - 0.3, dist);

    // Mix between original and darkened
    return mix(color * (1.0 - intensity), color, vignette);
}

/// Elliptical vignette (accounts for aspect ratio)
fn apply_vignette_ellipse(color: vec3<f32>, uv: vec2<f32>, intensity: f32, aspect: f32) -> vec3<f32> {
    let center = vec2<f32>(0.5, 0.5);
    var offset = uv - center;
    offset.x *= aspect; // Correct for aspect ratio

    let dist = length(offset);
    let vignette = 1.0 - smoothstep(0.4, 0.8, dist);

    return color * mix(1.0 - intensity, 1.0, vignette);
}

// ============================================================================
// Combined Effect Pass
// ============================================================================

/// Apply all effects in sequence
fn apply_all_effects(uv: vec2<f32>) -> vec3<f32> {
    var color: vec3<f32>;

    // Chromatic aberration (sample before other effects)
    if params.chromatic_intensity > 0.001 {
        color = apply_chromatic_aberration(uv, params.chromatic_intensity);
    } else {
        color = textureSample(input_texture, input_sampler, uv).rgb;
    }

    // Sharpen
    if params.sharpen_strength > 0.001 {
        // Re-sample with sharpening
        let sharpened = apply_sharpen(uv, params.sharpen_strength);
        // Blend with CA result if needed
        color = select(sharpened, color, params.chromatic_intensity > 0.001);
    }

    // Vignette
    if params.vignette_intensity > 0.001 {
        color = apply_vignette(color, uv, params.vignette_intensity, params.vignette_radius);
    }

    // Film grain (last, after tone mapping ideally)
    if params.grain_intensity > 0.001 {
        color = apply_grain(color, uv, params.grain_intensity, params.time);
    }

    return color;
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
    let color = apply_all_effects(in.uv);
    return vec4<f32>(color, 1.0);
}

// ============================================================================
// Individual Effect Entry Points
// ============================================================================

@fragment
fn fs_grain(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(input_texture, input_sampler, in.uv).rgb;
    let result = apply_grain(color, in.uv, params.grain_intensity, params.time);
    return vec4<f32>(result, 1.0);
}

@fragment
fn fs_sharpen(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = apply_sharpen(in.uv, params.sharpen_strength);
    return vec4<f32>(color, 1.0);
}

@fragment
fn fs_chromatic(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = apply_chromatic_aberration(in.uv, params.chromatic_intensity);
    return vec4<f32>(color, 1.0);
}

@fragment
fn fs_vignette(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(input_texture, input_sampler, in.uv).rgb;
    let result = apply_vignette(color, in.uv, params.vignette_intensity, params.vignette_radius);
    return vec4<f32>(result, 1.0);
}
