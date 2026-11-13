// ============================================================================
// READABLE VERSION: Tile Grid Pattern
// Original: ../texgen/tiles.hlsl (43 lines)
//
// Algorithm: Generates a grid of rectangular tiles with optional row offset.
//            Each tile outputs a unique ID value (normalized 0-1) for later
//            processing like randomization or material assignment.
//
// Features:
//   - Configurable grid dimensions
//   - Per-row horizontal offset (brick pattern)
//   - Border/gap between tiles
//   - Unique ID per tile for procedural variation
//
// Tile ID System:
//   Each tile outputs (tileIndex / totalTiles), creating a grayscale
//   gradient useful for:
//   - Colorizing with palette mapping
//   - Per-tile random variation
//   - Debugging/visualization
//
// Use Cases:
//   - Brick wall patterns
//   - Floor tile layouts
//   - Pixel grid backgrounds
//   - Chocolate bar / panel textures
//
// Parameters:
//   texgenParams.x — Column count (0-1 → 0-255)
//   texgenParams.y — Row count (0-1 → 0-255)
//   texgenParams.z — Row offset (0 = aligned, 0.5 = brick pattern)
//   texgenParams.w — Border size (relative to tile size)
// ============================================================================

float4 texgenParams : register(c1);

// ============================================================================
// Rectangle Test with Wrap-Around
//
// Tests if point is inside rectangle, handling horizontal wrapping
// for tiles that cross the UV boundary.
// ============================================================================
float DrawRect(float2 point, float4 rect)
{
    // Normalize rect x coordinates for wrapping
    rect.xz -= floor(rect.x);

    // Test both original position and wrapped (+1 in X) position
    bool insideOriginal = all(point > rect.xy) && all(point < rect.zw);
    bool insideWrapped = all(point + float2(1, 0) > rect.xy) && all(point + float2(1, 0) < rect.zw);

    return insideOriginal || insideWrapped;
}

// ============================================================================
// Pixel Shader — Generate Tile Grid
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Grid dimensions
    int2 gridCount = texgenParams.xy * 255;
    float totalTiles = gridCount.x * gridCount.y;
    float2 tileSize = 1.0 / gridCount;

    // Border size (scaled relative to smallest tile dimension)
    float border = min(tileSize.x, tileSize.y) * texgenParams.w;

    float result = 0;
    float2 tilePos = 0;
    int tileIndex = 1;

    // Iterate through all tiles
    for (int row = 0; row < gridCount.y; row++)
    {
        for (int col = 0; col < gridCount.x; col++)
        {
            // Rectangle bounds: (left+border, top+border) to (right-border, bottom-border)
            float4 tileBounds = float4(tilePos + border, tilePos + tileSize - border);

            // Accumulate tile ID if point is inside this tile
            result += DrawRect(texCoord, tileBounds) * (tileIndex / totalTiles);

            tilePos.x += tileSize.x;
            tileIndex++;
        }

        // Apply row offset for brick pattern and advance to next row
        tilePos.x = texgenParams.z * tileSize.x;
        tilePos.y += tileSize.y;
    }

    return result;
}
