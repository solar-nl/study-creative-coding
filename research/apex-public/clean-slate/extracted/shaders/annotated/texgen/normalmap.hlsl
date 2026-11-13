// ============================================================================
// READABLE VERSION: Height-to-Normal Map Generator
// Original: ../texgen/normalmap.hlsl (29 lines)
//
// Algorithm: Sobel-style finite difference normal extraction.
//            Samples height at 4 neighboring pixels, computes gradients,
//            constructs normal vector from derivatives.
//
// Parameters:
//   texgenParams.x — Control channel (0=R, 1=G, 2=B, 3=A, encoded as value × 256)
//   texgenParams.y — Strength (normal Z scale, encoded as value × 255)
//                    Higher values = flatter normals, lower = bumpier
//
// Output:
//   RGB = Normal vector (encoded as N × 0.5 + 0.5 for [0,1] range)
//   A = 1.0
//
// References:
//   - Standard finite-difference normal calculation
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D heightTexture : register(t0);

float4 texgenParams : register(c1);  // x=channel, y=strength

float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Sample offset: 0.5 pixels at 4096×4096 resolution
    // This provides a good balance between detail capture and noise
    float sampleOffset = 0.5 / 4096.0;

    // Decode which color channel to use as height data
    // 0=Red, 1=Green, 2=Blue, 3=Alpha
    int heightChannel = texgenParams.x * 256;

    // ========================================================================
    // Sample height at 4 neighboring positions (cross pattern)
    // This is a simplified Sobel operator using only horizontal/vertical samples
    // ========================================================================
    float heightLeft  = heightTexture.Sample(linearSampler, texCoord - float2(sampleOffset, 0))[heightChannel];
    float heightRight = heightTexture.Sample(linearSampler, texCoord + float2(sampleOffset, 0))[heightChannel];
    float heightDown  = heightTexture.Sample(linearSampler, texCoord - float2(0, sampleOffset))[heightChannel];
    float heightUp    = heightTexture.Sample(linearSampler, texCoord + float2(0, sampleOffset))[heightChannel];

    // ========================================================================
    // Compute normal Z scale from strength parameter
    // The strength controls how "steep" the resulting normals appear:
    //   - strength = 0: Maximum bumpiness (Z near 0)
    //   - strength = 1: Nearly flat surface (Z large)
    //
    // The formula applies power-of-4 falloff for artistic control:
    //   base = (1 - strength) × 1.2
    //   scale = base⁴ / 8
    // ========================================================================
    float strengthBase = (1 - texgenParams.y * 255 / 256.0) * 1.2;
    float zScale = strengthBase * strengthBase;     // base²
    zScale = zScale * zScale;                        // base⁴
    zScale = zScale / 8.0;                           // Normalize range

    // ========================================================================
    // Construct normal from height gradients
    // The gradient in X is (right - left), gradient in Y is (up - down)
    // Z component is the constant scale factor (smaller = bumpier)
    // ========================================================================
    float3 normal = normalize(float3(
        heightRight - heightLeft,   // dH/dx (horizontal gradient)
        heightUp - heightDown,      // dH/dy (vertical gradient)
        zScale                      // Z scale (controls bumpiness)
    ));

    // Encode normal from [-1,1] to [0,1] range for texture storage
    normal = normal * 0.5 + 0.5;

    return float4(normal, 1);
}
