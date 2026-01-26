# Post-Processing Pipeline

Phoenix provides a comprehensive post-processing system for transforming rendered images into cinematic output. Clean Slate demonstrates approximately 15 distinct post-processing effects, organized as multi-pass render techniques that execute after the main lighting passes.

This document covers the technical implementation of each effect, parameter conventions, and the typical post-processing chain used in production.

## Post-Processing Architecture

Post-processing in Phoenix operates on full-screen quads with texture inputs and outputs. Each effect is implemented as a render technique with one or more passes.

### Pipeline Position

```
┌─────────────────────────────────────────────────────────────────┐
│                     Phoenix Render Frame                        │
├─────────────────────────────────────────────────────────────────┤
│  G-Buffer Pass  →  Lighting Pass  →  Post-Processing Chain     │
│      (RT0-2)           (Main RT)         (Ping-Pong RTs)       │
└─────────────────────────────────────────────────────────────────┘
```

Post-processing executes after all scene lighting accumulates into the main render target. Effects read from one RT, write to another, enabling ping-pong chaining for multi-effect compositions.

### Common Constant Buffer Layout

All post-processing shaders share a scene buffer structure:

```hlsl
cbuffer SceneBuffer : register(b0)
{
    float time;         // Animation time
    float aspectRatio;  // Screen width / height
    float screenWidth;  // Resolution X
    float screenHeight; // Resolution Y
    // View/projection matrices for depth-aware effects
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
    float4x4 inverseViewMatrix;
    float4x4 inverseProjectionMatrix;
}

cbuffer MaterialBuffer : register(b1)
{
    // Effect-specific parameters
}
```

### Texture Slot Conventions

| Slot | Common Usage |
|------|--------------|
| t0 | Input color texture |
| t1-t6 | Additional inputs (previous frame, masks) |
| t7 | Depth buffer |

---

## Tone Mapping: ACES Color Grading

ACES (Academy Color Encoding System) provides industry-standard HDR to LDR conversion with filmic characteristics.

### Algorithm Overview

The ACES pipeline transforms HDR linear values to display-ready output:

1. **Input Transform**: sRGB/Rec.709 → ACES AP1 color space
2. **RRT+ODT**: Reference Rendering Transform + Output Device Transform
3. **Output Transform**: ACES AP1 → sRGB for display

### Implementation

```hlsl
// ACES Input Matrix: sRGB → AP1
float3x3 ACES_INPUT_MAT = float3x3(
    0.59719, 0.35458, 0.04823,
    0.07600, 0.90834, 0.01566,
    0.02840, 0.13383, 0.83777
);

// ACES Output Matrix: AP1 → sRGB
float3x3 ACES_OUTPUT_MAT = float3x3(
     1.60475, -0.53108, -0.07367,
    -0.10208,  1.10813, -0.00605,
    -0.00327, -0.07276,  1.07602
);

float4 ACESToneMap(float3 color)
{
    // Transform to ACES color space
    color = mul(ACES_INPUT_MAT, color);

    // RRT+ODT rational polynomial approximation
    // S-curve: lifts blacks, maintains midtones, rolls off highlights
    float3 a = color * (color + 0.0245786) - 0.000090537;
    float3 b = color * (0.983729 * color + 0.4329510) + 0.238081;
    color = a / b;

    // Transform back to output color space
    color = mul(ACES_OUTPUT_MAT, color);

    return float4(saturate(color), 1);
}
```

### Curve Characteristics

The RRT+ODT approximation creates an S-curve with three regions:

| Region | Behavior | Purpose |
|--------|----------|---------|
| Toe | Lifts blacks slightly | Better shadow detail |
| Linear | Maintains contrast | Natural midtone reproduction |
| Shoulder | Rolls off highlights | Prevents harsh clipping |

### Parameters

The Clean Slate implementation uses fixed ACES parameters with no artist adjustments, providing consistent cinematic output.

---

## Bloom (Glow)

Multi-pass progressive downsampling bloom extracts bright areas and creates soft glow around them.

### Pipeline Structure

Phoenix implements bloom as a 7-pass pipeline:

```
Pass 1: Threshold + Horizontal Blur → X/2, Y/1
Pass 2: Vertical Blur              → X/2, Y/2
Pass 3: Horizontal Blur            → X/4, Y/2
Pass 4: Vertical Blur              → X/4, Y/4
Pass 5: Horizontal Blur            → X/8, Y/4
Pass 6: Vertical Blur              → X/8, Y/8
Pass 7: Color Tint + Output        → Final
```

Each pass halves resolution in one dimension while applying separable blur, naturally creating larger blur radii at lower cost.

### Pass 1: Threshold Extraction

```hlsl
cbuffer MaterialBuffer : register(b1)
{
    float4 blurParams;  // xy = blur size, z = sample count
    float threshold;    // Brightness cutoff
    float power;        // Intensity multiplier
}

float4 Pass1_ThresholdHorizontal(float2 texCoord)
{
    float4 color = 0;
    float count = blurParams.z * 255;

    for (int x = 0; x < count; x++)
    {
        // Center the blur kernel
        float offset = (x - (count - 1) / 2.0) * blurParams.x / count / 4.0;
        float2 sampleUV = texCoord + offset * float2(1, 0);

        float4 sampleColor = inputTexture.Sample(linearSampler, sampleUV);

        // Threshold test (mask for pixels above threshold)
        float4 aboveThreshold = sampleColor >= threshold;

        // Extract bright part and amplify
        color += ((sampleColor - threshold) * (1 + power * 1000) + threshold) * aboveThreshold;
    }

    return color / count;
}
```

### Separable Blur Passes

Passes 2-6 use identical blur logic with alternating horizontal/vertical directions:

```hlsl
float4 GenericBlur(float2 texCoord, float2 direction, float blurSize, float count)
{
    float4 color = 0;

    for (int i = 0; i < count; i++)
    {
        float offset = (i - (count - 1) / 2.0) * blurSize / count / 4.0;
        color += inputTexture.Sample(linearSampler, texCoord + offset * direction);
    }

    return color / count;
}
```

### Final Pass: Color Tint

```hlsl
float4 Pass7_Output(float2 texCoord)
{
    return inputTexture.Sample(linearSampler, texCoord) * tintColor;
}
```

### Parameters

| Parameter | Encoding | Purpose |
|-----------|----------|---------|
| threshold | Direct (0-1) | Brightness cutoff |
| power | ×1000 scale | Extraction intensity |
| blur.xy | Pixel units | Blur radius |
| blur.z | ×255 | Sample count |
| color | RGBA | Final tint |

---

## Depth of Field

Physically-based circle of confusion (CoC) calculation followed by depth-aware blur passes.

### Algorithm Overview

Phoenix implements DoF in 3 passes:

1. **CoC Pass**: Calculate blur radius from depth using thin lens equation
2. **Disc Blur**: 8×8 sample disc blur weighted by CoC
3. **Refinement**: 3×3 cleanup with bleed prevention

### Thin Lens Circle of Confusion

The CoC formula derives from geometric optics:

```
c = A × |S2 - S1| / S2 × f / (S1 - f)

Where:
  A  = Aperture diameter
  S1 = Focal distance (in-focus plane)
  S2 = Object distance (pixel depth)
  f  = Focal length of the lens
```

### Implementation

```hlsl
cbuffer MaterialBuffer : register(b1)
{
    float4 blurParams;      // Unused in pass 1
    float4 cameraParams;    // x=focalDistance, y=focalLength, z=aperture
}

float CalculateCoC(float2 texCoord)
{
    // Decode camera parameters
    float focalDistance = cameraParams.x * 10;   // S1
    float focalLength = cameraParams.y / 10;     // f
    float aperture = cameraParams.z / 5;         // A (e.g., 0.024)

    // Get linear depth at this pixel
    float objectDistance = GetLinearDepth(texCoord);  // S2

    // Thin lens CoC formula
    float cocDiameter = aperture * abs(objectDistance - focalDistance) / objectDistance
                      * focalLength / (focalDistance - focalLength);

    // Normalize to reference aperture
    float cocPercent = cocDiameter / 0.024;

    // Clamp to reasonable range and scale
    return clamp(cocPercent, 0.0001, 0.12) * 0.3;
}

float4 CoCPass(float2 texCoord)
{
    float4 color = inputTexture.Sample(linearSampler, texCoord);
    color.w = CalculateCoC(texCoord);  // Store CoC in alpha
    return color;
}
```

### Depth-Aware Blurring

The refinement pass prevents background bleeding onto sharp foreground:

```hlsl
float4 RefinementPass(float2 texCoord)
{
    float centerDepth = GetLinearDepth(texCoord);
    float centerCoC = centerColor.a;

    float4 blurredColor = 0;
    float totalWeight = 0;

    // 3×3 kernel
    for (int x = 0; x < 3; x++)
    for (int y = 0; y < 3; y++)
    {
        float2 offset = float2(x - 1, y - 1) * 0.085;
        float2 sampleCoord = texCoord + offset * centerCoC;

        float sampleDepth = GetLinearDepth(sampleCoord);
        float sampleCoC = sampleColor.a;

        // Weight reduction for background samples
        float weight = 1.0;
        if (sampleDepth < centerDepth)  // Behind center
            weight = sampleCoC * bleedMultiplier;

        // Preserve weight if blur levels match
        if (centerCoC <= sampleCoC + bleedBias)
            weight = 1.0;

        blurredColor += sampleColor * saturate(weight);
        totalWeight += saturate(weight);
    }

    return blurredColor / totalWeight;
}
```

### Parameters

| Parameter | Encoding | Purpose |
|-----------|----------|---------|
| cameraParams.x | ×10 | Focal distance |
| cameraParams.y | ÷10 | Focal length |
| cameraParams.z | ÷5 | Aperture size |
| blurParams.x | ×255 | Bleed multiplier |
| blurParams.y | ÷10 | Bleed bias |

---

## Anti-Aliasing: FXAA

Fast Approximate Anti-Aliasing detects and smooths edges using luminance contrast.

### Two-Pass Pipeline

```
Pass 1: Luminance Prepass
  - Convert to linear space
  - Calculate luminance
  - Store in alpha channel

Pass 2: Edge Detection + Blending
  - Detect edges via contrast
  - Trace along edges
  - Blend to smooth jaggies
```

### Luminance Calculation

```hlsl
float4 LuminancePrepass(float2 texCoord)
{
    // Sample and convert sRGB → linear
    float4 color = pow(saturate(inputTexture.Sample(sampler, texCoord)), 1/2.4) * 1.055 - 0.055;

    // Store luminance in alpha
    color.w = dot(saturate(color.xyz), luminanceWeights / dot(luminanceWeights, 1));

    return color;
}
```

### Edge Detection Algorithm

FXAA 3.11 quality preset with 12 search steps:

```hlsl
float quality[12] = { 1, 1, 1, 1, 1, 1.5, 2, 2, 2, 2, 4, 8 };

float4 FxaaPixelShader(float2 position, float2 rcpFrame,
                       float subpix, float edgeThresh, float edgeThreshMin)
{
    // Sample center and 4-neighbors
    float4 rgbyM = SampleTexture(position);
    float lumaS = SampleTextureOffset(position, int2(0, 1)).w;
    float lumaE = SampleTextureOffset(position, int2(1, 0)).w;
    float lumaN = SampleTextureOffset(position, int2(0, -1)).w;
    float lumaW = SampleTextureOffset(position, int2(-1, 0)).w;

    // Early exit for low contrast (not an edge)
    float range = max(...) - min(...);
    if (range < max(edgeThreshMin, rangeMax * edgeThresh))
        return rgbyM;

    // Sample diagonals for direction detection
    // Compute edge orientation (horizontal vs vertical)
    // Trace along edge in both directions
    // Compute blend amount based on endpoints
    // Return blended sample
}
```

### Parameters

| Parameter | Typical Value | Purpose |
|-----------|---------------|---------|
| luminanceWeights | (0.299, 0.587, 0.114) | Standard luma |
| subpixelAmount | 0.75 | Sub-pixel AA strength |
| edgeThreshold | 0.166 | Edge detection sensitivity |
| edgeThresholdMin | 0.0833 | Minimum contrast threshold |

---

## Screen-Space Ambient Occlusion (SSAO)

Spiral-sampled SSAO estimates local occlusion using golden angle distribution.

### Algorithm Overview

```
1. Load surface normal from G-Buffer
2. Get view-space position from depth
3. Sample hemisphere using golden angle spiral
4. Compare depths to estimate occlusion
5. Output inverted occlusion (1 = no occlusion)
```

### Golden Angle Sampling

The golden angle (≈2.4 radians or 137.5°) provides optimal hemisphere coverage with any sample count:

```hlsl
float occlusion = 0.0;
float rotationAngle = HashNoise(pixelPos.xy * 100.0) * 6.28;  // Random start
float radiusStep = diameter * 0.2 / sampleCount / 255.0;

for (int i = 0; i < sampleCount; i++)
{
    // Spiral sample position
    float2 spiralOffset = float2(sin(rotationAngle), cos(rotationAngle));
    radius += radiusStep;

    // Sample neighbor
    float3 neighborPosition = GetViewPosition(pixelPos.xy + spiralOffset * radius * screenSize);
    float3 diff = neighborPosition - viewPosition;
    float3 direction = normalize(diff);
    float distance = length(diff);

    // Occlusion contribution
    float angleContribution = max(0.0, dot(normal, direction) - bias);
    float distanceAttenuation = 1.0 / (1.0 + distance);
    float distanceFalloff = smoothstep(maxDistance, maxDistance * 0.5, distance);

    occlusion += angleContribution * distanceAttenuation * distanceFalloff;

    // Advance by golden angle
    rotationAngle += 2.4;
}

return saturate(1 - occlusion * power / sampleCount);
```

### Parameters

| Parameter | Encoding | Purpose |
|-----------|----------|---------|
| dat.x | Direct | Power (intensity) |
| dat.y | ×255 | Sample count |
| dat.z | Direct | Diameter (search radius) |
| dat.w | Direct | Bias (min angle threshold) |
| dat2.x | Direct | Max distance (falloff) |

---

## Chromatic Aberration

Simulates lens imperfection by separating color channels radially from screen center.

### Implementation

```hlsl
float4 ChromaticAberration(float2 texCoord)
{
    float count = sampleCount * 255;
    float2 direction = 0.5 - texCoord;  // Radial from center

    float4 col = inputTexture.Sample(sampler, texCoord);
    float4 r = 0, b = 0;

    for (int x = 0; x < count; x++)
    {
        // Red channel shifts inward
        r += inputTexture.Sample(sampler, texCoord - direction * x / 200.0 * power);
        // Blue channel shifts outward
        b += inputTexture.Sample(sampler, texCoord + direction * x / 200.0 * power);
    }

    col.r = r.r / count;  // Replace red
    col.b = b.b / count;  // Replace blue
    // Green stays at center position

    return col;
}
```

### Parameters

| Parameter | Purpose |
|-----------|---------|
| power | Separation strength |
| sampleCount | Blur smoothness (×255) |

---

## Film Grain

Adds organic film-like noise with luminance-based response.

### Algorithm

```hlsl
float4 FilmGrain(float2 texCoord)
{
    float grainSize = lerp(1.5, 2.5, grainSizeParam);
    float2 m = float2(width / grainSize, height / grainSize);

    // Rotated coordinates for each channel (animated)
    float2 rotCoordsR = coordRot(texCoord, time + 1.425) * m;
    float2 rotCoordsG = coordRot(texCoord, time + 3.892) * m;
    float2 rotCoordsB = coordRot(texCoord, time + 5.835) * m;

    // 3D Perlin noise for each channel
    float3 noise = float3(
        pnoise3D(float3(rotCoordsR, 0)),
        pnoise3D(float3(rotCoordsG, 1)),
        pnoise3D(float3(rotCoordsB, 2))
    );

    // Optionally desaturate noise (colorAmount blends mono/color)
    noise = lerp(noise.r, noise, colorAmount);

    float3 color = inputTexture.Sample(sampler, texCoord).rgb;

    // Luminance-based response: more grain in shadows
    float luminance = lerp(0.0, dot(color, float3(0.3, 0.587, 0.114)), lumaAmount);
    float lum = smoothstep(0.2, 0.0, luminance) + luminance;

    // Apply grain with luminance-based attenuation
    return float4(color + lerp(noise, 0, pow(lum, 4)) * grainAmount * 0.1, 1);
}
```

### Parameters

| Parameter | Purpose |
|-----------|---------|
| colorAmount | Color vs. monochrome grain |
| lumaAmount | Luminance response strength |
| grainSize | Noise frequency |
| grainAmount | Overall intensity |

---

## Lens Flares

Generates multiple ghost reflections and halo effects from bright areas.

### Multi-Ghost Generation

```hlsl
float distances[8] = {0.5, 0.7, 1.03, 1.35, 1.55, 1.62, 2.2, 3.9};
float rgbScalesGhost[3] = {1.01, 1.00, 0.99};  // Slight chromatic split
float rgbScalesHalo[3] = {0.98, 1.00, 1.02};

float4 LensFlares(float2 texCoord)
{
    float2 dir = 0.5 - texCoord;  // Direction from center
    float4 ret = 0;

    for (int rgb = 0; rgb < 3; rgb++)
    {
        // Generate 8 ghosts per channel
        for (int i = 0; i < 8; i++)
        {
            float2 uv = texCoord + dir * distances[i] * rgbScalesGhost[rgb] * zoom * 2;
            float4 colour = inputTexture.Sample(sampler, uv);

            // Threshold check
            float lum = dot(colour.xyz, float3(0.299, 0.587, 0.114));
            colour *= lum > threshold * 4;

            // Disc falloff mask
            ret[rgb] += saturate(colour[rgb] - 0.5) * 1.5 * disc((uv - 0.5) * 2);
        }

        // Add halo ring
        float2 normDir = normalize(dir / float2(1, aspect)) * 0.4 * rgbScalesHalo[rgb];
        normDir.y *= aspect;
        float colour = inputTexture.Sample(sampler, texCoord + normDir)[rgb];
        ret[rgb] += saturate(colour - 0.5) * 1.5;
    }

    return ret;
}

float disc(float2 t)
{
    float x = saturate(1.0 - dot(t, t));
    return x * x;
}
```

### Pipeline

```
Pass 1: Ghost extraction + threshold
Pass 2: 3×3 blur
Pass 3: 8×8 disc blur (bokeh shape)
Pass 4: Final 3×3 blur + intensity
```

---

## Sharpen

Laplacian convolution kernel enhances edge contrast.

### Implementation

```hlsl
float3x3 sharpenKernel = float3x3(
    -1, -1, -1,
    -1,  9, -1,
    -1, -1, -1
);

float4 Sharpen(int2 pixelPos)
{
    float4 original = inputTexture.Load(int3(pixelPos, 0));

    // Apply convolution
    float4 sharpened = 0;
    for (int x = 0; x < 3; x++)
    for (int y = 0; y < 3; y++)
    {
        int2 samplePos = clamp(pixelPos + int2(x, y) - 1, 0, int2(xres, yres) - 1);
        sharpened += inputTexture.Load(int3(samplePos, 0)) * sharpenKernel[x][y];
    }

    // Blend between original and sharpened
    return lerp(original, sharpened, power * 5);
}
```

---

## Ghosting (Motion Blur)

Directional blur along a specified angle with threshold masking.

### Implementation

```hlsl
float4 Ghosting(float2 texCoord)
{
    float count = sampleCount * 255 + 1;
    float2 direction = float2(cos(angle * PI), sin(angle * PI));

    float4 col = inputTexture.Sample(sampler, texCoord);
    col *= saturate(col > threshold);  // Threshold mask

    for (int x = -count/2; x < count/2; x++)
    {
        float4 sample = inputTexture.Sample(sampler, texCoord + direction * x / 200.0 * power);
        sample *= saturate(sample > threshold);
        col += sample;
    }

    return col / count;
}
```

### Parameters

| Parameter | Purpose |
|-----------|---------|
| power | Blur distance |
| sampleCount | Blur smoothness (×255) |
| threshold | Brightness cutoff |
| direction | Angle in π radians |

---

## Effect Inventory

Clean Slate includes these post-processing effects:

| Effect | Passes | Primary Purpose |
|--------|--------|-----------------|
| ACES Color Grading | 1 | HDR → LDR tone mapping |
| Bloom (Glow) | 7 | Soft glow around bright areas |
| Depth of Field | 3 | Focus simulation with bokeh |
| FXAA | 2 | Edge anti-aliasing |
| SSAO | 1 | Contact shadows and ambient occlusion |
| Chromatic Aberration | 1 | Lens imperfection simulation |
| Film Grain | 1 | Organic film texture |
| Lens Flares | 4 | Ghost and halo effects |
| Sharpen | 1 | Edge enhancement |
| Ghosting | 1 | Directional motion blur |
| Screen-Space Reflections | 1 | Ray-marched reflections |

---

## Typical Post-Processing Chain

Clean Slate typically orders effects as:

```
1. SSAO (early, before lighting composite)
2. Screen-Space Reflections (needs G-Buffer)
3. Bloom extraction and blur passes
4. Depth of Field (focus simulation)
5. Lens Flares (bright spot effects)
6. Chromatic Aberration
7. Sharpen
8. Film Grain
9. ACES Tone Mapping (always last before FXAA)
10. FXAA (final anti-aliasing)
```

### Order Considerations

- **SSAO** runs early since it modifies ambient contribution
- **SSR** needs G-Buffer data before it's discarded
- **Bloom** should process HDR values before tone mapping
- **Tone mapping** converts HDR → LDR, must precede display-space effects
- **FXAA** operates on final LDR image with luminance in alpha

---

## Parameter Encoding Conventions

Phoenix encodes many parameters for compact representation:

| Pattern | Encoding | Range |
|---------|----------|-------|
| Sample counts | value × 255 | 0-255 |
| Focal distance | value × 10 | 0-10 |
| Focal length | value ÷ 10 | 0-0.1 |
| Aperture | value ÷ 5 | 0-0.2 |
| Angles | value × π | 0-π radians |
| Intensity | value × 1000 | 0-1000 |

This allows float parameters (typically 0-1) to encode useful ranges.

---

## Render Target Management

Post-processing requires careful RT management for ping-pong chaining:

```
Frame Start:
  RT_Main = Scene rendering
  RT_A = Available
  RT_B = Available

Bloom Pass 1: RT_Main → RT_A
Bloom Pass 2: RT_A → RT_B
Bloom Pass 3: RT_B → RT_A
...
DoF Pass 1: RT_A → RT_B
DoF Pass 2: RT_B → RT_A
...
Tone Map: RT_A → RT_Main
FXAA: RT_Main → Backbuffer
```

Phoenix manages this automatically through the render layer system.

---

## Implementation Notes

### Depth Buffer Access

Several effects (DoF, SSAO) require linear depth reconstruction:

```hlsl
float GetLinearDepth(float2 uv)
{
    float depth = depthTexture.Sample(sampler, uv).x;
    float4 clipPos = mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1));
    return -clipPos.z / clipPos.w;  // Negate for positive distance
}
```

### Performance Considerations

- **Separable blur**: 2D blur as two 1D passes reduces samples from N² to 2N
- **Progressive downsampling**: Bloom at lower resolutions is faster
- **Early exit**: FXAA skips low-contrast pixels
- **Sample count encoding**: Allows artist control over quality/performance

### HDR Workflow

Effects that operate on HDR values (bloom threshold, lens flares) must execute before tone mapping. The pipeline assumes linear HDR values until the ACES pass.

---

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture
- **[pipeline.md](pipeline.md)** — Render pass organization
- **[lighting.md](lighting.md)** — Light accumulation
- **[shaders.md](shaders.md)** — Shader patterns and constant buffers
- **[examples.md](examples.md)** — Clean Slate production examples

## Source References

Clean Slate project (`Projects/Clean Slate/extracted/shaders/materials/`):

| File | Lines | Effect |
|------|-------|--------|
| aces-color-grading.hlsl | 57 | ACES tone mapping |
| glow.hlsl | 235 | 7-pass bloom |
| depth-of-field.hlsl | 136 | 3-pass DoF |
| fxaa.hlsl | 202 | 2-pass anti-aliasing |
| ssao.hlsl | 90 | Spiral SSAO |
| chromatic-aberration.hlsl | 49 | Radial CA |
| film-grain.hlsl | 100 | Perlin grain |
| lens-flares.hlsl | 241 | 4-pass flares |
| sharpen.hlsl | 47 | Laplacian sharpen |
| ghosting.hlsl | 52 | Directional blur |
