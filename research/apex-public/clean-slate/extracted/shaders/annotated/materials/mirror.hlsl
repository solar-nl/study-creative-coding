// ============================================================================
// READABLE VERSION: Mirror Reflection (Line-Based)
// Original: ../materials/mirror.hlsl (76 lines)
//
// Algorithm: 2D reflection across an arbitrary line.
//            Reflects pixels from one side of a line to the other,
//            creating a mirror effect with configurable axis.
//
// Mathematical Basis:
//   Given a mirror line through point P with direction D:
//   1. For each pixel A, find the closest point X on the mirror line
//   2. Reflect A across X: A' = 2X - A
//   3. Sample texture at A' for pixels on the reflected side
//
// The reflection formula uses the dot product projection:
//   X = P + D * dot(A - P, D)  // Closest point on line
//   A' = 2X - A                 // Reflection of A across X
//
// Parameters:
//   dir — Mirror line angle (0-1 maps to 0-90 degrees, then to 0-π/2 radians)
//   centerx, centery — Point on the mirror line (UV coordinates)
//
// Note:
//   The shader includes Hungarian comments from the original author
//   explaining the math step by step.
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
    float direction;     // Mirror angle (0-1 → 0-90°)
    float centerX;       // Mirror line X position
    float centerY;       // Mirror line Y position
}

// ============================================================================
// Pixel Shader — Line Reflection
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Hardcoded aspect ratio (16:9) — matches original
    float aspect = 16.0 / 9.0;

    // ========================================================================
    // Convert direction parameter to angle
    //
    // direction (0-1) maps to 0-90 degrees (0 to π/2 radians)
    // dir = 0.5 means 45° mirror line
    // ========================================================================
    float angle = 3.14159265 * direction / 2;

    // Mirror line defined by:
    //   P = (centerX, centerY) — point on the line
    //   D = (sin(angle), cos(angle)) — direction vector
    float2 P = float2(centerX, centerY);
    float2 D = float2(sin(angle), cos(angle));

    // Current pixel position
    float2 A = texCoord;

    // ========================================================================
    // Aspect Ratio Correction
    //
    // Convert to square coordinate space for correct angle math.
    // Without this, a 45° line would appear distorted on non-square screens.
    // ========================================================================
    P.y /= aspect;
    A.y /= aspect;

    // ========================================================================
    // Side Test
    //
    // Determine which side of the mirror line this pixel is on.
    // The perpendicular to D is (-D.y, D.x).
    // If dot(A - P, perpendicular) > 0, pixel is on the "keep" side.
    // ========================================================================
    float2 perpendicular = float2(-D.y, D.x);
    if (dot(A - P, perpendicular) > 0)
    {
        // Pixel is on the non-reflected side — return original
        return inputTexture.Sample(linearSampler, texCoord);
    }

    // ========================================================================
    // Calculate Reflection
    //
    // X = closest point on mirror line to A
    // X = P + D * dot(A - P, D)
    //
    // A' = reflection of A across X
    // A' = 2X - A
    // ========================================================================
    float2 X = P + D * dot(A - P, D);
    float2 reflectedA = 2 * X - A;

    // Convert back to screen space
    reflectedA.y *= aspect;

    // ========================================================================
    // Bounds Check
    //
    // Only sample if the reflected coordinate is within [0, 1] range.
    // Otherwise return black (no valid reflection source).
    // ========================================================================
    float4 result = 0;

    if (length(reflectedA - clamp(reflectedA, 0, 1)) < 0.0001)
    {
        result = inputTexture.Sample(linearSampler, reflectedA);
    }

    return result;
}
