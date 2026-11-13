// ============================================================================
// READABLE VERSION: Separable Box Blur
// Original: ../texgen/blur.hlsl (36 lines)
//
// Algorithm: Two-pass separable blur (horizontal then vertical).
//            Uses 24 samples in each direction for smooth results.
//            Passes 1-2 blur horizontally, passes 3+ blur vertically.
//
// Parameters:
//   texgenParams.x — X blur amount (horizontal radius)
//   texgenParams.y — Y blur amount (vertical radius)
//
// Multi-Pass System:
//   Passes 0-2: Horizontal blur (XM=1, YM=0)
//   Passes 3+:  Vertical blur (XM=0, YM=1)
//
// Note: This is a box blur (uniform weights), not Gaussian.
//       For quality, run multiple passes to approximate Gaussian.
//
// References:
//   - Separable convolution optimization
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);

float4 passInfo : register(c0);      // x = pass index
float4 texgenParams : register(c1);  // x = X blur, y = Y blur

// Number of samples in each direction
#define SAMPLE_COUNT 24.0

float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 result = 0;

    // ========================================================================
    // Determine blur direction based on pass number
    // First 3 passes: horizontal (X multiplier = 1, Y multiplier = 0)
    // Later passes: vertical (X multiplier = 0, Y multiplier = 1)
    // ========================================================================
    float xMultiplier = 1;
    float yMultiplier = 0;

    if (passInfo.x + 0.5 >= 3)  // Pass 3 and beyond
    {
        xMultiplier = 0;
        yMultiplier = 1;
    }

    // ========================================================================
    // Calculate blur offsets
    // Start at negative half-width, step through to positive half-width
    // ========================================================================
    float2 blurRadius = float2(texgenParams.x * xMultiplier, texgenParams.y * yMultiplier);

    // Starting position: negative half of total blur width
    float2 sampleOffset = blurRadius * -0.5;

    // Step size: total blur width divided by sample count
    float2 sampleStep = blurRadius / SAMPLE_COUNT;

    // ========================================================================
    // Accumulate samples (box blur = uniform weights)
    // ========================================================================
    for (float i = 0; i < SAMPLE_COUNT; i++)
    {
        result += inputTexture.Sample(linearSampler, texCoord + sampleOffset);
        sampleOffset += sampleStep;
    }

    // Average all samples
    return result / SAMPLE_COUNT;
}
