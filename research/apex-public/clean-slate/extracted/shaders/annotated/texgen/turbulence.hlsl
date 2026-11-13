// ============================================================================
// READABLE VERSION: Turbulence (UV Distortion)
// Original: ../texgen/turbulence.hlsl (18 lines)
//
// Algorithm: Displaces UV coordinates based on a direction map texture.
//            Reads an angle from the data map, converts to a direction vector,
//            and offsets the sample position. Creates swirling, turbulent effects.
//
// Parameters:
//   texgenParams.x — Control channel (0=R, 1=G, 2=B, 3=A, encoded as value × 256)
//   texgenParams.y — Amount (distortion strength/radius)
//
// Inputs:
//   Textur (t0) — Source texture to distort
//   DataMap (t1) — Direction/angle map (typically noise or another texture)
//
// How It Works:
//   1. Sample the data map at current UV
//   2. Interpret the selected channel as an angle (0-1 → 0-2π)
//   3. Convert angle to unit direction vector (cos, sin)
//   4. Offset UV by direction × amount
//   5. Sample source texture at offset position
//
// Use Cases:
//   - Turbulent water/smoke effects
//   - Organic distortion patterns
//   - Heat shimmer effects
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D sourceTexture : register(t0);
Texture2D directionMap : register(t1);

float4 texgenParams : register(c1);  // x=channel, y=amount

float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // ========================================================================
    // Sample direction from data map
    // The selected channel contains a value [0, 1] representing an angle
    // ========================================================================
    int channel = (int)(texgenParams.x * 256);  // 0=R, 1=G, 2=B, 3=A
    float angleNormalized = directionMap.Sample(linearSampler, texCoord)[channel];

    // Convert from [0, 1] to [0, 2π] radians
    float angle = angleNormalized * 3.14159265 * 2;

    // ========================================================================
    // Convert angle to direction vector and apply displacement
    // cos/sin give a unit vector pointing in the direction of the angle
    // ========================================================================
    float2 direction = float2(cos(angle), sin(angle));
    float2 displacedUV = texCoord + direction * texgenParams.y;

    // Sample source texture at displaced position
    return sourceTexture.Sample(linearSampler, displacedUV);
}
