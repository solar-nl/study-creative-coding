// ============================================================================
// READABLE VERSION: Voronoi/Worley Cell Noise Generator
// Original: ../texgen/cells.hlsl (45 lines)
//
// Algorithm: Generates Worley noise (cellular noise) by computing distances
//            to randomly-placed feature points. Uses a multi-pass approach
//            where each pass checks a different random offset, maintaining
//            the minimum distance found so far.
//
// Parameters:
//   texgenParams.x — Number of iterations (encoded as value * 255)
//   texgenParams.y — Power/scale factor for distance calculation
//   texgenParams.z — Cell size multiplier
//   texgenParams.w — Distance metric (0 = Euclidean, 1 = Manhattan)
//
// Multi-Pass System:
//   Each pass tests a different random offset position.
//   passInfo.yzw contains per-pass random offsets for sampling variety.
//   The minimum distance across all passes becomes the final output.
//
// References:
//   - Steven Worley, "A Cellular Texture Basis Function" (SIGGRAPH 1996)
// ============================================================================

// Sampler for reading from previous pass result
SamplerState linearSampler : register(s0);

// Input textures
Texture2D previousPassTexture : register(t0);  // Accumulated minimum distances
Texture2D hashTexture : register(t1);          // 256x256 random feature point positions

// Constant buffer registers
float4 passInfo : register(c0);      // x=passIndex, yzw=random offsets for this pass
float4 texgenParams : register(c1);  // x=iterations, y=power, z=size, w=metric

// ============================================================================
// Calculate distance using the configured metric
// Supports both Euclidean (L2) and Manhattan (L1) distance.
//
// Parameters:
//   delta — Vector from current position to feature point
//
// Returns:
//   Distance value according to selected metric
// ============================================================================
float CalculateDistance(float2 delta)
{
    // Manhattan distance (L1 norm): |dx| + |dy|
    // Creates diamond-shaped cell patterns
    float distance = abs(delta.x) + abs(delta.y);

    // Euclidean distance (L2 norm): sqrt(dx² + dy²)
    // Creates circular cell patterns
    if (texgenParams.w == 0)  // Mode 0 = Euclidean
    {
        distance = length(delta);
    }

    return distance;
}

// ============================================================================
// Sample the hash texture to get a random feature point position
// The hash texture provides deterministic pseudo-random values.
//
// Parameters:
//   integerCoord — Grid coordinates (will be wrapped to 256x256)
//
// Returns:
//   XY position offset for the feature point (0-1 range)
// ============================================================================
float4 SampleFeaturePoint(float2 integerCoord)
{
    // Wrap coordinates to 256x256 tile, offset by 512 to avoid negative modulo issues
    return hashTexture.Load(int3(fmod(integerCoord * 256 + 512, 256), 0));
}

// ============================================================================
// Main pixel shader entry point
// Computes distance to the nearest feature point for this pass,
// then takes the minimum with all previous passes.
//
// Parameters:
//   texCoord — UV coordinates in [0, 1] range
//
// Returns:
//   Minimum distance to feature points (normalized to ~[0, 1] range)
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // passInfo.yzw contains random offsets unique to each pass
    // This creates variety by testing different feature point configurations
    float4 randomOffsets = passInfo.yzwy;

    // ========================================================================
    // Calculate distance to the feature point for this pass
    // ========================================================================

    // Get random offset for feature point position from hash texture
    // randomOffsets.yz indexes into the hash texture to get a unique position
    float2 featurePointOffset = SampleFeaturePoint(randomOffsets.yz).xy;

    // Vector from current UV to the feature point, centered in cell
    // frac() - 0.5 maps the fractional part to [-0.5, 0.5]
    float2 delta = (texCoord.xy - featurePointOffset);
    delta = frac(delta) - 0.5;

    // Calculate normalized distance
    // The normalization factors create appropriate value ranges:
    //   - 2/texgenParams.y: scale by inverse power parameter
    //   - /sqrt(2): normalize for diagonal (maximum possible distance in cell)
    //   - /((randomOffsets.z + 0.2) * texgenParams.z * 10 + 1): cell size scaling
    //
    // The 0.2 offset prevents division by zero when randomOffsets.z is small
    float cellScale = (randomOffsets.z + 0.2) * texgenParams.z * 10 + 1;
    float normalizedDistance = CalculateDistance(delta) * 2 / texgenParams.y / sqrt(2) / cellScale;

    // ========================================================================
    // Multi-pass minimum distance accumulation
    // ========================================================================
    if (passInfo.x > 0)  // Not the first pass
    {
        // Read distances from two offset positions in the previous pass result
        // This samples neighboring cells to find closer feature points
        float2 offset1 = texCoord + randomOffsets.xy;
        float2 offset2 = texCoord + randomOffsets.zw;

        float neighborDist1 = previousPassTexture.Sample(linearSampler, offset1).x;
        float neighborDist2 = previousPassTexture.Sample(linearSampler, offset2).x;

        // Keep the minimum of: this pass, neighbor1, neighbor2
        normalizedDistance = min(normalizedDistance, min(neighborDist1, neighborDist2));
    }

    // ========================================================================
    // Handle passes beyond iteration count
    // Once we've completed all requested iterations, pass through the result
    // ========================================================================
    if (passInfo.x + 0.5 >= texgenParams.x * 255)
    {
        normalizedDistance = previousPassTexture.Sample(linearSampler, texCoord).x;
    }

    return normalizedDistance;
}
