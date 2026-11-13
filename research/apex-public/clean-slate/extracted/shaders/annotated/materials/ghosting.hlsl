// ============================================================================
// READABLE VERSION: Ghosting (Motion Blur / Light Trails)
// Original: ../materials/ghosting.hlsl (52 lines)
//
// Algorithm: Directional blur with brightness threshold to create
//            light trails or motion ghost effects.
//
// Technique:
//   1. Sample pixels along a user-defined direction
//   2. Apply brightness threshold to isolate bright areas
//   3. Average all samples to create trailing effect
//
// Use Cases:
//   - Light streaks from bright points
//   - Simulated motion blur in a specific direction
//   - Ghost/echo effects
//
// Parameters:
//   power — Length/spread of the ghost trail
//   samplecnt — Number of blur samples (encoded: value * 255)
//   threshold — Brightness threshold (only bright pixels contribute)
//   direction — Direction of trails (0-1 maps to 0-180 degrees)
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
    float power;       // Trail length
    float sampleCount; // Sample count (encoded: value * 255)
    float threshold;   // Brightness threshold
    float direction;   // Direction (0-1 maps to 0-180 degrees)
}

// ============================================================================
// Pixel Shader — Ghosting Effect
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Decode sample count (+1 ensures at least one sample)
    float count = sampleCount * 255 + 1;

    // ========================================================================
    // Direction Calculation
    //
    // Convert normalized direction (0-1) to radians (0 to pi).
    // This gives a half-circle of possible directions.
    // ========================================================================
    float angle = direction * 3.14159265;
    float2 blurDirection = float2(cos(angle), sin(angle));

    // Sample center pixel and apply threshold
    float4 color = inputTexture.Sample(linearSampler, texCoord);
    color *= saturate(color > threshold);  // Zero out pixels below threshold

    // ========================================================================
    // Directional Accumulation
    //
    // Sample in both directions from center (-count/2 to +count/2)
    // This creates symmetric trails around bright spots.
    // ========================================================================
    for (int i = -count / 2; i < count / 2; i++)
    {
        // Calculate sample offset
        float2 offset = blurDirection * i / 200.0 * power;
        float2 sampleUV = texCoord + offset;

        // Sample and threshold
        float4 sampleColor = inputTexture.Sample(linearSampler, sampleUV);
        sampleColor *= saturate(sampleColor > threshold);

        color += sampleColor;
    }

    // Average all samples
    color = color / count;

    return color;
}
