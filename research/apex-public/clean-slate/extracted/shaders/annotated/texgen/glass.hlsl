// ============================================================================
// READABLE VERSION: Glass Distortion (Refraction)
// Original: ../texgen/glass.hlsl (26 lines)
//
// Algorithm: Simulates glass/water refraction by displacing UV coordinates
//            based on the gradient of a height/displacement map.
//
// How It Works:
//   1. Sample displacement map at current pixel and two offset positions
//   2. Compute gradient (rate of change) by differencing samples
//   3. Use gradient as UV offset direction and magnitude
//   4. Sample image texture at displaced UV
//
// Physics Background:
//   Real refraction bends light based on surface normal.
//   Surface normal relates to the gradient of a height field.
//   Steeper gradients (more change) = more bending.
//
// Gradient Calculation:
//   dx = sample(x) - sample(x + scatter)
//   dy = sample(y) - sample(y + scatter)
//   This approximates the partial derivatives of the height field.
//
// The scatter constant (1/32) determines the sampling distance for
// gradient estimation — smaller values = sharper but noisier edges.
//
// Use Cases:
//   - Water surface refraction
//   - Glass/lens distortion
//   - Heat haze effects
//   - Frosted glass
//   - Underwater caustics
//
// Parameters:
//   texgenParams.x — Control channel (0-3 = RGBA, for displacement map)
//   texgenParams.y — Distortion amount (0.5 = neutral, <0.5 inverts)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
Texture2D displacementMap : register(t1);
float4 texgenParams : register(c1);

// Sampling offset for gradient calculation
#define SCATTER (1.0 / 32.0)

// ============================================================================
// Pixel Shader — Glass Refraction Effect
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    int controlChannel = (int)(texgenParams.x * 256);

    // ========================================================================
    // Compute Gradient via Finite Differences
    //
    // Sample displacement at current position and two offset positions.
    // The difference gives approximate partial derivatives.
    // ========================================================================
    float centerValue = displacementMap.Sample(linearSampler, texCoord)[controlChannel];
    float rightValue = displacementMap.Sample(linearSampler, texCoord + float2(SCATTER, 0))[controlChannel];
    float downValue = displacementMap.Sample(linearSampler, texCoord + float2(0, SCATTER))[controlChannel];

    // Gradient = (dHeight/dx, dHeight/dy)
    float2 gradient = float2(centerValue - rightValue, centerValue - downValue);

    // ========================================================================
    // Apply Displacement
    //
    // Scale gradient by amount parameter (0.5 = neutral, centered at 0)
    // Positive amount = normal refraction, negative = inverted
    // ========================================================================
    float2 displacedUV = texCoord + gradient * (texgenParams.y - 0.5);

    return inputTexture.Sample(linearSampler, displacedUV);
}
