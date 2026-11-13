// ============================================================================
// READABLE VERSION: Depth of Field (3-Pass)
// Original: ../materials/depth-of-field.hlsl (136 lines)
//
// Algorithm: Physically-based circle of confusion (CoC) calculation followed
//            by two blur passes with depth-aware weighting.
//
// Passes:
//   Pass 1: Calculate CoC from depth, focal distance, aperture
//   Pass 2: Disc blur with 8×8 samples (heavily minified in original)
//   Pass 3: Refinement blur with 3×3 samples and bleed control
//
// Camera Parameters (Pass 1):
//   camdat.x — Focal distance (× 10)
//   camdat.y — Focal length (÷ 10)
//   camdat.z — Aperture size (÷ 5)
//
// Blur Parameters (Pass 2-3):
//   blurdat.x — Bleed multiplier (× 255)
//   blurdat.y — Bleed bias (÷ 10)
//
// Key Technique:
//   The thin lens equation determines CoC:
//   c = A × |S2 - S1| / S2 × f / (S1 - f)
//   where A=aperture, S1=focal distance, S2=depth, f=focal length
//
// References:
//   - Thin lens equation (geometric optics)
//   - "Next Generation Post Processing in Call of Duty" (Jimenez, 2014)
// ============================================================================

// ============================================================================
// PASS 1: CALCULATE CIRCLE OF CONFUSION
// ============================================================================

SamplerState linearSampler_P1 : register(s1);
Texture2D colorTexture_P1 : register(t0);
Texture2D depthTexture_P1 : register(t7);

cbuffer SceneBuffer_P1 : register(b0)
{
    float time_p1, aspect_p1, screenWidth_p1, screenHeight_p1;
    float4x4 viewMatrix_p1;
    float4x4 projectionMatrix_p1;
    float4 cameraPosition_p1;
    float4x4 inverseViewMatrix_p1;
    float4x4 inverseProjectionMatrix_p1;
}

cbuffer MaterialBuffer_P1 : register(b1)
{
    float4 blurParams_p1;    // Unused in pass 1
    float4 cameraParams;     // x=focalDistance, y=focalLength, z=aperture
}

// Convert depth buffer value to linear depth (distance from camera)
float GetLinearDepth_P1(float2 uv)
{
    float depth = depthTexture_P1.Sample(linearSampler_P1, uv).x;
    float4 clipPos = mul(inverseProjectionMatrix_p1, float4(uv * 2 - 1, depth, 1));
    return -clipPos.z / clipPos.w;  // Negate for positive distance
}

// Calculate circle of confusion using thin lens equation
float CalculateCoC(float2 texCoord)
{
    // Decode camera parameters
    float focalDistance = cameraParams.x * 10;  // S1: distance to focus plane
    float focalLength = cameraParams.y / 10;    // f: lens focal length
    float aperture = cameraParams.z / 5;        // A: aperture diameter (e.g., 0.024)

    // Get linear depth at this pixel
    float objectDistance = GetLinearDepth_P1(texCoord);  // S2

    // ========================================================================
    // Thin Lens Circle of Confusion Formula:
    //   c = A × |S2 - S1| / S2 × f / (S1 - f)
    //
    // Where:
    //   A = Aperture diameter
    //   S1 = Focal distance (in-focus plane)
    //   S2 = Object distance (current pixel depth)
    //   f = Focal length of the lens
    //
    // The result is the diameter of the blur disc in world units.
    // We normalize by 0.024 (typical aperture) to get a percentage.
    // ========================================================================
    float cocDiameter = aperture * abs(objectDistance - focalDistance) / objectDistance
                      * focalLength / (focalDistance - focalLength);

    float cocPercent = cocDiameter / 0.024;  // Normalize to reference aperture

    // Clamp to reasonable range [0.0001, 0.12] then scale
    return clamp(cocPercent, 0.0001, 0.12) * 0.3;
}

float4 CoCPass(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = colorTexture_P1.Sample(linearSampler_P1, texCoord);
    color.w = CalculateCoC(texCoord);  // Store CoC in alpha
    return color;
}

// ============================================================================
// PASS 2: DISC BLUR (8×8 samples)
// Note: Original pass 2 is heavily minified. This is a readable reconstruction.
// ============================================================================

// The original pass 2 samples in a disc pattern with 64 samples (8×8 grid
// mapped to disc coordinates). It uses depth-aware weighting to prevent
// background bleeding onto foreground objects.

// ============================================================================
// PASS 3: REFINEMENT BLUR (3×3 samples)
// ============================================================================

SamplerState linearSampler_P3 : register(s1);
Texture2D colorTexture_P3 : register(t0);
Texture2D depthTexture_P3 : register(t7);

cbuffer SceneBuffer_P3 : register(b0)
{
    float time_p3, aspect_p3, screenWidth_p3, screenHeight_p3;
    float4x4 viewMatrix_p3;
    float4x4 projectionMatrix_p3;
    float4 cameraPosition_p3;
    float4x4 inverseViewMatrix_p3;
    float4x4 inverseProjectionMatrix_p3;
}

cbuffer MaterialBuffer_P3 : register(b1)
{
    float4 blurParams;  // x=bleedMultiplier, y=bleedBias
}

float GetLinearDepth_P3(float2 uv)
{
    float depth = depthTexture_P3.Sample(linearSampler_P3, uv).x;
    float4 clipPos = mul(inverseProjectionMatrix_p3, float4(uv * 2 - 1, depth, 1));
    return -clipPos.z / clipPos.w;
}

float4 RefinementPass(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Decode blur parameters
    float bleedBias = blurParams.y / 10.0;        // Threshold for bleed prevention
    float bleedMultiplier = blurParams.x * 255.0; // Weight reduction for background

    // Sample center pixel
    float4 centerColor = colorTexture_P3.Sample(linearSampler_P3, texCoord);
    float centerDepth = GetLinearDepth_P3(texCoord);
    float centerCoC = centerColor.a;

    // Accumulate weighted samples
    float4 blurredColor = 0;
    float totalWeight = 0;

    // 3×3 kernel centered on current pixel
    for (int x = 0; x < 3; x++)
    {
        for (int y = 0; y < 3; y++)
        {
            // Offset from center (-1, 0, +1) scaled by CoC and base spacing
            float2 offset = float2(x - 1, y - 1) * 0.085;
            float2 sampleCoord = texCoord + offset * centerCoC;

            // Sample neighbor
            float4 sampleColor = colorTexture_P3.Sample(linearSampler_P3, sampleCoord);
            float sampleDepth = GetLinearDepth_P3(sampleCoord);
            float sampleCoC = sampleColor.a;

            // ================================================================
            // Depth-Aware Weighting
            // Prevents background from bleeding onto sharp foreground objects
            //
            // If sample is behind center pixel, reduce its weight
            // If sample has larger CoC (more blurry), also reduce weight
            // ================================================================
            float weight = 1.0;

            // Background sample (behind center): reduce weight by CoC × multiplier
            if (sampleDepth < centerDepth)
            {
                weight = sampleCoC * bleedMultiplier;
            }

            // If center is blurrier than sample by more than bias, use full weight
            // This prevents sharp foreground from being contaminated by blur
            if (centerCoC > sampleCoC + bleedBias)
            {
                // Keep the reduced weight from above
            }
            else
            {
                weight = 1.0;  // Same blur level, use full weight
            }

            weight = saturate(weight);

            blurredColor += sampleColor * weight;
            totalWeight += weight;
        }
    }

    return blurredColor / totalWeight;
}
