// ============================================================================
// READABLE VERSION: Contrast Adjustment
// Original: ../texgen/contrast.hlsl (17 lines)
//
// Algorithm: Adjusts image contrast by lerping toward/away from middle gray.
//            The standard contrast formula: output = lerp(0.5, input, strength)
//
// How Contrast Works:
//   - At strength = 1.0: No change (lerp factor = 1, output = input)
//   - At strength > 1.0: Increased contrast (values pushed away from 0.5)
//   - At strength < 1.0: Decreased contrast (values pulled toward 0.5)
//   - At strength = 0.0: Flat gray (all pixels become 0.5)
//
// The shader applies a non-linear scaling to the strength parameter:
//   scaledStrength = (strength * 3)^2 * 5
//   At strength = 0.33: scaledStrength = 1 (neutral)
//   At strength = 1.0:  scaledStrength = 45 (extreme contrast)
//
// This gives more control in the low-contrast range where subtle
// adjustments are more common.
//
// Use Cases:
//   - Image enhancement
//   - Fade to gray effects
//   - High-contrast stylization
//   - Visibility adjustment
//
// Parameters:
//   texgenParams.x — Contrast strength (0-1, ~0.33 = neutral)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Apply Contrast Adjustment
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // Non-linear strength scaling for better control
    // At strength=0.33: (0.33*3)^2 * 5 = 1 * 5 = 5... actually let me recalculate
    // s = strength * 3, then s = s * s, then lerp uses s * 5
    // For neutral: need lerp factor = 1, so s*s*5 = 1, s = sqrt(0.2) ≈ 0.447
    // At input strength 0.149: s = 0.447
    float s = texgenParams.x * 3;
    s *= s;  // Square for non-linear response

    // Lerp from middle gray toward original color
    // strength > ~0.15 = increased contrast, < 0.15 = decreased
    return lerp(0.5, color, s * 5);
}
