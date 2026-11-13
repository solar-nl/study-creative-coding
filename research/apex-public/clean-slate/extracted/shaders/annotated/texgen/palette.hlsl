// ============================================================================
// READABLE VERSION: Palette Lookup (Texgen)
// Original: ../texgen/palette.hlsl (30 lines)
//
// Algorithm: Maps input values to colors using a palette/gradient texture.
//            Supports two modes: single-channel mapping and per-channel mapping.
//
// Mode 1: Single Channel to Full Color (data1.z == 0)
//   - Samples one channel from input
//   - Uses that value to look up full RGBA from palette row
//   - Common for grayscale → color conversion
//
// Mode 2: Per-Channel Mapping (data1.z != 0)
//   - Each input channel independently looks up palette
//   - Returns specified channel from each lookup
//   - Enables independent channel curves
//
// Palette Texture Format:
//   - X axis: Input value (0-1)
//   - Y axis: Palette variation/row selection
//   - Multiple palette rows allow switching between color schemes
//
// Use Cases:
//   - Color grading with preset palettes
//   - False color visualization
//   - Artistic color mapping
//   - Switchable color themes
//
// Parameters:
//   texgenParams.x — Control channel selector (0-3 = RGBA)
//   texgenParams.y — Palette row/line to sample from
//   texgenParams.z — Mode (0 = single-channel, other = per-channel)
// ============================================================================

SamplerState clampSampler : register(s0);
SamplerState linearSampler : register(s1);
Texture2D inputTexture : register(t0);
Texture2D paletteTexture : register(t1);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Palette Lookup with Two Modes
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    int channel = (int)(texgenParams.x * 256);
    float paletteRow = texgenParams.y;

    // ========================================================================
    // Mode 1: Single Channel → Full Color
    // Sample one channel, use it to look up complete RGBA from palette
    // ========================================================================
    if (texgenParams.z == 0)
    {
        float controlValue = inputTexture.Sample(linearSampler, texCoord)[channel];
        return paletteTexture.Sample(linearSampler, float2(controlValue, paletteRow));
    }

    // ========================================================================
    // Mode 2: Per-Channel Lookup
    // Each RGBA channel independently looks up palette, extracts specified channel
    // ========================================================================
    float4 color = inputTexture.Sample(clampSampler, texCoord);
    float4 result;
    result.x = paletteTexture.SampleLevel(linearSampler, float2(color.x, paletteRow), 0)[channel];
    result.y = paletteTexture.SampleLevel(linearSampler, float2(color.y, paletteRow), 0)[channel];
    result.z = paletteTexture.SampleLevel(linearSampler, float2(color.z, paletteRow), 0)[channel];
    result.w = paletteTexture.SampleLevel(linearSampler, float2(color.w, paletteRow), 0)[channel];
    return result;
}
