// ============================================================================
// READABLE VERSION: Smoothstep Curve Application
// Original: ../texgen/smoothstep.hlsl (13 lines)
//
// Algorithm: Applies the smoothstep function to remap values with an S-curve.
//            Creates smooth transitions with zero derivative at edges.
//
// Smoothstep Math:
//   For t in [0, edge]:
//     x = clamp(t / edge, 0, 1)
//     output = x * x * (3 - 2 * x)
//
// The smoothstep function produces:
//   - Value 0 at input 0
//   - Value 1 at input = edge parameter
//   - Smooth S-curve transition between
//   - Zero slope at both endpoints (smooth acceleration/deceleration)
//
// Curve Shape:
//   - More gradual than linear near 0 and edge
//   - Steeper transition in the middle
//   - No harsh discontinuities
//
// Use Cases:
//   - Soft thresholding (binarize with soft edges)
//   - Contrast enhancement
//   - Smooth mask creation
//   - Animation easing
//   - Anti-aliased edge detection
//
// Parameters:
//   texgenParams.x — Edge threshold (values >= this become 1.0)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);
float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Apply Smoothstep
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // smoothstep(edge0, edge1, x) = smooth transition from 0 to 1
    // Here: edge0 = 0, edge1 = texgenParams.x
    // Values from 0 to edge1 are mapped through the S-curve to 0-1
    return smoothstep(0, texgenParams.x, color);
}
