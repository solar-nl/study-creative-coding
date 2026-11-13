// ============================================================================
// READABLE VERSION: Palette Remapping
// Original: ../materials/palette.hlsl (30 lines)
//
// Algorithm: Per-channel color remapping using lookup texture (LUT).
//            Each color channel is independently remapped through a
//            1D lookup texture, enabling flexible color grading.
//
// Technique:
//   For each RGBA channel:
//     output[i] = palette.Sample(input[i], 0)[i]
//
//   The palette texture is a 1D gradient where:
//   - X coordinate = input value (0-1)
//   - Output = remapped value for that channel
//
// Use Cases:
//   - Color correction curves
//   - Posterization effects
//   - False color visualization
//   - Stylized color grading
//   - Night vision / thermal imaging looks
//
// Palette Texture Format:
//   Width: Any (typically 256 for 8-bit precision)
//   Height: 1
//   Channels: RGBA (each channel's curve is stored in corresponding channel)
//
// Parameters:
//   Texture0 — Input image
//   Texture1 — Palette/LUT texture (1D gradient)
// ============================================================================

SamplerState linearSampler : register(s1);
Texture2D inputTexture : register(t0);
Texture2D paletteTexture : register(t1);

// ============================================================================
// Pixel Shader — Per-Channel Palette Lookup
// ============================================================================
float4 PixelMain(float4 pixelPos : SV_POSITION) : SV_TARGET0
{
    // Load input color
    float4 inputColor = inputTexture.Load(int3(pixelPos.xy, 0));

    // ========================================================================
    // Per-Channel Remapping
    //
    // Each channel is remapped independently:
    // - Use input value as U coordinate
    // - Sample palette at V=0 (1D lookup)
    // - Extract corresponding channel from result
    //
    // saturate() ensures we stay within valid UV range.
    // ========================================================================
    float4 result;
    result.x = paletteTexture.SampleLevel(linearSampler, float2(saturate(inputColor.x), 0), 0).x;
    result.y = paletteTexture.SampleLevel(linearSampler, float2(saturate(inputColor.y), 0), 0).y;
    result.z = paletteTexture.SampleLevel(linearSampler, float2(saturate(inputColor.z), 0), 0).z;
    result.w = paletteTexture.SampleLevel(linearSampler, float2(saturate(inputColor.w), 0), 0).w;

    return result;
}
