// ============================================================================
// READABLE VERSION: Directional Blur (Map-Controlled)
// Original: ../texgen/dirblur.hlsl (25 lines)
//
// Algorithm: Blurs along a direction specified per-pixel by a direction map.
//            Unlike uniform blur, the blur direction varies across the image.
//
// How It Works:
//   1. Read direction value from control texture (0-1 → 0-2π)
//   2. Convert to unit vector: (cos(dir), sin(dir))
//   3. Sample along that direction, accumulate and average
//
// This enables effects impossible with uniform blur:
//   - Radial blur (direction map = polar angle)
//   - Zoom blur (direction map = angle toward/from center)
//   - Flow-following blur (direction from velocity field)
//
// Sample Count:
//   21 samples per pixel (hardcoded as 'c')
//   More samples = smoother blur but slower
//
// Use Cases:
//   - Radial motion blur
//   - Zoom blur
//   - Flow visualization
//   - Artistic smear effects
//   - Speed lines
//
// Parameters:
//   texgenParams.x — Control channel from direction map (0-3 = RGBA)
//   texgenParams.y — Blur amount/length
// ============================================================================

SamplerState linearSampler : register(s0);
float4 texgenParams : register(c1);
Texture2D inputTexture : register(t0);
Texture2D directionMap : register(t1);

// Number of blur samples
#define SAMPLE_COUNT 21

// ============================================================================
// Pixel Shader — Sample Along Map-Defined Direction
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Read direction from map (0-1 value → 0-2π angle)
    int channel = (int)(texgenParams.x * 256);
    float direction = directionMap.Sample(linearSampler, texCoord)[channel];

    // Convert to unit vector
    float angle = direction * 3.14159265 * 2.0;
    float2 blurVector = float2(cos(angle), sin(angle));

    // Accumulate samples along direction
    float4 result = 0;

    for (int i = 1; i < SAMPLE_COUNT; i++)
    {
        // Sample at increasing distances along blur direction
        float2 offset = blurVector * i * texgenParams.y * 0.03;
        result += inputTexture.Sample(linearSampler, texCoord + offset);
    }

    // Average all samples
    return result / (SAMPLE_COUNT - 1);
}
