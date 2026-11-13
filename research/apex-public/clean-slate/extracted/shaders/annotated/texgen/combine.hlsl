// ============================================================================
// READABLE VERSION: Blend Modes (Combine)
// Original: ../texgen/combine.hlsl (27 lines)
//
// Algorithm: Implements standard compositing blend modes for combining two
//            textures. These are the same blend modes found in Photoshop,
//            After Effects, and other image editing software.
//
// Available Blend Modes:
//   0 — Add:         a + b                     (brightening, glow)
//   1 — Subtract:    a - b                     (darkening, difference)
//   2 — Multiply:    a * b                     (shadows, darken)
//   3 — Alpha:       a*(1-b.a) + b*b.a         (standard compositing)
//   4 — Min:         min(a, b)                 (darken only)
//   5 — Max:         max(a, b)                 (lighten only)
//   6 — Color Dodge: a / (1-b)                 (extreme lighten)
//   7 — Color Burn:  1 - (1-a)/b               (extreme darken)
//   8 — Screen:      1 - (1-a)*(1-b)           (lighten, opposite of multiply)
//   9 — Hard Light:  multiply if a<0.5, screen otherwise
//
// Mathematical Derivations:
//   Screen is "multiply the inverses, then invert"
//   Color Dodge divides by (1-overlay), approaching infinity as overlay→1
//   Color Burn is the inverse of color dodge
//   Hard Light combines multiply and screen based on value threshold
//
// Use Cases:
//   - Layer compositing
//   - Lighting effects (screen, add)
//   - Shadow effects (multiply, burn)
//   - Contrast enhancement (hard light)
//
// Parameters:
//   texgenParams.x — Blend mode selector (0-9, stored as 0-1 → 0-255)
// ============================================================================

SamplerState linearSampler : register(s0);
float4 texgenParams : register(c1);
Texture2D texture1 : register(t0);
Texture2D texture2 : register(t1);

// ============================================================================
// Pixel Shader — Apply Selected Blend Mode
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float4 a = texture1.Sample(linearSampler, texCoord);  // Base layer
    float4 b = texture2.Sample(linearSampler, texCoord);  // Blend layer

    int blendMode = (int)(texgenParams.x * 256);

    float4 result = a + b;  // Default: Add (mode 0)

    if (blendMode == 1)  // Subtract
        result = a - b;

    if (blendMode == 2)  // Multiply
        result = a * b;

    if (blendMode == 3)  // Alpha Composite
        result = a * (1 - b.w) + b * b.w;

    if (blendMode == 4)  // Darken (Min)
        result = min(a, b);

    if (blendMode == 5)  // Lighten (Max)
        result = max(a, b);

    if (blendMode == 6)  // Color Dodge
        result = a / (1 - b);

    if (blendMode == 7)  // Color Burn
        result = 1 - (1 - a) / b;

    if (blendMode == 8)  // Screen
        result = 1 - (1 - a) * (1 - b);

    if (blendMode == 9)  // Hard Light
        result = lerp(1 - 2 * (1 - a) * (1 - b), 2 * a * b, a < 0.5);

    return result;
}
