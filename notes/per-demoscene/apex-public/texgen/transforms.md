# apEx Texgen: UV Transforms and Distortion Shaders

Imagine you have a photograph and want to spin it, warp it like a funhouse mirror, or wrap it around a cylinder. You could redraw every pixel in its new position, but there's a smarter way: change where you sample from instead of where you write to. Transform shaders work exactly like this—they manipulate UV coordinates before sampling input textures, reshaping the coordinate space rather than moving pixels around.

This separation of concerns is the key insight. A color blend shader asks "what color should this pixel be?" A transform shader asks "where should I sample from to get this pixel's color?" By answering the second question first, you can rotate, mirror, tile, and distort textures with minimal code. More importantly, transforms compose: apply polar conversion to make a tunnel, then add turbulence to make it swirl, then pixelize it for a retro aesthetic. Each operation is a simple coordinate manipulation.

In Phoenix's texgen architecture, transforms form the second-largest shader category after generators. While generators create pixels from mathematical formulas, transforms reshape existing textures by remapping the coordinate space. This matters for size-constrained demos because a 26-byte rotozoom operator can create infinite variations of a single noise texture—spinning, scaling, positioning—without storing multiple versions.

## The Problem: Size-Constrained Asset Variation

Clean Slate needs to display the same noise texture at different scales, rotations, and positions across multiple scenes. Storing pre-rotated variants would consume kilobytes per texture. Even worse, scrolling effects or animated distortions would require hundreds of frames of pre-baked textures.

The naive solution—generate everything procedurally—fails because some effects are too expensive to compute per-frame. Perlin noise generation with 8 octaves takes significant GPU time. If you need that noise texture rotated 45 degrees and zoomed 2x, regenerating the noise with different parameters wastes cycles recalculating identical values.

Phoenix's transform shaders solve this by operating on existing textures as coordinate transformations. Generate the expensive noise once at 1024×1024, cache it in the texture pool, then create rotated/scaled/distorted variants by manipulating UVs. The coordinate transformation is trivial—a few trigonometric operations per pixel—while the underlying texture data remains unchanged. One noise texture, infinite variations through transforms.

## Transform Categories

Phoenix implements 9 core transform shaders that manipulate UV coordinates in distinct ways. They group into three conceptual categories based on their mathematical approach:

**Geometric Transforms** (rotozoom, translate, scale, mirror, loop) apply linear or affine transformations to the coordinate space. These preserve straight lines and parallel relationships. A square remains a square after rotation and scaling, just positioned and sized differently. Mirroring flips axes, looping tiles the space, but the underlying geometry stays Euclidean.

**Coordinate System Conversions** (to-polar) switch between Cartesian and polar representations. A linear gradient becomes a radial gradient. A horizontal stripe pattern wraps into a tunnel. These transforms are non-linear—straight lines become curves—but they're still deterministic and smooth. Every input coordinate maps to exactly one output coordinate.

**Distortion Transforms** (turbulence, mapdistort, glass) displace UVs based on auxiliary textures. Unlike geometric transforms, these create organic, irregular warping. The displacement field determines where each pixel samples from, enabling effects impossible with simple math: liquid ripples, heat shimmer, fabric wrinkles. They trade predictability for expressiveness.

| Shader | Category | Inputs | Parameters | Transform Type |
|--------|----------|--------|------------|----------------|
| rotozoom | Geometric | 1 | 4 | Rotation + uniform scale |
| translate | Geometric | 1 | 2-3 | UV offset (with optional 45° rotation) |
| scale | Geometric | 1 | 2 | Non-uniform scale |
| mirror | Geometric | 1 | 1 | Axis reflection |
| loop | Geometric | 1 | 2 | Tiling repetition |
| pixelize | Geometric | 1 | 2 | Grid quantization |
| to-polar | Conversion | 1 | 2 | Cartesian ↔ polar |
| turbulence | Distortion | 2 | 2 | Noise-driven angular displacement |
| mapdistort | Distortion | 2 | 2-3 | Map-based UV offset |
| glass | Distortion | 2 | 2 | Gradient-based refraction |

## Rotozoom: Rotation and Zoom Around a Center

The classic demoscene effect combines rotation and scaling in a single operation. Unlike separate rotate+scale transforms, rotozoom performs both around a user-defined center point with optimized trigonometry.

### Parameters

- **[0] Rotation**: Angle in normalized units (0-255 → 0-2π radians)
- **[1] Zoom**: Scale factor with inverse mapping (0 = infinite zoom, 128 ≈ 1:1, 255 = zoomed out)
- **[2] X Center**: Rotation pivot X coordinate (0-255 → 0-1 UV space)
- **[3] Y Center**: Rotation pivot Y coordinate

The zoom parameter uses an inverse relationship for intuitive control. Smaller values zoom in (magnify), larger values zoom out (show more). The specific formula `zoom = 0.25 / (param / 256)` maps the 0-255 range to approximately 4× zoom-in at param=64 to 4× zoom-out at param=255.

### Algorithm

The transform applies three operations in sequence: translate to center, rotate, scale and recenter. This is the standard approach for rotation around an arbitrary point.

```hlsl
// Convert parameters from 0-255 to working values
float2 center = texgenParams.zw * 255.0 / 256.0;
float zoom = 0.25 / (texgenParams.y * 255.0 / 256.0);
float angle = texgenParams.x * 255.0 / 256.0 * 2 * PI;

// Translate UV so center is at origin
float2 centered = texCoord - center;

// Apply rotation matrix
float cosA = cos(angle);
float sinA = sin(angle);
float2 rotated = float2(
    centered.x * cosA + centered.y * sinA,
    centered.y * cosA - centered.x * sinA
);

// Apply zoom and recenter at (0.5, 0.5)
float2 finalUV = rotated * zoom + 0.5;
return inputTexture.Sample(linearSampler, finalUV);
```

The rotation matrix applies the inverse transform to UV coordinates. When you rotate the coordinate system clockwise, the texture appears to rotate counter-clockwise relative to the viewport. The formula uses the standard 2D rotation matrix with angle negation implicit in the sign of `sinA` in the second component.

### Matrix Representation

For those familiar with linear algebra, rotozoom composes three transformations:

```
T_center = [1  0  -cx]
           [0  1  -cy]
           [0  0   1 ]

R_angle = [cos(θ)  sin(θ)  0]
          [-sin(θ) cos(θ)  0]
          [0       0       1]

S_zoom = [z  0  0.5]
         [0  z  0.5]
         [0  0   1 ]

Final = S_zoom × R_angle × T_center
```

The shader computes this product directly without building explicit matrices, saving ALU operations. Only 4 multiplies and 2 adds per pixel beyond the cos/sin calculation.

### Use Cases

**Spinning Logos**: Rotate a static texture continuously by animating the rotation parameter. Clean Slate uses this for intro sequence elements that orbit around screen center.

**Tunnel Effects**: Apply to-polar conversion followed by rotozoom. The polar transform wraps horizontal coordinates into circles, then rotozoom spins and zooms the tunnel in real-time.

**Kaleidoscopes**: Combine mirror and rotozoom. Mirror creates symmetry, rotozoom rotates the mirrored pattern to create mandala-like visuals.

**Background Animation**: Slow zoom and rotation of a noise texture creates evolving ambient backgrounds without regenerating noise each frame.

## Translate: UV Offset and 45-Degree Rotation

Translate shifts UV coordinates by a fixed offset, enabling scrolling textures and repositioning elements. It includes an optional 45-degree rotation preprocessor for creating diagonal patterns from orthogonal ones.

### Parameters

- **[0] Enable 45° Rotation**: Boolean flag (0 = disabled, >0 = enabled)
- **[1] X Offset**: Horizontal shift (0-255 → 0-1 UV space)
- **[2] Y Offset**: Vertical shift

The 45-degree rotation is unusual—most rotation effects use rotozoom. This specialized mode exists for efficiency: diagonal patterns are common in demoscene aesthetics, and hardcoding the angle eliminates parameter normalization and angle calculation overhead.

### Algorithm

The shader has two code paths depending on the rotation flag.

```hlsl
float2 uv = texCoord;

// Optional 45-degree rotation around center
if (texgenParams.x > 0) {
    float angle = PI / 4.0;  // 45 degrees
    float cosA = cos(angle);  // Both equal sqrt(2)/2
    float sinA = sin(angle);

    // Rotation matrix scaled by 1/sqrt(2) to compensate diagonal stretching
    float2x2 rotMatrix = float2x2(cosA, -sinA, sinA, cosA) / sqrt(2.0);

    // Transform around center (0.5, 0.5), scale from [-1,1] to [-0.5,0.5]
    uv = mul(rotMatrix, (uv - 0.5) * 2.0) / 2.0 + 0.5;
}

// Apply offset
float2 offset = texgenParams.yz * 255.0 / 256.0;
return inputTexture.Sample(linearSampler, uv + offset);
```

The rotation includes a `sqrt(2)` normalization factor. Without this, a 45-degree rotated square would have its diagonal length preserved, making the axis-aligned bounding box appear 1.414× larger. Dividing by `sqrt(2)` maintains consistent apparent size.

### Use Cases

**Scrolling Textures**: Animate the X or Y offset parameter to create moving backgrounds. Noise textures scrolled at different rates create parallax depth.

**Positioning Elements**: Shift procedural patterns to specific screen regions without regenerating at different seed coordinates.

**Diagonal Scanlines**: Generate horizontal lines, enable 45° rotation, create diagonal scanline patterns for CRT or glitch effects.

## Scale: Linear Value Remapping

Scale applies a linear transformation to color values, remapping the [0,1] range to a user-defined [min, max] range. Despite its name, this shader operates on color space rather than UV space—it's mislabeled in Phoenix's transform category and should be classified as a color adjustment.

### Parameters

- **[0-3] Min Color**: RGBA minimum value (4 bytes)
- **[4-7] Max Color**: RGBA maximum value (4 bytes)

Each parameter byte maps to a color channel component. The shader uses 8 of its 16 available parameter slots, leaving 8 unused.

### Algorithm

The operation is a straightforward linear interpolation per channel.

```hlsl
float4 color = inputTexture.Sample(linearSampler, texCoord);
float4 minColor = texgenParams;   // Parameters 0-3
float4 maxColor = texgenParams2;  // Parameters 4-7

// Linear interpolation: output = min + input * (max - min)
return lerp(minColor, maxColor, color);
```

When `minColor = (0,0,0,0)` and `maxColor = (1,1,1,1)`, the output equals the input (identity transform). Other values shift and scale the color range.

### Use Cases

**Darkening Images**: Set `min = (0,0,0,0)` and `max = (0.5,0.5,0.5,1)` to compress the dynamic range into the lower half, creating a darkened version.

**Brightening Shadows**: Set `min = (0.5,0.5,0.5,0)` and `max = (1,1,1,1)` to remap black→gray and white→white, lifting shadow detail.

**Color Tinting**: Use non-gray min/max colors to shift hues. For example, `min = (0,0,0.2,0)` adds blue tint to shadows.

**Gradient Remapping**: Convert grayscale to a color gradient by setting `min = red` and `max = blue`, interpolating between them.

Despite being misclassified, scale is useful for normalizing procedural textures that don't naturally fill the [0,1] range or for creating color variations without duplicating generation operators.

## Mirror: Axis Reflection

Mirror flips UV coordinates around one or both axes, creating symmetric patterns from asymmetric inputs. The shader supports four modes by interpreting the parameter as a bitfield.

### Parameters

- **[0] Axis Mode**: Controls which axes to mirror
  - `0` = Mirror X only
  - `1` = Mirror Y only
  - Other values = Both axes (in implementation, uses ternary operator with bitwise check)

The implementation uses a conditional check rather than bitfield manipulation, but the parameter functions as a simple axis selector.

### Algorithm

The core operation reflects coordinates around the center line (0.5 in UV space) using absolute value arithmetic.

```hlsl
float2 uv = texCoord;
float2 mirrored = 0.5 - abs(uv - 0.5);

// Apply mirroring based on axis parameter
uv.x = data1.x ? uv.x : mirrored.x;  // If param.x > 0, keep original X
uv.y = !data1.x ? uv.y : mirrored.y; // If param.x == 0, keep original Y

return Textur.Sample(sm, uv);
```

The `0.5 - abs(uv - 0.5)` formula works by centering coordinates at 0, taking absolute value (which mirrors both halves to positive), then shifting back. For UV values in [0,1]:

- `uv = 0.2` → `centered = -0.3` → `abs = 0.3` → `mirrored = 0.2` (unchanged)
- `uv = 0.8` → `centered = 0.3` → `abs = 0.3` → `mirrored = 0.2` (reflected)

This creates a fold-over effect where the right half reflects the left half (or bottom reflects top for Y-axis).

### Use Cases

**Symmetric Patterns**: Generate half a pattern procedurally, mirror to create perfect symmetry. Saves computation and ensures exact matching.

**Seamless Tiling Preparation**: Mirror edges of a texture to ensure seamless wrapping when tiled. The reflection creates continuity at boundaries.

**Kaleidoscope Effects**: Combine with rotozoom. Mirror creates 4-way symmetry, rotozoom spins the symmetric pattern.

**UI Element Generation**: Create buttons, badges, or icons with guaranteed symmetry by generating one quadrant and mirroring.

## Loop: Tiling Repetition

Loop repeats an input texture multiple times by scaling UV coordinates, relying on the sampler's wrap mode to handle the repetition seamlessly.

### Parameters

- **[0] X Tile Count**: Horizontal repetitions (0-255 → 0-255 actual tiles)
- **[1] Y Tile Count**: Vertical repetitions

The parameter maps directly to tile count with a 255/256 normalization factor. A parameter of 128 creates 127.5 tiles (visible as slight cutoff), while 255 creates approximately 254 tiles.

### Algorithm

The operation scales UV coordinates by the tile count, then relies on texture wrapping to create repetition.

```hlsl
float2 tileCount = float2(texgenParams.x * 255.0, texgenParams.y * 255.0);
return inputTexture.Sample(linearSampler, texCoord * tileCount);
```

When UV coordinates exceed [0,1], the sampler's wrap mode (set to `D3D11_TEXTURE_ADDRESS_WRAP` in Phoenix) causes the texture to repeat. Multiplying by 4 maps the [0,1] UV range to [0,4], which the sampler interprets as 4 complete texture repetitions.

The `frac()` function isn't needed because the sampler handles wrapping automatically. The shader simply scales coordinates and lets hardware texture addressing do the work.

### Use Cases

**Tiled Backgrounds**: Create repeating wallpaper or floor patterns by tiling a seamless base texture.

**Noise Frequency Adjustment**: Increase tile count to make noise patterns denser and higher-frequency without regenerating at higher octaves.

**Detail Textures**: Overlay high-frequency detail noise over lower-frequency base patterns by tiling 8x or 16x.

**Pattern Multiplication**: Turn a single element into a grid of elements for UI or geometric patterns.

## Pixelize: Grid Quantization

Pixelize reduces effective resolution by snapping UV coordinates to a grid, creating blocky mosaic effects. Unlike actual resolution reduction, this preserves output texture size while quantizing sampling positions.

### Parameters

- **[0] X Cell Count**: Horizontal grid divisions (0-255 cells)
- **[1] Y Cell Count**: Vertical grid divisions

Higher values create finer grids (smaller pixels), lower values create coarser blocks. The parameters are inverted to get cell size: `cellSize = 1.0 / (param * 255)`.

### Algorithm

The shader divides UV space into a grid, then samples from the center of each grid cell rather than the actual pixel position.

```hlsl
float2 cellSize = 1.0 / (texgenParams.xy * 255);

// Snap UV to cell center:
// 1. Remove fractional position within cell (fmod)
// 2. Add half cell size to sample from center
float2 snappedUV = texCoord - fmod(texCoord, cellSize) + cellSize / 2.0;

// Use SampleLevel to avoid mipmap selection based on UV derivatives
return inputTexture.SampleLevel(linearSampler, snappedUV, 0);
```

The `fmod(texCoord, cellSize)` operation returns the fractional position within the current cell. Subtracting this "floors" the coordinate to the cell's lower-left corner. Adding `cellSize / 2.0` moves to the center.

Why `SampleLevel` instead of `Sample`? Automatic mipmapping uses UV derivatives (rate of change between neighboring pixels) to select LOD. Quantization creates discontinuous UV jumps at cell boundaries, causing incorrect mipmap selection and artifacts. `SampleLevel(_, _, 0)` forces the highest detail mip, avoiding these issues.

### Use Cases

**Retro Aesthetics**: Create 8-bit or 16-bit style graphics by heavily quantizing modern textures.

**Mosaic Censorship**: Block out regions with coarse pixelization while preserving overall shape.

**Low-Resolution Simulation**: Mimic early computer graphics or pixel art styles on high-resolution displays.

**Transition Effects**: Animate cell count from high to low (or vice versa) for glitch transitions or digital "unmasking" effects.

## To-Polar: Coordinate System Conversion

To-polar converts between Cartesian (rectangular) and polar (radial) coordinate systems, enabling radial effects from linear patterns and vice versa.

### Parameters

- **[0] Direction**: Conversion mode (0 = rect→polar, non-zero = polar→rect)
- **[1] Flip Y**: Vertical flip toggle (0 = normal, non-zero = flipped)

The direction parameter determines which conversion function to apply. The flip is applied before conversion, allowing vertical reflection in either coordinate system.

### Rect-to-Polar Algorithm

This mode converts standard UV coordinates (x=horizontal, y=vertical) to polar representation (x=angle, y=radius).

```hlsl
float2 RectToPolar(float2 uv) {
    float2 centered = uv - 0.5;  // Shift origin to center

    // Radius: distance from center, scaled so corner = 1.0
    float radius = saturate(length(centered) * 2.0);

    // Angle: atan2 returns [-π, π], normalize to [0, 1]
    float angle = atan2(centered.x, centered.y) / (2 * PI);

    return float2(angle, radius);
}
```

The radius calculation uses `length(centered) * 2.0` to normalize the range. At the center, length is 0 (radius = 0). At the corner, length is `sqrt(0.5² + 0.5²) ≈ 0.707`, scaled by 2 gives ~1.414. The `saturate()` clamps values above 1.0, creating circular cropping.

The angle uses `atan2(x, y)` instead of `atan2(y, x)` to set 0° at top (UV y=0) and increase clockwise. This matches typical radial gradient conventions. The division by `2π` converts radians to normalized [0,1] range suitable for texture sampling.

### Polar-to-Rect Algorithm

This mode reverses the process, converting polar coordinates back to Cartesian.

```hlsl
float2 PolarToRect(float2 uv) {
    float radius = uv.y / 2.0;           // Input Y = radius [0,1]
    float angle = uv.x * 2 * PI;         // Input X = angle [0,1] → [0,2π]

    // Convert polar to Cartesian offset from center
    return radius * float2(sin(angle), cos(angle)) + 0.5;
}
```

The radius scales by 0.5 because the output UV space ranges from [0,1], so a radius of 0.5 spans from center to edge. The angle multiplies by `2π` to convert from normalized [0,1] back to radians. The result is offset by 0.5 to recenter at the middle of UV space.

### Use Cases

**Tunnel Effect**: Apply rect→polar to a horizontal stripe pattern. The stripes wrap into concentric circles, creating a classic tunnel. Animate the input pattern's X offset to make the tunnel scroll.

**Radial Gradients**: Convert a linear gradient to radial. A left-to-right gradient (dark→light) becomes a center-to-edge radial gradient.

**Star Burst Patterns**: Feed noise or fractal patterns through rect→polar. Vertical striations become radial spokes, horizontal become concentric rings.

**Circular Distortions**: Apply polar→rect to a distorted version of the polar representation. This creates swirling, twisting effects around the center.

**Clock Faces**: Use polar→rect to unwrap circular elements into linear strips for processing, then rewrap with rect→polar.

The bidirectional nature enables round-trip transformations: apply effects in one space, convert back to the other. For example, blur in polar space creates radial motion blur, while blur in Cartesian space affects polar patterns uniformly.

## Turbulence: Angular Noise Displacement

Turbulence displaces UV coordinates based on a direction map, creating swirling organic distortion. Unlike direct displacement, it interprets map values as angles, converting them to direction vectors.

### Inputs

- **t0**: Source texture to distort
- **t1**: Direction map (typically noise or procedural pattern)

The direction map is usually a grayscale noise texture generated by a Perlin or Voronoi operator. Each pixel's value determines the displacement direction at that location.

### Parameters

- **[0] Control Channel**: Which channel of direction map to read (0-3 = RGBA, encoded as value/256)
- **[1] Displacement Amount**: Offset strength (0-1, larger = stronger distortion)

The channel selection allows using RGBA noise textures where different channels encode different displacement scales or patterns. Amount scales the final displacement vector.

### Algorithm

The shader reads an angle from the direction map, converts it to a unit vector, then offsets the sample position.

```hlsl
int channel = (int)(texgenParams.x * 256);  // 0, 1, 2, or 3
float angleNormalized = directionMap.Sample(linearSampler, texCoord)[channel];

// Convert from [0,1] to [0,2π] radians
float angle = angleNormalized * 2 * PI;

// Convert angle to unit direction vector
float2 direction = float2(cos(angle), sin(angle));
float2 displacedUV = texCoord + direction * texgenParams.y;

return sourceTexture.Sample(linearSampler, displacedUV);
```

The direction map value acts as an angle lookup. A value of 0 maps to 0° (pointing right), 0.25 to 90° (pointing up), 0.5 to 180° (pointing left), and so on. The `cos/sin` conversion produces a unit vector pointing in that direction.

The displacement amount directly scales this unit vector. At amount=0.1, each pixel displaces by at most 0.1 UV units (10% of texture width). The actual displacement varies based on the direction map—uniform map values create straight displacement, turbulent values create chaotic swirls.

### Use Cases

**Liquid Effects**: Use animated noise as the direction map. Each frame's noise determines new displacement directions, creating flowing, turbulent motion.

**Heat Shimmer**: Apply small displacement amount (0.01-0.05) with high-frequency noise for subtle wavering distortion.

**Organic Warping**: Distort text or geometric patterns with low-frequency noise for biological, cellular aesthetics.

**Smoke and Fire**: Combine with upward scrolling and increasing displacement to create rising, turbulent plumes.

The key difference from mapdistort is the angle-to-vector conversion. Turbulence creates rotational, swirling flows because noise changes map to direction changes. Direct displacement (mapdistort) creates stretching and compression.

## Mapdistort: Direct UV Displacement

Mapdistort applies direct UV offset from a displacement map without angular conversion. The map value is the offset, enabling both subtle noise-based warping and extreme positional shifts.

### Inputs

- **t0**: Source texture to distort
- **t1**: Displacement map (noise, gradients, or hand-authored maps)

The displacement map should contain offset values where mid-gray (0.5) represents no displacement, darker values shift negatively, brighter values shift positively.

### Parameters

- **[0] Control Channel**: Which channel of displacement map to read (0-3 = RGBA)
- **[1] X Displacement Amount**: Horizontal offset scale
- **[2] Y Displacement Amount**: Vertical offset scale (optional—if using single amount, Y copies X)

The separate X/Y amounts allow anisotropic distortion. Horizontal-only displacement creates side-to-side warping, vertical-only creates up-down.

### Algorithm

The shader reads a displacement value, centers it at 0, then scales and applies it as UV offset.

```hlsl
int channel = (int)(texgenParams.x * 256);
float displacement = distortMap.Sample(linearSampler, texCoord)[channel];

// Center displacement at 0 (0.5 = no offset, 0 = -max, 1 = +max)
// Scale by amount
float2 offset = displacement * float2(texgenParams.y, texgenParams.z);
float2 distortedUV = texCoord + offset;

return inputTexture.Sample(linearSampler, distortedUV);
```

Wait—the code doesn't subtract 0.5 to center. This means displacement maps interpret 0 as no offset, and positive values displace in positive UV direction. To create bidirectional displacement, the displacement map itself should be authored with 0.5 as neutral gray, then the shader scales directly.

Actually, checking the source more carefully: the formula is just `displacement * amount`, which means:
- `displacement = 0` → no offset
- `displacement = 0.5` → offset by 0.5 × amount
- `displacement = 1.0` → offset by 1.0 × amount

For centered displacement, the map should be pre-offset or the shader should subtract 0.5 first. The implementation as-shown creates unidirectional displacement. This might be a simplification, or the maps are expected to be pre-centered.

### Use Cases

**Noise-Based Warping**: Use Perlin noise as displacement for organic, flowing distortion. Low-frequency noise creates gentle waves, high-frequency creates jittery detail.

**Heat Haze**: Animated vertical displacement with horizontal noise creates rising heat shimmer effects.

**Fabric Wrinkles**: Directional noise patterns create cloth-like folding and creasing when applied to flat textures.

**Water Surface**: Combine horizontal and vertical displacement with animated ripple patterns for water surface refraction simulation.

**Refraction Alternatives**: While glass shader uses gradient-based displacement for physically-inspired refraction, mapdistort uses direct values for artistic control.

## Glass: Gradient-Based Refraction

Glass simulates refraction by displacing UVs based on the gradient of a displacement map. Unlike mapdistort's direct offset, glass computes the rate of change of the displacement field, mimicking how surface normals affect light bending.

### Inputs

- **t0**: Source texture to refract
- **t1**: Displacement/height map (lighter = higher, darker = lower)

The displacement map represents a height field. The gradient of this field approximates surface normals, which determine refraction direction in real glass or water.

### Parameters

- **[0] Control Channel**: Which channel of displacement map to read (0-3 = RGBA)
- **[1] Distortion Amount**: Displacement strength (0.5 = neutral, <0.5 inverts, >0.5 amplifies)

The amount parameter centers at 0.5 rather than 0. This allows bidirectional control: values below 0.5 create negative (inverted) refraction, above 0.5 create positive refraction.

### Algorithm

The shader estimates the gradient by sampling the displacement map at three points: center, right, and down. The differences approximate partial derivatives.

```hlsl
#define SCATTER (1.0 / 32.0)  // Sampling offset for gradient estimation

int channel = (int)(texgenParams.x * 256);

// Sample displacement at current position and two neighbors
float centerValue = displacementMap.Sample(linearSampler, texCoord)[channel];
float rightValue = displacementMap.Sample(linearSampler,
                     texCoord + float2(SCATTER, 0))[channel];
float downValue = displacementMap.Sample(linearSampler,
                    texCoord + float2(0, SCATTER))[channel];

// Compute gradient (finite differences)
float2 gradient = float2(centerValue - rightValue, centerValue - downValue);

// Apply displacement based on gradient
float2 displacedUV = texCoord + gradient * (texgenParams.y - 0.5);

return inputTexture.Sample(linearSampler, displacedUV);
```

The gradient calculation uses forward differences: `center - neighbor`. This approximates the slope of the height field in each direction. Steep slopes (large differences) create stronger displacement, flat regions (small differences) create minimal offset.

The `SCATTER` constant (1/32) determines the sampling distance. Smaller values yield more accurate gradients but amplify noise. Larger values smooth the gradient but lose detail. Phoenix's choice of 1/32 balances sharpness and stability for typical procedural displacement maps.

The amount parameter shifts by 0.5 before scaling, so `amount = 0.5` produces zero displacement (neutral), `amount = 1.0` scales gradient by 0.5, and `amount = 0.0` scales by -0.5 (inverted refraction).

### Physical Interpretation

Real refraction occurs when light enters a material with different refractive index. The surface normal determines the bending angle. In a height field, the gradient points perpendicular to contour lines—uphill. The normal is perpendicular to the gradient (rotated 90°).

Glass shader doesn't rotate the gradient to compute the true normal. Instead, it uses the gradient directly as displacement. This approximation works visually because:

1. Gradient magnitude correlates with surface steepness (sharper features bend light more)
2. Gradient direction indicates which way the surface tilts
3. UV displacement in gradient direction creates visually plausible refraction

For physically accurate refraction, you'd compute the normal `N = normalize(float3(-gradient.x, -gradient.y, 1))`, then apply Snell's law. Phoenix skips this for simplicity and performance—the gradient alone suffices for convincing effects.

### Use Cases

**Water Surface Refraction**: Use animated noise or ripple patterns as displacement. The gradient creates flowing, shimmering refraction matching water movement.

**Glass Material**: Static noise or Voronoi patterns create frosted or textured glass effects.

**Heat Shimmer**: Subtle gradients with low-frequency noise mimic atmospheric distortion.

**Underwater Caustics**: While not caustics in the traditional sense (focused light patterns), gradient displacement of bright patterns creates organic, shifting light pools.

**Lens Distortion**: Radial gradient maps create barrel or pincushion distortion for camera lens simulation.

## Transform Chains: Order Sensitivity and Composition

Transform order matters profoundly. Unlike commutative operations (A + B = B + A), coordinate transformations compose non-commutatively: rotating then scaling differs from scaling then rotating.

### Example 1: Rotation vs. Tiling Order

**Chain A: rotozoom → loop**

1. Rotozoom rotates and scales the input texture
2. Loop tiles the rotated result

Result: A rotated pattern, repeated across UV space. Each tile is identical and rotated.

**Chain B: loop → rotozoom**

1. Loop tiles the input texture
2. Rotozoom rotates the entire tiled grid

Result: The tiling pattern itself rotates. Tiles near the center stay aligned, but tiles away from center rotate around the center point. Creates a spiraling, kaleidoscopic grid.

The visual difference is dramatic. Chain A creates uniform repetition of a rotated element. Chain B creates a rotational arrangement of elements.

### Example 2: Polar Conversion Placement

**Chain A: gradient → to-polar(rect→polar)**

A horizontal linear gradient (left=dark, right=bright) becomes a radial gradient (center=dark, edge=bright). The linear ramp wraps around the center.

**Chain B: to-polar(rect→polar) → gradient**

This doesn't make sense—gradient generators ignore input textures. They produce fresh color ramps. The polar conversion has no effect.

Better example:

**Chain A: noise → to-polar(rect→polar)**

Perlin noise becomes radial noise. Vertical striations (if present) become circular rings, horizontal striations become radial spokes.

**Chain B: noise → to-polar(rect→polar) → turbulence**

The noise converts to polar, then turbulence distorts the polar pattern. Because turbulence interprets values as angles, it creates swirling, spiraling distortion in the radial space.

### Example 3: Distortion Pipeline Position

**Chain A: noise → turbulence → colorize**

Turbulence distorts the noise, then colorize maps the distorted grayscale to colors. The distortion warps the noise pattern before color mapping.

**Chain B: noise → colorize → turbulence**

Colorize first maps grayscale to RGB, then turbulence distorts the colored result. If turbulence uses the red channel as displacement, it creates different warping than using grayscale.

**Chain C: noise → mapdistort(using same noise as displacement) → blur**

The noise distorts itself—self-displacement creates recursive, fractal-like warping. Blur then smooths the chaotic result.

### General Ordering Principles

**Coordinate Space Changes First**: Polar conversion, mirror, and geometric transforms should typically precede distortion and color operations. Reason: distortions work in a coordinate space, so establish the space first.

**Distortions Late**: Turbulence, mapdistort, and glass introduce irregularity. Apply them after establishing the base pattern but before final color grading. This preserves the distortion's expressiveness while allowing color adjustments.

**Tiling and Pixelization Last**: Loop and pixelize are usually final steps. Tiling repeats whatever exists, so apply it after all modifications. Pixelization is an aesthetic overlay, not a spatial transform, so it comes last.

**Scale and Translate for Positioning**: Use these to finalize placement. They don't distort or fundamentally change the pattern, just reposition and size it.

**Exceptions for Effect**: Rules break when creating specific effects. Rotating after distortion can create unexpected but useful patterns. Mirroring post-blur creates symmetric soft shapes. Experimentation reveals non-obvious chains.

## Transform Shader Comparison Matrix

This table clarifies when to use each transform based on desired effect:

| Goal | Recommended Shader(s) | Alternative Approach | Notes |
|------|----------------------|----------------------|-------|
| Spin a texture | rotozoom | translate (if only 45°) | Rotozoom handles arbitrary angles |
| Scale non-uniformly | scale (but color-space, not UV) | Use parent texture at different resolution | True UV scaling not exposed separately |
| Create symmetry | mirror | Duplicate and flip in graph | Mirror is single-op, more efficient |
| Tile a pattern | loop | Generate at higher frequency | Loop reuses existing texture |
| Reduce resolution | pixelize | Generate at lower res | Pixelize preserves texture size |
| Convert to radial | to-polar (rect→polar) | Generate in polar space initially | Conversion reuses existing patterns |
| Create tunnel | to-polar + rotozoom | Custom polar generator | Composition more flexible |
| Organic distortion | turbulence or mapdistort | Displacement in shader code | Separate map enables reuse |
| Refraction effect | glass | mapdistort with gradient | Glass simpler for height fields |
| Scrolling animation | translate (animated offset) | Shader with time parameter | Translate operator enables sequencing |

## Implications for Rust Framework Design

Phoenix's transform shaders reveal several architectural insights applicable to a Rust-based creative coding framework.

### Adopt: Matrix-Based Transform API

Instead of separate operators for rotate, scale, translate, expose a unified transform stack:

```rust
struct Transform {
    matrix: Mat3,  // 3x3 for 2D homogeneous coordinates
}

impl Transform {
    fn rotate(angle: f32) -> Self { /* ... */ }
    fn scale(sx: f32, sy: f32) -> Self { /* ... */ }
    fn translate(tx: f32, ty: f32) -> Self { /* ... */ }

    fn then(&self, other: &Transform) -> Transform {
        Transform { matrix: other.matrix * self.matrix }
    }
}
```

This allows users to compose transforms explicitly:

```rust
let transform = Transform::rotate(PI/4)
    .then(&Transform::scale(2.0, 2.0))
    .then(&Transform::translate(0.5, 0.5));
```

The `then` method makes order explicit and enables optimization—combining multiple matrices before sending to GPU.

### Adopt: Polar Conversion as First-Class Operation

Polar transformations are common enough to warrant dedicated support. Expose as a transform mode:

```rust
enum CoordinateSpace {
    Cartesian,
    Polar { origin: Vec2 },
}

trait Texture {
    fn in_space(&self, space: CoordinateSpace) -> Texture;
}

// Usage:
let tunnel = noise_texture
    .in_space(CoordinateSpace::Polar { origin: Vec2::new(0.5, 0.5) })
    .rotate(angle);
```

This makes the intent clear: operate in polar space, then convert back implicitly.

### Adopt: Type-Safe Displacement Connections

Distortion shaders take two inputs: source and displacement map. Make this explicit in the type system:

```rust
struct Displacement {
    map: Texture,
    channel: ColorChannel,
    amount: f32,
}

enum DistortionMode {
    Direct(Displacement),      // mapdistort
    Angular(Displacement),     // turbulence
    Gradient(Displacement),    // glass
}

impl Texture {
    fn distort(&self, mode: DistortionMode) -> Texture {
        // ...
    }
}

// Usage:
let warped = base_texture.distort(
    DistortionMode::Angular(Displacement {
        map: noise,
        channel: ColorChannel::Red,
        amount: 0.1,
    })
);
```

This prevents accidentally passing color textures as displacement maps and clarifies the distortion type.

### Adopt: Animation Support for Transform Parameters

Many transforms become powerful when animated. Provide time-varying parameter support:

```rust
trait Animatable {
    fn at_time(&self, t: f32) -> f32;
}

struct AnimatedParam {
    curve: Box<dyn Fn(f32) -> f32>,
}

impl Animatable for AnimatedParam {
    fn at_time(&self, t: f32) -> f32 {
        (self.curve)(t)
    }
}

// Usage:
let spinning = texture.transform(
    Transform::rotate(AnimatedParam::new(|t| t * 2.0 * PI))
);
```

This enables declarative animation without manual per-frame parameter updates.

### Consider: Compile-Time Transform Chain Optimization

Rust's type system can enforce or optimize transform chains:

```rust
// Marker types for transform categories
struct Geometric;
struct Distortion;
struct ColorSpace;

struct TypedTransform<T> {
    inner: Transform,
    _phantom: PhantomData<T>,
}

// Enforce ordering: geometric before distortion
impl TypedTransform<Geometric> {
    fn then_distort(self, dist: DistortionMode) -> TypedTransform<Distortion> {
        // ...
    }
}

// Prevent distortion chaining without intermediate blending
impl TypedTransform<Distortion> {
    // No `then_distort` method—forces user to blend or convert back first
}
```

This prevents nonsensical chains like "distort → distort → distort" without intermediate rendering.

### Consider: Lazy Evaluation with Smart Caching

Phoenix caches at the operator level. Rust can go further with automatic memoization:

```rust
struct CachedTexture {
    generator: Box<dyn Fn() -> RawTexture>,
    cache: RefCell<Option<Arc<RawTexture>>>,
}

impl CachedTexture {
    fn get(&self) -> Arc<RawTexture> {
        let mut cache = self.cache.borrow_mut();
        cache.get_or_insert_with(|| {
            Arc::new((self.generator)())
        }).clone()
    }
}

// Usage:
let expensive_noise = CachedTexture::new(|| generate_perlin_8_octaves());
let rotated = expensive_noise.get().rotate(PI/4);  // Reuses cached noise
let scaled = expensive_noise.get().scale(2.0, 2.0); // Reuses same cache
```

The `Arc` enables sharing the cached texture across multiple transform chains without duplication.

### Avoid: Implicit Parameter Normalization

Phoenix normalizes parameters by dividing by 255. This loses precision and creates confusion (is 128 = 0.5 or 0.501953?). Use explicit ranges:

```rust
struct Param<T> {
    value: T,
    range: Range<T>,
}

impl Param<f32> {
    fn normalized(&self) -> f32 {
        (self.value - self.range.start) / (self.range.end - self.range.start)
    }
}

// Usage:
let rotation = Param { value: PI/4, range: 0.0..TAU };
let zoom = Param { value: 2.0, range: 0.1..10.0 };
```

This preserves full `f32` precision and makes parameter semantics explicit.

### Avoid: Single-Purpose Hardcoded Angles

Translate's 45-degree rotation is inflexible. Instead, expose general rotation and let optimization eliminate redundant parameters:

```rust
// Instead of special-casing 45 degrees:
texture.translate(offset).rotate_45();

// Provide general rotation and optimize:
texture.translate(offset).rotate(PI/4);

// Compiler or runtime can detect constant angle and use specialized path
```

This keeps the API surface smaller while maintaining flexibility.

## Related Documents

This document focused on UV transform and distortion shaders. For the complete texgen picture, see:

- **overview.md** — Texgen system architecture, operator graphs, texture pooling, multi-pass rendering
- **pipeline.md** — Operator evaluation flow, dependency resolution, caching strategies
- **operators.md** — Per-operator parameter layouts, filter assignments, resolution encoding
- **shaders.md** — HLSL shader structure, constant buffer conventions, sampler states
- **generators.md** — Noise generation (Perlin, Voronoi), gradients, tile patterns, procedural creation (to be written)
- **color-blend.md** — Blend modes, colorize, HSL adjustment, color curves (to be written)

## Source File Reference

All source paths are relative to `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/`.

| Shader | Source Path | Annotated Path | Lines | Key Parameters |
|--------|-------------|----------------|-------|----------------|
| rotozoom | texgen/rotozoom.hlsl | annotated/texgen/rotozoom.hlsl | 26 | [0]=angle, [1]=zoom, [2-3]=center |
| translate | texgen/translate.hlsl | annotated/texgen/translate.hlsl | 24 | [0]=rot45, [1-2]=offset |
| scale | texgen/scale.hlsl | annotated/texgen/scale.hlsl | 22 | [0-7]=min/max colors |
| mirror | texgen/mirror.hlsl | — | 14 | [0]=axis mode |
| loop | texgen/loop.hlsl | annotated/texgen/loop.hlsl | 14 | [0-1]=tile counts |
| pixelize | texgen/pixelize.hlsl | annotated/texgen/pixelize.hlsl | 16 | [0-1]=cell counts |
| to-polar | texgen/to-polar.hlsl | annotated/texgen/to-polar.hlsl | 33 | [0]=direction, [1]=flip Y |
| turbulence | texgen/turbulence.hlsl | annotated/texgen/turbulence.hlsl | 18 | [0]=channel, [1]=amount |
| mapdistort | texgen/mapdistort.hlsl | annotated/texgen/mapdistort.hlsl | 18 | [0]=channel, [1-2]=XY amounts |
| glass | texgen/glass.hlsl | annotated/texgen/glass.hlsl | 26 | [0]=channel, [1]=amount |

**Key Line References**:

- **rotozoom.hlsl**: Lines 45-70 implement rotation matrix and zoom application
- **to-polar.hlsl**: Lines 48-59 (rect→polar), 67-74 (polar→rect) define coordinate conversions
- **turbulence.hlsl**: Lines 43-53 convert angle to direction vector
- **glass.hlsl**: Lines 60-65 compute gradient via finite differences
- **pixelize.hlsl**: Line 50 implements UV quantization with `fmod`

Transform shaders demonstrate how coordinate manipulation creates visual complexity from simple mathematical operations. By separating "what to draw" (generators, color operations) from "where to sample" (transforms), Phoenix achieves remarkable expressive range with minimal code. A Rust framework can adopt these patterns while leveraging stronger type systems and modern GPU APIs for improved safety and cross-platform support.
