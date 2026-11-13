// ============================================================================
// READABLE VERSION: Two-Color Gradient Mapping (Colorize)
// Original: ../texgen/colorize.hlsl (18 lines)
//
// Algorithm: Maps a grayscale value to a two-color gradient.
//            Converts single-channel data to full color using linear
//            interpolation between two user-defined colors.
//
// How It Works:
//   1. Sample specified channel from input texture
//   2. Use that value (0-1) as interpolation factor
//   3. Lerp between Color1 and Color2
//
// This is the classic "false color" or "thermal imaging" effect when
// using contrasting colors, or a tint effect when colors are similar.
//
// Use Cases:
//   - Heat map visualization
//   - Duotone effects
//   - Grayscale to color conversion
//   - Data visualization
//   - Stylized rendering
//
// Parameters:
//   Color1 — Color at input value 0 (RGBA)
//   Color2 — Color at input value 1 (RGBA)
//   texgenParams.x — Control channel (0-3 = RGBA, stored as 0-1 → 0-255)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 Color1 : register(c1);
float4 Color2 : register(c2);
float4 texgenParams : register(c3);

// ============================================================================
// Pixel Shader — Map Single Channel to Color Gradient
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Select which channel to use as control value
    int controlChannel = (int)(texgenParams.x * 256);

    // Sample the control channel (0-1)
    float factor = inputTexture.Sample(linearSampler, texCoord)[controlChannel];

    // Interpolate between the two colors
    return lerp(Color1, Color2, factor);
}
