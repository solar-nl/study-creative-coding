// fxaa.wgsl - Fast Approximate Anti-Aliasing
//
// Implements FXAA 3.11 quality preset for edge smoothing.
// Detects edges via luminance contrast and blends along the edge direction.
//
// Reference: [07-post-processing.md](../../07-post-processing.md#fxaa)
// Original: Timothy Lottes, NVIDIA

// ============================================================================
// Constants
// ============================================================================

/// Minimum contrast threshold (relative)
const EDGE_THRESHOLD_MIN: f32 = 0.0312;

/// Edge detection threshold (relative to local max)
const EDGE_THRESHOLD: f32 = 0.125;

/// Number of search iterations along edge
const SEARCH_STEPS: i32 = 10;

/// Subpixel aliasing removal amount (0 = off, 1 = full)
const SUBPIXEL_QUALITY: f32 = 0.75;

// ============================================================================
// Bind Groups
// ============================================================================

struct FxaaParams {
    /// Texel size (1/width, 1/height)
    texel_size: vec2<f32>,
    /// Edge threshold (default: 0.125)
    edge_threshold: f32,
    /// Minimum edge threshold (default: 0.0312)
    edge_threshold_min: f32,
    /// Subpixel quality (default: 0.75)
    subpixel: f32,
    padding: vec3<f32>,
}

@group(0) @binding(0) var input_texture: texture_2d<f32>;
@group(0) @binding(1) var input_sampler: sampler;
@group(0) @binding(2) var<uniform> params: FxaaParams;

// ============================================================================
// Helper Functions
// ============================================================================

/// Compute luminance using perceptual weights
fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.299, 0.587, 0.114));
}

/// Sample texture and return luminance
fn sample_luma(uv: vec2<f32>) -> f32 {
    return luminance(textureSample(input_texture, input_sampler, uv).rgb);
}

/// Sample texture with offset
fn sample_offset(uv: vec2<f32>, offset: vec2<f32>) -> vec4<f32> {
    return textureSample(input_texture, input_sampler, uv + offset * params.texel_size);
}

// ============================================================================
// FXAA Implementation
// ============================================================================

fn fxaa(uv: vec2<f32>) -> vec3<f32> {
    let texel = params.texel_size;

    // Sample center and 4 neighbors
    let rgbM = textureSample(input_texture, input_sampler, uv).rgb;
    let lumaM = luminance(rgbM);

    let lumaNW = sample_luma(uv + texel * vec2<f32>(-1.0, -1.0));
    let lumaNE = sample_luma(uv + texel * vec2<f32>( 1.0, -1.0));
    let lumaSW = sample_luma(uv + texel * vec2<f32>(-1.0,  1.0));
    let lumaSE = sample_luma(uv + texel * vec2<f32>( 1.0,  1.0));

    let lumaN = sample_luma(uv + texel * vec2<f32>( 0.0, -1.0));
    let lumaS = sample_luma(uv + texel * vec2<f32>( 0.0,  1.0));
    let lumaW = sample_luma(uv + texel * vec2<f32>(-1.0,  0.0));
    let lumaE = sample_luma(uv + texel * vec2<f32>( 1.0,  0.0));

    // Find min/max luma
    let lumaMin = min(lumaM, min(min(lumaN, lumaS), min(lumaW, lumaE)));
    let lumaMax = max(lumaM, max(max(lumaN, lumaS), max(lumaW, lumaE)));

    // Contrast check - skip low contrast areas
    let lumaRange = lumaMax - lumaMin;
    if lumaRange < max(params.edge_threshold_min, lumaMax * params.edge_threshold) {
        return rgbM;
    }

    // Subpixel aliasing test
    let lumaL = (lumaN + lumaS + lumaE + lumaW) * 0.25;
    let rangeL = abs(lumaL - lumaM);
    var blendL = max(0.0, (rangeL / lumaRange) - 0.25) * (1.0 / 0.75);
    blendL = min(params.subpixel, blendL);

    // Compute edge direction
    let edgeH = abs((lumaNW + lumaNE) - 2.0 * lumaN) +
                abs((lumaW + lumaE) - 2.0 * lumaM) * 2.0 +
                abs((lumaSW + lumaSE) - 2.0 * lumaS);

    let edgeV = abs((lumaNW + lumaSW) - 2.0 * lumaW) +
                abs((lumaN + lumaS) - 2.0 * lumaM) * 2.0 +
                abs((lumaNE + lumaSE) - 2.0 * lumaE);

    let isHorizontal = edgeH >= edgeV;

    // Select edge endpoints
    var luma1: f32;
    var luma2: f32;
    var step_uv: vec2<f32>;

    if isHorizontal {
        luma1 = lumaN;
        luma2 = lumaS;
        step_uv = vec2<f32>(0.0, texel.y);
    } else {
        luma1 = lumaW;
        luma2 = lumaE;
        step_uv = vec2<f32>(texel.x, 0.0);
    }

    // Gradient check
    let gradient1 = luma1 - lumaM;
    let gradient2 = luma2 - lumaM;
    let isLuma1Steeper = abs(gradient1) >= abs(gradient2);

    let gradient_scaled = 0.25 * max(abs(gradient1), abs(gradient2));

    // Step in steeper direction
    var lumaLocalAvg: f32;
    if isLuma1Steeper {
        step_uv = -step_uv;
        lumaLocalAvg = 0.5 * (luma1 + lumaM);
    } else {
        lumaLocalAvg = 0.5 * (luma2 + lumaM);
    }

    // Search along edge
    var uv1 = uv + step_uv * 0.5;
    var uv2 = uv + step_uv * 0.5;

    var search_uv: vec2<f32>;
    if isHorizontal {
        search_uv = vec2<f32>(texel.x, 0.0);
    } else {
        search_uv = vec2<f32>(0.0, texel.y);
    }

    var lumaEnd1: f32 = 0.0;
    var lumaEnd2: f32 = 0.0;
    var reached1 = false;
    var reached2 = false;

    // Search in both directions
    for (var i: i32 = 0; i < SEARCH_STEPS; i = i + 1) {
        if !reached1 {
            uv1 -= search_uv;
            lumaEnd1 = sample_luma(uv1) - lumaLocalAvg;
            reached1 = abs(lumaEnd1) >= gradient_scaled;
        }
        if !reached2 {
            uv2 += search_uv;
            lumaEnd2 = sample_luma(uv2) - lumaLocalAvg;
            reached2 = abs(lumaEnd2) >= gradient_scaled;
        }
        if reached1 && reached2 {
            break;
        }
    }

    // Calculate blend amount based on edge distance
    var dist1: f32;
    var dist2: f32;
    if isHorizontal {
        dist1 = uv.x - uv1.x;
        dist2 = uv2.x - uv.x;
    } else {
        dist1 = uv.y - uv1.y;
        dist2 = uv2.y - uv.y;
    }

    let distFinal = min(dist1, dist2);
    let edgeLength = dist1 + dist2;

    var pixelOffset = -distFinal / edgeLength + 0.5;

    // Final blend
    let isLumaMSmaller = lumaM < lumaLocalAvg;
    let correctVariation = ((dist1 < dist2) ? lumaEnd1 : lumaEnd2) < 0.0 != isLumaMSmaller;

    var finalOffset: f32;
    if correctVariation {
        finalOffset = pixelOffset;
    } else {
        finalOffset = 0.0;
    }

    finalOffset = max(finalOffset, blendL);

    // Apply blend
    var finalUv = uv;
    if isHorizontal {
        finalUv.y += finalOffset * step_uv.y;
    } else {
        finalUv.x += finalOffset * step_uv.x;
    }

    return textureSample(input_texture, input_sampler, finalUv).rgb;
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
    let color = fxaa(in.uv);
    return vec4<f32>(color, 1.0);
}
