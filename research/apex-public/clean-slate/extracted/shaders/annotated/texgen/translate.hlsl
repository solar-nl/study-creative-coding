// ============================================================================
// READABLE VERSION: UV Translation (Offset)
// Original: ../texgen/translate.hlsl (24 lines)
//
// Algorithm: Offsets UV coordinates to pan/scroll a texture, with an optional
//            45-degree rotation preprocessing step.
//
// Features:
//   - Simple UV offset (pan/scroll)
//   - Optional 45° rotation with √2 scale compensation
//
// The 45° Rotation Option:
//   When enabled, rotates the texture 45° and scales by 1/√2 to maintain
//   the same apparent size. This is useful for creating diagonal patterns
//   from horizontal/vertical ones.
//
// Math for 45° rotation:
//   θ = π/4 (45 degrees)
//   Scale by 1/√2 to compensate for diagonal stretching
//   Rotation matrix: [cos(θ) -sin(θ)] / √2
//                    [sin(θ)  cos(θ)]
//
// Use Cases:
//   - Scrolling backgrounds
//   - Animated texture panning
//   - Diagonal pattern conversion
//   - Texture alignment adjustment
//
// Parameters:
//   texgenParams.x — Enable 45° rotation (>0 = enabled)
//   texgenParams.yz — X and Y offset amounts (0-1 → 0-255 range)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 PassData : register(c0);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Apply Offset and Optional 45° Rotation
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float2 uv = texCoord;

    // ========================================================================
    // Optional 45° Rotation
    //
    // Rotates UV by 45 degrees around center (0.5, 0.5).
    // The 1/√2 scale factor compensates for diagonal stretching.
    // ========================================================================
    if (texgenParams.x > 0)
    {
        float angle = 3.14159265 / 4.0;  // 45 degrees
        float cosA = cos(angle);
        float sinA = sin(angle);

        // Build rotation matrix scaled by 1/√2
        float2x2 rotMatrix = float2x2(cosA, -sinA, sinA, cosA) / sqrt(2.0);

        // Transform around center
        uv = mul(rotMatrix, (uv - 0.5) * 2.0) / 2.0 + 0.5;
    }

    // ========================================================================
    // Apply UV Offset
    // Parameters stored as 0-1, convert to fractional offset
    // ========================================================================
    float2 offset = texgenParams.yz * 255.0 / 256.0;

    return inputTexture.Sample(linearSampler, uv + offset);
}
