// ============================================================================
// READABLE VERSION: Solid Color Fill
// Original: ../texgen/solid-color.hlsl (11 lines)
//
// Algorithm: Outputs a constant color across the entire texture.
//            The simplest possible texture generator.
//
// This shader ignores UV coordinates entirely and returns the same
// RGBA value for every pixel.
//
// Use Cases:
//   - Base color for layered effects
//   - Flat backgrounds
//   - Color constants in material graphs
//   - Placeholder textures
//   - Clear color for render targets
//
// Parameters:
//   texgenParams — RGBA color value (each component 0-1)
// ============================================================================

float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Output Constant Color
// ============================================================================
float4 PixelMain(float4 position : TEXCOORD0) : SV_TARGET0
{
    return texgenParams;
}
