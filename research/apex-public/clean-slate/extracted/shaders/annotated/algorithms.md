# Algorithm Cross-Reference Index

Quick lookup for algorithms implemented across Clean Slate's shader collection. Organized by category with shader locations and key function names.

## Physically-Based Rendering

### Cook-Torrance BRDF

**Location**: `materials/pbr-mixed-rendering.hlsl`

The standard metallic-roughness PBR workflow:

| Function | Purpose |
|----------|---------|
| `DistributionGGX()` | GGX/Trowbridge-Reitz normal distribution |
| `GeometrySchlickGGX()` | Schlick-GGX geometry term (single direction) |
| `GeometrySmith()` | Smith geometry term (combined view + light) |
| `fresnelSchlick()` | Schlick's Fresnel approximation |

**Key Formula**:
```
BRDF = (D × G × F) / (4 × NdotV × NdotL)
```

### Roughness/Metalness Modifiers

**Location**: `materials/pbr-mixed-rendering.hlsl:ApplyModifier()`

Bidirectional modifier using 127/255 as neutral midpoint:

```hlsl
if (modifier <= 127/255.0)
    return value * modifier / (127/255.0);  // Scale down
else
    return lerp(value, 1, (modifier - 127/255.0) / (128/255.0));  // Push toward 1
```

### Normal Mapping (Derivative-Based)

**Location**: `materials/pbr-mixed-rendering.hlsl:perturb_normal()`

Constructs tangent frame from screen-space derivatives without explicit tangent attributes:

```hlsl
float3 dp1 = ddx(position);
float3 dp2 = ddy(position);
float2 duv1 = ddx(uv);
float2 duv2 = ddy(uv);
// Solve for tangent/bitangent from UV gradients
```

## Area Lighting

### Linearly Transformed Cosines (LTC)

**Location**: `materials/area-sphere-light-ltc.hlsl`

Analytical area light integration via BRDF transformation:

| Function | Purpose |
|----------|---------|
| `InitLTC()` | Sample LTC matrix from lookup tables |
| `LTC_Evaluate()` | Clip polygon to hemisphere and integrate edges |
| `AngleAxis3x3()` | Build rotation matrix for disc orientation |

**Key Insight**: Transform polygon by M⁻¹, integrate clamped cosine analytically, avoid Monte Carlo noise.

**Lookup UV Mapping**:
```hlsl
float2 ltcUV = float2(roughness, sqrt(1 - NdotV)) * 15./16 + 1./32;
```
Maps roughness and viewing angle to 16×16 texture, offset to texel centers.

### Sphere Light Approximation (Non-LTC)

**Location**: `materials/area-sphere-light-non-ltc.hlsl`

Representative point method for sphere lights:
1. Find closest point on sphere to reflection ray
2. Calculate energy normalization based on solid angle
3. Apply standard BRDF at representative point

### LTC Optimized Variant

**Location**: `materials/area-sphere-light-ltc-optimized.hlsl`

Performance-optimized LTC with inline specular calculation:
- Removes separate diffuse pass
- Inlines Fresnel term in LTC evaluation
- Single texture fetch per light

### Diffuse-Only Sphere Light

**Location**: `materials/area-sphere-light-diffuseonly.hlsl`

Simplified area light for diffuse-only surfaces (no specular):
```hlsl
diffuse = saturate(dot(N, lightDir)) * radiusFactor;
```

### Light Body Rendering

**Location**: `materials/area-body-sphere-light-body.hlsl`

Renders the visible light source itself (emissive quad) with view-angle falloff:
```hlsl
falloff = saturate(1 - abs(dot(normalize(lightPos - viewPos), lightNormal)));
```

### Deferred Ambient Light

**Location**: `materials/deferred-ambient-light.hlsl`

Simple hemisphere ambient lighting in deferred pass:
```hlsl
ambient = lerp(groundColor, skyColor, (N.y + 1) * 0.5);
```

### Fake Cubemap Reflections

**Location**: `materials/deferred-fake-cubemap.hlsl`

Box-projected cubemap approximation without actual cubemap:
- Projects reflection ray to enclosing box
- Samples environment from projected point

## Shadow Mapping

### Percentage-Closer Filtering (PCF)

**Location**: `materials/pbr-mixed-rendering.hlsl:VSM()`

Despite the name `VSM`, this implements 5×5 PCF:

```hlsl
for (int x = 0; x < 5; x++)
    for (int y = 0; y < 5; y++)
        shadow += SampleCmpLevelZero(shadowMap, uv + offset * softness, depth);
return shadow / 25.0;
```

### Light Matrix Construction

**Location**: `materials/pbr-mixed-rendering.hlsl:buildLightMatrix()`, `buildOrthoMatrix()`

Constructs view-projection matrix from light position and direction for shadow mapping.

### Variance Shadow Maps (VSM)

**Location**: `materials/shadow-pass.hlsl`

Outputs depth and depth² for statistical shadow filtering:
```hlsl
return float2(depth, depth * depth).xyxy;
```

VSM uses variance `E[x²] - E[x]²` to estimate shadow softness, reducing aliasing.

### Shadow Pass with Vertex Displacement

**Location**: `materials/shadow-pass-with-uv-offset.hlsl`

Shadow depth pass that applies the same vertex displacement as the main render, ensuring shadows match deformed geometry.

## Procedural Noise

### Multi-Octave Perlin Noise

**Location**: `texgen/noise.hlsl`

| Function | Original | Purpose |
|----------|----------|---------|
| `PixelMain()` | `p()` | Main entry, accumulates octaves |
| `sampleHashTexture()` | `GetNoise()` | Read from 256×256 hash texture |

**Parameters** (encoded as bytes × 255):
- `data1.x` — Minimum octave
- `data1.y` — Maximum octave
- `data1.z` — Persistence (amplitude falloff per octave)
- `data1.w` — Interpolation mode (0=smoothstep, 1=linear)

**Smoothstep Formula**:
```hlsl
t *= t * (3 - 2 * t);  // S(t) = t²(3 - 2t)
```

### Voronoi/Worley Cells

**Location**: `texgen/cells.hlsl`, `texgen/cells-2.hlsl`

| Function | Original | Purpose |
|----------|----------|---------|
| `distanceMetric()` | `le()` | Manhattan or Euclidean distance |
| `PixelMain()` | `p()` | Multi-pass minimum distance field |
| `Voronoi()` | `voronoi()` | 3×3 neighborhood search |

**Distance Metrics**:
```hlsl
// Manhattan (data1.w = 1)
float dist = abs(delta.x) + abs(delta.y);

// Euclidean (data1.w = 0)
float dist = length(delta);
```

### Voronoi Cell Edges

**Location**: `texgen/celledges.hlsl`

Two-pass edge detection using perpendicular bisector method:
1. Pass 1: Find nearest cell seed
2. Pass 2: For each other seed, compute distance to edge bisector

```hlsl
// Edge distance = dot(midpoint, normalized direction to other seed)
float d = dot(0.5 * (nearestVec + otherVec), normalize(otherVec - nearestVec));
```

### Superellipse (Rounded Rectangle)

**Location**: `texgen/rectangle.hlsl`

Generates shapes from diamonds to rounded rectangles using:
```hlsl
distance = (|x/a|^n + |y/b|^n)^(1/n)
```

| Exponent | Shape |
|----------|-------|
| n = 1 | Diamond |
| n = 2 | Ellipse |
| n > 2 | Rounded rectangle |
| n → ∞ | Rectangle |

### Sprite Scattering

**Location**: `texgen/sprinkle.hlsl`

Distributes texture sprites with random position, rotation, and scale:
- Noise texture provides per-sprite random values
- 3×3 tile neighborhood sampling for seamless tiling
- Alpha blending for overlapping sprites

### Tile Grid Pattern

**Location**: `texgen/tiles.hlsl`

Generates grid of tiles with:
- Configurable grid dimensions
- Row offset for brick patterns
- Border/gap between tiles
- Unique ID per tile for procedural variation

### Fractal Turbulence

**Location**: `texgen/turbulence.hlsl`

Absolute value noise for turbulent patterns:
```hlsl
turbulence += abs(noise(uv * frequency)) * amplitude;
```

### Subplasma (Catmull-Rom)

**Location**: `texgen/subplasma.hlsl`

Smooth plasma using Catmull-Rom spline interpolation between grid points.

## Post-Processing

### FXAA (Fast Approximate Anti-Aliasing)

**Location**: `materials/fxaa.hlsl`

Edge detection via luminance contrast, blend along detected edges.

### SSAO (Screen-Space Ambient Occlusion)

**Location**: `materials/ssao.hlsl`

Sample hemisphere around each pixel in view space, compare depths to estimate occlusion.

### Depth of Field

**Location**: `materials/depth-of-field.hlsl`

Circle of confusion based on depth difference from focal plane, blur accordingly.

### Screen-Space Reflections

**Location**: `materials/screen-space-reflections.hlsl`

Ray march in screen space along reflection vector, find first hit with depth buffer.

### Chromatic Aberration

**Location**: `materials/chromatic-aberration.hlsl`

Sample RGB channels at offset UVs based on distance from center.

### Film Grain

**Location**: `materials/film-grain.hlsl`

Add noise based on hash function, modulated by luminance.

### ACES Color Grading

**Location**: `materials/aces-color-grading.hlsl`

ACES filmic tone mapping curve for HDR-to-LDR conversion:
```hlsl
// ACES approximation (Narkowicz 2015)
color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
```

### Ghosting (Motion Trails)

**Location**: `materials/ghosting.hlsl`

Temporal smear effect by blending current frame with previous:
```hlsl
output = lerp(currentFrame, previousFrame, ghostAmount);
```

### Glow (Bloom Extraction)

**Location**: `materials/glow.hlsl`

Bright pass filter for bloom pipeline:
- Extracts pixels above threshold
- Subtracts threshold and scales remainder

### Lens Flares

**Location**: `materials/lens-flares.hlsl`

Multiple flare elements positioned opposite to bright spots:
- Ghosts at inverted UV positions
- Halo rings from radial gradient
- Chromatic separation per element

### Sharpen (Unsharp Mask)

**Location**: `materials/sharpen.hlsl`

Edge enhancement via high-pass filter:
```hlsl
sharpened = original + (original - blurred) * strength;
```

### Mapped Fresnel

**Location**: `materials/mapped-fresnel.hlsl`

Fresnel-based rim lighting with texture control:
```hlsl
fresnel = pow(1 - saturate(dot(N, V)), power);
rimColor = texture.Sample(uv * fresnelFactor);
```

### Mirror (Reflection Flip)

**Location**: `materials/mirror.hlsl`

Simple UV flip for planar reflection rendering:
```hlsl
uv.x = 1 - uv.x;  // Horizontal mirror
```

## Texture Operations

### Height-to-Normal Map

**Location**: `texgen/normalmap.hlsl`

Sobel filter to compute normal from height field:
```hlsl
float dx = height(x+1, y) - height(x-1, y);
float dy = height(x, y+1) - height(x, y-1);
normal = normalize(float3(-dx, -dy, scale));
```

### Gaussian Blur

**Location**: `texgen/blur.hlsl`

Separable Gaussian kernel, typically 9-tap or 13-tap.

### Directional Blur

**Location**: `texgen/dirblur.hlsl`

Blur along specified angle/direction vector.

### HSL/HSV Color Space

**Location**: `texgen/hsl.hlsl`, `texgen/hslcurves.hlsl`

RGB ↔ HSV conversion for hue/saturation/value adjustments:

```hlsl
// HSV to RGB (sextant-based)
rgb = (1 - sextantRGB * saturation) * value;
```

Note: Despite naming, hslcurves.hlsl implements HSV (Value), not HSL (Lightness).

### Color Curves (LUT-Based)

**Location**: `texgen/curves.hlsl`, `materials/palette.hlsl`

Per-channel remapping using 1D lookup textures:
```hlsl
result.r = curveLUT.Sample(float2(input.r, 0)).r;
result.g = curveLUT.Sample(float2(input.g, 0)).g;
// etc.
```

### Contrast Adjustment

**Location**: `texgen/contrast.hlsl`

Standard contrast formula with non-linear strength scaling:
```hlsl
output = lerp(0.5, input, strength);
```

### Two-Color Gradient (Colorize)

**Location**: `texgen/colorize.hlsl`

Maps grayscale to two-color gradient:
```hlsl
output = lerp(color1, color2, grayscale);
```

### Glass Distortion

**Location**: `texgen/glass.hlsl`

Refraction effect using height gradient as displacement:
```hlsl
gradient = float2(center - right, center - down);  // Finite difference
displacedUV = uv + gradient * amount;
```

### Rotozoom

**Location**: `texgen/rotozoom.hlsl`

Combined rotation and zoom transformation on UV coordinates.

### Polar Coordinates

**Location**: `texgen/to-polar.hlsl`

Bidirectional Cartesian ↔ Polar conversion:

```hlsl
// Rect to Polar
radius = length(uv - 0.5) * 2;
angle = atan2(uv.x - 0.5, uv.y - 0.5) / (2π);

// Polar to Rect
x = radius * sin(angle * 2π) + 0.5;
y = radius * cos(angle * 2π) + 0.5;
```

### Directional Blur (Map-Controlled)

**Location**: `texgen/dirblur.hlsl`

Blur direction specified per-pixel by a texture:
```hlsl
direction = dirMap.Sample(uv) * 2π;  // 0-1 → angle
blurVec = float2(cos(direction), sin(direction));
// Sample along blurVec
```

Enables radial/zoom blur when direction map contains polar angles.

### Map Distortion

**Location**: `texgen/mapdistort.hlsl`

Direct UV displacement (simpler than glass):
```hlsl
offset = distortMap.Sample(uv) * amount;
displacedUV = uv + offset;
```

## Blend Modes

**Location**: `texgen/combine.hlsl`

Standard compositing blend modes:

| Mode | Formula | Effect |
|------|---------|--------|
| Add | `a + b` | Brightening, glow |
| Subtract | `a - b` | Darkening |
| Multiply | `a × b` | Shadows, darken |
| Screen | `1 - (1-a)(1-b)` | Lighten (inverse multiply) |
| Color Dodge | `a / (1 - b)` | Extreme lighten |
| Color Burn | `1 - (1-a) / b` | Extreme darken |
| Hard Light | Multiply if a<0.5, Screen otherwise | Contrast |
| Min/Max | `min(a,b)` / `max(a,b)` | Darken/Lighten only |
| Alpha | `a(1-b.α) + b·b.α` | Standard compositing |

### Masked Blending

**Location**: `texgen/mixmap.hlsl`

Spatially-varying blend using mask texture:
```hlsl
blendFactor = mask.Sample(uv);
output = lerp(texture1, texture2, blendFactor);
```

## Geometry Techniques

### Animated Wireframe

**Location**: `materials/wireframe.hlsl`

Geometry shader expands lines to screen-space quads:
1. Line input → 2 triangles forming quad
2. Perpendicular direction in NDC for consistent width
3. Animation drives line "growth" from vertex timing values
4. Soft edges via power falloff

```hlsl
perpendicular = float4(-lineDir.y, lineDir.x, 0, 0) * width;
```

### Point Sprites (Billboarding)

**Location**: `materials/pointsprites.hlsl`

Geometry shader expands points to camera-facing quads:
- Uses camera right/up vectors for orientation
- Supports per-particle size and rotation
- UV coordinates generated in geometry shader

### Vertex Displacement

**Location**: `materials/colored-texture-uv-offset-anim.hlsl`, `materials/pbr-mixed-rendering-with-vertex-offset.hlsl`

Texture-driven vertex displacement with animation:
```hlsl
offset = deformTexture.Sample(uv2 + animOffset).x;
displacedPos = position + direction * offset * (1 - vertexColor.r);
```

The vertex color red channel acts as a displacement mask.

## Utility Functions

### Tangent Frame Construction

Used in multiple shaders for normal mapping without vertex tangents:

```hlsl
float3 dp1 = ddx(position);
float3 dp2 = ddy(position);
float3 T = dp2 × N;
float3 B = N × dp1;
```

### Axis-Angle Rotation

**Location**: `materials/area-sphere-light-ltc.hlsl:AngleAxis3x3()`

Build rotation matrix from axis and angle (optimized for Y=0 case).

### Smoothstep Variants

Standard smoothstep: `t² × (3 - 2t)`
Hermite smoothstep: `t³ × (t × (6t - 15) + 10)` (not used in Clean Slate)

## Algorithm Patterns

### Multi-Pass Accumulation

Many texgen shaders use multi-pass rendering where each pass builds on the previous:

```hlsl
if (passIndex > 0)
    result += previousPassTexture.Sample(sampler, uv);
```

**Used in**: `noise.hlsl`, `cells.hlsl`, `turbulence.hlsl`

### Modifier Application

The bidirectional modifier pattern appears throughout materials:

1. Texture provides base value (0-1)
2. Modifier (0-1, neutral at ~0.5) scales or interpolates
3. Result used for roughness, metalness, etc.

### G-Buffer Packing

Multiple render targets encode surface properties:

| RT | Contents |
|----|----------|
| RT0 | Albedo.rgb, Metalness |
| RT1 | Normal.xyz, Roughness |
| RT2 | Emissive.rgb, Alpha |

## Reference Links

- [GGX/Trowbridge-Reitz](https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.pdf) — Original microfacet paper
- [LTC Area Lights](https://eheitzresearch.wordpress.com/415-2/) — Heitz et al. Unity Labs
- [Perlin Noise](https://mrl.cs.nyu.edu/~perlin/paper445.pdf) — Ken Perlin's original paper
- [FXAA](https://developer.download.nvidia.com/assets/gamedev/files/sdk/11/FXAA_WhitePaper.pdf) — NVIDIA whitepaper
