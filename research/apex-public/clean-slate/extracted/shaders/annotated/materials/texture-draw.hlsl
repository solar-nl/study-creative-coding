// ============================================================================
// READABLE VERSION: Texture Draw (Fullscreen Blit)
// Original: ../materials/texture-draw.hlsl (31 lines)
//
// Algorithm: Simple fullscreen texture display with color tint.
//            The most basic post-processing shader — just samples a texture
//            and applies a color multiplier.
//
// Use Cases:
//   - Display intermediate render targets
//   - Apply color grading/tinting
//   - Fade to black/white effects
//   - Compositing layers with blend modes
//
// Parameters:
//   color — RGBA multiplier applied to texture
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    // Empty
}

cbuffer MaterialBuffer : register(b1)
{
    float4 color;  // Color tint/multiplier
}

// ============================================================================
// Pixel Shader — Simple Textured Output
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    return inputTexture.Sample(linearSampler, texCoord) * color;
}
