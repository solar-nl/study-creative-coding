// ============================================================================
// READABLE VERSION: Masked Mix (Map-Controlled Blend)
// Original: ../texgen/mixmap.hlsl (16 lines)
//
// Algorithm: Blends two textures using a third texture as a per-pixel mask.
//            Each pixel reads its blend factor from the mask texture,
//            enabling spatially-varying transitions.
//
// Math:
//   mask = mixMap.Sample(uv)[channel]
//   output = lerp(texture1, texture2, mask)
//
// Where mask values mean:
//   0.0 → Show texture1
//   0.5 → 50% blend
//   1.0 → Show texture2
//
// The mask can be:
//   - A grayscale gradient for smooth transitions
//   - A hard-edged shape for cutouts
//   - Procedural patterns for interesting blends
//   - Animated noise for dissolve effects
//
// Use Cases:
//   - Terrain blending (grass/dirt/rock)
//   - Masked overlays
//   - Shaped transitions (wipes)
//   - Damage/wear effects
//   - Dissolve animations
//
// Parameters:
//   texgenParams.x — Control channel from mask (0-3 = RGBA)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D texture1 : register(t0);
Texture2D texture2 : register(t1);
Texture2D mixMapTexture : register(t2);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Map-Based Blend
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Read blend factor from specified channel of mix map
    int channel = (int)(texgenParams.x * 256);
    float blendAmount = mixMapTexture.Sample(linearSampler, texCoord)[channel];

    // Sample both textures
    float4 color1 = texture1.Sample(linearSampler, texCoord);
    float4 color2 = texture2.Sample(linearSampler, texCoord);

    return lerp(color1, color2, blendAmount);
}
