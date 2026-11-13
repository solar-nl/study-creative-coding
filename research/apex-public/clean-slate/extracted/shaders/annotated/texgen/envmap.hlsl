// ============================================================================
// READABLE VERSION: Environment Map Gradient (Radial Falloff)
// Original: ../texgen/envmap.hlsl (17 lines)
//
// Algorithm: Generates a radial gradient for use as environment map lighting
//            or sphere mapping. Creates a smooth falloff from center to edge
//            with configurable inner and outer radii.
//
// Math:
//   1. Calculate distance from center (scaled by X/Y factors)
//   2. Map distance to 0-1 range using inner/outer radii
//   3. Inner radius = fully bright (1.0)
//   4. Outer radius = fully dark (0.0)
//
// Formula:
//   output = 1 + (innerRadius - distance) / (outerRadius - innerRadius)
//
// Use Cases:
//   - Sphere environment lighting
//   - Radial vignette
//   - Spotlight falloff texture
//   - Dome/hemisphere gradients
//
// Parameters:
//   texgenParams.x — Outer radius (larger = smaller gradient)
//   texgenParams.y — Inner radius (fully bright zone)
//   texgenParams.zw — X and Y scale factors (aspect ratio adjustment)
// ============================================================================

float4 texgenParams : register(c1);

// ============================================================================
// Pixel Shader — Generate Radial Gradient
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float outerRadius = texgenParams.x;
    float innerRadius = texgenParams.y;
    float2 scale = texgenParams.zw;

    // Distance from center with aspect ratio adjustment
    float2 centeredUV = (texCoord - 0.5) / (scale * outerRadius);
    float distance = length(centeredUV);

    // Map distance to brightness:
    // - At distance = innerRadius → output = 1
    // - At distance = outerRadius → output = 0
    float radiusRange = outerRadius - innerRadius;
    return 1 + (innerRadius - distance) / radiusRange;
}
