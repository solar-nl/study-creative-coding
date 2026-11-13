// ============================================================================
// READABLE VERSION: Voronoi Distance Field (Cells 2)
// Original: ../texgen/cells-2.hlsl (39 lines)
//
// Algorithm: Voronoi diagram distance field computation.
//            Generates the classic "cellular" or "crystal" pattern by computing
//            the distance to the nearest randomly-placed cell center.
//
// How Voronoi Works:
//   1. Divide space into a grid of cells
//   2. Each cell has a random "seed" point (from noise texture)
//   3. For each pixel, find distance to nearest seed
//   4. Output distance creates organic cell patterns
//
// Optimization:
//   Only checks 3x3 neighborhood of grid cells (not entire space),
//   since the nearest seed must be within adjacent cells.
//
// Use Cases:
//   - Organic textures (cells, stones, skin)
//   - Caustics approximation
//   - Terrain features
//   - Abstract patterns
//
// Parameters:
//   texgenParams.xy — Grid cell count (0-1 maps to 0-255)
// ============================================================================

float4 PassData : register(c0);
float4 texgenParams : register(c1);
Texture2D noiseTexture : register(t0);

// ============================================================================
// Noise Lookup — Get Random Point Position for Grid Cell
//
// Returns a pseudo-random offset (0-1) for the cell center.
// The modulo wrapping enables seamless tiling.
// ============================================================================
float4 GetNoise(float2 cellCoord, float2 gridSize)
{
    // Map cell coordinate to noise texture with tiling
    int3 texCoord = int3(fmod(cellCoord / gridSize * 256 + 512, 256), 0);
    return noiseTexture.Load(texCoord);
}

// ============================================================================
// Voronoi Distance Field
//
// Computes minimum distance to any cell center in 3x3 neighborhood.
// Returns sqrt of minimum squared distance for proper Euclidean metric.
// ============================================================================
float Voronoi(float2 position, float2 gridSize)
{
    float2 cellCoord = floor(position);   // Which grid cell we're in
    float2 localPos = frac(position);     // Position within cell (0-1)

    float minDistSq = 8.0;  // Tracks minimum squared distance

    // Check all 9 neighboring cells
    for (int j = -1; j <= 1; j++)
    {
        for (int i = -1; i <= 1; i++)
        {
            float2 neighborOffset = float2(i, j);

            // Get random seed position for this neighbor cell
            float2 seedOffset = GetNoise(cellCoord + neighborOffset, gridSize).xy;

            // Vector from local position to seed point
            float2 toSeed = neighborOffset - localPos + seedOffset;

            // Track minimum squared distance
            float distSq = dot(toSeed, toSeed);
            minDistSq = min(minDistSq, distSq);
        }
    }

    return sqrt(minDistSq);
}

// ============================================================================
// Pixel Shader — Generate Voronoi Pattern
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Scale UV to grid space (parameters stored as 0-1, convert to count)
    float2 gridSize = texgenParams.xy * 255;

    return Voronoi(texCoord * gridSize, gridSize);
}
