// ============================================================================
// READABLE VERSION: Gradient Pattern Generator
// Original: ../texgen/gradient.hlsl (23 lines)
//
// Algorithm: Generates various gradient patterns based on UV coordinates.
//            Six pattern types: radial, box, horizontal, vertical, and
//            bidirectional variants.
//
// Parameters:
//   texgenParams.x — Pattern type (0-5, encoded as value × 256)
//
// Pattern Types:
//   0 = Radial (circular) — distance from center
//   1 = Box (diamond) — max(|x|, |y|) from center
//   2 = Horizontal — left to right
//   3 = Vertical — top to bottom
//   4 = Horizontal bidirectional — center to edges
//   5 = Vertical bidirectional — center to edges
//
// Output:
//   Grayscale value (0 = black/edge, 1 = white/center for radial patterns)
// ============================================================================

float4 texgenParams : register(c1);  // x = pattern type

float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float result = 0;

    // Decode pattern type from normalized parameter
    int patternType = (int)(texgenParams.x * 256);

    // Center the coordinate system at (0.5, 0.5)
    // This makes UV go from [-0.5, 0.5] instead of [0, 1]
    float2 centered = texCoord - 0.5;

    // ========================================================================
    // Pattern 0: Radial Gradient (Circular)
    // Distance from center, normalized so corners reach 0
    // sqrt(2) is the distance from center to corner
    // ========================================================================
    if (patternType == 0)
    {
        result = 1 - length(centered) * 2 / sqrt(2);
    }

    // ========================================================================
    // Pattern 1: Box Gradient (Diamond/Square)
    // Uses Chebyshev distance (max of |x|, |y|)
    // Creates a square pattern that reaches 0 at edges
    // ========================================================================
    if (patternType == 1)
    {
        result = 1 - max(abs(centered.x), abs(centered.y)) * 2;
    }

    // ========================================================================
    // Pattern 2: Horizontal Linear Gradient
    // Simple left-to-right ramp (0 at left, 1 at right)
    // ========================================================================
    if (patternType == 2)
    {
        result = texCoord.x;
    }

    // ========================================================================
    // Pattern 3: Vertical Linear Gradient
    // Simple top-to-bottom ramp (0 at top, 1 at bottom)
    // ========================================================================
    if (patternType == 3)
    {
        result = texCoord.y;
    }

    // ========================================================================
    // Pattern 4: Horizontal Bidirectional Gradient
    // White in center, black at left and right edges
    // Uses absolute value of distance from center
    // ========================================================================
    if (patternType == 4)
    {
        result = 1 - abs(1 - texCoord.x * 2);
    }

    // ========================================================================
    // Pattern 5: Vertical Bidirectional Gradient
    // White in center, black at top and bottom edges
    // ========================================================================
    if (patternType == 5)
    {
        result = 1 - abs(1 - texCoord.y * 2);
    }

    return result;
}
