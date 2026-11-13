// ============================================================================
// READABLE VERSION: RGB Channel Curves
// Original: ../texgen/curves.hlsl (19 lines)
//
// Algorithm: Per-channel color remapping using a lookup texture (LUT).
//            Each RGBA channel is independently remapped through a
//            1D lookup texture, enabling flexible color grading.
//
// This is identical in concept to the materials/palette.hlsl shader,
// but implemented in the texgen pipeline.
//
// How LUT Curves Work:
//   For each channel:
//     output[i] = curvesTexture.Sample(input[i], 0)[i]
//
//   The curves texture is a 1D gradient where:
//   - X coordinate = input value (0-1)
//   - Each channel stores its own curve (R→R, G→G, B→B, A→A)
//
// Curve Types Possible:
//   - Linear (identity): No change
//   - S-curve: Increased contrast
//   - Gamma: Brightness adjustment
//   - Invert: White becomes black
//   - Posterize: Stepped values
//   - Any arbitrary remapping
//
// Use Cases:
//   - Color grading
//   - Levels/curves adjustment (like Photoshop)
//   - Contrast enhancement
//   - Color channel separation
//
// Parameters:
//   Texture0 — Input image
//   Texture1 — Curves lookup texture (1D RGBA gradient)
// ============================================================================

SamplerState linearSampler : register(s0);
SamplerState curvesSampler : register(s1);

Texture2D inputTexture : register(t0);
Texture2D curvesTexture : register(t1);

// ============================================================================
// Pixel Shader — Per-Channel Curve Lookup
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // Remap each channel through its corresponding curve
    float4 result;
    result.x = curvesTexture.SampleLevel(curvesSampler, float2(color.x, 0), 0).x;
    result.y = curvesTexture.SampleLevel(curvesSampler, float2(color.y, 0), 0).y;
    result.z = curvesTexture.SampleLevel(curvesSampler, float2(color.z, 0), 0).z;
    result.w = curvesTexture.SampleLevel(curvesSampler, float2(color.w, 0), 0).w;

    return result;
}
