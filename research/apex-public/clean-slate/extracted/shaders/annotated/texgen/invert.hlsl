// ============================================================================
// READABLE VERSION: Color Inversion
// Original: ../texgen/invert.hlsl (11 lines)
//
// Algorithm: Inverts all color channels by subtracting from 1.
//            The classic photographic negative effect.
//
// Math:
//   output = 1 - input
//
// This inverts all four RGBA channels. Note that inverting alpha
// will make opaque pixels transparent and vice versa, which may
// or may not be desired depending on use case.
//
// Color Theory:
//   Inversion produces the complementary color:
//   - Red (1,0,0) → Cyan (0,1,1)
//   - White (1,1,1) → Black (0,0,0)
//   - 50% gray → 50% gray (unchanged)
//
// Use Cases:
//   - Negative image effect
//   - Mask inversion
//   - Complementary color generation
//   - High-contrast visualization
//   - X-ray/film negative look
//
// Parameters:
//   None (full inversion of all channels)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);  // Unused but declared

// ============================================================================
// Pixel Shader — Invert All Channels
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    return 1 - inputTexture.Sample(linearSampler, texCoord);
}
