# Phoenix Texgen Shader System

Texgen shaders are GPU programs that transform UV coordinates and input textures into output pixels. Unlike rendering shaders that handle 3D geometry, texgen shaders operate on 2D fullscreen quads, making them conceptually simpler but algorithmically diverse. Each shader is a self-contained image processing operation—you might compose 20 texgen operations to create a single material texture.

The texgen pipeline resembles a node-based compositor like Nuke or Substance Designer, but implemented as a minimal runtime system fitting in a 64k executable. Shaders chain together through multi-pass rendering: each pass reads the previous result, applies a transformation, writes to a render target, then generates mipmaps. The entire system shares a single vertex shader and constant buffer layout, reducing code duplication.

Phoenix includes 37 texgen shaders spanning five categories: generators create patterns from UV coordinates alone, transforms manipulate existing textures through geometric operations, color/blend shaders adjust appearance and composite layers, filters apply convolution-based effects, and specialized shaders handle normals and text. Understanding the common infrastructure reveals how these diverse operations share a unified architecture.

## The Fullscreen Quad Contract

Every texgen shader operates on the same implicit geometry: a fullscreen quad covering clip space from [-1, 1]. The vertex shader transforms this quad to screen space while preserving UV coordinates in [0, 1] range. Pixel shaders receive UV coordinates and output colors—no vertex manipulation, no depth testing, just pure 2D image processing.

### Shared Vertex Shader

All texgen operations use a single pass-through vertex shader. The Phoenix engine creates a vertex buffer containing two triangles covering the screen, with positions and UVs pre-computed. The vertex shader simply transforms position to clip space and passes UV coordinates to the pixel shader.

The vertex format contains six floats per vertex: three for position (XYZ in clip space), two for UV coordinates, and one padding float for alignment. The shader reads position and UV, outputs clip-space position with the `SV_POSITION` semantic, and passes UV with the `TEXCOORD0` semantic. No matrices, no transformations—just data forwarding.

This approach eliminates per-shader vertex code. Whether generating noise, blurring an image, or transforming to polar coordinates, the same six vertices feed the pipeline. The vertex shader compiles once; pixel shaders provide the algorithmic variety.

### Pixel Shader Signature

All texgen pixel shaders follow the same signature pattern:

```hlsl
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
```

The `texCoord` input arrives in [0, 1] range, where (0, 0) represents the top-left corner and (1, 1) the bottom-right. The return value writes to render target 0—the current output texture. Some shaders sample input textures at `texCoord` directly; others transform coordinates before sampling or synthesize values from mathematical functions.

The shader names its entry point `p()` in minified form. The full parameter name `texCoord` becomes `t`, return type becomes implicit. This minification shaves bytes from the compressed executable without changing semantics.

## Constant Buffer Architecture

### Parameter Packing

Texgen shaders receive parameters through a compact constant buffer layout. The system allocates 20 constant buffer slots (5 float4 registers) shared across all shaders. The CPU-side code in `Texgen.cpp` packs data into this buffer before each render pass.

The first float4 register (`c0`) contains pass information:
- `x` component holds the current pass index (0-based integer)
- `y`, `z`, `w` components contain random values regenerated each pass

Registers `c1` through `c4` store shader-specific parameters. The demotool UI exposes parameter sliders ranging 0-255 as bytes. The CPU converts these bytes to normalized floats (dividing by 255.0) before uploading to GPU. Shaders interpret these normalized values according to their semantics—some multiply by constants to recover full range, others use the 0-1 range directly.

```cpp
// Texgen.cpp:151-153
ShaderData[0] = (float)x;  // Pass index
for (int y = 0; y < 3; y++)
  ShaderData[y + 1] = rand() / (float)RAND_MAX;  // Random [0,1]
for (int y = 0; y < TEXGEN_MAX_PARAMS; y++)
  ShaderData[y + 4] = Parameters[y] / 255.0f;  // Normalized params
```

### Register Declarations

Shaders declare constant buffer registers using HLSL's `register()` syntax. The pass information always binds to `c0`, but shaders name this register differently based on their needs. The noise shader calls it `passInfo` to emphasize pass-based accumulation:

```hlsl
float4 passInfo : register(c0);      // x=pass, y/z/w=random
float4 texgenParams : register(c1);  // Shader-specific parameters
```

The colorize shader renames parameter registers for semantic clarity:

```hlsl
float4 PassData : register(c0);      // Same slot as passInfo
float4 Color1 : register(c1);        // First color gradient endpoint
float4 Color2 : register(c2);        // Second color gradient endpoint
float4 texgenParams : register(c3);  // Control channel selector
```

This flexibility allows shader authors to use meaningful names without allocating additional GPU resources. The register slot determines binding; the variable name aids human comprehension.

### Parameter Encoding

Parameters pack into bytes in the demotool, requiring shaders to decode them. The encoding conventions vary by parameter semantics. Integer selectors (blend mode, pattern type, color channel) multiply by 256 and cast to int:

```hlsl
int blendMode = (int)(texgenParams.x * 256);  // 0-255 selector
```

Continuous values (strength, zoom, rotation) multiply by constants to restore full range:

```hlsl
float angle = texgenParams.x * 255.0 / 256.0 * 3.14159265 * 2.0;  // 0-2π
float zoom = 0.25 / (texgenParams.y * 255.0 / 256.0);  // Inverse relation
```

The `255/256` factor appears frequently—it maps the normalized [0, 1] range back to the original [0, 255] byte range while avoiding exact 1.0 values that might cause edge case issues with modulo or indexing operations.

Some parameters use bidirectional encoding where 0.5 represents "no change." The HSL shader darkens for values below 0.5 and brightens above:

```hlsl
if (params.z < 0.5)
  color.z *= params.z * 2;  // Darken: 0→black, 0.5→unchanged
else
  color.z = lerp(color.z, 1, (params.z - 0.5) * 2);  // Brighten: 0.5→unchanged, 1→white
```

## Texture Binding Conventions

### Input Texture Slots

Texgen shaders bind input textures to registers `t0` through `t4`. The binding order follows consistent conventions: the primary input (or previous pass result) binds to `t0`, secondary inputs bind to `t1` and `t2`, and specialized lookup tables bind to `t1` or later slots.

For single-pass shaders operating on one input, `t0` contains the source texture:

```hlsl
Texture2D inputTexture : register(t0);
```

Multi-input shaders declare additional textures:

```hlsl
Texture2D texture1 : register(t0);  // Base layer
Texture2D texture2 : register(t1);  // Blend layer
```

Shaders using displacement or control maps declare them separately:

```hlsl
Texture2D sourceTexture : register(t0);   // Image to distort
Texture2D directionMap : register(t1);    // Displacement vectors
```

### Hash Texture for Randomness

Procedural generators (noise, cells, sprinkle, subplasma) need random values but can't use `rand()` in shaders. Phoenix solves this with a pre-generated 256×256 hash texture uploaded once during initialization. This texture contains pseudo-random RGBA values generated CPU-side.

Shaders bind the hash texture to `t1` and sample it using integer coordinates:

```hlsl
Texture2D hashTexture : register(t1);

float4 SampleHashTexture(float2 integerCoord)
{
  float2 scaledCoord = integerCoord * 256 * (max(1, passInfo.x) * (1 + passInfo.y));
  return hashTexture.Load(int3(fmod(scaledCoord, 256), 0));
}
```

The `Load()` method performs point sampling without filtering—it returns exact texel values. The `fmod(..., 256)` wraps coordinates to create seamless tiling. The coordinate scaling incorporates pass index and random offsets to generate different values per pass without allocating additional textures.

### Multi-Pass Texture Flow

Multi-pass shaders read from the previous pass result via `t0`. The `Texgen.cpp` render loop manages this ping-pong pattern:

```cpp
// Texgen.cpp:163
if (Inputs[0] || x)
  Textures[scnt++] = x ? SwapBuffer->View : Inputs[0]->View;
```

On pass 0, `t0` binds to the first external input (or null). On pass 1+, `t0` binds to the previous pass output. This enables accumulation patterns where each pass adds to the result:

```hlsl
// noise.hlsl:156
if (relativePassIndex > 0)
  noiseValue += previousPassTexture.Sample(linearSampler, texCoord);
else
  noiseValue += 0.5;  // First pass: start with midpoint
```

The swap happens automatically—shaders simply read from `t0` and write to `SV_TARGET0` without managing render target binding.

## Sampler Configuration

Phoenix creates three global samplers during engine initialization. These samplers bind to slots `s0`, `s1`, and `s2`, available to all texgen shaders.

### Sampler Slot Assignments

| Slot | Address Mode | Filter | Comparison | Common Use |
|------|--------------|--------|------------|------------|
| s0 | Wrap | Linear | Never | Tiling patterns, seamless textures |
| s1 | Clamp | Linear | Never | Edge-aware sampling, no-wrap effects |
| s2 | Border | Linear | Less | Shadow comparison (unused in texgen) |

The wrap sampler (`s0`) enables seamless tiling by repeating texture coordinates beyond [0, 1]. When a shader samples at UV coordinate (1.3, 0.7), the sampler wraps to (0.3, 0.7), creating infinite repetition. Most texgen operations use wrap mode—noise functions, transforms, and color operations all assume tileable results.

The clamp sampler (`s1`) clamps coordinates to [0, 1] range. Sampling at (1.3, 0.7) returns the same value as (1.0, 0.7)—the edge pixel color. This prevents artifacts in effects that intentionally extend beyond texture boundaries, though few texgen shaders use it in practice.

The shadow comparison sampler (`s2`) exists for consistency with rendering shaders but sees no texgen usage. Shadow mapping requires depth comparison, irrelevant for 2D texture generation.

### Filtering Implications

All texgen samplers use `D3D11_FILTER_MIN_MAG_MIP_LINEAR`—trilinear filtering. When sampling between texels, the GPU interpolates four neighboring pixels (bilinear), then interpolates between mipmap levels (trilinear). This produces smooth results but can blur fine details.

Some effects deliberately avoid filtering. The hash texture sampling uses `Load()` instead of `Sample()` to get exact texel values without interpolation. This preserves the discrete random values needed for noise generation.

The mipmap generation happens automatically after each pass via `GenerateMips()` call in the render loop. This ensures correct mip levels for the next pass, crucial when shaders sample at varying frequencies (noise octaves, blur kernels).

## Multi-Pass Rendering Patterns

### Accumulation (Fractal Noise)

The noise shader implements multi-octave Perlin noise through accumulation. Each pass generates one octave at a specific frequency and amplitude, adding it to the accumulated result from previous passes.

Pass 0 generates the base octave at the coarsest frequency. It samples the hash texture at grid cell corners, interpolates between them (with optional smoothstep), and writes the result centered around 0.5:

```hlsl
// noise.hlsl:158-163
if (relativePassIndex > 0)
  noiseValue += previousPassTexture.Sample(linearSampler, texCoord);
else
  noiseValue += 0.5;  // First pass: bias to mid-gray
```

Pass 1+ doubles the frequency (halves the cell size), scales amplitude by the persistence factor, generates the new octave, and adds it to the previous result. The frequency doubling creates the characteristic fractal pattern where fine details overlay coarse structure.

The min/max octave parameters control which passes actually execute. Passes outside the specified range simply copy the previous result:

```hlsl
// noise.hlsl:170-173
if (passInfo.x + 0.5 > maxOctave)
  noiseValue = previousPassTexture.Sample(linearSampler, texCoord);
```

This allows selecting octave subsets (e.g., "only octaves 2-5") without recompiling shaders or changing pass counts.

### Iterative Minimum (Voronoi Cells)

The cells shader finds minimum distance to randomly placed feature points using an iterative multi-pass approach. Each pass checks different positions and maintains the minimum distance found so far.

Pass 0 calculates distance from the current UV to a randomly positioned feature point. The hash texture provides the feature point location, the shader computes distance (Euclidean or Manhattan based on parameter), and writes the result.

Pass 1+ reads distances from two offset positions in the previous pass result, computes the distance to a new feature point for this pass, and keeps the minimum of the three:

```hlsl
// cells.hlsl:125-132
float2 offset1 = texCoord + randomOffsets.xy;
float2 offset2 = texCoord + randomOffsets.zw;

float neighborDist1 = previousPassTexture.Sample(linearSampler, offset1).x;
float neighborDist2 = previousPassTexture.Sample(linearSampler, offset2).x;

normalizedDistance = min(normalizedDistance, min(neighborDist1, neighborDist2));
```

The offset sampling checks neighboring cells, ensuring the shader finds nearby feature points that might be closer than points in the current cell. The random offsets (from `passInfo.yzw`) vary per pass, searching different regions of space.

After N iterations (typically 16), the minimum distance converges to the correct Voronoi value. More passes improve accuracy but increase render time—a tunable quality-performance trade-off.

### Separable Convolution (Blur)

The blur shader exploits separability to reduce sample count. A 2D blur naive implementation requires N² samples (24×24 = 576 for Phoenix's blur). Separating into horizontal then vertical passes requires only 2N samples (24+24 = 48).

Passes 0-2 perform horizontal blur. The shader sets the X step vector to the blur radius and Y step to zero, then accumulates 24 samples along the horizontal line:

```hlsl
// blur.hlsl:42-49
float xMultiplier = 1;
float yMultiplier = 0;

if (passInfo.x + 0.5 >= 3)  // Pass 3+
{
  xMultiplier = 0;
  yMultiplier = 1;
}
```

The first horizontal pass reads the input texture and outputs a horizontally blurred result. Passes 1-2 read the previous horizontal pass, applying additional horizontal blur. Three passes approximate a Gaussian distribution better than a single box filter.

Passes 3+ perform vertical blur. They read the horizontally blurred result from passes 0-2, set the Y step vector to the blur radius, and accumulate 24 samples along the vertical line. The output is the fully blurred image.

This pattern applies to any separable convolution—Gaussian blur, box blur, certain sharpening kernels. The key insight: if the 2D kernel equals the product of two 1D kernels, separate the passes.

### Pass Skip Pattern (Conditional Execution)

Several shaders include conditional logic to skip passes outside a parameter-specified range. The noise shader demonstrates this with min/max octave parameters—artists select which octave range to include without changing the shader.

The shader calculates the relative pass index (absolute pass minus minimum octave). If the current pass falls below the minimum or above the maximum, it simply copies the previous result:

```hlsl
// noise.hlsl:73-78, 170-173
float minOctave = texgenParams.x * 255 - 1;
float maxOctave = texgenParams.y * 255;
int relativePassIndex = passInfo.x + 0.5 - minOctave;

if (passInfo.x + 0.5 > maxOctave)
  noiseValue = previousPassTexture.Sample(linearSampler, texCoord);
```

This pattern enables flexible pass control without dynamic pass count allocation. The shader always executes the full pass count, but "inactive" passes become no-ops that propagate the previous result. The overhead is minimal—a texture sample and comparison—while the flexibility simplifies parameter design.

## Algorithm Inventory

### Hash-Based Noise Sampling

Procedural generators need random values but lack CPU `rand()` access. The hash texture pattern solves this: upload a 256×256 texture containing pre-computed random RGBA values, sample it using wrapped integer coordinates, and use the values as deterministic "random" data.

The hash texture contains values generated via XOR-shift PRNG on the CPU side. The `Texgen.cpp` file implements a 96-bit XOR-shift generator that produces full-period random sequences. These values fill the hash texture once during initialization.

Shaders sample the hash texture using `Load()` with integer coordinates. The `fmod(..., 256)` ensures coordinates wrap correctly, creating seamless tiling. The coordinate scaling incorporates pass index and frequency multipliers to generate different values across passes without re-uploading the texture:

```hlsl
// noise.hlsl:47-56
float4 SampleHashTexture(float2 integerCoord)
{
  float2 scaledCoord = integerCoord * 256 * (max(1, passInfo.x) * (1 + passInfo.y));
  return hashTexture.Load(int3(fmod(scaledCoord, 256), 0));
}
```

The `max(1, passInfo.x)` ensures scaling starts at 256 even on pass 0, preventing division by zero. The `(1 + passInfo.y)` adds frequency variation based on the random value from the constant buffer.

This technique enables noise, cellular patterns, sprite scattering, and plasma generation without uploading new data per frame. The hash texture is random access, tileable, and compact (256×256×4 bytes = 256KB uncompressed).

### Bilinear Interpolation with Smoothstep

Value noise requires interpolating between grid cell corners to create smooth gradients. The noise shader implements this with a two-stage process: find the four corner values, then interpolate based on position within the cell.

The shader finds the grid cell containing the current UV coordinate by flooring to the nearest cell boundary:

```hlsl
// noise.hlsl:98-101
float2 fractionalPart = uv % cellSize;
uv -= fractionalPart;            // Snap to bottom-left corner
fractionalPart /= cellSize;      // Normalize to [0,1] within cell
```

Standard bilinear interpolation would use `fractionalPart` directly as the interpolation factor. However, this creates visible grid artifacts—the derivative of linear interpolation is discontinuous at grid cell boundaries.

Smoothstep fixes this by applying an S-curve that has zero derivative at 0 and 1:

```hlsl
// noise.hlsl:109-114
if (texgenParams.w == 0)  // Smoothstep mode
  fractionalPart *= fractionalPart * (3 - 2 * fractionalPart);
```

The formula `t² × (3 - 2t)` is equivalent to `3t² - 2t³`, the cubic Hermite interpolant. At `t=0`, both the value and derivative equal zero. At `t=1`, the value equals 1 and derivative equals zero. This eliminates the visible grid pattern while preserving smooth gradients.

The shader then performs standard bilinear interpolation using the adjusted fractional part, sampling the four corners and interpolating along X then Y:

```hlsl
// noise.hlsl:132-148
noiseX = lerp(
  SampleHashTexture(uv),
  SampleHashTexture(float2(oppositeCorner.x, uv.y)),
  fractionalPart.x
);

noiseY = lerp(
  SampleHashTexture(float2(uv.x, oppositeCorner.y)),
  SampleHashTexture(oppositeCorner),
  fractionalPart.x
);

float4 noiseValue = (lerp(noiseX, noiseY, fractionalPart.y) - 0.5) * amplitude;
```

The subtraction of 0.5 centers the noise around zero for signed accumulation. Multiplying by amplitude scales the octave according to the persistence factor.

### Gradient Estimation (Normal Mapping)

The normalmap shader converts height data to surface normals using finite difference approximation. It samples height at four neighboring pixels (left, right, up, down) and computes gradients from the differences:

```hlsl
// normalmap.hlsl:41-44
float heightLeft  = heightTexture.Sample(linearSampler, texCoord - float2(sampleOffset, 0))[channel];
float heightRight = heightTexture.Sample(linearSampler, texCoord + float2(sampleOffset, 0))[channel];
float heightDown  = heightTexture.Sample(linearSampler, texCoord - float2(0, sampleOffset))[channel];
float heightUp    = heightTexture.Sample(linearSampler, texCoord + float2(0, sampleOffset))[channel];
```

The sample offset is 0.5 pixels at 4096×4096 resolution—a balance between capturing detail and avoiding noise. Smaller offsets amplify noise; larger offsets miss fine features.

The gradient in X equals the difference between right and left samples divided by the sample spacing. Similarly for Y. Since the sample spacing cancels in the normalization step, the shader omits the division:

```hlsl
// normalmap.hlsl:66-70
float3 normal = normalize(float3(
  heightRight - heightLeft,   // dH/dx
  heightUp - heightDown,      // dH/dy
  zScale                      // Bumpiness control
));
```

The Z component is not derived from height—it's a scale factor controlling bumpiness. Larger Z values flatten the normal toward (0, 0, 1), reducing perceived height variation. Smaller Z values amplify the XY components, increasing bumpiness.

The strength parameter controls this through a power-of-four falloff:

```hlsl
// normalmap.hlsl:56-59
float strengthBase = (1 - texgenParams.y * 255 / 256.0) * 1.2;
float zScale = strengthBase * strengthBase;  // base²
zScale = zScale * zScale;                     // base⁴
zScale = zScale / 8.0;
```

At strength=0, `zScale` approaches 0, creating extreme bumpiness. At strength=1, `zScale` is large, creating nearly flat surfaces. The power-of-four curve provides intuitive control—small strength changes near zero have large effects; near one, changes have subtle effects.

The final normal encodes from [-1, 1] to [0, 1] for texture storage: `normal * 0.5 + 0.5`.

### Color Space Conversion (RGB ↔ HSV)

The HSL shader (despite its name) uses HSV color space for hue, saturation, and value adjustments. The RGB to HSV conversion finds the maximum and minimum RGB components, computes saturation and value directly, then calculates hue based on which component is dominant.

Value equals the maximum RGB component—straightforward. Saturation equals the chroma (max - min) divided by value, measuring how far the color deviates from grayscale:

```hlsl
// hsl.hlsl:37-47
hsv.z = max(max(rgb.r, rgb.g), rgb.b);  // Value
float minComponent = min(min(rgb.r, rgb.g), rgb.b);
float delta = hsv.z - minComponent;     // Chroma

if (hsv.z != 0)
  hsv.y = delta / hsv.z;  // Saturation
else
  hsv.y = 0;
```

Hue calculation depends on which RGB component is largest. The hue circle divides into six 60° segments (red, yellow, green, cyan, blue, magenta). The shader calculates which segment and the position within that segment:

```hlsl
// hsl.hlsl:51-62
float3 distFromMax = hsv.z - rgb;

hsv.x = (distFromMax.b - distFromMax.g) / delta;  // Red max: segment 0

if (rgb.g == hsv.z)
  hsv.x = (distFromMax.r - distFromMax.b) / delta + 2;  // Green max: segment 1-2

if (rgb.b == hsv.z)
  hsv.x = (distFromMax.g - distFromMax.r) / delta + 4;  // Blue max: segment 3-4

if (delta == 0)
  hsv.x = -1;  // Grayscale: hue undefined
```

The result is hue in [0, 6] range, where each integer represents a 60° hue segment. Fractional values indicate position within the segment.

HSV to RGB reverses this process. The shader determines the hue segment, calculates the RGB pattern for that segment, then applies saturation and value:

```hlsl
// hsl.hlsl:83-101
int sextant = (int)hsv.x;
float fraction = hsv.x - sextant;

rgb = float3(0, 1 - fraction, 1);           // Sextant 0
if (sextant == 1) rgb = float3(fraction, 0, 1);
if (sextant == 2) rgb = float3(1, 0, 1 - fraction);
// ... etc

return (1 - rgb * hsv.y) * hsv.z;  // Apply saturation and value
```

The final multiplication `(1 - rgb * saturation) * value` applies saturation and value simultaneously. When saturation=0, all RGB components become equal (grayscale). When saturation=1, the pattern from the hue segment applies fully.

### Rotation Matrices (Rotozoom)

The rotozoom shader applies 2D rotation and uniform scaling around a center point. The standard 2D rotation matrix rotates a vector by angle θ:

```
[cos(θ)   -sin(θ)]
[sin(θ)    cos(θ)]
```

However, UV transformation for texture sampling requires the inverse transform. To rotate the texture clockwise, rotate the sampling coordinates counter-clockwise:

```hlsl
// rotozoom.hlsl:63-66
float2 rotatedUV = float2(
  uv.x * cosA + uv.y * sinA,
  uv.y * cosA - uv.x * sinA
);
```

The signs on `sinA` flip compared to the standard rotation matrix, implementing the inverse rotation. This makes the texture appear to rotate in the expected direction when visualized.

The full transformation sequence:
1. Translate UV so the center point becomes the origin: `uv = texCoord - center`
2. Apply inverse rotation (rotates sampling coordinates opposite to desired texture rotation)
3. Apply zoom (scale): `rotatedUV * zoom`
4. Translate back to standard UV space (center at 0.5): `+ 0.5`

The zoom parameter has inverse semantics—smaller parameter values produce more zoom:

```hlsl
// rotozoom.hlsl:48
float zoom = 0.25 / (texgenParams.y * 255.0 / 256.0);
```

This inversion simplifies artist workflow. A zoom parameter of 0 produces maximum zoom (division by small value), while 1 produces minimal zoom (division by ~255). Slider to the right zooms in, matching intuitive expectations.

### Catmull-Rom Spline Interpolation

The subplasma shader generates smooth patterns using Catmull-Rom splines instead of linear interpolation. Catmull-Rom splines pass through control points with continuous first derivatives, producing smoother results than linear interpolation but avoiding the overshoot of cubic Bézier curves.

Given four control points v0, v1, v2, v3 and parameter t in [0, 1], the Catmull-Rom spline interpolates between v1 (at t=0) and v2 (at t=1), using v0 and v3 to determine tangents:

```hlsl
// subplasma.hlsl:52-60
float4 P = (v3 - v2) - (v0 - v1);   // Cubic coefficient
float4 Q = (v0 - v1) - P;            // Quadratic coefficient
float4 R = v2 - v0;                  // Linear coefficient (tangent)

float4 result = (((P * t) + Q) * t + R) * t + v1;
```

This implements the polynomial form: `v1 + Rt + Qt² + Pt³` using Horner's method for efficient evaluation. The coefficients P, Q, R derive from the standard Catmull-Rom basis functions.

The subplasma shader uses this for two-pass interpolation. Pass 1 interpolates horizontally across random grid values. Pass 2+ interpolates vertically across the horizontally-smoothed result. The end result is smooth 2D noise without the grid artifacts of simple bilinear interpolation.

The shader also supports linear interpolation mode for comparison or when performance matters more than quality:

```hlsl
// subplasma.hlsl:117-124
if (texgenParams.y == 0)  // Catmull-Rom
  result = CatmullRomInterpolate(samples[0], samples[1], samples[2], samples[3], t);
else  // Linear
  result = lerp(samples[1], samples[2], t);
```

## Shader Catalog

### Generators (8 shaders)

Generators create patterns from UV coordinates alone, without input textures. They form the foundation of procedural texture pipelines.

**noise.hlsl** — Multi-octave Perlin-style value noise. Parameters: min octave, max octave, persistence, interpolation mode (smoothstep/linear). Uses 8 passes to accumulate up to 8 octaves with frequency doubling and amplitude scaling per octave. The hash texture provides random values at grid cell corners; bilinear interpolation with optional smoothstep creates smooth gradients. Essential for terrain textures, cloud patterns, and organic variation.

**cells.hlsl** — Voronoi/Worley cellular noise. Parameters: iteration count, distance power, cell size, distance metric (Euclidean/Manhattan). Uses 16 passes to iteratively find minimum distance to randomly placed feature points. Each pass checks different spatial offsets to ensure nearby cells are considered. Outputs distance-to-nearest-feature as grayscale. Used for cracked surfaces, cellular patterns, and biological textures.

**cells-2.hlsl** — Variant of cells.hlsl with different feature point distribution. Same algorithm, different hash texture sampling pattern creates alternative cellular structures. Useful when standard Voronoi produces unwanted regularity.

**celledges.hlsl** — Cell edge extraction. Extends cells.hlsl to output cell boundary locations instead of distances. Creates thin lines at Voronoi cell boundaries, useful for wireframe effects, circuit boards, and cracked glass patterns. Parameters include edge width control.

**gradient.hlsl** — Six geometric gradient patterns. Parameter: pattern type (radial, box, horizontal, vertical, horizontal-bidirectional, vertical-bidirectional). Single-pass shader computing gradients from UV coordinates via distance functions. Radial uses Euclidean distance from center, box uses Chebyshev distance, bidirectional patterns use absolute value of distance. Foundation for vignettes, radial masks, and blend maps.

**solid-color.hlsl** — Constant color output. Parameter: RGBA color. The simplest generator—returns the parameter color for all pixels. Useful as a base layer for blending, as a mask color, or for debugging texture chains.

**tiles.hlsl** — Rectangular tile grid with optional brick pattern. Parameters: column count, row count, row offset, border size. Iterates through grid cells, testing if the current UV falls within each tile's bounds (accounting for border). Outputs unique ID per tile as grayscale gradient. Row offset enables brick pattern (offset 0.5 shifts every other row by half tile width). Used for tile floors, brick walls, and grid overlays.

**sprinkle.hlsl** — Random sprite distribution. Parameters: sprite count, min size, max size. For each sprite instance, samples hash texture to get random position, rotation, and size, transforms current UV to sprite-local coordinates, samples the input sprite texture, and alpha-blends the result. Checks 3×3 tile neighborhood to handle sprites crossing UV boundaries, ensuring seamless tiling. Creates particle-like effects, scattered debris, star fields.

**subplasma.hlsl** — Smooth plasma using Catmull-Rom splines. Parameters: density (grid resolution), interpolation mode (Catmull-Rom/linear). Pass 0 samples hash texture at grid points. Pass 1 interpolates horizontally using Catmull-Rom splines. Pass 2+ interpolates vertically. The two-stage interpolation produces smoother results than bilinear noise while maintaining tileable output. Used for organic backgrounds, cloud layers, and liquid surfaces.

**envmap.hlsl** — Environment map lookup. No parameters—samples a pre-uploaded environment map based on UV coordinates. Used as a placeholder or when integrating artist-authored textures into the procedural pipeline.

**text.hlsl** — Text rendering via pre-generated texture atlas. Samples a text texture atlas at the current UV. The atlas is generated CPU-side with font rendering; the shader simply samples and outputs. Used for overlaying text on textures or creating text-based masks.

### Transforms (10 shaders)

Transforms manipulate existing textures through geometric operations on UV coordinates.

**rotozoom.hlsl** — Rotation and uniform zoom around a center point. Parameters: rotation angle (0-1 → 0-2π), zoom factor (inverse relationship), center point XY. Applies 2D rotation matrix and scaling in UV space. Used for spinning logos, kaleidoscope effects, and animated backgrounds.

**translate.hlsl** — UV offset (panning). Parameters: X offset, Y offset. Adds offset to UV coordinates before sampling. Creates scrolling textures, position adjustments, and animation effects.

**scale.hlsl** — Non-uniform scaling. Parameters: X scale, Y scale. Multiplies UV coordinates by scale factors centered around (0.5, 0.5). Stretches or compresses textures along each axis independently.

**mirror.hlsl** — Symmetry via mirroring. Parameter: axis (horizontal/vertical/both). Flips UV coordinates across specified axes. Creates symmetrical patterns from asymmetric inputs—useful for kaleidoscopes and mandala effects.

**loop.hlsl** — Tiled repetition. Parameters: X repeat count, Y repeat count. Multiplies UV by repeat factors and takes fractional part, causing the texture to tile multiple times within [0, 1] UV range. Creates mosaic patterns and increases pattern density.

**pixelize.hlsl** — Pixelation/mosaic effect. Parameters: X pixel count, Y pixel count. Snaps UV coordinates to a coarse grid, sampling each grid cell at its center. Creates retro pixel art aesthetic or censorship-style blocks.

**to-polar.hlsl** — Cartesian ↔ polar coordinate conversion. Parameters: direction (rect→polar or polar→rect), Y-axis flip. Rect→polar converts (x, y) to (angle, radius), useful for radial blur and star bursts. Polar→rect converts (angle, radius) to (x, y), creating tunnel effects when applied to linear patterns.

**turbulence.hlsl** — Directional UV displacement. Parameters: control channel, displacement amount. Samples a direction map, interprets the selected channel as an angle, converts to direction vector, and offsets UV by that vector scaled by amount. Creates swirling distortions, heat shimmer, and organic warping.

**mapdistort.hlsl** — Map-based UV distortion. Parameters: distortion power, threshold. Samples a distortion map, thresholds it to binary values, and offsets UV coordinates where the map exceeds threshold. Creates complex, data-driven distortions for transitions and effects.

### Color and Blend (11 shaders)

Color shaders adjust appearance, remap values, and composite layers.

**colorize.hlsl** — Two-color gradient mapping. Parameters: color 1 (RGBA), color 2 (RGBA), control channel. Samples the specified channel from input texture and uses it as interpolation factor between two colors. Creates duotone effects, false color visualization, and heatmaps.

**hsl.hlsl** — HSV color adjustment (despite the name). Parameters: hue shift (0-1 → 0-360°), saturation multiplier (0-4×), lightness adjustment (bidirectional). Converts RGB to HSV, applies adjustments, converts back. Hue shift rotates around the color wheel, saturation multiplier scales chroma, lightness parameter darkens (below 0.5) or brightens (above 0.5). Essential for color grading and mood adjustment.

**hslcurves.hlsl** — HSL adjustment with spline-based curves. No parameters—uses pre-uploaded spline lookup textures for precise per-channel control. More sophisticated than linear hsl.hlsl, enabling complex color grading like selective color correction.

**curves.hlsl** — RGB curve adjustment via spline lookup. No parameters—samples pre-uploaded curve textures to remap each RGB channel independently. The demotool UI provides curve editors; the shader applies the baked curves. Standard tool for contrast, levels, and tone mapping.

**palette.hlsl** — Per-channel palette lookup (1D LUT). Parameter: palette texture. Remaps each RGBA channel through a 1D lookup texture. The palette texture is a horizontal gradient where position encodes input value and color encodes output value. Enables posterization, color grading, and false-color effects.

**contrast.hlsl** — Contrast adjustment. Parameter: contrast amount. Applies standard contrast formula: `((color - 0.5) * contrast) + 0.5`. Values above 0.5 brighten, below 0.5 darken, creating S-curve contrast enhancement.

**invert.hlsl** — Color inversion. No parameters—returns `1 - color` for RGB channels, preserves alpha. Creates negative images or inverts masks.

**smoothstep.hlsl** — Edge-based clamping via smoothstep function. Parameters: low edge, high edge. Applies HLSL's `smoothstep(low, high, color)` which clamps values below low to 0, above high to 1, and smoothly interpolates between. Useful for creating sharp masks with anti-aliased edges.

**combine.hlsl** — Blend mode compositor with 10 modes. Parameter: blend mode selector (0-9). Samples two input textures and applies the selected blend mode: Add (v1+v2), Subtract (v1-v2), Multiply (v1×v2), Alpha (standard alpha composite), Min, Max, Screen (1-(1-v1)×(1-v2)), Overlay (conditional multiply/screen), Color Dodge (v1/(1-v2)), Color Burn (1-(1-v1)/v2). These match Photoshop's blend modes, enabling familiar compositing workflows.

**mix.hlsl** — Simple linear blend. Parameter: mix factor (0-1). Returns `lerp(texture1, texture2, factor)`. Simpler than combine's alpha blend mode, useful when only linear mixing is needed.

**mixmap.hlsl** — Three-texture blend with control map. Parameter: blend curve. Samples three textures and a control map. The control map value selects between textures using the blend curve parameter to control transition smoothness. Creates terrain splatting effects and multi-layer blending.

**replace-alpha.hlsl** — Alpha channel replacement. No parameters—samples two textures, takes RGB from texture 1 and alpha from texture 2. Useful for separate opacity control or when combining procedural color with procedural masks.

### Filters (3 shaders)

Filters apply convolution-based image processing.

**blur.hlsl** — Separable box blur. Parameters: X blur radius, Y blur radius. Uses six passes: passes 0-2 blur horizontally with 24 samples each, passes 3-5 blur vertically with 24 samples each. The separable approach reduces sample count from 576 (24×24) to 48 (24+24). Multiple passes approximate Gaussian distribution better than single-pass box filter. Essential for glow effects, depth-of-field simulation, and softening harsh edges.

**dirblur.hlsl** — Directional motion blur. Parameters: direction angle, blur amount. Samples along a line in the specified direction, accumulating samples. Creates motion blur streaks, speed lines, and directional smearing effects. Single-pass (no separation possible for arbitrary directions).

### Normal and Specialized (3 shaders)

**normalmap.hlsl** — Height-to-normal conversion via gradient estimation. Parameters: control channel (which channel contains height), strength (bumpiness control). Samples height at four neighboring pixels, computes gradients via finite differences, constructs normal vector with Z component scaled by strength. Outputs RGB-encoded normals for use in lighting shaders.

**glass.hlsl** — Glass refraction effect combining two textures. Parameters: refraction strength, normal scale. Samples a normal map to get surface normals, uses normals to offset UV coordinates for refraction distortion, samples background texture with distorted UVs, and blends with foreground. Creates glass, water, and transparent material effects.

## Performance Characteristics

### Texture Bandwidth

Texgen shaders are bandwidth-bound, not compute-bound. Modern GPUs execute ALU instructions far faster than they can fetch texture data. The blur shader samples 48 textures per pixel (24 horizontal + 24 vertical across six passes), generating significant memory traffic.

The mipmapping after each pass (`GenerateMips()` in the render loop) ensures subsequent passes sample the appropriate mip level based on UV derivatives. This reduces bandwidth when downsampling but requires generating full mip chains—a GPU copy operation.

Texture format matters for multi-pass bandwidth. Phoenix uses 16-bit float RGBA (`DXGI_FORMAT_R16G16B16A16_FLOAT`) for texgen render targets, balancing precision against memory consumption. 8-bit integer formats (UNORM) would introduce banding artifacts after accumulation; 32-bit float is unnecessarily large for most operations.

### Branching and Divergence

GPU execution groups threads into warps (NVIDIA) or wavefronts (AMD), typically 32-64 threads executing the same instruction simultaneously (SIMD). Divergent control flow—where threads within a warp take different branches—serializes execution, reducing performance.

The combine shader's if-chain for blend modes seems divergence-prone:

```hlsl
if (blendMode == 1) result = a - b;
if (blendMode == 2) result = a * b;
if (blendMode == 3) result = a * (1 - b.w) + b * b.w;
// ... 7 more modes
```

However, the blend mode parameter is constant across the entire fullscreen quad—all pixels execute the same branch. This creates no divergence; the GPU predicts the branch uniformly across the warp. The if-chain compiles to conditional moves or predication, not expensive branch instructions.

True divergence occurs when neighboring pixels take different branches based on varying data (texture samples, UV coordinates). None of the texgen shaders exhibit this pattern—control flow depends on uniform parameters, not per-pixel texture data.

### Sample Count

The sprinkle shader's nested loops generate the highest sample count. With parameter settings of 255 sprites, three tile offsets in each dimension (3×3=9 tiles), it executes 255×9 = 2,295 loop iterations per pixel. Each iteration samples the hash texture and potentially the sprite texture, reaching ~4,000 texture samples per pixel.

This explains why sprinkle is one of the slower texgen operations. The iteration count is parameter-controlled—fewer sprites execute faster, trading coverage density for performance.

The blur shader's 48 samples per pixel (across six passes) is modest in comparison. The separable approach keeps sample count linear with blur radius rather than quadratic.

Most other shaders sample 1-4 textures per pass, executing quickly. Generator shaders (noise, cells) balance hash texture lookups against ALU math for interpolation; modern GPUs hide texture latency with math operations.

## Extending the System

### Adding New Shaders

Phoenix's texgen architecture makes adding shaders straightforward. Create a HLSL file following the standard pattern:

1. Declare constant buffer registers (`c0` for pass info, `c1`-`c4` for parameters)
2. Declare input textures (`t0` for primary input, `t1` for secondary, etc.)
3. Declare samplers (`s0` for wrap mode, `s1` for clamp)
4. Implement pixel shader with signature `float4 p(float2 t : TEXCOORD0) : SV_TARGET0`
5. Register the shader in the filter array with a `DataDescriptor` specifying pass count and parameter count

The system handles vertex shader binding, constant buffer upload, texture binding, render target swapping, and mipmap generation automatically. The shader author focuses purely on the pixel transformation algorithm.

Example skeleton for a new shader:

```hlsl
SamplerState sm : register(s0);
Texture2D input : register(t0);
float4 passInfo : register(c0);
float4 params : register(c1);

float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  // Your algorithm here
  float4 color = input.Sample(sm, t);
  // Transform color based on params...
  return color;
}
```

### Multi-Pass Considerations

When designing multi-pass shaders, decide the pass count statically. The `DataDescriptor.PassCount` specifies the maximum passes; the shader can skip later passes via conditional logic (like noise's min/max octave pattern) but cannot dynamically allocate additional passes.

Each pass reads from `t0` (which automatically binds to the previous pass result for pass 1+) and writes to `SV_TARGET0`. The system swaps render targets between passes—the shader doesn't manage this.

Random values in `passInfo.yzw` regenerate each pass, providing per-pass variation without additional CPU→GPU communication. Use these for effects requiring different random offsets per iteration.

### Texture Lookup Tables

Shaders requiring complex lookup data (curves, palettes, environment maps) receive pre-uploaded textures in slots `t1`-`t4`. The demotool generates these on the CPU side (e.g., evaluating spline curves, rendering text atlases) and uploads them before invoking the shader.

The shader treats lookup textures as read-only. Sampling with `SampleLevel(..., 0)` disables mipmap filtering, useful when the lookup table represents discrete data rather than continuous imagery.

## Implications for Rust Framework

### Adopt: Fullscreen Quad Convention

The single shared vertex shader for all 2D operations eliminates per-shader vertex code. WGSL supports the same pattern—upload triangle vertex data once, bind it for all 2D shaders, let pixel shaders provide algorithmic variety.

Consider going further: modern GPUs support vertex pulling (loading vertex data in the vertex shader) or even compute shaders for 2D image processing, eliminating vertex buffers entirely.

### Adopt: Separable Convolution

Blur and similar convolution operations should always separate into horizontal and vertical passes when possible. The bandwidth savings (O(N) vs O(N²)) outweigh the overhead of additional render passes. Implement this as a pattern, not a one-off optimization.

### Adopt: Hash Texture for Procedural Randomness

The pre-computed random texture approach beats shader-based PRNG in simplicity and performance. Upload once, sample everywhere. Consider expanding to multiple hash textures for different noise frequencies or higher-dimensional noise (3D, 4D).

### Modify: Use Compute Shaders

WGSL compute shaders can replace pixel shaders for many texgen operations, especially those without spatial coherence (generators, color operations). Compute shaders offer explicit thread group control and shared memory, potentially improving performance for certain algorithms.

However, retain the pixel shader path for operations benefiting from hardware interpolation and mipmap generation. Blur and transforms sample textures at varying UVs—pixel shaders with automatic derivative computation and mip selection are ideal.

### Modify: Type-Safe Parameter Encoding

Phoenix's byte-to-float parameter encoding is compact but error-prone. A Rust framework can use type-safe parameter definitions:

```rust
enum BlendMode { Add, Subtract, Multiply, /* ... */ }

struct CombineParams {
    mode: BlendMode,
}
```

The parameter system serializes these to GPU buffers using derive macros or codegen. Shaders receive the same compact layout but CPU code works with typed values, catching errors at compile time.

### Modify: Dynamic Pass Counts

Phoenix allocates pass counts statically per shader. A Rust framework can determine pass count dynamically based on parameters (e.g., "use exactly as many passes as selected octaves" instead of "run 8 passes, skip inactive ones").

This requires tighter CPU-GPU integration but eliminates wasted passes. Consider using indirect draw calls or dynamic pipeline selection to adjust pass counts at runtime.

### Avoid: String-Based Shader Code

Phoenix compiles HLSL at runtime, embedding shader source strings in the executable. WGSL avoids this—shaders compile to SPIR-V or WGSL bytecode ahead-of-time. Rust's `wgpu` compiles shaders during pipeline creation, catching errors early without runtime overhead.

For hot-reloading during development, watch shader files and recompile on change. For release builds, bake all shaders into the binary as compiled bytecode.

## Related Documents

- **[overview.md](overview.md)** — Texgen system architecture and pipeline flow
- **[pipeline.md](pipeline.md)** — Multi-pass rendering and render target management
- **[generators.md](generators.md)** — Deep dive into procedural noise algorithms
- **[transforms.md](transforms.md)** — Geometric transformation patterns
- **[color-blend.md](color-blend.md)** — Color space operations and blend modes
- **[../code-traces/noise-generation.md](../code-traces/noise-generation.md)** — Annotated walkthrough of noise shader

## Source References

All shader source code is located in:
- `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/texgen/` — Original minified shaders
- `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/annotated/texgen/` — Annotated versions with detailed comments

Infrastructure code:
- `demoscene/apex-public/apEx/Phoenix/Texgen.cpp` — Render loop, constant buffer packing, texture binding (lines 92-186)
- `demoscene/apex-public/apEx/Phoenix/phxEngine.cpp` — Sampler creation, hash texture generation

Key shaders referenced:
- `noise.hlsl` — Multi-octave noise (53 lines minified, 177 lines annotated)
- `cells.hlsl` — Voronoi cellular noise (45 lines minified, 146 lines annotated)
- `blur.hlsl` — Separable box blur (36 lines minified, 75 lines annotated)
- `combine.hlsl` — Blend modes (27 lines minified, 83 lines annotated)
- `hsl.hlsl` — Color space conversion (73 lines minified, 144 lines annotated)
- `normalmap.hlsl` — Gradient-based normal generation (29 lines minified, 77 lines annotated)
- `rotozoom.hlsl` — 2D rotation and zoom (26 lines minified, 73 lines annotated)
- `subplasma.hlsl` — Catmull-Rom interpolated plasma (54 lines minified, 129 lines annotated)
- `sprinkle.hlsl` — Random sprite distribution (47 lines minified, 110 lines annotated)
