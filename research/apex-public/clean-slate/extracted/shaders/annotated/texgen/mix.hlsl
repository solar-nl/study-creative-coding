// ============================================================================
// READABLE VERSION: Linear Mix (Blend)
// Original: ../texgen/mix.hlsl (14 lines)
//
// Algorithm: Linear interpolation between two textures using a constant factor.
//            The fundamental blending operation: output = lerp(A, B, amount)
//
// Math:
//   output = texture1 * (1 - amount) + texture2 * amount
//
// Behavior:
//   amount = 0.0 → 100% texture1
//   amount = 0.5 → 50% blend of both
//   amount = 1.0 → 100% texture2
//
// This is the simplest form of texture blending, with a constant blend
// factor across the entire image. For spatially-varying blending, use
// mixmap.hlsl which reads the blend factor from a third texture.
//
// Use Cases:
//   - Cross-fade between textures
//   - Animated transitions
//   - Opacity control
//   - Texture layering
//
// Parameters:
//   texgenParams.x — Blend amount (0-1)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D texture1 : register(t0);
Texture2D texture2 : register(t1);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Constant-Factor Linear Blend
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color1 = texture1.Sample(linearSampler, texCoord);
    float4 color2 = texture2.Sample(linearSampler, texCoord);

    return lerp(color1, color2, texgenParams.x);
}
