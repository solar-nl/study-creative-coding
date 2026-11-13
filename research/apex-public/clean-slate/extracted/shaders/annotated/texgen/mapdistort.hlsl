// ============================================================================
// READABLE VERSION: Map-Based UV Distortion
// Original: ../texgen/mapdistort.hlsl (18 lines)
//
// Algorithm: Displaces UV coordinates using values from a distortion map.
//            Simple direct offset — the map value IS the offset, not a gradient.
//
// Difference from Glass Shader:
//   - Glass: Uses gradient (derivative) of displacement map
//   - MapDistort: Uses raw displacement values directly
//
// This means:
//   - Glass creates refraction-like bending at edges
//   - MapDistort creates direct positional shifts
//
// Math:
//   distortValue = distortMap.Sample(uv)[channel]
//   outputUV = inputUV + distortValue * (amountX, amountY)
//
// The distortion map can be:
//   - Noise for organic warping
//   - Gradients for directional shifts
//   - Patterns for structured distortion
//
// Use Cases:
//   - Noise-based warping
//   - Heat shimmer (with animated noise)
//   - Fabric/cloth texture wrinkles
//   - Water surface ripples
//   - Organic shape distortion
//
// Parameters:
//   texgenParams.x — Control channel from distort map (0-3 = RGBA)
//   texgenParams.y — X displacement amount
//   texgenParams.z — Y displacement amount
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
Texture2D distortMap : register(t1);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Apply Direct UV Displacement
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Read displacement value from selected channel
    int channel = (int)(texgenParams.x * 256);
    float displacement = distortMap.Sample(linearSampler, texCoord)[channel];

    // Apply displacement with separate X and Y amounts
    float2 offset = displacement * float2(texgenParams.y, texgenParams.z);
    float2 distortedUV = texCoord + offset;

    return inputTexture.Sample(linearSampler, distortedUV);
}
