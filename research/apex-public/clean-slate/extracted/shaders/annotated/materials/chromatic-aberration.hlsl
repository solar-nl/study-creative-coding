// ============================================================================
// READABLE VERSION: Chromatic Aberration
// Original: ../materials/chromatic-aberration.hlsl (49 lines)
//
// Algorithm: Simulates lens chromatic aberration by sampling R and B channels
//            at offset UV positions, while keeping G at the original position.
//
// Technique:
//   Real lenses refract different wavelengths at different angles, causing
//   color fringing especially toward image edges. This shader approximates
//   the effect by:
//   1. Computing radial direction from center to current pixel
//   2. Sampling Red channel along -direction (toward center)
//   3. Sampling Blue channel along +direction (away from center)
//   4. Keeping Green channel at original position
//
// Parameters:
//   power — Strength of the aberration offset
//   samplecnt — Number of samples (encoded as value * 255)
//
// Note:
//   Higher sample counts produce smoother gradients but cost more.
//   The /200 divisor controls the base offset scale.
// ============================================================================

SamplerState linearSampler : register(s1);
Texture2D inputTexture : register(t0);

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float time, aspectRatio, screenWidth, screenHeight;
}

cbuffer MaterialBuffer : register(b1)
{
    float power;       // Aberration strength
    float sampleCount; // Sample count (encoded: value * 255)
}

// ============================================================================
// Pixel Shader — Chromatic Aberration
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Decode sample count from normalized value
    float count = sampleCount * 255;

    // Direction from pixel toward image center
    // This creates radial aberration strongest at edges
    float2 direction = 0.5 - texCoord;

    // Sample original color (will keep green channel)
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // ========================================================================
    // Accumulate Red and Blue with Progressive Offset
    //
    // Red shifts toward center (negative direction)
    // Blue shifts away from center (positive direction)
    // Each sample has increasing offset based on index
    // ========================================================================
    float4 redAccum = 0;
    float4 blueAccum = 0;

    for (int i = 0; i < count; i++)
    {
        // Progressive offset: sample i has offset i/200 * power
        float offsetScale = i / 200.0 * power;

        // Red: sample toward center
        redAccum += inputTexture.Sample(linearSampler, texCoord - direction * offsetScale);

        // Blue: sample away from center
        blueAccum += inputTexture.Sample(linearSampler, texCoord + direction * offsetScale);
    }

    // Average the accumulated samples
    color.r = redAccum.r / count;
    color.b = blueAccum.b / count;

    return color;
}
