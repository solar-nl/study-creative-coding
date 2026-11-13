// ============================================================================
// READABLE VERSION: Lens Flares
// Original: ../materials/lens-flares.hlsl (241 lines, 4 passes)
//
// Algorithm: Multi-pass lens flare simulation combining:
//            1. Ghost artifacts (symmetric copies at various distances)
//            2. Halo effect (ring around bright sources)
//            3. Blur passes for softening
//
// Optical Basis:
//   Real lens flares occur when light bounces between lens elements.
//   Each bounce creates a "ghost" at a specific distance from center.
//   The halo forms from light scattering in the lens coating.
//
// Pipeline:
//   Pass 1: Generate ghosts and halo from bright spots
//   Pass 2: 3x3 blur for softening
//   Pass 3: 8x8 disc-shaped bokeh blur
//   Pass 4: Final 3x3 blur + intensity
//
// Parameters:
//   threshold — Brightness threshold for flare sources
//   zoom — Distance multiplier for ghost positions
//   blursize — Blur radius for softening passes
//   power — Final intensity multiplier
// ============================================================================

SamplerState linearSampler : register(s1);
Texture2D inputTexture : register(t0);

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float time, aspectRatio;
}

cbuffer MaterialBuffer : register(b1)
{
    float blurSize, threshold, zoom;
    float4 color;
}

static const float PI = 3.14159265;

// ============================================================================
// Disc Falloff Function
//
// Creates a soft circular falloff for ghost artifacts.
// Returns 1 at center, falls off quadratically to 0 at edge.
// ============================================================================
float DiscFalloff(float2 offset)
{
    float x = saturate(1.0 - dot(offset, offset));
    return x * x;
}

// ============================================================================
// Pass 1: Ghost Generation
//
// Creates multiple ghost copies of bright spots at varying distances
// from the image center. Each color channel is slightly offset for
// chromatic separation.
// ============================================================================
float4 Pass1_Ghosts(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Predefined ghost distances (empirically chosen for realistic look)
    float distances[8] = {0.5, 0.7, 1.03, 1.35, 1.55, 1.62, 2.2, 3.9};

    // Chromatic offset scales for ghosts (R slightly larger, B slightly smaller)
    float rgbScalesGhost[3] = {1.01, 1.00, 0.99};

    // Chromatic offset scales for halo
    float rgbScalesHalo[3] = {0.98, 1.00, 1.02};

    // Direction from current pixel toward center
    float2 direction = 0.5 - texCoord;

    float4 result = 0;

    // ========================================================================
    // Generate Ghost Artifacts (Per Color Channel)
    //
    // For each ghost distance, sample the source and add if above threshold.
    // The disc falloff creates soft circular shapes.
    // ========================================================================
    for (int rgb = 0; rgb < 3; rgb++)
    {
        for (int i = 0; i < 8; i++)
        {
            // Calculate ghost position with chromatic offset
            float2 ghostUV = texCoord + direction * distances[i] * rgbScalesGhost[rgb] * zoom * 2;

            // Sample and threshold
            float4 sampleColor = inputTexture.Sample(linearSampler, ghostUV);
            float luminance = dot(sampleColor.xyz, float3(0.299, 0.587, 0.114));
            sampleColor *= luminance > threshold * 4;

            // Add with disc falloff and slight offset boost
            result[rgb] += saturate(sampleColor[rgb] - 0.5) * 1.5 * DiscFalloff((ghostUV - 0.5) * 2);
        }

        // ====================================================================
        // Add Halo Effect
        //
        // Sample along a fixed radius from center (perpendicular to radial)
        // This creates the characteristic ring around bright sources.
        // ====================================================================
        float2 fixedDir = direction;
        fixedDir.y /= aspectRatio;  // Correct for non-square aspect

        float2 normDir = normalize(fixedDir);
        normDir *= 0.4 * rgbScalesHalo[rgb];
        normDir.y *= aspectRatio;  // Correct back to UV space

        float haloSample = inputTexture.Sample(linearSampler, texCoord + normDir)[rgb];
        result[rgb] += saturate(haloSample - 0.5) * 1.5;
    }

    return result;
}

// ============================================================================
// Pass 2: Simple 3x3 Box Blur
// ============================================================================
cbuffer MaterialBuffer2 : register(b1)
{
    float blurSize2, power2;
}

float4 Pass2_Blur(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = 0;
    float totalWeight = 0;

    for (int x = 0; x < 3; x++)
    for (int y = 0; y < 3; y++)
    {
        float2 offset = float2(x, y) - 1;
        float2 coord = texCoord + offset * blurSize2 * 0.1 * float2(1 / aspectRatio, 1);
        color += inputTexture.SampleLevel(linearSampler, coord, 0);
        totalWeight += 1;
    }

    return color / totalWeight;
}

// ============================================================================
// Pass 3: Disc-Shaped Bokeh Blur (8x8 samples)
//
// Maps square sample grid to unit disc for more natural bokeh shape.
// ============================================================================
cbuffer MaterialBuffer3 : register(b1)
{
    float blurSize3;
}

// Shirley's concentric disc mapping
float2 ToUnitDisc(float2 gridPos)
{
    float a = 2 * gridPos.x - 1;
    float b = 2 * gridPos.y - 1;

    float r = b;
    float phi = (PI / 4) * (a / b) + (PI / 2);

    if (a * a > b * b)
    {
        r = a;
        phi = (PI / 4) * (b / a);
    }

    return float2(cos(phi) / aspectRatio, sin(phi)) * r;
}

float4 Pass3_BokehBlur(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = 0;
    float totalWeight = 0;

    for (int x = 0; x < 8; x++)
    for (int y = 0; y < 8; y++)
    {
        float2 offset = ToUnitDisc((float2(x, y) + 0.5) / 8.0);
        float2 coord = texCoord + offset * 0.2 * blurSize3;
        color += inputTexture.Sample(linearSampler, coord);
        totalWeight += 1;
    }

    return color / totalWeight;
}

// ============================================================================
// Pass 4: Final Blur + Intensity
// ============================================================================
cbuffer MaterialBuffer4 : register(b1)
{
    float blurSize4, intensity;
}

float4 Pass4_FinalBlur(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = 0;
    float totalWeight = 0;

    for (int x = 0; x < 3; x++)
    for (int y = 0; y < 3; y++)
    {
        float2 offset = float2(x, y) - 1;
        float2 coord = texCoord + offset * blurSize4 * 0.02 * float2(1 / aspectRatio, 1);
        color += inputTexture.Sample(linearSampler, coord);
        totalWeight += 1;
    }

    return (color / totalWeight) * intensity;
}
