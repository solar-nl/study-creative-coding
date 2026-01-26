# Phoenix Texgen Color Manipulation, Blending, and Filters

Color operations transform pixel values after coordinate mapping and pattern generation. They adjust hue, apply gradients, mix textures, and filter images. Where generators create patterns and transforms warp space, color operations shape the final appearance—the crucial last mile from mathematical patterns to visually compelling textures.

Think of procedural texture generation like cooking a complex dish. Generators provide raw ingredients (noise patterns, gradients), transforms prepare them (scaling, rotating), and color operations are the finishing touches—seasoning, glazing, plating. A blob of Perlin noise becomes brushed metal after hue adjustment, contrast enhancement, and directional blur. The mathematics matter less than the aesthetics they produce.

This becomes critical when working under size constraints. A 64k demo cannot ship with pre-graded textures—every color adjustment must happen procedurally. Phoenix implements eleven color manipulation shaders, four blending operators, two filters, and two normal-generation tools. Each shader compresses to a few hundred bytes yet produces effects indistinguishable from manual photo editing.

## The Color Pipeline Problem

Procedural generators output mathematical patterns, not finished textures. Perlin noise produces smooth gradients centered around 0.5. Voronoi cells output distance fields in grayscale. Gradients interpolate between extremes. These patterns carry information but lack aesthetic appeal.

The color pipeline bridges mathematics and art. It takes neutral mathematical outputs and transforms them into the textures artists expect: warm metal tones, vibrant gradients, high-contrast edges, soft glows. Three categories handle this transformation: color adjustment (shift colors within a single texture), blending (combine multiple textures), and filtering (apply spatial convolution).

## Overview Tables

### Color Adjustment Operations

| Shader | Parameters | Lookup | Description |
|--------|------------|--------|-------------|
| hsl | 3 | None | Hue/Saturation/Lightness shift in HSV space |
| hslcurves | 0 | Spline | Per-channel HSL curves via 1D LUT |
| colorize | 9 | None | Grayscale to two-color gradient mapping |
| curves | 0 | Spline | Per-channel RGB curves via 1D LUT |
| palette | 3 | Spline | 2D lookup table mapping with row selection |
| contrast | 1 | None | Midpoint-centered contrast adjustment |
| smoothstep | 1 | None | Soft threshold with edge smoothing |
| invert | 0 | None | Color inversion (1 - color) |

### Blending Operations

| Shader | Inputs | Parameters | Description |
|--------|--------|------------|-------------|
| combine | 2 | 1 | 10 Photoshop-style blend modes |
| mix | 2 | 1 | Simple linear interpolation |
| mixmap | 3 | 1 | Third texture controls blend amount |
| replace-alpha | 2 | 0 | Swap alpha channel from second input |

### Filtering Operations

| Shader | Parameters | Passes | Description |
|--------|------------|--------|-------------|
| blur | 2 | 6 | Separable box blur (approximates Gaussian) |
| dirblur | 2 | 1 | Directional motion blur along angle |

### Normal Map Generation

| Shader | Parameters | Description |
|--------|------------|-------------|
| normalmap | 2 | Height-to-normal via finite differences |
| glass | 2 | Refraction-based displacement |

All shaders follow Phoenix's fullscreen quad pattern: sample input textures at UV coordinates, transform colors or coordinates, output to render target. Parameters arrive normalized (0-1 range) in constant buffers, requiring shaders to rescale them to meaningful ranges.

## hsl.hlsl - HSV Color Adjustment

The HSL shader (despite its name) operates in HSV color space to shift hue, saturation, and value. It converts RGB input to HSV, applies adjustments, and converts back. This approach preserves perceptual color relationships better than direct RGB manipulation—rotating hue by 60 degrees shifts red to yellow to green smoothly around the color wheel.

**Parameters**:
- `[0] Hue`: Hue rotation (0-1 maps to 0-6 hue units, representing full 360-degree circle)
- `[1] Saturation`: Saturation multiplier (0-1 maps to 0-4x saturation)
- `[2] Lightness`: Bidirectional adjustment (0-0.5 darkens, 0.5-1 brightens)

The hue parameter uses a 0-6 range because HSV color space divides the hue circle into six segments of 60 degrees each: red (0-1), yellow (1-2), green (2-3), cyan (3-4), blue (4-5), magenta (5-6). This matches the hardware-friendly sextant representation common in color conversion algorithms.

### RGB to HSV Conversion

Converting RGB to HSV starts by finding the value (V), which equals the maximum RGB component. The minimum component and the difference between them (chroma) determine saturation and hue:

```hlsl
float3 rgb_to_hsv(float3 c)
{
  float3 r;

  // Value = brightest channel
  r.z = max(max(c.x, c.y), c.z);
  float Min = min(min(c.x, c.y), c.z);

  // Chroma = range of RGB values
  float delta = r.z - Min;

  // Saturation = chroma / value (avoid divide by zero)
  if (r.z != 0)
    r.y = delta / r.z;
  else
    r.y = 0;

  // Hue depends on which component is maximum
  float3 m = r.z - c;  // Distance from max for each channel

  // Default: red is max (hue sector 0)
  r.x = (m.z - m.y) / delta;

  // Green is max (hue sector 1-2)
  if (c.y == r.z)
    r.x = (m.x - m.z) / delta + 2;

  // Blue is max (hue sector 3-4)
  if (c.z == r.z)
    r.x = (m.y - m.x) / delta + 4;

  // Grayscale (no chroma, hue undefined)
  if (delta == 0)
    r.x = -1;

  return r;  // Returns (hue [0-6], saturation [0-1], value [0-1])
}
```

The hue calculation computes which 60-degree segment of the color wheel the color occupies. If red is the maximum component, hue falls in segment 0 or 5 (red to yellow or magenta to red). The fractional part within the segment comes from comparing the other two components. When green is max, the shader adds 2 to shift into segments 1-2 (yellow to cyan). Blue max shifts to segments 3-4 (cyan to magenta).

The special case for grayscale (delta == 0) sets hue to -1, indicating undefined hue. Pure grayscale has no dominant color direction—it sits at the center of the HSV cylinder where the hue wheel collapses to a point.

### HSV to RGB Conversion

Converting back to RGB reverses the process. The hue determines which sector of the color wheel, the fractional position within that sector, and the RGB pattern for that sector:

```hlsl
float3 hsv_to_rgb(float3 h)
{
  float3 r;

  // Wrap hue to [0, 6] range
  h.x = fmod(h.x + 6, 6);

  // Determine sector (0-5) and fractional position
  float f = h.x - (int)h.x;
  int o = h.x;

  // Each sector has a specific RGB ramp pattern
  r = float3(0, 1 - f, 1);           // Sector 0: Red max, green rising, blue zero
  if (o == 1) r = float3(f, 0, 1);           // Sector 1: Red falling, green max, blue zero
  if (o == 2) r = float3(1, 0, 1 - f);       // Sector 2: Red zero, green max, blue rising
  if (o == 3) r = float3(1, f, 0);           // Sector 3: Red zero, green falling, blue max
  if (o == 4) r = float3(1 - f, 1, 0);       // Sector 4: Red rising, green zero, blue max
  if (o == 5) r = float3(0, 1, f);           // Sector 5: Red max, green zero, blue rising

  // Apply saturation and value
  return (1 - r * h.y) * h.z;
}
```

Each sector defines a different RGB pattern. In sector 0 (red to yellow), red stays at maximum, green rises from 0 to 1, blue stays at 0. In sector 3 (cyan to blue), red stays at 0, green falls from 1 to 0, blue stays at maximum. The pattern ensures smooth transitions around the color wheel.

The final multiplication `(1 - r * saturation) * value` applies saturation and value simultaneously. When saturation equals 0, all components become equal (grayscale). When saturation equals 1, the sector pattern applies fully. The value scales the entire result—zero produces black, one produces full brightness.

### Lightness Adjustment

The lightness parameter uses a split semantic: values below 0.5 darken, values above brighten. This creates an intuitive slider where the middle position (0.5) leaves the image unchanged:

```hlsl
float4 d = data1 / 256 * 255;  // Decode normalized parameters

c.x += d.x * 6;      // Hue shift: 0-1 maps to 0-6 (full circle)
c.y *= d.y * 4;      // Saturation: 0-1 maps to 0-4x multiplier

// Lightness (actually Value in HSV)
if (d.z < 0.5)
  c.z *= d.z * 2;                        // Darken: 0→black, 0.5→unchanged
else
  c.z = lerp(c.z, 1, (d.z - 0.5) * 2);   // Brighten: 0.5→unchanged, 1→white
```

Darkening multiplies the value by `param * 2`, which ranges from 0 to 1 as param goes from 0 to 0.5. At param=0, value becomes 0 (black). At param=0.5, value multiplies by 1 (unchanged).

Brightening uses linear interpolation between current value and white (1.0). The interpolation factor `(param - 0.5) * 2` ranges from 0 to 1 as param goes from 0.5 to 1. At param=0.5, interpolation factor is 0 (no change). At param=1, interpolation factor is 1 (full white).

This asymmetric approach matches perceptual expectations. Darkening via multiplication feels natural—50% brightness means half the light. Brightening via interpolation prevents oversaturation—pushing bright colors toward white creates highlights without clipping.

**Use Cases**: Color grading scenes, tinting textures to match art direction, desaturating backgrounds, creating day/night variants.

## colorize.hlsl - Gradient Mapping

The colorize shader maps grayscale values to a two-color gradient. It samples a single channel from the input texture and uses that value as the interpolation factor between two color endpoints. This creates false-color visualization, heat maps, and tinting effects.

**Parameters**:
- `[0-3] Color1`: RGBA start color (four bytes)
- `[4-7] Color2`: RGBA end color (four bytes)
- `[8] Channel`: Which input channel to sample (0=R, 1=G, 2=B, 3=A)

The implementation is remarkably simple:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float f = Textur.Sample(sm, t)[(int)(Data1.x * 256)];
  return lerp(Color1, Color2, f);
}
```

The channel selector `(int)(Data1.x * 256)` converts the normalized 0-1 parameter to integer 0-3, used as an array index into the sampled color. The HLSL syntax `color[0]` accesses the red channel, `color[1]` green, etc.

The interpolation happens per-component. If Color1 is red (1, 0, 0, 1) and Color2 is blue (0, 0, 1, 1), a grayscale value of 0.3 produces `(0.7, 0, 0.3, 1)`—70% red, 30% blue, blending toward purple.

**Use Cases**: False color for scientific visualization (temperature maps), converting grayscale noise to colored variations (red rust, blue ice), creating duotone poster effects.

## curves.hlsl - Per-Channel Curves

The curves shader applies independent tone curves to each RGBA channel using a pre-uploaded 1D lookup texture. This enables precise control over contrast, levels, and color grading—operations common in photo editing software.

**Lookup**: 4096×1 RGBA texture containing spline-evaluated curves

The shader samples the lookup texture once per channel, using the input value as the UV coordinate:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 c = Textur.Sample(sm, t);
  float4 r;

  r.x = Curves.SampleLevel(cs, float2(c.x, 0), 0).x;  // Red curve
  r.y = Curves.SampleLevel(cs, float2(c.y, 0), 0).y;  // Green curve
  r.z = Curves.SampleLevel(cs, float2(c.z, 0), 0).z;  // Blue curve
  r.w = Curves.SampleLevel(cs, float2(c.w, 0), 0).w;  // Alpha curve

  return r;
}
```

The `SampleLevel(..., 0)` call disables mipmap filtering, ensuring the shader reads the exact texel values from mip level 0. This prevents blurring of the curve data, which represents discrete tone mapping rather than continuous imagery.

The CPU-side code generates the curves texture by evaluating splines at 4096 points. The demotool UI provides a curve editor where artists draw S-curves for contrast, gamma curves for brightness, or custom shapes for creative effects. The baked curves upload once; the shader applies them every frame.

**Use Cases**: Contrast enhancement (S-curve), gamma correction, color grading (lift/gamma/gain), creative color shifts.

## hslcurves.hlsl - HSL Curves

The HSL curves shader combines RGB-to-HSV conversion with curve-based adjustment. It converts input colors to HSV, applies curves to hue/saturation/value independently, and converts back to RGB. This enables selective color correction—adjusting only blue tones, boosting saturation in highlights, shifting hue in shadows.

**Lookup**: Same 4096×1 RGBA spline texture as curves.hlsl

The implementation mirrors the standard HSL shader but replaces parameter-based adjustment with curve lookups:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 c = Textur.Sample(sm, t);
  c.xyz = rgb_to_hsv(c.xyz);

  float4 r;
  r.x = Curves.Sample(cs, float2(c.x / 6, 0)).x * 6;  // Hue curve (0-6 range)
  r.y = Curves.Sample(cs, float2(c.y, 0)).y;          // Saturation curve
  r.z = Curves.Sample(cs, float2(c.z, 0)).z;          // Value curve

  return float4(hsv_to_rgb(r.xyz), c.w);
}
```

The hue lookup divides by 6 to normalize the 0-6 hue range to 0-1 for texture sampling, then multiplies the result by 6 to restore the range. The curve can remap hues arbitrarily—shifting skin tones toward orange, cooling blue skies, swapping complementary colors.

Saturation and value curves operate in 0-1 range directly. A saturation S-curve boosts vibrant colors while leaving muted colors alone. A value curve can create high-key (bright) or low-key (dark) looks.

**Use Cases**: Selective color grading, creating filmic color palettes, simulating color film characteristics.

## palette.hlsl - Lookup Table Mapping

The palette shader uses a 2D texture as a lookup table, mapping input values through artist-defined color palettes. Unlike curves (1D), palette supports complex multi-color gradients and per-channel independent lookups.

**Parameters**:
- `[0] Channel`: Which input channel to use (0=R, 1=G, 2=B, 3=A)
- `[1] Palette Row`: Y coordinate in palette texture (0-1)
- `[2] Mode`: 0 = single channel lookup, non-zero = per-channel lookup

**Lookup**: 2D palette texture (width=gradient resolution, height=multiple palettes)

The palette texture stores multiple color gradients as horizontal rows. The Y coordinate selects which palette to use. The X coordinate (input value) selects position within that palette.

Single-channel mode samples once using the selected channel:

```hlsl
int ch = (int)(data1.x * 256);

if (data1.z == 0)  // Single-channel mode
{
  float c = Textur.Sample(sm, t)[ch];
  return DataMap1.Sample(sm, float2(c, data1.y));  // X = value, Y = palette row
}
```

Per-channel mode samples four times, using each RGBA component as independent X coordinates:

```hlsl
float4 c = Textur.Sample(cm, t);
float4 r;

r.x = DataMap1.SampleLevel(sm, float2(c.x, data1.y), 0)[ch];
r.y = DataMap1.SampleLevel(sm, float2(c.y, data1.y), 0)[ch];
r.z = DataMap1.SampleLevel(sm, float2(c.z, data1.y), 0)[ch];
r.w = DataMap1.SampleLevel(sm, float2(c.w, data1.y), 0)[ch];

return r;
```

This mode enables complex color remapping. Each channel can follow a different mapping curve, creating cross-channel color shifts impossible with simple curves.

**Use Cases**: Posterization (stepped color gradients), vintage film looks (limited color palettes), thematic color schemes (cyberpunk neon, desert sunset).

## contrast.hlsl - Contrast Adjustment

The contrast shader applies a simple midpoint-centered contrast curve. Values above 0.5 push toward white, values below push toward black, creating an S-curve effect that enhances tonal separation.

**Parameter**: `[0] Strength` (0-1, mapped to 0-5x multiplier)

The implementation uses a power-based curve:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 c = Textur.Sample(sm, t);

  float s = data1.x * 3;
  s *= s;  // Square the strength

  return lerp(0.5, c, s * 5);
}
```

The strength parameter scales to 0-3, squares to create non-linear response (0-9), then multiplies by 5 for the final range (0-45). This creates strong contrast at high values—a slider at 1.0 produces 45x multiplication, crushing midtones toward pure black or white.

The `lerp(0.5, c, strength)` formula pulls all values toward 0.5 when strength is low (zero strength produces uniform gray), and amplifies deviations from 0.5 when strength is high. Values above 0.5 get brighter, below 0.5 get darker.

This differs from standard contrast formulas like `(c - 0.5) * strength + 0.5`, which linearly scale around the midpoint. Phoenix's quadratic approach provides more aggressive contrast at high settings.

**Use Cases**: Punching up procedural textures before blending, creating hard-edged masks from soft gradients, preparing textures for thresholding.

## smoothstep.hlsl - Soft Threshold

The smoothstep shader clamps values to 0 or 1 with smooth transitions at the edges. It implements HLSL's built-in `smoothstep()` function, which creates hermite interpolation between two thresholds.

**Parameter**: `[0] Edge` (0-1, upper threshold; lower threshold always 0)

The implementation is minimal:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  return smoothstep(0, data1.x, Textur.Sample(sm, t));
}
```

The `smoothstep(edge0, edge1, x)` function clamps `x` to [0, 1] based on the edges:
- If `x < edge0`, return 0
- If `x > edge1`, return 1
- Otherwise, return hermite interpolation: `t² × (3 - 2t)` where `t = (x - edge0) / (edge1 - edge0)`

This creates soft-edged masks from gradients. A gradient from 0 to 1 becomes a sharp cutoff at the edge parameter, but with anti-aliased transitions instead of hard pixel boundaries.

**Use Cases**: Converting soft shadows to hard shadows with feathered edges, creating soft alpha masks, generating smooth binary patterns from noise.

## invert.hlsl - Color Inversion

The invert shader performs simple color negation. It subtracts each color component from 1, creating photographic negative effects.

**Parameters**: None

The entire implementation:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  return 1 - Textur.Sample(sm, t);
}
```

This inverts RGB channels but also alpha. For textures where alpha represents opacity, this flips transparent regions to opaque and vice versa. If preserving alpha is important, the calling code must combine inverted RGB with original alpha using replace-alpha shader.

**Use Cases**: Creating negative images, inverting masks for boolean operations, artistic effects.

## combine.hlsl - Photoshop Blend Modes

The combine shader implements ten blend modes matching Photoshop's layer blending. It samples two input textures and composites them based on the selected mode. This enables complex multi-layer effects without manual formula implementation.

**Parameter**: `[0] Mode` (0-9 selector)

### Blend Mode Formulas

| Mode | Value | Formula | Visual Effect |
|------|-------|---------|---------------|
| Add | 0 | `a + b` | Lighten (additive), creates glow |
| Subtract | 1 | `a - b` | Darken (subtractive), creates shadows |
| Multiply | 2 | `a * b` | Darken (multiplicative), tints shadows |
| Alpha | 3 | `a * (1-bα) + b * bα` | Standard over operator |
| Min | 4 | `min(a, b)` | Keep darkest per-component |
| Max | 5 | `max(a, b)` | Keep lightest per-component |
| Color Dodge | 6 | `a / (1 - b)` | Bright highlights, washed midtones |
| Color Burn | 7 | `1 - (1-a) / b` | Deep shadows, rich midtones |
| Screen | 8 | `1 - (1-a) * (1-b)` | Soft lighten, preserves highlights |
| Overlay | 9 | Conditional | Contrast boost (multiply darks, screen lights) |

The implementation uses a series of conditional assignments:

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 v1 = Textur.Sample(sm, t);
  float4 v2 = Textur2.Sample(sm, t);
  float4 r = v1 + v2;  // Default to Add

  int Type = (int)(data1.x * 256);

  if (Type == 1) r = v1 - v2;
  if (Type == 2) r = v1 * v2;
  if (Type == 3) r = v1 * (1 - v2.w) + v2 * v2.w;
  if (Type == 4) r = min(v1, v2);
  if (Type == 5) r = max(v1, v2);
  if (Type == 6) r = v1 / (1 - v2);
  if (Type == 7) r = 1 - (1 - v1) / v2;
  if (Type == 8) r = 1 - (1 - v1) * (1 - v2);
  if (Type == 9) r = lerp(1 - 2 * (1 - v1) * (1 - v2), 2 * v1 * v2, v1 < 0.5);

  return r;
}
```

The conditionals don't cause GPU divergence because the blend mode is uniform across all pixels in the fullscreen quad. All threads execute the same branch, maintaining SIMD efficiency.

### Overlay Mode Breakdown

Overlay (mode 9) uses different formulas for dark vs. light regions:

```hlsl
if (v1 < 0.5)
  r = 2 * v1 * v2;                // Multiply darks (2x intensity for normalization)
else
  r = 1 - 2 * (1 - v1) * (1 - v2);  // Screen lights (inverted multiply)
```

The condition `v1 < 0.5` determines whether to darken or lighten. Dark regions (below 50% gray) use multiply, making them darker. Light regions use screen, making them brighter. This creates a strong contrast boost—darks get darker, lights get lighter, midtones stay relatively unchanged.

The 2x multiplier in both branches compensates for the 0-0.5 input range. Without it, multiply would produce overly dark results (0.3 * 0.3 = 0.09), and screen would be too subtle.

### Color Dodge and Burn

Color dodge `a / (1 - b)` brightens layer `a` based on layer `b`. Where `b` is black (0), the result equals `a` (no change). Where `b` is white (approaching 1), the division by `(1 - 1) = 0` creates extreme brightness, blowing out highlights.

Color burn `1 - (1 - a) / b` darkens layer `a` based on layer `b`. Where `b` is white (1), the result equals `a`. Where `b` is black (approaching 0), the division creates extreme darkness, crushing shadows to black.

These modes produce dramatic effects—dodge for lens flares, burn for deep shadows. They're non-linear and can produce out-of-range values requiring clamping.

**Use Cases**: Layer-based compositing (glow layers via screen, shadow layers via multiply), texture blending (terrain layers via overlay), masking (min/max for boolean operations).

## mix.hlsl - Linear Blend

The mix shader provides simple linear interpolation between two textures. It's simpler than combine's alpha blend mode, useful when only basic mixing is needed.

**Parameter**: `[0] Amount` (0-1, blend factor)

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  return lerp(Textur.Sample(sm, t), Tex2.Sample(sm, t), data1.x);
}
```

At amount=0, the shader outputs texture 1. At amount=1, it outputs texture 2. At amount=0.5, it outputs the average of both textures.

This differs from alpha blending (combine mode 3), which uses texture 2's alpha channel to control blending. Mix ignores alpha and uses a constant blend factor.

**Use Cases**: Crossfading between textures, time-based interpolation, simple texture averaging.

## mixmap.hlsl - Map-Controlled Blend

The mixmap shader uses a third texture as a blend map, controlling per-pixel interpolation between two textures. This enables spatially-varying blending—terrain splatting, masked transitions, painted blend regions.

**Parameters**:
- `[0] Channel`: Which channel of blend map to use (0=R, 1=G, 2=B, 3=A)

**Inputs**:
- `t0`: First texture
- `t1`: Second texture
- `t2`: Blend map

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float Amount = MixMap.Sample(sm, t)[(int)(data1.x * 256)];
  return lerp(Textur.Sample(sm, t), Tex2.Sample(sm, t), Amount);
}
```

The blend map can be procedurally generated (noise, gradients) or artist-painted. Black regions show texture 1, white regions show texture 2, gray creates smooth transitions.

Using different channels enables multi-layer blending. The red channel blends textures A/B, green blends B/C, blue blends C/D. This creates complex layered materials from a single blend map texture.

**Use Cases**: Terrain texture splatting (grass/dirt/rock transitions), decal placement, weathering effects (rust appearing in specific regions).

## replace-alpha.hlsl - Alpha Channel Swap

The replace-alpha shader combines RGB from one texture with alpha from another. This separates color and opacity control, useful when procedurally generating transparency masks independently from color patterns.

**Parameters**: None

**Inputs**:
- `t0`: Source color (RGB used)
- `t1`: Source alpha (red channel used as new alpha)

```hlsl
float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 c = Textur.Sample(sm, t);
  float4 c2 = Textur2.Sample(sm, t);

  return float4(c.xyz, c2.x);
}
```

The shader samples texture 2's red channel for alpha. This convention allows grayscale masks to control opacity—bright regions become opaque, dark regions transparent.

**Use Cases**: Applying procedural opacity masks to colored textures, creating cutouts from gradients, separating color and opacity generation pipelines.

## blur.hlsl - Separable Box Blur

The blur shader implements multi-pass box blur using separable convolution. It performs horizontal blur in passes 0-2, vertical blur in passes 3-5, with each pass accumulating 24 samples along its axis.

**Parameters**:
- `[0] X Amount`: Horizontal blur radius (0-1)
- `[1] Y Amount`: Vertical blur radius (0-1)

**Passes**: 6 (3 horizontal + 3 vertical)

A naive 2D blur requires N² samples—for 24×24 sampling, that's 576 texture fetches per pixel. Separable blur reduces this to 2N samples (48 total) by blurring horizontally then vertically. This 12x reduction makes real-time blur practical.

### Algorithm

The shader determines blur direction based on pass index:

```hlsl
float XM = 1;
float YM = 0;

if (PassData.x + 0.5 >= 3)  // Pass 3 and beyond
{
  XM = 0;
  YM = 1;
}
```

Passes 0-2 blur horizontally (XM=1, YM=0). Passes 3+ blur vertically (XM=0, YM=1). This switches the blur axis mid-pipeline.

The blur loop accumulates samples along the active axis:

```hlsl
#define oneway 24.0f

float2 xd = float2(data1.x * XM, data1.y * YM) * -0.5;  // Start offset
float2 xxd = float2(data1.x * XM, data1.y * YM) / oneway;  // Step size

for (float x = 0; x < oneway; x++)
{
  res += Textur.Sample(sm, t + xd);
  xd += xxd;
}

return res / oneway;  // Average
```

The loop starts at `-0.5 * radius`, steps by `radius / 24` for 24 iterations, ending at `+0.5 * radius`. This creates a box filter centered on the current pixel.

### Why Multiple Passes?

A single horizontal pass followed by single vertical pass would suffice mathematically. Phoenix uses three passes per direction for quality—each pass slightly smooths the result, approximating a Gaussian distribution better than a raw box filter.

Repeated box filters converge toward Gaussian blur as pass count increases. Three passes per axis (six total) provides good quality without excessive cost. More passes would approach true Gaussian blur but with diminishing returns.

### Texture Bandwidth

Blur is bandwidth-intensive. Each pixel performs 48 texture samples across all passes. At 1024×1024 resolution, this totals 50 million texture fetches. Modern GPUs handle this via texture caching and parallel execution, but blur remains one of the slowest texgen operations.

The separable approach mitigates this—non-separable 24×24 blur would require 576 samples, a 12x increase. The separability trade-off is essential for real-time performance.

**Use Cases**: Glow effects (blur bright regions), depth-of-field simulation, soft shadows, reducing texture noise.

## dirblur.hlsl - Directional Motion Blur

The directional blur shader samples along a line in a specified direction, creating motion blur or directional smearing effects. Unlike separable blur, directional blur cannot split into passes—it requires sampling along arbitrary angles.

**Parameters**:
- `[0] Direction`: Blur angle (0-1 maps to 0-2π radians)
- `[1] Amount`: Blur distance/strength (0-1)

**Inputs**:
- `t0`: Source texture
- `t1`: Direction map (per-pixel angle control)

**Passes**: 1 (no separation possible)

The shader reads per-pixel direction from the direction map:

```hlsl
#define c 21  // Sample count

float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float d = DirMap.Sample(sm, t)[(int)(data1.x * 256)];
  float2 vec = float2(cos(d * 3.14159265 * 2), sin(d * 3.14159265 * 2));

  float4 ret = 0;

  for (int x = 1; x < c; x++)
    ret += Textur.Sample(sm, t + (vec * x * data1.y * 0.03));

  return ret / (c - 1);
}
```

The direction value (0-1) maps to 0-2π via multiplication by `2π`. The cosine and sine convert this to a unit direction vector. The loop samples 21 points along this direction, scaled by the amount parameter.

The `0.03` scale factor controls maximum blur extent. At amount=1, the blur samples 21 pixels spread over `21 * 0.03 = 0.63` UV units (63% of texture width). This creates strong directional streaking.

### Per-Pixel Direction

Unlike blur.hlsl's uniform direction, dirblur reads direction from a texture. This enables:
- **Radial blur**: Direction map contains angle from center (polar coordinates)
- **Flow field blur**: Direction map follows vector field (water flow, wind direction)
- **Edge-aware blur**: Direction map aligned with image gradients

The direction map itself can be procedurally generated (gradients, noise) or computed from other textures (normal maps, optical flow).

**Use Cases**: Motion blur for fast-moving objects, speed lines in action scenes, radial blur for explosions, flow-based distortions.

## normalmap.hlsl - Height to Normal Conversion

The normalmap shader converts grayscale height maps to tangent-space normal maps using finite difference gradient estimation. It samples height at four neighboring pixels, computes X and Y gradients, and constructs a normal vector.

**Parameters**:
- `[0] Channel`: Which input channel contains height data (0=R, 1=G, 2=B, 3=A)
- `[1] Strength`: Normal intensity control (0=extreme bumpiness, 1=nearly flat)

Normal maps encode surface orientation as RGB colors. The red channel stores the X component of the normal vector, green stores Y, blue stores Z. A flat surface pointing straight up encodes as (0.5, 0.5, 1.0) in [0,1] range, representing normal vector (0, 0, 1) in [-1,1] range.

### Gradient Estimation

The shader samples height at four neighbors forming a cross pattern:

```hlsl
float d = 0.5 / 4096.0f;  // Sample offset

int DataChannel = data1.x * 256;

float x1 = Textur.Sample(sm, t - float2(d, 0))[DataChannel];
float x2 = Textur.Sample(sm, t + float2(d, 0))[DataChannel];
float y1 = Textur.Sample(sm, t - float2(0, d))[DataChannel];
float y2 = Textur.Sample(sm, t + float2(0, d))[DataChannel];
```

The sample offset `0.5 / 4096` represents half a pixel at 4096×4096 resolution. This balances detail capture (smaller offsets capture fine features) against noise sensitivity (larger offsets smooth over noise).

The gradient in X equals the difference between right and left samples: `dH/dx = (x2 - x1) / (2 * offset)`. Similarly for Y: `dH/dy = (y2 - y1) / (2 * offset)`. The shader skips the division—it cancels out during normalization.

### Normal Construction

The normal vector's X and Y components come directly from gradients. The Z component is a scale factor controlling bumpiness:

```hlsl
float s = (1 - data1.y * 255 / 256.0f) * 1.2;
s *= s;  // s²
s *= s;  // s⁴
s /= 8.0;

float3 n = normalize(float3(x2 - x1, y2 - y1, s)) / 2 + 0.5;
```

The strength parameter undergoes power-of-four transformation: `((1 - strength) * 1.2)⁴ / 8`. At strength=0, `s ≈ 0.4`, creating strong XY gradients (bumpy). At strength=1, `s ≈ 0`, but the calculation actually approaches a small positive value, creating nearly flat normals.

Larger Z values flatten the normal toward pointing straight up (0, 0, 1). Smaller Z values amplify the XY components, increasing perceived bumpiness. This provides intuitive control—higher strength parameter creates less bumpy surfaces.

The final division by 2 and addition of 0.5 encodes the normalized [-1,1] vector to [0,1] for texture storage: `encoded = (normal + 1) / 2`.

**Use Cases**: Converting procedural heightfields to normal maps, creating bumpy surfaces from noise, generating detail normals for materials.

## glass.hlsl - Refraction Displacement

The glass shader simulates refraction by displacing UV coordinates based on a displacement map. It samples a height or normal map, uses gradients as displacement vectors, and samples the source texture at offset coordinates. This creates glass distortion, water refraction, and heat shimmer effects.

**Parameters**:
- `[0] Channel`: Which displacement map channel to use (0=R, 1=G, 2=B, 3=A)
- `[1] Amount`: Displacement strength (bidirectional, 0.5=no displacement)

**Inputs**:
- `t0`: Source texture (distorted)
- `t1`: Displacement map (height or normal)

```hlsl
#define c 3
#define Scatter 1/32.0f

float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
  float4 dx = DataMap.Sample(sm, float2(t.x + Scatter, t.y));
  float4 dy = DataMap.Sample(sm, float2(t.x, t.y + Scatter));

  float d = DataMap.Sample(sm, t)[(int)(data1.x * 256)];

  float2 dv = float2(d - dx.x, d - dy.y);
  float2 n = t + dv * (data1.y - 0.5);

  return Textur.Sample(sm, n);
}
```

The shader computes gradients by comparing center sample `d` with offset samples `dx` and `dy`. The gradient `(d - dx.x, d - dy.y)` points in the direction of steepest height change.

The displacement multiplier `(amount - 0.5)` creates bidirectional control. At amount=0, displacement is -0.5 (reversed gradients). At amount=0.5, no displacement. At amount=1, displacement is +0.5 (forward gradients).

The final sample `Textur.Sample(sm, t + displacement)` reads the source texture at offset coordinates. Regions with steep gradients in the displacement map pull source pixels from farther away, creating distortion.

### Refraction Physics

Real refraction follows Snell's law: `n₁ sin(θ₁) = n₂ sin(θ₂)`. This shader approximates refraction by assuming displacement proportional to surface normal angle. It's physically inaccurate but visually plausible for glass and water effects.

For accurate refraction, the shader would need to:
1. Convert displacement map to normals
2. Compute incident and refracted ray directions using Snell's law
3. Trace rays through the medium
4. Sample at ray intersection points

Phoenix's approximation skips ray tracing, using gradient-based displacement instead. This runs in real-time and looks convincing for rough glass, rippling water, and heat distortion.

**Use Cases**: Glass materials, underwater distortion, heat shimmer, magnification effects.

## Implications for Rust Framework

Phoenix's color and blend shaders demonstrate patterns valuable for any procedural texture system. A Rust framework targeting similar goals should adopt these patterns while leveraging Rust's type safety and modern GPU APIs.

**Adopt: Type-safe blend mode enum**. Phoenix's integer selector is compact but error-prone. Rust enums provide type safety:

```rust
enum BlendMode {
    Add, Subtract, Multiply, Alpha,
    Min, Max, ColorDodge, ColorBurn,
    Screen, Overlay,
}

impl BlendMode {
    fn apply(&self, a: Vec4, b: Vec4) -> Vec4 {
        match self {
            BlendMode::Add => a + b,
            BlendMode::Multiply => a * b,
            // ...
        }
    }
}
```

Shaders receive the enum as a u32, avoiding string parsing or error-prone integer magic numbers.

**Adopt: Color space utilities**. RGB↔HSV conversion is common enough to warrant a shared library. Rust can provide:

```rust
pub fn rgb_to_hsv(rgb: Vec3) -> Vec3 { /* ... */ }
pub fn hsv_to_rgb(hsv: Vec3) -> Vec3 { /* ... */ }
```

These functions work both on CPU (for parameter preview) and GPU (via shader includes). WGSL supports function imports, enabling shared color utilities across shaders.

**Adopt: Spline-based curve evaluation**. Phoenix's 4096-point LUT approach balances precision and memory. Rust frameworks should support:
- CPU-side spline evaluation for curve baking
- 1D texture upload for GPU sampling
- Curve editor integration (UI or file-based)

The `wgpu` texture API makes 1D texture upload straightforward:

```rust
queue.write_texture(
    ImageCopyTexture { texture: &curve_texture, mip_level: 0, ... },
    curve_data,  // [u8; 4096 * 4] RGBA
    ImageDataLayout { bytes_per_row: 4096 * 4, ... },
    Extent3d { width: 4096, height: 1, depth: 1 },
);
```

**Modify: Compute shaders for blur**. Phoenix uses pixel shaders for blur, which work but miss optimization opportunities. Compute shaders enable:
- Shared memory caching for horizontal passes (load 24 samples once, share across thread group)
- Better memory access patterns (coalesced reads)
- Explicit workgroup sizing (64×1 threads for horizontal blur, 1×64 for vertical)

WGSL compute shaders handle this elegantly:

```wgsl
var<workgroup> cache: array<vec4<f32>, 256>;

@compute @workgroup_size(256, 1, 1)
fn blur_horizontal(@builtin(local_invocation_id) local_id: vec3<u32>) {
    cache[local_id.x] = texture_load(...);
    workgroupBarrier();

    var sum = vec4<f32>(0.0);
    for (var i = 0; i < 24; i++) {
        sum += cache[local_id.x + i];
    }
    // Write output
}
```

**Modify: F16 normal encoding**. Phoenix encodes normals as 8-bit RGBA, quantizing to 256 levels per component. Modern GPUs support 16-bit float textures (`Rgba16Float`), providing:
- Higher precision (10-bit mantissa vs 8-bit integer)
- No encode/decode overhead (normals stay in [-1,1] range)
- Better interpolation (hardware handles float filtering)

The memory cost is 8 bytes per pixel (vs 4 bytes for 8-bit), but quality improves significantly for high-frequency normal maps.

**Modify: Gaussian blur weights**. Phoenix's box blur (uniform weights) approximates Gaussian blur through multiple passes. Directly implementing Gaussian weights provides better quality in fewer passes:

```wgsl
const WEIGHTS: array<f32, 7> = array(
    0.383, 0.242, 0.061, 0.006, 0.000, 0.000, 0.000
);

var sum = texture_load(center) * WEIGHTS[0];
for (var i = 1; i < 7; i++) {
    sum += texture_load(center + i) * WEIGHTS[i];
    sum += texture_load(center - i) * WEIGHTS[i];
}
```

This requires 13 samples (vs 24 for box blur) while producing superior results. The weights come from a pre-computed Gaussian kernel.

**Avoid: Per-pixel blend mode selection**. Phoenix's uniform blend mode (same across all pixels) avoids GPU divergence. Per-pixel mode selection would cause branching:

```wgsl
// AVOID: Per-pixel mode from texture causes divergence
let mode = u32(mode_texture.sample(uv).r * 10.0);
if mode == 0 { /* add */ }
else if mode == 1 { /* multiply */ }
// Different pixels take different branches = slow
```

Keep blend modes uniform or use separate shaders per mode. Modern pipeline caching makes shader switching cheap.

**Consider: Procedural LUT generation**. Phoenix uploads artist-authored curves and palettes. A Rust framework can also generate LUTs procedurally:

```rust
// Contrast curve: S-shaped
fn generate_contrast_lut(contrast: f32) -> Vec<u8> {
    (0..4096)
        .map(|i| {
            let x = i as f32 / 4095.0;
            let y = ((x - 0.5) * contrast + 0.5).clamp(0.0, 1.0);
            (y * 255.0) as u8
        })
        .collect()
}
```

This enables runtime parameter adjustment without pre-baking every curve variant.

**Consider: Importance sampling for blur**. Uniform blur samples waste effort on low-weight distant pixels. Importance sampling concentrates samples where Gaussian weight is highest:

```rust
// Poisson disk samples weighted by Gaussian
const SAMPLES: &[(f32, f32, f32)] = &[
    (0.0, 0.0, 0.383),      // Center: highest weight
    (1.0, 0.0, 0.242),      // Near: moderate weight
    (-1.0, 0.0, 0.242),
    // ... fewer distant samples
];
```

This reduces sample count from 24 to ~12 while maintaining quality. The trade-off: irregular sampling patterns complicate separable optimization.

## Related Documents

This document covers color manipulation, blending, and filtering shaders. For complete texgen context, see:

- **[overview.md](overview.md)** — Texgen architecture, operator graphs, texture pooling
- **[pipeline.md](pipeline.md)** — Multi-pass rendering, dependency resolution, caching
- **[operators.md](operators.md)** — Per-operator parameter layouts and filter assignments
- **[shaders.md](shaders.md)** — Shader infrastructure, constant buffers, fullscreen quad pattern
- **[generators.md](generators.md)** — Noise algorithms, gradients, cellular patterns
- **[transforms.md](transforms.md)** — UV manipulation, rotation, polar coordinates

For annotated source code walkthroughs:

- **[../code-traces/color-grading.md](../code-traces/color-grading.md)** — HSL adjustment implementation details
- **[../code-traces/blur-implementation.md](../code-traces/blur-implementation.md)** — Separable blur pass management

Cross-system integration:

- **[../rendering/materials.md](../rendering/materials.md)** — How materials consume texgen color outputs
- **[../rendering/post-processing.md](../rendering/post-processing.md)** — Post-processing uses similar blend modes

## Source File Reference

All source paths relative to `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/texgen/`.

**Color Adjustment Shaders**:
- `hsl.hlsl` (73 lines) — HSV color space adjustment with hue rotation, saturation scaling, lightness bidirectional control
- `hslcurves.hlsl` (63 lines) — HSL adjustment via spline lookup textures
- `colorize.hlsl` (18 lines) — Two-color gradient mapping from grayscale
- `curves.hlsl` (19 lines) — Per-channel RGB curve adjustment via LUT
- `palette.hlsl` (30 lines) — 2D palette lookup with row selection
- `contrast.hlsl` (17 lines) — Power-based contrast adjustment centered at 0.5
- `smoothstep.hlsl` (13 lines) — Hermite threshold with soft edges
- `invert.hlsl` (11 lines) — Simple color negation

**Blending Shaders**:
- `combine.hlsl` (27 lines) — 10 Photoshop blend modes (add, multiply, overlay, screen, dodge, burn, etc.)
- `mix.hlsl` (14 lines) — Linear interpolation between two textures
- `mixmap.hlsl` (16 lines) — Three-texture blend with control map
- `replace-alpha.hlsl` (14 lines) — Alpha channel replacement

**Filtering Shaders**:
- `blur.hlsl` (36 lines) — Six-pass separable box blur (24 samples per direction)
- `dirblur.hlsl` (25 lines) — Single-pass directional motion blur (21 samples)

**Normal Generation**:
- `normalmap.hlsl` (29 lines) — Height-to-normal via finite differences
- `glass.hlsl` (26 lines) — Refraction displacement via gradient sampling

**Annotated Versions** (with detailed comments):
- `annotated/texgen/hsl.hlsl` (144 lines) — RGB↔HSV conversion explained
- `annotated/texgen/blur.hlsl` (75 lines) — Separable convolution breakdown
- `annotated/texgen/normalmap.hlsl` (77 lines) — Gradient estimation details

**Infrastructure**:
- `../../apEx/Phoenix/Texgen.cpp` (lines 120-185) — Multi-pass render loop, texture binding
- `../../apEx/Phoenix/Texgen.h` (lines 66-103) — Filter descriptors, parameter encoding
