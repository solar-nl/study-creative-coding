// ============================================================================
// READABLE VERSION: Alpha Channel Replacement
// Original: ../texgen/replace-alpha.hlsl (14 lines)
//
// Algorithm: Replaces the alpha channel of one texture with a channel from
//            another texture. Keeps RGB from texture1, takes alpha from
//            the red channel of texture2.
//
// Operation:
//   output.rgb = texture1.rgb
//   output.a = texture2.r
//
// This is useful when alpha information is stored separately from color,
// such as when using a separate mask texture for transparency.
//
// Note: Uses the RED channel of texture2, not the alpha channel.
// This is common because many image formats and tools handle grayscale
// masks in the red channel.
//
// Use Cases:
//   - Applying external transparency masks
//   - Creating cutouts from shape textures
//   - Separating alpha workflow (color artist + alpha artist)
//   - Converting grayscale masks to alpha
//   - Sprite sheet alpha extraction
//
// Parameters:
//   Texture0 — Source color (RGB used)
//   Texture1 — Source alpha (Red channel used as alpha)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D colorTexture : register(t0);
Texture2D alphaTexture : register(t1);

// ============================================================================
// Pixel Shader — Combine RGB + External Alpha
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = colorTexture.Sample(linearSampler, texCoord);
    float4 alpha = alphaTexture.Sample(linearSampler, texCoord);

    // RGB from color texture, alpha from red channel of alpha texture
    return float4(color.xyz, alpha.x);
}
