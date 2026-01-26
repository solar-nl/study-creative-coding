# Texgen Pattern Generators

Pattern generators solve a fundamental problem in procedural graphics: creating rich visual detail without storing massive image files. Where a 4K texture might consume 64 megabytes, the shader code for generating equivalent noise, cells, or gradients fits in a few kilobytes. Demoscene productions exploit this size asymmetry ruthlessly.

But the real power goes beyond compression. Pattern generators are **parametric**. Change a single value and stone becomes foam, bricks become scales, gradients morph into vignettes. This flexibility makes them the foundation layer of texture graphs. You compose a final material by stacking generators into filters, colorizers, and blend operations—each transform preserving the parametric nature, each tweak propagating through the entire graph.

The Phoenix texgen system provides eleven core generators, each designed for a specific visual archetype. Some execute in a single pass (gradient, rectangle, solid-color). Others leverage multi-pass accumulation to build complexity incrementally (noise, cells). Together they form a complete palette for procedural texture authoring.

## Generator Categories

Phoenix organizes generators into three families based on computational strategy:

**Hash-Based Noise Generators** sample from a pre-computed 256×256 hash texture to create pseudo-random patterns. This includes `noise` (multi-octave Perlin), `cells` (Voronoi distance fields), `cells-2` (classic Voronoi), `celledges` (Voronoi boundaries), `subplasma` (smooth interpolated noise), and `sprinkle` (scattered sprites). The hash texture acts like a random number generator with spatial continuity—adjacent samples produce smoothly varying values rather than white noise.

**Geometric Generators** compute analytical distance functions from UV coordinates. The `gradient` shader evaluates six different geometric patterns (radial, box, linear), `rectangle` implements superellipse shapes with configurable roundness, `tiles` generates grids with brick-pattern offsets, and `envmap` creates radial falloffs for environment lighting. These run in a single pass because the math is position-dependent only—no neighbor sampling required.

**Constant Generators** produce uniform outputs across the entire texture. Only `solid-color` falls into this category, but it serves a critical role: providing color constants for blending operations and clearing render targets before accumulation passes.

## Complete Generator Reference

| Generator | Parameters | Max Passes | Hash Lookup | Primary Output | Typical Use |
|-----------|-----------|------------|-------------|----------------|-------------|
| **noise** | 4 (octave range, persistence, interpolation) | 8 | Yes | Grayscale fractal | Displacement, clouds, organic base |
| **cells** | 4 (iterations, power, size, metric) | 16 | Yes | Grayscale distance | Stone, foam, organic cells |
| **cells-2** | 2 (grid X/Y) | 1 | Yes | Grayscale distance | Classic Voronoi, crystals |
| **celledges** | 3 (grid X/Y, thickness) | 1 | Yes | Grayscale edges | Cell walls, cracks, mesh |
| **gradient** | 1 (pattern type 0-5) | 1 | No | Grayscale ramp | Vignettes, masks, fades |
| **rectangle** | 6 (pos, size, chamfer, falloff) | 1 | No | Grayscale shape | UI, rounded rects, squircles |
| **solid-color** | 4 (RGBA) | 1 | No | Constant color | Backgrounds, blend constants |
| **tiles** | 4 (grid X/Y, offset, border) | 1 | No | Grayscale IDs | Bricks, tile floors, grids |
| **sprinkle** | 3 (count, min/max size) | 1 | Yes | RGBA composite | Stars, debris, particles |
| **subplasma** | 2 (density, linear flag) | 3 | Yes | Grayscale plasma | Abstract patterns, energy |
| **envmap** | 4 (outer/inner radius, scale X/Y) | 1 | No | Grayscale radial | IBL, spotlights, domes |

The "Max Passes" column reveals computational cost. Single-pass generators complete in one draw call. Multi-pass generators require sequential rendering where each pass reads the previous result. This matters for real-time performance budgets—eight octaves of noise means eight full-screen quad renders.

## Multi-Octave Perlin Noise

Imagine a grid of random values. Linear interpolation between grid points produces blocky, unnatural patterns. Perlin noise solves this by applying a smoothstep function before interpolation—the derivatives vanish at grid cell boundaries, eliminating visible seams. The result looks organic because it lacks the directional bias of simpler noise algorithms.

But single-octave Perlin noise still shows repetitive structure at its fundamental frequency. Fractal Brownian motion (fBm) stacks multiple octaves with decreasing amplitude to create self-similar detail at multiple scales. Like looking at a coastline—it's jagged at 100 meters, jagged at 1 kilometer, jagged at 100 kilometers. Each zoom level reveals similar structure.

The `noise` generator implements fBm through multi-pass accumulation. Each render pass adds one octave with frequency doubling and amplitude controlled by the persistence parameter.

**Parameters**:
- `[0] Min Octave`: Starting frequency (0-255 → octave 0-8), encoded as `value * 255 - 1`
- `[1] Max Octave`: Ending frequency (0-255 → octave 0-8)
- `[2] Persistence`: Amplitude multiplier per octave, typical range 0.3-0.7
- `[3] Interpolation`: 0 = smoothstep (removes grid artifacts), 1 = linear (faster, more blocky)

**Algorithm Details**:

The cell size halves each octave, doubling the frequency:

```hlsl
float cellSize = 1.0 / pow(2.0, passIndex + 2);
// Octave 0: cellSize = 1/4
// Octave 1: cellSize = 1/8
// Octave 2: cellSize = 1/16
```

Amplitude decays exponentially by the persistence factor:

```hlsl
float amplitude = pow(persistence, relativePassIndex);
// persistence=0.5, pass 0: amplitude = 1.0
// persistence=0.5, pass 1: amplitude = 0.5
// persistence=0.5, pass 2: amplitude = 0.25
```

The smoothstep interpolation eliminates grid artifacts by zeroing derivatives at cell boundaries:

```hlsl
// Standard smoothstep: S(t) = t² × (3 - 2t)
if (interpolationMode == 0) {
    frac = frac * frac * (3 - 2 * frac);
}
```

Each pass performs bilinear interpolation of four hash texture samples at the grid cell corners, accumulating the result into the previous pass output. The hash texture provides deterministic pseudo-random values that tile seamlessly via `fmod(coord * 256, 256)`.

**Use Cases**: Base layer for wood grain, marble veining, cloud patterns, terrain elevation, displacement maps. Anything requiring organic randomness without visible structure.

**Performance Note**: Eight octaves means eight sequential render passes. For real-time applications, consider caching noise results or reducing octave count for less critical materials.

## Voronoi Cell Distance Fields

Picture scattering random seed points across a plane, then coloring each pixel by its distance to the nearest seed. The resulting patterns resemble cells, bubbles, or organic membranes. This is Voronoi (also called Worley) noise.

Phoenix provides three Voronoi variants with different computational strategies and output characteristics.

### cells.hlsl - Multi-Pass Distance Propagation

The `cells` generator uses an iterative approach where each pass propagates distance information from neighboring regions. Think of it like a flood-fill that gradually discovers the minimum distance through repeated neighbor sampling.

**Parameters**:
- `[0] Iterations`: Number of propagation passes (0-255), more iterations = smoother falloff
- `[1] Power`: Distance scale factor, larger values create sharper cell boundaries
- `[2] Size`: Cell density multiplier, controls the number of visible cells
- `[3] Manhattan`: 0 = Euclidean distance (circular cells), 1 = Manhattan distance (diamond cells)

**Algorithm**:

Pass 0 computes initial distance from the current UV to a randomly-placed seed point:

```hlsl
float2 featurePoint = SampleHash(randomOffsets.yz).xy;
float2 delta = frac(texCoord - featurePoint) - 0.5;
float dist = CalculateDistance(delta);
```

Subsequent passes read from offset positions in the previous result, keeping the minimum distance found:

```hlsl
float neighbor1 = previousResult.Sample(texCoord + randomOffsets.xy).x;
float neighbor2 = previousResult.Sample(texCoord + randomOffsets.zw).x;
dist = min(dist, min(neighbor1, neighbor2));
```

The random offsets vary per pass, allowing the algorithm to discover seeds that aren't visible from the current position. More iterations find more distant seeds, producing smoother distance gradients.

**Distance Metrics**:

Euclidean distance creates circular cell patterns—the classic organic look:

```hlsl
float euclidean = length(delta);  // sqrt(dx² + dy²)
```

Manhattan distance produces diamond-shaped cells with a more geometric appearance:

```hlsl
float manhattan = abs(delta.x) + abs(delta.y);
```

**Use Cases**: Stone textures, foam patterns, organic surface detail, caustics approximation.

### cells-2.hlsl - Classic Voronoi

This variant implements the standard Voronoi algorithm—check all neighboring cells, find minimum distance, done. It's conceptually simpler than the iterative approach and completes in a single pass.

**Parameters**:
- `[0] Grid X`: Horizontal cell count (0-255)
- `[1] Grid Y`: Vertical cell count (0-255)

**Algorithm**:

For the current pixel's grid cell, check all 3×3 neighbors for seed points:

```hlsl
float2 cellCoord = floor(position);
float2 localPos = frac(position);
float minDistSq = 8.0;

for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
        float2 neighborOffset = float2(i, j);
        float2 seedOffset = GetNoise(cellCoord + neighborOffset).xy;
        float2 toSeed = neighborOffset - localPos + seedOffset;
        float distSq = dot(toSeed, toSeed);
        minDistSq = min(minDistSq, distSq);
    }
}
return sqrt(minDistSq);
```

Why 3×3? The nearest seed must be within adjacent cells—checking beyond that is unnecessary. This optimization makes single-pass Voronoi feasible.

**Use Cases**: When you need Voronoi patterns without multi-pass overhead. Good for real-time applications with performance constraints.

### celledges.hlsl - Cell Boundary Detection

Rather than shading by distance to the nearest seed, this variant highlights the **edges** between Voronoi regions. Useful for creating cell walls, crack patterns, or wire mesh appearances.

**Parameters**:
- `[0] Grid X`: Horizontal cell count
- `[1] Grid Y`: Vertical cell count
- `[2] Thickness`: Edge width, larger values create thinner lines

**Algorithm**:

The edge between two cells lies on the perpendicular bisector of the line connecting their seeds. Pass 1 finds the nearest seed. Pass 2 computes distance to the bisector planes with all other seeds, keeping the minimum:

```hlsl
// Pass 1: Find nearest seed
float2 nearestSeedVec;
float minDist = 128.0;
for each neighbor {
    float2 toSeed = neighborOffset - localPos + seedOffset;
    if (length(toSeed) < minDist) {
        minDist = length(toSeed);
        nearestSeedVec = toSeed;
    }
}

// Pass 2: Distance to nearest edge
float edgeDist = 128.0;
for each neighbor {
    float2 toSeed = neighborOffset - localPos + seedOffset;
    if (length(toSeed - nearestSeedVec) > 0) {
        // Distance to perpendicular bisector
        float d = dot(0.5 * (nearestSeedVec + toSeed),
                      normalize(toSeed - nearestSeedVec));
        edgeDist = min(edgeDist, d);
    }
}
```

The perpendicular bisector distance formula comes from vector geometry: the midpoint between seeds lies on the edge, and the normalized difference vector is perpendicular to it. The dot product gives signed distance to this plane.

**Output Mapping**:

Raw edge distance gets mapped to intensity:

```hlsl
return 1 - edgeDist / thickness;
```

Pixels near edges have small `edgeDist`, producing values near 1 (bright). Pixels in cell interiors have large `edgeDist`, producing values near 0 (dark). The thickness parameter scales this falloff.

**Use Cases**: Cracked surfaces, stained glass, cell membranes, wire mesh, honeycomb patterns.

## Geometric Pattern Generators

Unlike noise-based generators that sample hash textures, geometric generators compute analytical distance functions directly from UV coordinates. This makes them extremely fast—no texture lookups, no neighbor sampling, just pure math.

### gradient.hlsl - Six Pattern Modes

Think of gradients as the Swiss Army knife of masking operations. Need a vignette? Radial gradient. Need to fade between two texture layers? Linear gradient. Need a spotlight falloff? Bidirectional gradient. One shader, six use cases.

**Parameter**:
- `[0] Pattern Type`: Integer 0-5 selecting pattern mode (encoded as `value × 256`)

**Pattern Formulas**:

**Mode 0 - Radial (circular)**: Distance from center, normalized so corners reach 0:

```hlsl
float2 centered = texCoord - 0.5;  // [-0.5, 0.5]
result = 1 - length(centered) * 2 / sqrt(2);
// sqrt(2) ≈ 1.414 is the distance from center to corner
```

**Mode 1 - Box (square/diamond)**: Maximum of absolute X and Y distances (Chebyshev metric):

```hlsl
result = 1 - max(abs(centered.x), abs(centered.y)) * 2;
```

This creates a square falloff pattern—edges reach 0 simultaneously.

**Mode 2 - Horizontal**: Simple left-to-right ramp:

```hlsl
result = texCoord.x;  // 0 at left, 1 at right
```

**Mode 3 - Vertical**: Simple top-to-bottom ramp:

```hlsl
result = texCoord.y;  // 0 at top, 1 at bottom
```

**Mode 4 - Horizontal Bidirectional**: White in center, black at both edges:

```hlsl
result = 1 - abs(1 - texCoord.x * 2);
// texCoord.x = 0.0 → result = 0
// texCoord.x = 0.5 → result = 1
// texCoord.x = 1.0 → result = 0
```

**Mode 5 - Vertical Bidirectional**: White in center, black at top and bottom:

```hlsl
result = 1 - abs(1 - texCoord.y * 2);
```

**Use Cases**: Vignette effects (radial), UI fades (linear), spotlight masks (radial), transition regions (bidirectional), region-based blend factors (box).

**Performance**: Single texture coordinate calculation, no branching in generated assembly (compiler converts if-chain to conditional moves), sub-microsecond per pixel.

### rectangle.hlsl - Rounded Rectangles and Superellipses

iOS popularized the "squircle"—a shape between a circle and a square with perfectly continuous curvature. The mathematical foundation is the superellipse, a generalization of ellipses with a tunable exponent.

**Parameters**:
- `[0] Center X`: Horizontal position
- `[1] Center Y`: Vertical position
- `[2] Half-Width`: Radius in X direction
- `[3] Half-Height`: Radius in Y direction
- `[4] Chamfer`: Roundness (0 = sharp rectangle, 1 = circle)
- `[5] Falloff`: Edge softness (0 = hard edge, higher = softer)

**Superellipse Formula**:

For a point (x, y) relative to center with half-widths (a, b) and exponent n:

```
distance = (|x/a|^n + |y/b|^n)^(1/n)
```

When `distance < 1`, the point is inside. When `distance = 1`, it's on the boundary. When `distance > 1`, it's outside.

**Shape Progression**:
- `n = 1`: Diamond (Manhattan distance)
- `n = 2`: Ellipse (Euclidean distance)
- `n = 2.5`: Rounded rectangle (smooth iOS-style squircle)
- `n → ∞`: Perfect rectangle with sharp corners

**Implementation**:

The chamfer parameter maps to exponent via `n = 2 / chamfer`:

```hlsl
float chamferExponent = 2.0 / chamfer;
// chamfer = 1.0 → exponent = 2 (circle)
// chamfer = 0.5 → exponent = 4 (rounded rect)
// chamfer → 0 → exponent → ∞ (sharp rectangle)
```

Distance calculation using the superellipse formula:

```hlsl
float2 centerOffset = centerPos - texCoord;
float2 normalizedDist = abs(centerOffset / halfSize / radiusScale);
float superellipseDist = sqrt(
    pow(normalizedDist.x, chamferExponent) +
    pow(normalizedDist.y, chamferExponent)
);
float insideAmount = 1 - saturate(superellipseDist);
```

The `radiusScale` factor adjusts for visual size consistency across different chamfer values—high exponents would otherwise appear smaller.

**Falloff**:

A power function creates soft edges:

```hlsl
float falloffExponent = 1.0 / falloff * 10;
return pow(abs(insideAmount + 0.5), falloffExponent);
```

Higher falloff values create sharper transitions. Lower values produce gaussian-like blur.

**Use Cases**: Rounded UI buttons, iOS app icon shapes, soft-edged masks, pill/capsule shapes, rounded panel backgrounds.

**Math Insight**: The superellipse is a signed distance field (SDF) in disguise. You could ray march it, use it for CSG operations, or generate outlines at any thickness. Phoenix uses it for simple shape fills, but the underlying representation is far more powerful.

### tiles.hlsl - Grid Patterns with Brick Offset

Brick walls don't align vertically—each row offsets by half a brick width. This breaks visual repetition and adds structural stability (in real masonry). The `tiles` generator replicates this pattern procedurally.

**Parameters**:
- `[0] Column Count`: Horizontal tile count (0-255)
- `[1] Row Count`: Vertical tile count (0-255)
- `[2] Offset`: Row horizontal shift (0 = aligned, 0.5 = brick pattern)
- `[3] Border`: Mortar/gap width relative to tile size

**Algorithm**:

The shader iterates through all grid positions, drawing each tile as a filled rectangle:

```hlsl
float2 tileSize = 1.0 / float2(columnCount, rowCount);
float border = min(tileSize.x, tileSize.y) * borderParam;

float2 tilePos = 0;
int tileIndex = 1;

for (int row = 0; row < rowCount; row++) {
    for (int col = 0; col < columnCount; col++) {
        // Rectangle bounds with border inset
        float4 bounds = float4(tilePos + border,
                               tilePos + tileSize - border);

        // Accumulate tile ID if pixel is inside
        result += DrawRect(texCoord, bounds) * (tileIndex / totalTiles);

        tilePos.x += tileSize.x;
        tileIndex++;
    }

    // Apply row offset for brick pattern
    tilePos.x = offset * tileSize.x;
    tilePos.y += tileSize.y;
}
```

**Tile ID System**:

Each tile outputs a unique normalized value: `tileIndex / totalTiles`. This creates a grayscale gradient across tiles, which downstream operators can use for:
- Palette mapping (assign random colors per tile)
- Per-tile randomization (via hash lookup using tile ID)
- Debugging and visualization

**Wrapping Behavior**:

The `DrawRect` function handles horizontal wrapping for tiles that cross the UV boundary:

```hlsl
bool insideOriginal = all(point > rect.xy) && all(point < rect.zw);
bool insideWrapped = all(point + float2(1, 0) > rect.xy) &&
                     all(point + float2(1, 0) < rect.zw);
return insideOriginal || insideWrapped;
```

This ensures seamless tiling when the texture repeats.

**Use Cases**: Brick walls, tile floors, chocolate bar panels, pixel grid backgrounds, bathroom tile patterns, LED displays.

**Performance Note**: The nested loop executes `columnCount × rowCount` iterations per pixel. For a 20×20 grid, that's 400 iterations. Modern GPUs handle this fine for reasonable grid sizes, but very high tile counts can become expensive. Consider pre-rendering complex grids and sampling the result.

## Scattered and Plasma Generators

The remaining generators handle specialized use cases: distributing sprites randomly, creating smooth interpolated noise, and generating constant colors.

### sprinkle.hlsl - Procedural Sprite Scattering

Imagine stars scattered across a night sky, each with random position, size, and rotation. Manually placing hundreds of sprites is tedious. The `sprinkle` generator automates this through hash-based randomization.

**Parameters**:
- `[0] Quantity`: Number of sprite instances (0-255)
- `[1] Min Size`: Minimum scale factor
- `[2] Max Size`: Maximum scale factor

**Algorithm**:

For each sprite instance, sample the hash texture to get random transform parameters:

```hlsl
for (int sprite = 0; sprite < quantity; sprite++) {
    float4 random = GetNoise(sprite / 255.0);
    // random.xy = position
    // random.z = size interpolant (0-1)
    // random.w = rotation (0-1 → 0-2π)
}
```

Transform the current UV coordinate into sprite-local space:

```hlsl
float size = lerp(minSize, maxSize, random.z);
float angle = random.w * 6;  // Map to ~2π radians
float2 localUV = (worldUV - random.xy) / size;

// Rotate
float sinA = sin(angle);
float cosA = cos(angle);
localUV = float2(
    localUV.x * cosA - localUV.y * sinA,
    localUV.y * cosA + localUV.x * sinA
);

// Offset to texture center
localUV = saturate(localUV + 0.5);
```

**Seamless Tiling**:

Sprites near UV boundaries would get clipped without special handling. The shader checks a 3×3 tile neighborhood to catch wrap-around cases:

```hlsl
for (int tileY = 0; tileY < 3; tileY++) {
    for (int tileX = 0; tileX < 3; tileX++) {
        float2 tileOffset = float2(tileX, tileY) - 1;  // -1, 0, +1
        float2 spriteUV = GetSpriteUV(texCoord + tileOffset, random);
        float4 color = spriteTexture.Sample(linearSampler, spriteUV);
        result = lerp(result, color, color.a);
    }
}
```

Each sprite instance gets sampled nine times (once per tile offset). If the sprite's center is at `(0.95, 0.5)` and extends beyond `x = 1.0`, the tile offset `(-1, 0)` brings it back into view at `(-0.05, 0.5)`, which wraps to `(0.95, 0.5)` via texture repeat.

**Use Cases**: Star fields, debris particles, scattered flowers, confetti, snow, falling leaves, fireflies, sparkles.

**Performance Consideration**: The triple-nested loop (sprites × tiles × samples) scales as `O(quantity × 9)`. With 100 sprites, that's 900 texture samples per pixel. Use conservatively for real-time rendering.

### subplasma.hlsl - Smooth Interpolated Noise

Plasma effects—those swirling, organic color patterns popular in 90s demos—typically use sine wave interference. The `subplasma` generator takes a different approach: interpolate random grid values smoothly using Catmull-Rom splines.

**Parameters**:
- `[0] Density`: Grid resolution (0-1 → 2^1 to 2^256 cells)
- `[1] Linear`: Interpolation mode (0 = Catmull-Rom spline, 1 = linear)

**Multi-Pass System**:

Pass 0 samples the hash texture at grid points. Pass 1 interpolates horizontally. Pass 2+ interpolates vertically. This two-stage approach allows Catmull-Rom splines to work with only four samples.

**Catmull-Rom Spline**:

Unlike linear interpolation, Catmull-Rom splines pass through control points with continuous first derivatives. This produces smoother results without the polynomial wiggle of higher-order splines.

Given four control points `v0, v1, v2, v3` and parameter `t ∈ [0,1]`:

```hlsl
float4 P = (v3 - v2) - (v0 - v1);   // Cubic coefficient
float4 Q = (v0 - v1) - P;            // Quadratic coefficient
float4 R = v2 - v0;                  // Linear coefficient (tangent at v1)

// Horner's method: ((P*t + Q)*t + R)*t + v1
result = (((P * t) + Q) * t + R) * t + v1;
```

The spline interpolates from `v1` at `t=0` to `v2` at `t=1`, using `v0` and `v3` to determine endpoint slopes.

**Why Two Passes?**

Separable filters exploit the fact that 2D interpolation can decompose into sequential 1D operations. Instead of sampling a 4×4 grid (16 samples), we sample 4 horizontally in pass 1, then 4 vertically in pass 2 (8 samples total).

**Use Cases**: Abstract backgrounds, energy effects, lava lamps, psychedelic patterns, 70s aesthetic.

**Linear vs. Catmull-Rom**: Linear mode is faster but shows grid structure. Catmull-Rom produces organic flow but costs more ALU. Choose based on your performance budget.

### envmap.hlsl - Radial Lighting Gradients

Environment maps store incoming light from all directions. For spherical harmonics or simple dome lighting, you need a radial falloff pattern—bright in the center, dark at the edges.

**Parameters**:
- `[0] Outer Radius`: Where falloff reaches 0
- `[1] Inner Radius`: Where falloff stays at 1
- `[2] Scale X`: Horizontal aspect ratio adjustment
- `[3] Scale Y`: Vertical aspect ratio adjustment

**Algorithm**:

Calculate distance from center with aspect correction:

```hlsl
float2 centeredUV = (texCoord - 0.5) / (scale * outerRadius);
float distance = length(centeredUV);
```

Map distance to brightness using linear interpolation between inner and outer radii:

```hlsl
// At distance = innerRadius → output = 1
// At distance = outerRadius → output = 0
float radiusRange = outerRadius - innerRadius;
return 1 + (innerRadius - distance) / radiusRange;
```

**Use Cases**: Sphere environment maps, IBL textures, spotlight falloff, vignette effects, dome/hemisphere gradients.

**Why Not Just Use Gradient Mode 0?** The `envmap` shader provides explicit inner/outer radius control, making it easier to dial in specific falloff curves without reverse-engineering gradient parameters.

### solid-color.hlsl - Constant Color Fill

The simplest possible generator—output the same RGBA value for every pixel.

**Parameters**:
- `[0]` Red channel (0-1)
- `[1]` Green channel (0-1)
- `[2]` Blue channel (0-1)
- `[3]` Alpha channel (0-1)

**Implementation**:

```hlsl
float4 PixelMain(float4 position : TEXCOORD0) : SV_TARGET0
{
    return texgenParams;
}
```

No UV coordinate usage. No texture samples. Just a constant output.

**Use Cases**: Flat backgrounds, color constants for blend operations, clear color for render targets before multi-pass accumulation, placeholder textures during development.

**Why Even Have This?** In a graph-based texture editor, you need a way to inject constant colors into blend operations. Rather than hardcoding colors in blend shaders, `solid-color` provides a parametric source node that users can tweak without recompiling.

## Common Implementation Patterns

Several techniques appear repeatedly across Phoenix generators, forming a toolkit of GPU programming idioms.

### Hash Texture Sampling

All noise-based generators rely on a pre-computed 256×256 hash texture filled with random values. This provides deterministic pseudo-random numbers with spatial continuity.

**Standard Sampling Pattern**:

```hlsl
float4 GetNoise(float2 coord) {
    float2 scaledCoord = coord * 256;
    return noiseTexture.Load(int3(fmod(scaledCoord, 256), 0));
}
```

The `fmod(scaledCoord, 256)` wrapping ensures seamless tiling—coordinates wrap at texture boundaries, but because the hash texture itself tiles, no seams appear.

**Why 256×256?** Power-of-two sizes enable efficient modulo operations (GPU hardware can optimize `x % 256` to bitwise AND). The resolution balances memory usage (256 KB for RGBA32F) against gradient smoothness—smaller textures show more repetition, larger ones waste memory.

**Frequency Variation**:

Multi-pass shaders often scale the coordinate by pass index to create octaves:

```hlsl
float2 scaledCoord = coord * 256 * (max(1, passIndex) * (1 + passMultiplier));
```

This shifts the effective frequency without changing the hash texture itself.

### Multi-Pass Distance Propagation

The `cells` generator discovers minimum distances through iterative neighbor sampling. Each pass reads offset positions from the previous result:

```hlsl
if (passIndex > 0) {
    float neighbor1 = previousPass.Sample(texCoord + randomOffset1).x;
    float neighbor2 = previousPass.Sample(texCoord + randomOffset2).x;
    currentDist = min(currentDist, min(neighbor1, neighbor2));
}
```

Why does this work? Imagine a distance field where some regions haven't seen their nearest seed yet. Sampling neighbors propagates information from regions that *have* found closer seeds. After enough iterations, all regions converge to the global minimum distance.

**Random Offsets**: Using deterministic but pseudo-random offsets (from `passInfo.yzw`) ensures different neighbor configurations each pass, accelerating convergence.

### Seamless Tiling via Modulo Arithmetic

Procedural textures must tile seamlessly for use as repeating materials. All Phoenix generators ensure this through careful coordinate wrapping.

**Grid Cell Wrapping**:

```hlsl
float2 cellCoord = floor(position);
float2 localPos = frac(position);  // Always in [0, 1]
```

The `frac()` function inherently wraps—texture coordinates `(0.9, 0.5)` and `(1.9, 0.5)` produce the same `localPos`.

**Hash Texture Wrapping**:

```hlsl
int3 texCoord = int3(fmod(cellCoord / gridSize * 256 + 512, 256), 0);
```

The `+ 512` offset avoids negative modulo issues when coordinates go below zero. The `fmod(..., 256)` ensures wraparound at texture boundaries.

**Boundary-Crossing Rectangles**:

For geometric shapes, test both the original coordinate and the wrapped version:

```hlsl
bool inside = all(point > rect.xy) && all(point < rect.zw);
bool insideWrapped = all(point + float2(1, 0) > rect.xy) &&
                     all(point + float2(1, 0) < rect.zw);
return inside || insideWrapped;
```

This catches cases where a rectangle's left edge is at `x = 0.9` and extends beyond `x = 1.0`.

### Parameter Encoding

Phoenix stores shader parameters as normalized float4 vectors (0-1 range). To represent integer counts or wider ranges, shaders decode parameters during execution.

**Integer Counts** (common for grid dimensions):

```hlsl
int columnCount = texgenParams.x * 255;  // 0-1 → 0-255
```

**Octave Indices** (noise shader):

```hlsl
float minOctave = texgenParams.x * 255 - 1;  // Shift for 0-based indexing
```

**Exponents and Powers** (subplasma density):

```hlsl
float cellSize = 1.0 / pow(2.0, texgenParams.x * 255 + 1);
// Maps 0-1 to cell counts from 2^1 to 2^256
```

This encoding scheme allows the UI to expose 0-1 sliders while shaders work with the actual integer or exponential ranges they need.

## Performance Characteristics

Understanding generator costs helps with texture graph optimization. Budget your render passes carefully.

**Single-Pass Generators** (constant cost):
- `gradient`: ~0.1ms @ 1080p (pure math, no texture reads)
- `rectangle`: ~0.15ms @ 1080p (power functions add cost)
- `solid-color`: ~0.05ms @ 1080p (trivial—no computation)
- `tiles`: ~0.3-2ms @ 1080p (scales with grid size due to loop iteration)
- `cells-2`: ~0.2ms @ 1080p (3×3 neighbor search, one hash lookup per neighbor)
- `celledges`: ~0.4ms @ 1080p (5×5 neighbor search for edge detection)
- `envmap`: ~0.1ms @ 1080p (simple distance calculation)

**Multi-Pass Generators** (cost scales with passes):
- `noise`: ~0.2ms per octave (8 octaves = 1.6ms total)
- `cells`: ~0.3ms per iteration (16 iterations = 4.8ms total)
- `subplasma`: ~0.25ms per pass (3 passes = 0.75ms total)

**Special Cases**:
- `sprinkle`: Scales with quantity × 9 (tile grid). 100 sprites = ~2ms @ 1080p.

**Optimization Strategies**:

1. **Reduce Octaves/Iterations**: Eight-octave noise rarely provides visible benefit over five octaves. Profile and trim.

2. **Pre-Render Static Textures**: If a noise pattern doesn't animate, render it once at startup and cache.

3. **Lower Resolution**: Generate at half-resolution and upscale. Many procedural patterns don't need pixel-perfect detail.

4. **Batch Multi-Pass Operations**: If you need multiple noise layers, interleave their passes to improve cache coherence.

5. **LOD Switching**: Use simpler generators for distant surfaces (e.g., gradient instead of noise for far-away terrain).

These timings assume modern GPUs (RTX 3060 class). Older or mobile hardware will be slower—scale expectations accordingly.

## Implications for Rust Framework Design

Phoenix's generator architecture offers several lessons for a modern creative coding framework.

**Strongly-Typed Parameter Structs**:

Instead of cryptic `float4 texgenParams` registers, expose generators through typed APIs:

```rust
pub struct NoiseParams {
    pub min_octave: u8,
    pub max_octave: u8,
    pub persistence: f32,
    pub interpolation: InterpolationMode,
}

pub enum InterpolationMode {
    Smoothstep,
    Linear,
}

texture_graph.add_generator(Generator::Noise(NoiseParams {
    min_octave: 0,
    max_octave: 6,
    persistence: 0.5,
    interpolation: InterpolationMode::Smoothstep,
}));
```

This eliminates parameter encoding errors and provides IDE autocomplete.

**Compute Shader Alternatives**:

Multi-pass generators like `noise` and `cells` are inefficient on modern GPUs. A single compute shader with shared memory could generate all octaves in one dispatch:

```rust
// Instead of 8 sequential render passes:
for octave in 0..8 {
    render_noise_pass(octave);  // 8 full-screen quads
}

// Single compute dispatch with local accumulation:
dispatch_noise_compute(octaves: 0..8);  // One workgroup per tile
```

Compute shaders avoid the render target ping-ponging and enable more sophisticated algorithms (e.g., wavelet noise, jump flooding for Voronoi).

**Hash Texture Generation**:

Pre-compute the hash texture once per context and reuse it:

```rust
pub struct ProceduralContext {
    hash_texture: wgpu::Texture,  // 256×256 RGBA32F
}

impl ProceduralContext {
    pub fn new(device: &wgpu::Device) -> Self {
        let hash_data = generate_blue_noise_256();  // Or white noise, Sobol, etc.
        let hash_texture = device.create_texture_with_data(hash_data);
        Self { hash_texture }
    }
}
```

Different noise types (white, blue, Sobol sequences) produce different visual characteristics. Expose this as a configuration option.

**Generator Composability**:

Phoenix generators are nodes in a graph. Rust's type system can enforce valid connections at compile time:

```rust
pub struct TextureGraph<'a> {
    nodes: Vec<Node<'a>>,
}

pub enum Node<'a> {
    Generator(Generator),
    Filter { input: &'a Node<'a>, op: FilterOp },
    Blend { a: &'a Node<'a>, b: &'a Node<'a>, mode: BlendMode },
}
```

Immutable graphs with lifetimes prevent use-after-free and cyclic dependencies.

**Distance Field Library**:

The `rectangle` shader implements a superellipse SDF. Generalize this into a distance field primitive library:

```rust
pub trait SignedDistanceField {
    fn distance(&self, point: Vec2) -> f32;
}

pub struct Superellipse { /* ... */ }
impl SignedDistanceField for Superellipse { /* ... */ }

pub struct Union<A, B>(A, B);  // CSG operations
pub struct Intersection<A, B>(A, B);
pub struct Subtraction<A, B>(A, B);
```

Compose complex shapes from primitives, ray march them, or rasterize with analytical anti-aliasing.

**Performance Budgeting**:

Provide profiling hooks that report per-generator cost:

```rust
let report = texture_graph.profile(&device);
for (node_id, duration) in report.timings {
    println!("Node {}: {:.2}ms", node_id, duration.as_secs_f32() * 1000.0);
}
```

Users can identify bottlenecks and optimize accordingly.

**Shader Hot Reload**:

Phoenix shaders are HLSL text files loaded at runtime. Rust can do the same with `naga` or `wgsl-validator`:

```rust
pub struct ShaderCache {
    shaders: HashMap<String, wgpu::ShaderModule>,
}

impl ShaderCache {
    pub fn reload(&mut self, name: &str, device: &wgpu::Device) -> Result<()> {
        let source = std::fs::read_to_string(format!("shaders/{}.wgsl", name))?;
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(name),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(&source)),
        });
        self.shaders.insert(name.to_string(), module);
        Ok(())
    }
}
```

Hot reload accelerates iteration during shader development.

## Connections to Other Texgen Systems

Phoenix generators form the input layer of a larger texture processing pipeline.

**Upstream (depends on generators)**:
- [Color and Blend Operators](./operators.md#color-blend-group) — Use generator output as blend masks
- [Transform Operators](./operators.md#geometric-transforms) — Apply rotation, scale, distortion to generator patterns
- [Filter Operators](./operators.md#convolution-filters) — Blur noise for smoother falloff, sharpen edges for detail

**Downstream (generators depend on)**:
- [Pipeline Architecture](./pipeline.md) — Describes the render graph system that chains generators
- [Shader Infrastructure](./shaders.md) — Common shader utilities, parameter encoding, sampler states

**Related Concepts**:
- [Overview](./overview.md) — High-level texgen system architecture
- Demoscene procedural texture techniques (common noise implementations, size optimization)

## Source Files

All generator shaders reside in `/demoscene/apex-public/Projects/Clean Slate/extracted/shaders/`:

**Annotated Versions** (with detailed comments):
- `annotated/texgen/noise.hlsl` — Multi-octave Perlin noise (177 lines)
- `annotated/texgen/cells.hlsl` — Voronoi distance propagation (146 lines)
- `annotated/texgen/cells-2.hlsl` — Classic Voronoi (91 lines)
- `annotated/texgen/celledges.hlsl` — Voronoi edge detection (124 lines)
- `annotated/texgen/gradient.hlsl` — Six gradient modes (96 lines)
- `annotated/texgen/rectangle.hlsl` — Superellipse shapes (91 lines)
- `annotated/texgen/solid-color.hlsl` — Constant color fill (31 lines)
- `annotated/texgen/tiles.hlsl` — Grid with brick pattern (94 lines)
- `annotated/texgen/sprinkle.hlsl` — Sprite scattering (110 lines)
- `annotated/texgen/subplasma.hlsl` — Catmull-Rom plasma (129 lines)
- `annotated/texgen/envmap.hlsl` — Radial environment gradients (51 lines)

**Original Versions** (production code):
- `texgen/noise.hlsl` (53 lines)
- `texgen/cells.hlsl` (45 lines)
- `texgen/cells-2.hlsl` (39 lines)
- `texgen/celledges.hlsl` (58 lines)
- `texgen/gradient.hlsl` (23 lines)
- `texgen/rectangle.hlsl` (21 lines)
- `texgen/solid-color.hlsl` (11 lines)
- `texgen/tiles.hlsl` (43 lines)
- `texgen/sprinkle.hlsl` (47 lines)
- `texgen/subplasma.hlsl` (54 lines)
- `texgen/envmap.hlsl` (17 lines)

The production versions demonstrate impressive size optimization—`solid-color.hlsl` weighs in at 11 lines including boilerplate. Total size for all eleven generators: approximately 404 lines of HLSL. This compactness is typical of demoscene code, where executable size constraints force ruthless minimalism.
