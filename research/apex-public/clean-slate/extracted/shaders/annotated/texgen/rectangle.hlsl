// ============================================================================
// READABLE VERSION: Rounded Rectangle (Superellipse)
// Original: ../texgen/rectangle.hlsl (21 lines)
//
// Algorithm: Generates a rounded rectangle using the superellipse equation.
//            The superellipse formula |x/a|^n + |y/b|^n = 1 creates shapes
//            ranging from diamonds (n<2) to circles (n=2) to rectangles (n>2).
//
// Superellipse Math:
//   For point (x, y) relative to center, with radii (a, b) and exponent n:
//   distance = (|x/a|^n + |y/b|^n)^(1/n)
//
//   When distance < 1, point is inside the shape.
//   When distance = 1, point is on the boundary.
//   When distance > 1, point is outside.
//
// Shape Variations (controlled by Chamfer parameter):
//   n = 1   : Diamond (rhombus)
//   n = 2   : Ellipse
//   n = 2.5 : Rounded rectangle
//   n → ∞   : Perfect rectangle
//
// The shader converts the inside/outside function to a smooth gradient
// with configurable falloff for soft edges.
//
// Use Cases:
//   - Rounded UI elements
//   - Pill/capsule shapes
//   - Soft-edged masks
//   - iOS-style icons (squircles)
//
// Parameters:
//   texgenParams.xy — Center position
//   texgenParams.zw — Half-width and half-height (radii)
//   texgenParams2.x — Chamfer (roundness): 0 = circle, 1 = rectangle
//   texgenParams2.y — Falloff sharpness (0 = hard edge, higher = softer)
// ============================================================================

float4 texgenParams : register(c1);
float4 texgenParams2 : register(c2);

// ============================================================================
// Pixel Shader — Generate Superellipse Shape
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // ========================================================================
    // Superellipse Exponent
    //
    // The chamfer parameter (0-1) maps to exponent (1-∞).
    // Formula: exponent = 2 / chamfer, so:
    //   chamfer = 1.0 → exponent = 2 (circle)
    //   chamfer = 0.5 → exponent = 4 (rounded rect)
    //   chamfer → 0   → exponent → ∞ (sharp rectangle)
    //
    // The dc variable adjusts radius scaling to maintain consistent size.
    // ========================================================================
    float chamferExponent = 2.0 / texgenParams2.x;
    float radiusScale = (1 + texgenParams2.x) / 2;

    // Vector from center to current point (with small offset to avoid edge artifacts)
    float2 centerOffset = texgenParams.xy - texCoord + 0.5 / 255.0;

    // Normalize by radii (adjusted for chamfer)
    float2 normalizedDist = abs(centerOffset / texgenParams.zw / radiusScale);

    // ========================================================================
    // Superellipse Distance
    //
    // distance = (|x|^n + |y|^n)^(1/n)
    // Inside = distance < 1, on boundary = 1, outside > 1
    // ========================================================================
    float superellipseDist = sqrt(
        pow(normalizedDist.x, chamferExponent) +
        pow(normalizedDist.y, chamferExponent)
    );

    // Convert to inside/outside: 1 at center, 0 at boundary, negative outside
    float insideAmount = 1 - saturate(superellipseDist);

    // ========================================================================
    // Falloff
    //
    // Apply power function for soft edge gradient.
    // The +0.5 offset shifts the falloff curve.
    // Higher falloff values create sharper edges.
    // ========================================================================
    float falloffExponent = 1.0 / texgenParams2.y * 10;
    return pow(abs(insideAmount + 0.5), falloffExponent);
}
