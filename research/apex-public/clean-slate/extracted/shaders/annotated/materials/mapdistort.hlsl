// ============================================================================
// READABLE VERSION: Map Distortion (UV Displacement)
// Original: ../materials/mapdistort.hlsl (36 lines)
//
// Algorithm: Texture-based UV displacement with masking.
//            Uses a distortion texture to selectively offset UV coordinates.
//
// Technique:
//   1. Sample distortion texture at current UV
//   2. If distortion > 0.5 in either channel, apply offset
//   3. If no distortion (both < 0.5), discard pixel
//
// The threshold at 0.5 creates a binary mask — pixels with distortion map
// values above 0.5 get displaced, others are discarded (transparent).
//
// Use Cases:
//   - Heat shimmer effects
//   - Water ripple distortion
//   - Selective refraction overlay
//   - Masked displacement for transitions
//
// Parameters:
//   power.xy — UV offset amount in X and Y directions
//   Texture1 (Disto) — Distortion map (RG channels used as offset direction)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);       // Source image to distort
Texture2D distortionTexture : register(t1);  // Distortion/mask map

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    // Empty in original
}

cbuffer MaterialBuffer : register(b1)
{
    float2 power;  // Offset strength in UV units
}

// ============================================================================
// Pixel Shader — UV Displacement
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // ========================================================================
    // Sample Distortion Map
    //
    // The distortion texture's RG channels indicate:
    // - Values > 0.5: Apply offset in that direction
    // - Values <= 0.5: No distortion (masked out)
    //
    // The comparison "> 0.5" converts to 1 or 0
    // ========================================================================
    float2 distortion = distortionTexture.Sample(linearSampler, texCoord).rg;
    float2 mask = distortion > 0.5;

    // If no distortion in either channel, discard (transparent)
    if (!any(mask))
        discard;

    // ========================================================================
    // Apply UV Offset
    //
    // The mask (0 or 1) is multiplied by power to create the offset.
    // This means only pixels where distortion > 0.5 get displaced,
    // and they're displaced by the full 'power' amount.
    // ========================================================================
    float2 offsetUV = texCoord + mask * power;

    return inputTexture.Sample(linearSampler, offsetUV);
}
