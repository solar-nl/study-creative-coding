// ============================================================================
// READABLE VERSION: Polar Coordinate Transform
// Original: ../texgen/to-polar.hlsl (33 lines)
//
// Algorithm: Converts between Cartesian (rectangular) and polar coordinates.
//            Enables radial effects like tunnels, circular distortions, and
//            wrapping linear patterns into circles.
//
// Coordinate Systems:
//   Cartesian: (x, y) — standard UV coordinates
//   Polar: (θ, r) — angle and radius from center
//
// Rect → Polar (mode 0):
//   r = distance from center (0 at center, 1 at corner)
//   θ = angle around center (0-1 mapped from -π to π)
//
// Polar → Rect (mode 1):
//   x = r * sin(θ * 2π) + 0.5
//   y = r * cos(θ * 2π) + 0.5
//
// Use Cases:
//   Rect → Polar:
//     - Radial blur preparation
//     - Circular vignette
//     - Star burst patterns
//
//   Polar → Rect:
//     - Tunnel effect (linear pattern becomes circular tunnel)
//     - Wrap linear gradient into radial
//     - Clock/dial faces
//
// Parameters:
//   texgenParams.x — Direction (0 = Rect→Polar, other = Polar→Rect)
//   texgenParams.y — Flip Y axis (0 = normal, other = flipped)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);

// ============================================================================
// Cartesian to Polar Conversion
//
// Takes UV in [0,1] space, outputs:
//   x = angle (0-1, wrapping)
//   y = radius (0 at center, 1 at edge)
// ============================================================================
float2 RectToPolar(float2 uv)
{
    float2 centered = uv - 0.5;

    // Radius: distance from center, scaled so corner = 1
    float radius = saturate(length(centered) * 2.0);

    // Angle: atan2 gives -π to π, normalize to 0-1
    float angle = atan2(centered.x, centered.y) / 3.14159265 / 2.0;

    return float2(angle, radius);
}

// ============================================================================
// Polar to Cartesian Conversion
//
// Takes UV where x = angle (0-1), y = radius (0-1)
// Outputs standard UV coordinates
// ============================================================================
float2 PolarToRect(float2 uv)
{
    float radius = uv.y / 2.0;
    float angle = uv.x * 3.14159265 * 2.0;

    // Convert angle+radius to XY offset from center
    return radius * float2(sin(angle), cos(angle)) + 0.5;
}

// ============================================================================
// Pixel Shader — Apply Polar Transform
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float2 uv = texCoord;

    // Optional Y-axis flip
    if (texgenParams.y != 0)
        uv.y = 1 - uv.y;

    // Apply selected transform direction
    if (texgenParams.x == 0)
        uv = RectToPolar(uv);
    else
        uv = PolarToRect(uv);

    // Use SampleLevel to avoid mipmap artifacts at polar singularity
    return inputTexture.SampleLevel(linearSampler, uv, 0);
}
