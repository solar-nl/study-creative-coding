// ============================================================================
// READABLE VERSION: SubPlasma (Catmull-Rom Interpolated Plasma)
// Original: ../texgen/subplasma.hlsl (54 lines)
//
// Algorithm: Generates smooth plasma patterns by interpolating random values
//            on a grid using Catmull-Rom splines (pass 2) or linear (pass 1).
//            Pass 0 generates the initial random grid; later passes smooth it.
//
// Parameters:
//   texgenParams.x — Density (grid resolution, encoded as 2^(value×255+1))
//   texgenParams.y — Linear flag (0 = Catmull-Rom spline, 1 = linear lerp)
//
// Multi-Pass System:
//   Pass 0: Sample random noise at grid points
//   Pass 1: Horizontal interpolation (smooths X direction)
//   Pass 2+: Vertical interpolation (smooths Y direction)
//
// Key Technique:
//   Catmull-Rom splines produce smoother results than linear interpolation
//   because they pass through control points with continuous first derivatives.
//
// References:
//   - Catmull-Rom spline: E. Catmull, R. Rom (1974)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
Texture2D hashTexture : register(t1);

float4 passInfo : register(c0);      // x = pass index, y = frequency multiplier
float4 texgenParams : register(c1);  // x = density, y = linear flag

// ============================================================================
// Sample random value from hash texture
// ============================================================================
float4 SampleHashTexture(float2 integerCoord)
{
    float2 scaledCoord = integerCoord * 256 * (max(1, passInfo.x) * (1 + passInfo.y));
    return hashTexture.Load(int3(fmod(scaledCoord, 256), 0));
}

// ============================================================================
// Catmull-Rom Spline Interpolation
// Given 4 control points and parameter t in [0,1], returns smooth interpolation.
// The spline passes through v1 at t=0 and v2 at t=1.
//
// Formula: ((P×t + Q)×t + R)×t + v1
//   where P = (v3-v2) - (v0-v1)
//         Q = (v0-v1) - P
//         R = v2 - v0
// ============================================================================
float4 CatmullRomInterpolate(float4 v0, float4 v1, float4 v2, float4 v3, float t)
{
    float4 P = (v3 - v2) - (v0 - v1);   // Cubic coefficient
    float4 Q = (v0 - v1) - P;            // Quadratic coefficient
    float4 R = v2 - v0;                  // Linear coefficient (tangent at v1)

    // Horner's method for polynomial evaluation
    float4 result = (((P * t) + Q) * t + R) * t + v1;
    return result;
}

// ============================================================================
// Main Pixel Shader
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Calculate grid cell size from density parameter
    // Density 0 = 2 cells, Density 1 = 2^256 cells (practically infinite)
    float cellSize = 1 / pow(2.0, texgenParams.x * 255.0 + 1);

    // Find grid cell containing this UV coordinate
    float2 uv = texCoord;
    float2 fractionalPart = uv % cellSize;
    uv = uv - fractionalPart;  // Snap to cell corner

    // Sample initial noise value at grid position
    float4 result = SampleHashTexture(uv);

    // ========================================================================
    // Passes 1+: Interpolate between grid values
    // ========================================================================
    if (passInfo.x > 0)
    {
        // Determine interpolation direction
        // Pass 1-2: Horizontal (step in X)
        // Pass 3+: Vertical (step in Y)
        float2 stepDirection = float2(cellSize, 0);
        if (passInfo.x + 0.5 >= 2)
        {
            stepDirection = float2(0, cellSize);
        }

        // Sample 4 neighboring values for spline interpolation
        // v0, v1, v2, v3 are evenly spaced along the interpolation direction
        float4 samples[4];
        for (int i = 0; i < 4; i++)
        {
            samples[i] = inputTexture.Sample(linearSampler, texCoord + stepDirection * i);
        }

        // Calculate interpolation parameter (0-1 within the cell)
        float t = fractionalPart.x;
        if (passInfo.x + 0.5 >= 2)
        {
            t = fractionalPart.y;
        }

        // Normalize t to [0, 1] range within the cell
        t = t / cellSize;

        // ====================================================================
        // Choose interpolation method
        // Catmull-Rom produces smoother curves but is more expensive
        // Linear is faster but shows more grid artifacts
        // ====================================================================
        if (texgenParams.y == 0)  // Catmull-Rom mode
        {
            result = CatmullRomInterpolate(samples[0], samples[1], samples[2], samples[3], t);
        }
        else  // Linear mode
        {
            result = lerp(samples[1], samples[2], t);
        }
    }

    return result;
}
