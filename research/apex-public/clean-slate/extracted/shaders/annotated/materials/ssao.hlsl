// ============================================================================
// READABLE VERSION: Screen-Space Ambient Occlusion (SSAO)
// Original: ../materials/ssao.hlsl (90 lines)
//
// Algorithm: Spiral-sampled SSAO with golden angle distribution.
//            Samples hemisphere around each pixel in view space,
//            compares depths to estimate local occlusion.
//
// Parameters:
//   dat.x — Power (occlusion intensity multiplier)
//   dat.y — Sample count (encoded as value × 255)
//   dat.z — Diameter (search radius)
//   dat.w — Bias (minimum angle contribution threshold)
//   dat2.x — Max distance (falloff threshold)
//
// Key Technique:
//   Golden angle (≈2.4 radians) spiral sampling provides uniform coverage
//   of the hemisphere with any sample count, avoiding clustering artifacts.
//
// References:
//   - "Screen Space Ambient Occlusion" (Crytek, 2007)
//   - Alchemy SSAO (Arkane Studios)
// ============================================================================

SamplerState linearSampler : register(s1);

Texture2D normalRoughnessTexture : register(t0);  // G-Buffer normal + roughness
Texture2D depthTexture : register(t7);            // Depth buffer

cbuffer SceneBuffer : register(b0)
{
    float time, aspectRatio, screenWidth, screenHeight;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
    float4x4 inverseViewMatrix;
    float4x4 inverseProjectionMatrix;
}

cbuffer MaterialBuffer : register(b1)
{
    float4 ssaoParams;       // x=power, y=samples, z=diameter, w=bias
    float4 ssaoParams2;      // x=maxDistance
}

// Predefined constant (can be overridden by ssaoParams2.x)
#define MAX_DISTANCE 0.07

// ============================================================================
// Simple hash function for pseudo-random rotation per pixel
// Creates variation to break up banding artifacts
// ============================================================================
float HashNoise(float2 pixelCoord)
{
    // Standard hash function using prime-like constants
    float3 p3 = frac(float3(pixelCoord.xyx) * float3(0.1031, 0.11369, 0.13787));
    p3 += dot(p3, p3.yzx + 19.19);
    return frac((p3.x + p3.y) * p3.z);
}

// ============================================================================
// Reconstruct view-space position from depth and UV
// ============================================================================
float3 GetViewPosition(float depth, float2 uv)
{
    // Unproject from clip space to view space
    float4 clipPos = mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1));
    return clipPos.xyz / clipPos.w;
}

// Overload that samples depth from texture
float3 GetViewPosition(int2 pixelCoord)
{
    float2 uv = pixelCoord / float2(screenWidth, screenHeight);
    float depth = depthTexture.Load(int3(pixelCoord, 0)).x;

    float4 clipPos = mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1));
    return clipPos.xyz / clipPos.w;
}

// ============================================================================
// Main Pixel Shader
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0, float4 pixelPos : SV_POSITION) : SV_TARGET0
{
    // Load surface normal from G-Buffer and transform to view space
    float4 normalData = normalRoughnessTexture.Load(int3(pixelPos.xy, 0));
    float3 normal = normalize(mul(transpose(inverseViewMatrix), float4(normalData.xyz, 0)).xyz);
    normal.y *= -1;  // Flip Y for view-space convention

    // Get view-space position of current pixel
    float3 viewPosition = GetViewPosition(pixelPos.xy);

    // ========================================================================
    // Spiral SSAO Sampling
    // Uses golden angle (≈137.5° or 2.4 radians) to create a uniform spiral
    // that covers the hemisphere evenly regardless of sample count.
    // ========================================================================

    float occlusion = 0.0;
    float radius = 0.0;

    // Random starting angle per pixel (breaks up banding)
    float rotationAngle = HashNoise(pixelPos.xy * 100.0) * 6.28;  // 2π

    // Radius increment per sample
    // diameter × 0.2 / sampleCount gives total radius spread
    float radiusStep = ssaoParams.z * 0.2 / ssaoParams.y / 255.0;
    int sampleCount = (int)(ssaoParams.y * 255.0);

    for (int i = 0; i < sampleCount; i++)
    {
        // Spiral sample position
        float2 spiralOffset = float2(sin(rotationAngle), cos(rotationAngle));
        radius += radiusStep;

        // Sample neighbor position in view space
        float2 samplePixel = pixelPos.xy + (spiralOffset * radius) * float2(screenWidth, screenHeight);
        float3 neighborPosition = GetViewPosition(samplePixel);

        // Vector from current position to sample
        float3 diff = neighborPosition - viewPosition;
        float distance = length(diff);
        float3 direction = diff / distance;

        // ====================================================================
        // Occlusion calculation:
        //   - dot(normal, direction) gives the angle contribution
        //   - Subtract bias to ignore samples nearly parallel to surface
        //   - 1/(1+distance) provides distance attenuation
        //   - smoothstep fades out samples beyond max distance
        // ====================================================================
        float angleContribution = max(0.0, dot(normal, direction) - ssaoParams.w);
        float distanceAttenuation = 1.0 / (1.0 + distance);
        float distanceFalloff = smoothstep(ssaoParams2.x, ssaoParams2.x * 0.5, distance);

        occlusion += angleContribution * distanceAttenuation * distanceFalloff;

        // Advance rotation by golden angle (≈2.4 radians)
        // This magic number provides optimal hemisphere coverage
        rotationAngle += 2.4;
    }

    // Average and normalize
    occlusion /= sampleCount;

    // Return inverted occlusion (1 = no occlusion, 0 = full occlusion)
    // Power parameter controls intensity
    return saturate(1 - occlusion * ssaoParams.x);
}
