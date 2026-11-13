// ============================================================================
// READABLE VERSION: Voronoi Cell Edges
// Original: ../texgen/celledges.hlsl (58 lines)
//
// Algorithm: Two-pass Voronoi edge detection using the edge bisector method.
//            First finds the nearest cell center, then computes distance to
//            the nearest edge between cells.
//
// Edge Bisector Method:
//   Pass 1: Find nearest seed point (mr = vector to nearest)
//   Pass 2: For each other seed, compute distance to the perpendicular
//           bisector plane between the nearest seed and that seed.
//
// The key insight: The edge between two Voronoi cells lies on the
// perpendicular bisector of the line connecting their seeds.
//
// Math for Pass 2:
//   midpoint = (mr + r) / 2           — Point on bisector
//   normal = normalize(r - mr)        — Direction perpendicular to edge
//   distance = dot(midpoint, normal)  — Signed distance to bisector plane
//
// Use Cases:
//   - Cell membrane/wall textures
//   - Cracked surface patterns
//   - Wire mesh appearance
//   - Stained glass outlines
//
// Parameters:
//   texgenParams.xy — Grid cell count (0-1 → 0-255)
//   texgenParams.z — Edge thickness (larger = thinner lines)
// ============================================================================

float4 PassData : register(c0);
float4 texgenParams : register(c1);
Texture2D noiseTexture : register(t0);

// ============================================================================
// Noise Lookup — Get Random Seed Position for Grid Cell
// ============================================================================
float4 GetNoise(float2 cellCoord, float2 gridSize)
{
    int3 texCoord = int3(fmod(cellCoord / gridSize * 256 + 512, 256), 0);
    return noiseTexture.Load(texCoord);
}

// ============================================================================
// Voronoi Edge Distance
//
// Two-pass algorithm:
// 1. Find nearest seed point (stores vector to it in 'nearestSeedVec')
// 2. Find distance to nearest edge (perpendicular bisector with other seeds)
// ============================================================================
float VoronoiEdges(float2 position, float2 gridSize)
{
    float2 cellCoord = floor(position);
    float2 localPos = frac(position);

    float2 nearestSeedVec;  // Vector to nearest seed point

    // ========================================================================
    // Pass 1: Find Nearest Seed
    // ========================================================================
    float minDistSq = 128.0;
    for (int j = -1; j <= 1; j++)
    {
        for (int i = -1; i <= 1; i++)
        {
            float2 neighborOffset = float2(i, j);
            float2 seedOffset = GetNoise(cellCoord + neighborOffset, gridSize).xy;
            float2 toSeed = neighborOffset - localPos + seedOffset;
            float distSq = dot(toSeed, toSeed);

            if (distSq < minDistSq)
            {
                minDistSq = distSq;
                nearestSeedVec = toSeed;
            }
        }
    }

    // ========================================================================
    // Pass 2: Find Distance to Nearest Edge
    //
    // For each seed, compute distance to the perpendicular bisector plane
    // between that seed and the nearest seed. The minimum is the edge distance.
    // ========================================================================
    float edgeDist = 128.0;
    for (int k = -2; k <= 2; k++)
    {
        for (int l = -2; l <= 2; l++)
        {
            float2 neighborOffset = float2(l, k);
            float2 seedOffset = GetNoise(cellCoord + neighborOffset, gridSize).xy;
            float2 toSeed = neighborOffset - localPos + seedOffset;

            // Skip if this is the nearest seed (would divide by zero)
            if (length(toSeed - nearestSeedVec) > 0)
            {
                // Distance to perpendicular bisector:
                // midpoint = 0.5 * (nearestSeedVec + toSeed)
                // edge_normal = normalize(toSeed - nearestSeedVec)
                // distance = dot(midpoint, edge_normal)
                float d = dot(0.5 * (nearestSeedVec + toSeed), normalize(toSeed - nearestSeedVec));
                edgeDist = min(edgeDist, d);
            }
        }
    }

    return edgeDist;
}

// ============================================================================
// Pixel Shader — Generate Cell Edge Pattern
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    float2 gridSize = texgenParams.xy * 255;
    float edgeDist = VoronoiEdges(texCoord * gridSize, gridSize);

    // Convert distance to intensity: closer to edge = brighter
    // thickness parameter controls falloff (larger = thinner lines)
    return 1 - edgeDist / texgenParams.z;
}
