// ============================================================================
// READABLE VERSION: Rotation and Zoom Transform
// Original: ../texgen/rotozoom.hlsl (26 lines)
//
// Algorithm: Applies 2D rotation and uniform scaling around a center point.
//            Classic demoscene "rotozoom" effect used for tunnels, plasma,
//            and kaleidoscopic visuals.
//
// Transform Order:
//   1. Translate UV so center point is at origin
//   2. Apply rotation matrix
//   3. Apply zoom (scale)
//   4. Translate back to center at (0.5, 0.5)
//
// Rotation Matrix:
//   [cos(θ)  sin(θ)]
//   [-sin(θ) cos(θ)]
//
// The shader applies the inverse transform to UV coordinates, which is
// equivalent to transforming the texture in the opposite direction.
//
// Use Cases:
//   - Spinning logos/patterns
//   - Tunnel effects
//   - Kaleidoscope rotations
//   - Animated backgrounds
//   - UI transitions
//
// Parameters:
//   texgenParams.x — Rotation angle (0-1 → 0-2π radians)
//   texgenParams.y — Zoom level (0-1 → 0-255, smaller = more zoom)
//   texgenParams.zw — Center point (0-1 coordinates)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Apply Rotation and Zoom
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Get center point (parameters stored as 0-1, need slight adjustment)
    float2 center = texgenParams.zw * 255.0 / 256.0;

    // Calculate zoom factor (inverse relationship: smaller param = more zoom)
    float zoom = 0.25 / (texgenParams.y * 255.0 / 256.0);

    // Translate so center is at origin
    float2 uv = texCoord - center;

    // Calculate rotation angle (0-1 maps to 0-2π)
    float angle = texgenParams.x * 255.0 / 256.0 * 3.14159265 * 2.0;

    // Rotation matrix components
    float cosA = cos(angle);
    float sinA = sin(angle);

    // Apply rotation (inverse transform for UV mapping)
    // This rotates the sampling coordinates in the opposite direction,
    // which makes the texture appear to rotate in the specified direction
    float2 rotatedUV = float2(
        uv.x * cosA + uv.y * sinA,
        uv.y * cosA - uv.x * sinA
    );

    // Apply zoom and recenter at (0.5, 0.5)
    float2 finalUV = rotatedUV * zoom + 0.5;

    return inputTexture.Sample(linearSampler, finalUV);
}
