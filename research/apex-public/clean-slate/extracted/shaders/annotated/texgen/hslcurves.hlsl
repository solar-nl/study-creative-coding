// ============================================================================
// READABLE VERSION: HSV Curves (Hue/Saturation/Value Adjustment)
// Original: ../texgen/hslcurves.hlsl (63 lines)
//
// Algorithm: Applies curves adjustment in HSV color space.
//            Converts RGB to HSV, applies per-channel curves, converts back.
//
// Note: Despite the name "HSLCurves", this shader actually operates in
// HSV (Hue, Saturation, Value) space, not HSL (Hue, Saturation, Lightness).
// The difference:
//   - HSV Value: Pure color at V=1 (e.g., pure red)
//   - HSL Lightness: Pure color at L=0.5 (white at L=1)
//
// HSV Color Space:
//   H (Hue): 0-6 representing color wheel position
//     0=Red, 1=Yellow, 2=Green, 3=Cyan, 4=Blue, 5=Magenta, 6=Red
//   S (Saturation): 0-1 from gray to full color
//   V (Value): 0-1 from black to full brightness
//
// Use Cases:
//   - Hue rotation/shifting
//   - Saturation boost/reduction
//   - Value/brightness curves
//   - Color-preserving adjustments
//
// Parameters:
//   Texture0 — Input image
//   Texture1 — Curves texture (H in R, S in G, V in B)
// ============================================================================

SamplerState linearSampler : register(s0);
SamplerState curvesSampler : register(s1);

Texture2D inputTexture : register(t0);
Texture2D curvesTexture : register(t1);

// ============================================================================
// RGB to HSV Conversion
//
// Algorithm:
//   V = max(R, G, B)
//   S = (V - min(R, G, B)) / V
//   H = computed from which channel is maximum and differences
//
// Output: float3(H, S, V) where H is in range 0-6
// ============================================================================
float3 RgbToHsv(float3 rgb)
{
    float3 hsv;

    // Value = maximum channel
    hsv.z = max(max(rgb.x, rgb.y), rgb.z);
    float minChannel = min(min(rgb.x, rgb.y), rgb.z);

    float delta = hsv.z - minChannel;

    // Saturation = range / max (or 0 if max is 0)
    hsv.y = (hsv.z != 0) ? delta / hsv.z : 0;

    // Hue calculation based on which channel is max
    float3 deltaFromMax = hsv.z - rgb;

    // Default: red is max → H between yellow and magenta
    hsv.x = (deltaFromMax.z - deltaFromMax.y) / delta;

    // Green is max → H between cyan and yellow
    if (rgb.y == hsv.z)
        hsv.x = (deltaFromMax.x - deltaFromMax.z) / delta + 2;

    // Blue is max → H between magenta and cyan
    if (rgb.z == hsv.z)
        hsv.x = (deltaFromMax.y - deltaFromMax.x) / delta + 4;

    // Handle achromatic (gray) case
    if (delta == 0)
        hsv.x = -1;

    return hsv;
}

// ============================================================================
// HSV to RGB Conversion
//
// Uses the standard sextant-based conversion.
// H is expected in range 0-6 (wraps via fmod).
// ============================================================================
float3 HsvToRgb(float3 hsv)
{
    float3 rgb;

    // Wrap hue to 0-6 range
    hsv.x = fmod(hsv.x + 6, 6);

    // Fractional part for interpolation within sextant
    float frac = hsv.x - (int)hsv.x;
    int sextant = (int)hsv.x;

    // Each sextant has a different RGB formula
    // Pattern: one channel at 1, one at 0, one transitioning
    rgb = float3(0, 1 - frac, 1);          // Sextant 0: R↑, G=0, B=1
    if (sextant == 1) rgb = float3(frac, 0, 1);         // G↑, R=0, B=1
    if (sextant == 2) rgb = float3(1, 0, 1 - frac);     // G=1, R=0, B↓
    if (sextant == 3) rgb = float3(1, frac, 0);         // G=1, R↑, B=0
    if (sextant == 4) rgb = float3(1 - frac, 1, 0);     // G↓, R=1, B=0
    if (sextant == 5) rgb = float3(0, 1, frac);         // G=0, R=1, B↑

    // Apply saturation and value: rgb = V * (1 - S * (1 - rgb))
    return (1 - rgb * hsv.y) * hsv.z;
}

// ============================================================================
// Pixel Shader — Apply Curves in HSV Space
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);

    // Convert to HSV
    float3 hsv = RgbToHsv(color.xyz);

    // Apply curves (hue normalized to 0-1 for lookup, then scaled back)
    float3 adjusted;
    adjusted.x = curvesTexture.Sample(curvesSampler, float2(hsv.x / 6, 0)).x * 6;
    adjusted.y = curvesTexture.Sample(curvesSampler, float2(hsv.y, 0)).y;
    adjusted.z = curvesTexture.Sample(curvesSampler, float2(hsv.z, 0)).z;

    // Convert back to RGB, preserve original alpha
    return float4(HsvToRgb(adjusted), color.w);
}
