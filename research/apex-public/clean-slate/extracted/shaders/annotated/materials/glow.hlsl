// ============================================================================
// READABLE VERSION: Multi-Pass Glow (Bloom)
// Original: ../materials/glow.hlsl (235 lines, 7 passes)
//
// Algorithm: Progressive downsampling bloom with separable box blur.
//            Extracts bright areas, progressively downsamples and blurs,
//            then composites back to create a soft glow around bright regions.
//
// Pipeline:
//   Pass 1: Threshold extraction + horizontal blur → X/2, Y/1
//   Pass 2: Vertical blur → X/2, Y/2
//   Pass 3: Horizontal blur → X/4, Y/2
//   Pass 4: Vertical blur → X/4, Y/4
//   Pass 5: Horizontal blur → X/8, Y/4
//   Pass 6: Vertical blur → X/8, Y/8
//   Pass 7: Color tint and output
//
// The progressive downsampling (X/2, X/4, X/8) naturally creates increasingly
// soft blur while reducing computation cost.
//
// Parameters:
//   threshold — Brightness cutoff for glow extraction
//   power — Intensity multiplier for extracted glow
//   blur.xy — Blur radius (x for horizontal, y for vertical)
//   blur.z — Sample count (encoded: value * 255)
//   color — Final tint color
// ============================================================================

SamplerState linearSampler : register(s1);
Texture2D inputTexture : register(t0);

// ============================================================================
// Pass 1: Threshold + Horizontal Blur (Full → Half Width)
// ============================================================================
cbuffer SceneBuffer1 : register(b0) { }

cbuffer MaterialBuffer1 : register(b1)
{
    float4 blurParams;    // xy = blur size, z = sample count
    float threshold;      // Brightness threshold
    float power;          // Intensity multiplier
}

float4 Pass1_ThresholdHorizontal(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = 0;
    float count = blurParams.z * 255;

    for (int x = 0; x < count; x++)
    {
        // Center the blur kernel around the current pixel
        float offset = (x - (count - 1) / 2.0) * blurParams.x / count / 4.0;
        float2 sampleUV = texCoord + offset * float2(1, 0);

        float4 sampleColor = inputTexture.Sample(linearSampler, sampleUV);

        // Threshold test (mask for pixels above threshold)
        float4 aboveThreshold = sampleColor >= threshold;

        // Extract bright part and amplify
        // Formula: ((color - threshold) * (1 + power*1000) + threshold) * mask
        color += ((sampleColor - threshold) * (1 + power * 1000) + threshold) * aboveThreshold;
    }

    return color / count;
}

// ============================================================================
// Pass 2: Vertical Blur (Half Width → Quarter Height)
// ============================================================================
cbuffer SceneBuffer2 : register(b0) { }

cbuffer MaterialBuffer2 : register(b1)
{
    float2 blurSize2;
    float sampleCount2;
}

float4 Pass2_Vertical(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = 0;
    float count = sampleCount2 * 255;

    for (int x = 0; x < count; x++)
    {
        float offset = (x - (count - 1) / 2.0) * blurSize2.y / count / 4.0;
        color += inputTexture.Sample(linearSampler, texCoord + offset * float2(0, 1));
    }

    return color / count;
}

// ============================================================================
// Passes 3-6: Alternating Horizontal/Vertical Blur
//
// Each pass halves resolution in one dimension while blurring.
// This creates progressively larger blur radii cheaply.
// ============================================================================
// Pass 3: Horizontal (X/2→X/4)
// Pass 4: Vertical (Y/2→Y/4)
// Pass 5: Horizontal (X/4→X/8)
// Pass 6: Vertical (Y/4→Y/8)
//
// All use the same blur kernel structure as Pass 2.

// ============================================================================
// Pass 7: Color Tint Output
// ============================================================================
cbuffer SceneBuffer7 : register(b0) { }

cbuffer MaterialBuffer7 : register(b1)
{
    float4 blurParams7;
    float4 tintColor;
}

float4 Pass7_Output(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Sample blurred glow and apply color tint
    return inputTexture.Sample(linearSampler, texCoord) * tintColor;
}

// ============================================================================
// Generic Blur Pass (Used by Passes 2-6)
//
// Separable box blur in either horizontal or vertical direction.
// Direction is controlled by the offset vector (1,0) or (0,1).
// ============================================================================
float4 GenericBlur(float2 texCoord, float2 direction, float blurSize, float count)
{
    float4 color = 0;

    for (int i = 0; i < count; i++)
    {
        float offset = (i - (count - 1) / 2.0) * blurSize / count / 4.0;
        color += inputTexture.Sample(linearSampler, texCoord + offset * direction);
    }

    return color / count;
}

// ============================================================================
// Single-Pass Annotated Version (for reference)
//
// This combines the multi-pass structure into a documented single shader.
// In practice, the original uses 7 separate passes with intermediate textures.
//
// Bloom Quality Notes:
//   - More passes = softer, larger bloom radius
//   - Higher sample counts = smoother blur gradients
//   - Lower threshold = more areas contribute to glow
//   - Higher power = more intense glow extraction
// ============================================================================
