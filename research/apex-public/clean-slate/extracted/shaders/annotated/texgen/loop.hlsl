// ============================================================================
// READABLE VERSION: UV Tiling (Loop)
// Original: ../texgen/loop.hlsl (14 lines)
//
// Algorithm: Tiles/repeats a texture by scaling UV coordinates.
//            The sampler's wrap mode handles the actual repetition.
//
// How Tiling Works:
//   UV coordinates normally range from 0-1.
//   Multiplying by N causes the texture to repeat N times.
//   Example: UV * 4 = texture repeats 4 times in each direction.
//
// The sampler state (wrap mode) must be set to "repeat" for seamless
// tiling. If set to "clamp", only the last row/column would be extended.
//
// Use Cases:
//   - Creating seamless repeating patterns
//   - Scaling detail textures
//   - Adjusting noise frequency
//   - Wallpaper/floor tile effects
//
// Parameters:
//   texgenParams.x — X tile count (0-1 → 0-255 repeats)
//   texgenParams.y — Y tile count (0-1 → 0-255 repeats)
// ============================================================================

SamplerState linearSampler : register(s0);
float4 texgenParams : register(c1);
Texture2D inputTexture : register(t0);

// ============================================================================
// Pixel Shader — Sample with Tiled UVs
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Scale UV by tile count (parameters stored as 0-1, convert to count)
    float2 tileCount = float2(texgenParams.x * 255.0, texgenParams.y * 255.0);
    return inputTexture.Sample(linearSampler, texCoord * tileCount);
}
