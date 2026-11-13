// ============================================================================
// READABLE VERSION: Linear Value Remapping (Scale)
// Original: ../texgen/scale.hlsl (22 lines)
//
// Algorithm: Linearly remaps input values from [0,1] to [min,max] range.
//            The fundamental brightness/contrast adjustment with explicit
//            minimum and maximum values.
//
// Math:
//   output = lerp(minColor, maxColor, input)
//   output = minColor + input * (maxColor - minColor)
//
// When minColor = (0,0,0,0) and maxColor = (1,1,1,1), output equals input.
// Other values shift and scale the entire color range.
//
// Examples:
//   Min=(0,0,0), Max=(0.5,0.5,0.5) → Darkens image
//   Min=(0.5,0.5,0.5), Max=(1,1,1) → Brightens shadows
//   Min=(0,0,1), Max=(1,0,0) → Grayscale to red-blue gradient
//
// Use Cases:
//   - Levels adjustment (black/white point)
//   - Range remapping for data visualization
//   - Color tinting
//   - Value normalization
//
// Parameters:
//   texgenParams — Minimum color (RGBA)
//   texgenParams2 — Maximum color (RGBA)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);
float4 texgenParams2 : register(c2);

// ============================================================================
// Pixel Shader — Linear Remapping
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    float4 minColor = texgenParams;
    float4 maxColor = texgenParams2;

    // Linear interpolation from min to max based on input value
    return lerp(minColor, maxColor, color);
}
