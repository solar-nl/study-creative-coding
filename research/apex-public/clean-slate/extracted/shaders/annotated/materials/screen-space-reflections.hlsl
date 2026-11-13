// ============================================================================
// READABLE VERSION: Screen-Space Reflections (SSR)
// Original: ../materials/screen-space-reflections.hlsl (136 lines)
//
// Algorithm: Ray marching in screen space along the reflection vector.
//            Uses binary refinement for accurate hit detection.
//            Fades out at screen edges and distant hits.
//
// Parameters:
//   dat.x — Radius (maximum ray march distance, × 64)
//   dat.y — Steps (number of ray march steps, × 255)
//   dat.z — Background extra (boost for non-reflective pixels)
//   dat.w — Accept bias (hit detection tolerance, × 0.1)
//   radmult — Radius multiplier
//
// G-Buffer Input:
//   t0: Color buffer (RGB, A = reflection mask)
//   t1: Normal + Roughness (xyz, w)
//   t7: Depth buffer
//
// Key Technique:
//   After linear ray march finds approximate hit, binary refinement
//   (halving step size) improves accuracy without extra samples.
//
// References:
//   - "Efficient GPU Screen-Space Ray Tracing" (Morgan McGuire, 2014)
// ============================================================================

SamplerState pointSampler : register(s0);

Texture2D colorTexture : register(t0);
Texture2D normalRoughnessTexture : register(t1);
Texture2D depthTexture : register(t7);

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
    float4 ssrParams;      // x=radius, y=steps, z=backgroundExtra, w=acceptBias
    float radiusMultiplier;
}

// ============================================================================
// View-space position reconstruction from depth
// ============================================================================
float3 GetViewPosition(float depth, float2 uv)
{
    float4 clipPos = mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1));
    return clipPos.xyz / clipPos.w;
}

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
    // Load background color and reflection mask
    float4 background = colorTexture.Load(int3(pixelPos.xy, 0));

    // Early exit for non-reflective pixels (mask in alpha channel)
    if (background.w <= 0)
    {
        return background * (1 + ssrParams.z);  // Apply background boost
    }

    // ========================================================================
    // Setup: Get surface normal and view-space position
    // ========================================================================

    // Load and transform normal to view space
    float4 normalData = normalRoughnessTexture.Load(int3(pixelPos.xy, 0));
    float4 viewNormal = mul(transpose(inverseViewMatrix), float4(normalData.xyz, 0));
    viewNormal.y *= -1;  // Flip Y for view-space convention

    // Get view-space position of current pixel
    float3 viewPosition = GetViewPosition(pixelPos.xy);

    // Calculate reflection vector in view space
    float3 reflectionDir = reflect(normalize(viewPosition), normalize(viewNormal.xyz));

    // ========================================================================
    // Ray March Parameters
    // ========================================================================
    float RADIUS = ssrParams.x * 64 * radiusMultiplier;
    float STEPS = ssrParams.y * 255;

    // Store original values for fadeout calculation
    float3 reflectionDirOriginal = reflectionDir;
    float3 viewPositionStart = viewPosition;

    // Scale reflection direction to step size
    reflectionDir *= RADIUS / (float)STEPS;

    float2 screenCoord;
    float4 projectedPos;

    // ========================================================================
    // Linear Ray March with Binary Refinement
    // March along reflection ray, project each sample to screen space,
    // compare depths to find intersection with scene geometry.
    // ========================================================================
    for (int i = 0; i < STEPS; i++)
    {
        // Advance ray position
        viewPosition += reflectionDir;

        // Project to screen space
        projectedPos = mul(projectionMatrix, float4(viewPosition, 1));
        projectedPos.xyz /= projectedPos.w;
        screenCoord = projectedPos.xy * 0.5 + 0.5;  // [-1,1] → [0,1]

        // Sample depth at projected position
        float sceneDepth = depthTexture.Load(int3(screenCoord * float2(screenWidth, screenHeight), 0)).x;

        // Reconstruct view-space position at that depth
        float3 targetPosition = GetViewPosition(screenCoord * float2(screenWidth, screenHeight));

        // Check if ray is close enough to scene geometry
        float hitDistance = length(targetPosition - viewPosition);
        float acceptThreshold = (RADIUS / (float)STEPS) + ssrParams.w * 0.1;

        if (hitDistance < acceptThreshold)
        {
            // Potential hit - check if ray is behind the surface
            if (sceneDepth < projectedPos.z)
            {
                // Binary refinement: step back and halve step size
                // This improves accuracy without additional samples
                viewPosition -= reflectionDir;
                reflectionDir *= 0.5;
            }
        }
    }

    // ========================================================================
    // Fadeout Calculations
    // Reduce reflection contribution at screen edges and for distant hits
    // ========================================================================

    // Screen edge fadeout: fade as we approach [-1,1] clip boundaries
    float2 clipBoundary = saturate(abs(projectedPos.xy));
    float edgeFadeout = saturate(1 - length(clipBoundary));

    // Depth fadeout: fade for samples behind the far plane
    float depthFadeout = saturate(projectedPos.z);

    // Distance fadeout: fade for rays that traveled far
    // Uses pow(..., 16) for sharp falloff near max radius
    float distanceTraveled = length(viewPositionStart - viewPosition);
    float distanceFadeout = 1.0 - saturate(pow(distanceTraveled / RADIUS, 16));

    // Combine all fadeout factors
    float combinedFadeout = min(min(edgeFadeout, depthFadeout), distanceFadeout);

    // ========================================================================
    // Sample Reflection Color
    // Use roughness to select mip level (rougher = blurrier reflection)
    // ========================================================================
    float mipLevel = normalData.w * 16;  // Roughness → mip level
    float4 reflection = colorTexture.SampleLevel(pointSampler, screenCoord, mipLevel);

    // ========================================================================
    // Composite: background + reflection × fadeout × mask × (1 - roughness)
    // ========================================================================
    return background + reflection * combinedFadeout * background.w * (1 - normalData.w);
}
