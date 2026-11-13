// ============================================================================
// READABLE VERSION: ACES Color Grading (Tone Mapping)
// Original: ../materials/aces-color-grading.hlsl (57 lines)
//
// Algorithm: ACES (Academy Color Encoding System) filmic tone mapping.
//            Converts HDR linear values to LDR display-ready output using
//            the RRT (Reference Rendering Transform) and ODT (Output Device
//            Transform) approximation.
//
// The ACES Pipeline:
//   1. Transform from working color space to ACES color space (input matrix)
//   2. Apply the RRT+ODT combined curve (filmic S-curve)
//   3. Transform from ACES to output color space (output matrix)
//
// Curve Approximation:
//   The RRT+ODT is approximated by the rational polynomial:
//   output = (color * (color + 0.0245786) - 0.000090537) /
//            (color * (0.983729 * color + 0.4329510) + 0.238081)
//
// Parameters:
//   power — (unused in this implementation)
//   samplecnt — (unused in this implementation)
//
// References:
//   - ACES Central: https://acescentral.com/
//   - "Practical HDR and Wide Color Techniques in Gran Turismo SPORT"
//   - Krzysztof Narkowicz's ACES approximation
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
    float power;      // Unused
    float sampleCount; // Unused
}

// ============================================================================
// Pixel Shader — ACES Tone Mapping
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0, float4 pixelPos : SV_POSITION) : SV_TARGET0
{
    // Load HDR color
    float3 color = inputTexture.Load(int3(pixelPos.xy, 0)).rgb;

    // ========================================================================
    // ACES Input Matrix
    //
    // Transforms from sRGB/Rec.709 working space to ACES AP1 color space.
    // This matrix is the product of sRGB-to-XYZ and XYZ-to-AP1 transforms.
    // ========================================================================
    float3x3 ACES_INPUT_MAT = float3x3(
        0.59719, 0.35458, 0.04823,
        0.07600, 0.90834, 0.01566,
        0.02840, 0.13383, 0.83777
    );

    // ========================================================================
    // ACES Output Matrix
    //
    // Transforms from ACES AP1 back to sRGB/Rec.709 for display.
    // This is approximately the inverse of the input matrix, but also
    // includes adjustments for the output device characteristics.
    // ========================================================================
    float3x3 ACES_OUTPUT_MAT = float3x3(
         1.60475, -0.53108, -0.07367,
        -0.10208,  1.10813, -0.00605,
        -0.00327, -0.07276,  1.07602
    );

    // Transform to ACES color space
    color = mul(ACES_INPUT_MAT, color);

    // ========================================================================
    // RRT + ODT Approximation
    //
    // This rational polynomial approximates the combined effect of:
    // - Reference Rendering Transform (RRT): Scene-referred to display-referred
    // - Output Device Transform (ODT): Display-referred to device code values
    //
    // The curve has an S-shape with:
    // - Toe region: Lifts blacks slightly for better shadow detail
    // - Linear region: Maintains contrast in midtones
    // - Shoulder region: Rolls off highlights smoothly to prevent clipping
    //
    // Formula: (x * (x + 0.0245786) - 0.000090537) /
    //          (x * (0.983729 * x + 0.4329510) + 0.238081)
    // ========================================================================
    float3 a = color * (color + 0.0245786) - 0.000090537;
    float3 b = color * (0.983729 * color + 0.4329510) + 0.238081;
    color = a / b;

    // Transform back to output color space
    color = mul(ACES_OUTPUT_MAT, color);

    // Clamp to valid display range
    color = saturate(color);

    return float4(color, 1);
}
