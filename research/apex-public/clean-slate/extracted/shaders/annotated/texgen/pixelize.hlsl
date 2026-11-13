// ============================================================================
// READABLE VERSION: Pixelization (Mosaic Effect)
// Original: ../texgen/pixelize.hlsl (16 lines)
//
// Algorithm: Reduces texture resolution by snapping UV coordinates to a grid.
//            Creates the classic "pixelated" or "mosaic" look.
//
// How It Works:
//   1. Divide UV space into a grid of cells
//   2. For each pixel, find which cell it belongs to
//   3. Sample from the center of that cell instead of the actual position
//
// Math:
//   cellSize = 1 / cellCount
//   snappedUV = UV - fmod(UV, cellSize) + cellSize/2
//
// The fmod operation "floors" the UV to the cell boundary, then we
// offset by half a cell to sample from the center.
//
// SampleLevel with mip=0 is used instead of Sample to avoid mipmap
// artifacts at cell boundaries.
//
// Use Cases:
//   - Retro/8-bit aesthetics
//   - Privacy/censorship blur alternative
//   - Low-res texture simulation
//   - Stylized rendering
//   - Transition effects
//
// Parameters:
//   texgenParams.x — Horizontal cell count (0-1 → 0-255)
//   texgenParams.y — Vertical cell count (0-1 → 0-255)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Sample at Quantized UV
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Calculate cell size from count
    float2 cellSize = 1.0 / (texgenParams.xy * 255);

    // Snap UV to cell center:
    // 1. Subtract the fractional position within cell (fmod)
    // 2. Add half cell size to sample from center
    float2 snappedUV = texCoord - fmod(texCoord, cellSize) + cellSize / 2.0;

    // Use SampleLevel to avoid mipmap selection issues
    return inputTexture.SampleLevel(linearSampler, snappedUV, 0);
}
