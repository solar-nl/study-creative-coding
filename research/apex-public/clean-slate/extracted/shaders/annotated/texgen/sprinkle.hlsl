// ============================================================================
// READABLE VERSION: Sprite Scattering (Sprinkle)
// Original: ../texgen/sprinkle.hlsl (47 lines)
//
// Algorithm: Distributes a texture sprite randomly across the output.
//            Each sprite instance has random position, rotation, and size
//            derived from a noise texture.
//
// Technique:
//   For each of N sprites:
//     1. Sample noise to get random position, size, and rotation
//     2. Transform current UV to sprite-local coordinates
//     3. Sample source texture and blend with alpha
//
// Tiling Strategy:
//   To handle sprites that cross tile boundaries, the shader samples
//   from a 3x3 grid of tile offsets (-1 to +1 in each direction).
//   This ensures seamless tiling without clipped sprites.
//
// Use Cases:
//   - Particle-like textures (stars, sparkles)
//   - Scattered leaves, flowers, debris
//   - Random logo/pattern placement
//   - Confetti effects
//
// Parameters:
//   texgenParams.x — Sprite count (0-1 → 0-255)
//   texgenParams.y — Minimum sprite size
//   texgenParams.z — Maximum sprite size
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D spriteTexture : register(t0);
Texture2D noiseTexture : register(t1);
float4 PassData : register(c0);
float4 texgenParams : register(c1);

// ============================================================================
// Noise Lookup — Get Random Values for Sprite Instance
//
// Returns: xy = position, z = size interpolant, w = rotation
// ============================================================================
float4 GetNoise(float2 index)
{
    // PassData provides variation across texture generations
    float2 coord = index * 256 * (max(1, PassData.x) * (1 + PassData.y));
    return noiseTexture.Load(int3(fmod(coord, 256), 0));
}

// ============================================================================
// Transform UV to Sprite-Local Coordinates
//
// Applies inverse transform: translate to sprite center, scale, rotate
// ============================================================================
float2 GetSpriteUV(float2 worldUV, float4 spriteRandom)
{
    // Size interpolated between min and max
    float size = lerp(texgenParams.y, texgenParams.z, spriteRandom.z);

    // Random rotation (0-1 mapped to 0-2π via *6)
    float angle = spriteRandom.w * 6;
    float sinA = sin(angle);
    float cosA = cos(angle);

    // Transform: translate to sprite center, then scale
    float2 localUV = (worldUV - spriteRandom.xy) / size;

    // Apply rotation
    localUV = float2(
        localUV.x * cosA - localUV.y * sinA,
        localUV.y * cosA + localUV.x * sinA
    );

    // Offset to texture center and clamp to valid range
    return saturate(localUV + 0.5);
}

// ============================================================================
// Pixel Shader — Composite All Sprite Instances
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 result = 0;

    int spriteCount = texgenParams.x * 255;

    for (int spriteIdx = 0; spriteIdx < spriteCount; spriteIdx++)
    {
        // Get random transform for this sprite
        float4 spriteRandom = GetNoise(spriteIdx / 255.0);

        // Check 3x3 tile neighborhood for seamless tiling
        for (int tileY = 0; tileY < 3; tileY++)
        {
            for (int tileX = 0; tileX < 3; tileX++)
            {
                // Offset UV for tile wrapping (-1, 0, +1)
                float2 tileOffset = float2(tileX, tileY) - 1;
                float2 spriteUV = GetSpriteUV(texCoord + tileOffset, spriteRandom);

                // Sample and alpha-blend
                float4 spriteColor = spriteTexture.Sample(linearSampler, spriteUV);
                result = lerp(result, spriteColor, spriteColor.a);
            }
        }
    }

    return result;
}
