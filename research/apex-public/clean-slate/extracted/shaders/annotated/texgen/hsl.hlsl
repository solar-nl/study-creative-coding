// ============================================================================
// READABLE VERSION: HSV/HSL Color Adjustment
// Original: ../texgen/hsl.hlsl (73 lines)
//
// Algorithm: Converts RGB to HSV, applies hue rotation and saturation/lightness
//            adjustments, then converts back to RGB. Uses standard color space
//            conversion formulas.
//
// Parameters:
//   texgenParams.x — Hue rotation (0-1 maps to 0-6 hue units, i.e., full rotation)
//   texgenParams.y — Saturation multiplier (0-1 maps to 0-4×)
//   texgenParams.z — Lightness adjustment (0-0.5 = darken, 0.5-1 = brighten)
//
// Color Space:
//   Uses HSV (Hue, Saturation, Value) internally.
//   Hue is in range [0, 6] representing the color wheel in 60° segments.
//   The "lightness" parameter is actually applied to Value.
//
// References:
//   - Standard RGB↔HSV conversion algorithms
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D inputTexture : register(t0);

float4 texgenParams : register(c1);  // x=hue, y=saturation, z=lightness

// ============================================================================
// Convert RGB to HSV
// H is in range [0, 6] (hue sextant), S and V in [0, 1]
// ============================================================================
float3 RgbToHsv(float3 rgb)
{
    float3 hsv;

    // Value = maximum RGB component
    hsv.z = max(max(rgb.r, rgb.g), rgb.b);
    float minComponent = min(min(rgb.r, rgb.g), rgb.b);

    // Chroma (range of RGB values)
    float delta = hsv.z - minComponent;

    // Saturation = chroma / value (avoid divide by zero)
    if (hsv.z != 0)
        hsv.y = delta / hsv.z;
    else
        hsv.y = 0;

    // Hue calculation (which sextant of the color wheel)
    // distance from max to each component
    float3 distFromMax = hsv.z - rgb;

    // Default: red is max, hue between yellow and magenta
    hsv.x = (distFromMax.b - distFromMax.g) / delta;

    // Green is max: hue between cyan and yellow
    if (rgb.g == hsv.z)
        hsv.x = (distFromMax.r - distFromMax.b) / delta + 2;

    // Blue is max: hue between magenta and cyan
    if (rgb.b == hsv.z)
        hsv.x = (distFromMax.g - distFromMax.r) / delta + 4;

    // Handle grayscale (no chroma)
    if (delta == 0)
        hsv.x = -1;

    return hsv;
}

// ============================================================================
// Convert HSV back to RGB
// H is in range [0, 6], S and V in [0, 1]
// ============================================================================
float3 HsvToRgb(float3 hsv)
{
    float3 rgb;

    // Wrap hue to [0, 6] range
    hsv.x = fmod(hsv.x + 6, 6);

    // Fractional part determines position within sextant
    float fraction = hsv.x - (int)hsv.x;

    // Sextant (which 60° segment of the color wheel)
    int sextant = (int)hsv.x;

    // Each sextant has a specific RGB pattern
    // The pattern is determined by which component is ramping up or down
    rgb = float3(0, 1 - fraction, 1);           // Sextant 0: Red max, Green falling
    if (sextant == 1) rgb = float3(fraction, 0, 1);         // Green max, Red rising
    if (sextant == 2) rgb = float3(1, 0, 1 - fraction);     // Green max, Blue falling
    if (sextant == 3) rgb = float3(1, fraction, 0);         // Blue max, Green rising
    if (sextant == 4) rgb = float3(1 - fraction, 1, 0);     // Blue max, Red falling
    if (sextant == 5) rgb = float3(0, 1, fraction);         // Red max, Blue rising

    // Apply saturation and value
    // (1 - rgb * saturation) * value
    // When saturation = 0, all components become equal (grayscale)
    // When saturation = 1, full color intensity
    return (1 - rgb * hsv.y) * hsv.z;
}

// ============================================================================
// Main Pixel Shader
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // Decode parameters (stored as normalized 0-1, need to rescale)
    float4 params = texgenParams / 256 * 255;

    // Convert to HSV
    color.xyz = RgbToHsv(color.xyz);

    // ========================================================================
    // Apply adjustments
    // ========================================================================

    // Hue rotation: params.x maps 0-1 to 0-6 (full color wheel rotation)
    color.x += params.x * 6;

    // Saturation: params.y maps 0-1 to 0-4× multiplier
    color.y *= params.y * 4;

    // Lightness (actually Value in HSV):
    //   params.z < 0.5: darken (multiply value by params.z * 2)
    //   params.z > 0.5: brighten (lerp value toward 1)
    if (params.z < 0.5)
    {
        color.z *= params.z * 2;  // Darken: 0 = black, 0.5 = unchanged
    }
    else
    {
        color.z = lerp(color.z, 1, (params.z - 0.5) * 2);  // Brighten: 0.5 = unchanged, 1 = white
    }

    // Convert back to RGB and clamp
    color.xyz = saturate(HsvToRgb(color.xyz));

    return color;
}
