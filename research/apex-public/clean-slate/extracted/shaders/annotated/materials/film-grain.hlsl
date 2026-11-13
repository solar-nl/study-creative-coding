// ============================================================================
// READABLE VERSION: Film Grain
// Original: ../materials/film-grain.hlsl (101 lines)
//
// Algorithm: Animated 3D Perlin noise overlaid on the image to simulate
//            photographic film grain. Grain intensity is modulated by
//            scene luminance (darker areas get more visible grain).
//
// Technique:
//   1. Generate time-animated 3D Perlin noise at screen coordinates
//   2. Optionally colorize the grain (separate R/G/B noise)
//   3. Scale grain visibility by luminance response curve
//   4. Blend grain additively with original image
//
// Perlin Noise Implementation:
//   Uses a procedural hash function instead of a permutation texture.
//   Implements standard trilinear interpolation with Hermite smoothstep.
//
// Parameters:
//   coloramount — Color vs monochrome grain (0 = mono, 1 = full color)
//   lumamount — Luminance response strength (0 = flat, 1 = full response)
//   grainsiz — Grain scale (0 = fine, 1 = coarse)
//   grainam — Grain intensity multiplier
//
// References:
//   - "Improved Noise Reference Implementation" (Ken Perlin)
//   - Martins Upitis' film grain shader
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
    float colorAmount, luminanceAmount;
    float grainSize, grainIntensity;
}

// ============================================================================
// Random Number Generator (Hash-Based)
//
// Generates pseudo-random values from 2D coordinates using a hash function.
// Time parameter animates the grain.
// ============================================================================
float4 RandomHash(float2 coord)
{
    // Classic hash using sine and dot product with "magic" constants
    return frac(
        sin(dot(coord + float2(time, time), float2(12.9898, 78.233))) * 43758.5453
        * float4(1, 1.2154, 1.3453, 1.3647)
    ) * 2 - 1;  // Map to [-1, 1] range
}

// ============================================================================
// Hermite Smoothstep Fade (Quintic)
//
// Ken Perlin's improved smoothstep: 6t^5 - 15t^4 + 10t^3
// Has zero first AND second derivatives at boundaries for smoother results.
// ============================================================================
float Fade(float t)
{
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// ============================================================================
// 3D Perlin Noise
//
// Standard implementation using hash-based gradients and trilinear
// interpolation with smoothstep blending.
// ============================================================================
float PerlinNoise3D(float3 p)
{
    float permTexUnit = 1.0 / 256.0;
    float permTexUnitHalf = 0.5 / 256.0;

    // Integer coordinates (scaled for hash lookup)
    float3 pi = permTexUnit * floor(p) + permTexUnitHalf;

    // Fractional coordinates for interpolation
    float3 pf = frac(p);

    // Sample gradients at 8 cube corners
    float n[8];
    for (int x = 0; x < 2; x++)
        for (int y = 0; y < 2; y++)
            for (int z = 0; z < 2; z++)
            {
                // Get gradient from hash, compute dot product with offset
                float4 hashVal = RandomHash(float2(
                    RandomHash(pi.xy + permTexUnit * float2(x, y)).w,
                    pi.z + permTexUnit * z
                ));
                float3 gradient = hashVal.xyz * 4.0 - 1.0;
                n[x*4 + y*2 + z] = dot(gradient, pf - float3(x, y, z));
            }

    // Trilinear interpolation with smoothstep
    float4 n_x = lerp(float4(n[0], n[1], n[2], n[3]),
                      float4(n[4], n[5], n[6], n[7]),
                      Fade(pf.x));
    float2 n_xy = lerp(n_x.xy, n_x.zw, Fade(pf.y));
    float n_xyz = lerp(n_xy.x, n_xy.y, Fade(pf.z));

    return n_xyz;
}

// ============================================================================
// Coordinate Rotation (for grain variation)
// Rotates UV coordinates while maintaining aspect ratio
// ============================================================================
float2 RotateCoord(float2 coord, float angle)
{
    coord.x *= aspectRatio;
    coord = mul(float2x2(cos(angle), -sin(angle), sin(angle), cos(angle)), coord);
    coord.x /= aspectRatio;
    return coord;
}

// ============================================================================
// Pixel Shader — Film Grain
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Calculate grain scale (1.5 to 2.5 range)
    float grainScale = lerp(1.5, 2.5, grainSize);
    float2 grainRes = float2(screenWidth / grainScale, screenHeight / grainScale);

    // ========================================================================
    // Generate Color Grain
    //
    // Each color channel uses different rotation angles for the noise
    // coordinates, creating subtle color variation in the grain.
    // ========================================================================
    float2 rotCoordsR = RotateCoord(texCoord, time + 1.425) * grainRes;
    float2 rotCoordsG = RotateCoord(texCoord, time + 3.892) * grainRes;
    float2 rotCoordsB = RotateCoord(texCoord, time + 5.835) * grainRes;

    float3 noise = float3(
        PerlinNoise3D(float3(rotCoordsR, 0)),
        PerlinNoise3D(float3(rotCoordsG, 1)),
        PerlinNoise3D(float3(rotCoordsB, 2))
    );

    // Blend between monochrome and color grain
    noise = lerp(noise.r, noise, colorAmount);

    // Sample original image
    float3 color = inputTexture.Sample(linearSampler, texCoord).rgb;

    // ========================================================================
    // Luminance-Based Grain Response
    //
    // Film grain is typically more visible in shadows. This curve:
    // - Increases grain in dark areas (smoothstep from 0.2 to 0)
    // - Decreases grain in bright areas (via pow(lum, 4))
    // ========================================================================
    float luminance = lerp(0.0, dot(color, float3(0.3, 0.587, 0.114)), luminanceAmount);
    float lumResponse = smoothstep(0.2, 0.0, luminance) + luminance;

    // Apply grain with luminance-weighted intensity
    float3 grainMask = lerp(noise, 0, pow(lumResponse, 4)) * grainIntensity * 0.1;

    return float4(color + grainMask, 1);
}
