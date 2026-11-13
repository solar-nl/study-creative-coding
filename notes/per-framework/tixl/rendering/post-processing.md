# Post-Processing in tixl

Every visual medium develops its own vocabulary for making images look intentional. Film grain, lens flares, and bloom are not defects — they are signatures of capture hardware that audiences learned to associate with cinematic quality. Modern real-time rendering deliberately reintroduces these artifacts. Tixl's post-processing system is where that conversation between raw rendering output and final aesthetic intent happens.

The fundamental insight behind tixl's approach is that post-processing is just another operator in the graph. There is no separate "post stack" with a fixed execution order. Instead, you wire up post effects the same way you wire anything else: a `RenderTarget` produces a `Texture2D`, that texture travels as a pin connection to a `Bloom` or `ToneMapping` operator, and the result emerges as another `Texture2D` that can be fed further downstream. This data-flow model means every creative decision about ordering is visible and changeable without diving into any configuration panel.

Think of it like a darkroom workflow. The render target is the exposed film — it captures the raw scene in HDR. Each subsequent operator is a developing chemical tray: one tray extracts highlights (bright pass), another blurs them (downsample pyramid), another pushes shadow detail (tone mapping), and finally the print lands on paper in a form human eyes can appreciate. The difference from traditional rendering pipelines is that you see all the trays laid out on the graph canvas and can rearrange them freely.

The problem this system solves is visual quality at interactive frame rates. Raw rasterization produces physically accurate brightness values, but monitors cannot display the full range of HDR light. Bright surfaces clip to white, subtle gradients collapse, and the image looks flat or blown-out. Post-processing operators recondition the image into the monitor's usable range while preserving perceptual contrast — and along the way add effects like bloom that communicate the energy of bright light sources.

## The Operator Graph and Post-Processing Chains

In tixl, a post-processing chain takes this topology:

```
RenderTarget
  ├── ColorBuffer (Texture2D)  ──► Bloom ──► ToneMapping ──► Fxaa ──► Output
  └── DepthBuffer (Texture2D)  ──► ColorGradeDepth ─────────────────► Output
```

Each image operator follows the same pattern at the C# level: one or more `InputSlot<Texture2D>` pins, one `Slot<Texture2D>` output pin. At the HLSL level, each operator runs a fullscreen triangle pass — a vertex shader transforms three vertices into a clip-space triangle that covers the screen, and a pixel shader samples the incoming texture and writes the result. No geometry assembly or vertex buffers are involved.

The vertex shader for this pattern is the standard fullscreen triangle trick:

```hlsl
// Operators/Lib/Assets/shaders/dx11/fullscreen-texture.hlsl
Output vsMain(uint id: SV_VertexID)
{
    Output output;
    output.texcoord = float2((id << 1) & 2, id & 2);
    output.position = float4(output.texcoord * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}
```

Three vertices with `SV_VertexID` 0, 1, 2 compute UV coordinates that form a large triangle extending beyond NDC bounds. The rasterizer clips it to the viewport, producing exactly one fragment per pixel. This technique avoids the overhead of a vertex buffer, a common pattern in DX11 post-processing.

## Bloom

Bloom is the poster child of cinematic post-processing and tixl implements a full multi-resolution pyramid approach that the industry calls "dual Kawase blur" or more generically the "downsample-blur-upsample" pattern. The key insight is that blur at the original resolution is expensive and physically wrong — real-world lens glow spreads light at many spatial frequencies simultaneously. By blurring at progressively lower resolutions and then recombining, you get wide, soft halos cheaply.

### The Bloom Operator Interface

The `Bloom` operator (`Operators/Lib/Symbols/image/fx/blur/Bloom.cs`) exposes these parameters:

| Parameter | Type | Purpose |
|---|---|---|
| `Image` | `Texture2D` | Source HDR image |
| `Intensity` | `float` | Overall bloom strength multiplier |
| `ColorWeights` | `Vector4` | Per-channel luminance weights for bright pass |
| `Threshold` | `float` | Luminance cutoff below which pixels do not bloom |
| `GlowGradient` | `Gradient` | Color tint per pyramid level (close-in vs far glow) |
| `GainAndBias` | `Vector2` | Controls the gain/bias curve shaping level intensity distribution |
| `MaxLevels` | `int` | Number of downsample levels (clamped to 1–10) |
| `Blur` | `float` | Blur kernel offset within each level |
| `Clamp` | `bool` | Whether to clamp the blurred texture at borders |

The real execution logic lives in `_ExecuteBloomPasses` (`Operators/Lib/Symbols/image/fx/_/_ExecuteBloomPasses.cs`), which is the implementation operator wired behind the `Bloom` user-facing operator. Separating the user-facing API from the internal implementation is a recurring tixl pattern.

### Pipeline Step-by-Step

The C# code in `_ExecuteBloomPasses.UpdateSave()` executes four distinct GPU passes per frame, with concrete constant buffers matched to each:

**Step 1 — Bright Pass.** The source texture is drawn into a full-resolution render target using a `BrightPassPS` pixel shader. This shader reads luminance using weighted RGB channels and zeros out any pixel below the threshold:

```csharp
// From _ExecuteBloomPasses constant buffer
struct ThresholdParams {   // 16 bytes, register(b0)
    Vector3 ColorWeights;  // per-channel luminance weights
    float   Threshold;     // cutoff luminance
}
```

Pixels that survive the threshold are written to `_brightPassTarget`. This intermediate texture contains only the "glowing" content — bright emitters, specular highlights, light sources.

**Step 2 — Downsample + Blur Pyramid.** A loop runs from level 0 to `levels - 1`. Each iteration does three sub-passes:

1. Downsample: render the previous level's texture at half resolution into `_blurTargetsA[level]` using bilinear filtering
2. Vertical blur: `_blurTargetsA[level]` → `_blurTargetsB[level]`, with a blur direction of `(0, blurOffset)`
3. Horizontal blur: `_blurTargetsB[level]` → `_blurTargetsA[level]`, with a blur direction of `(blurOffset, 0)`

The separable blur constant buffer encodes the direction and resolution:

```csharp
struct BlurParameters {   // 32 bytes, register(b0)
    float DirX;           // horizontal blur direction
    float DirY;           // vertical blur direction
    float Width;          // render target width in pixels
    float Height;         // render target height in pixels
    int   UseMask;        // whether to apply a mask texture
    int   MaskInvert;     // invert mask polarity
    int   ClampTexture;   // clamp UV at borders
    int   _padding0;
}
```

At level 0 the texture is half the original resolution, at level 1 it is a quarter, and so on. A scene at 1920x1080 with five levels generates textures at 960x540, 480x270, 240x135, 120x67, and 60x33.

**Step 3 — Initial Composite.** The source HDR texture is copied directly to `_compositeTarget` using a point sampler copy pass. This establishes the baseline before bloom is accumulated on top.

**Step 4 — Upsample and Additive Blend.** The pipeline reverses direction, iterating from the deepest (smallest) level up to level 0. For each level the blurred texture is drawn onto `_compositeTarget` with additive blending enabled (`AdditiveBlendState`). Each additive draw uses:

```csharp
struct CompositeParams {      // 64 bytes, register(b0)
    Vector2 InvTargetSize;    // 1/width, 1/height of composite target
    Vector2 InvSourceSize;    // 1/width, 1/height of blurred level
    Vector4 PassColor;        // per-level tint from GlowGradient
    float   PassIntensity;    // Intensity * normalized level weight
    Vector3 __padding;
}
```

The `PassIntensity` for each level is pre-calculated by `CalculateDistribution()`, which uses a bisection root-finder to invert the gain-bias curve and produce normalized weights summing to 1.0. This lets users shape whether bloom energy is weighted toward fine (close) or coarse (distant) frequencies using the `GainAndBias` input.

### Resource Management

Tixl manages the texture pyramid through a `RenderTargetSet` helper class that pairs a `Texture2D`, `RenderTargetView`, and `ShaderResourceView` together. The pyramid is lazy-initialized and invalidated when resolution, format, or level count changes:

```csharp
private sealed class RenderTargetSet {
    public Texture2D Texture;
    public RenderTargetView RTV;
    public ShaderResourceView SRV;
    public readonly Size2 Resolution;
}

private readonly List<RenderTargetSet?> _blurTargetsA = [];
private readonly List<RenderTargetSet?> _blurTargetsB = [];
private RenderTargetSet? _brightPassTarget;
private RenderTargetSet? _compositeTarget;
```

## Tone Mapping

HDR rendering means fragment colors can be any positive floating-point value — a sun surface might write `float4(1000, 900, 800, 1)`. Monitors can only display values in roughly [0, 1]. Tone mapping is the mathematical operator that remaps the full HDR range into the display-usable range without simply clipping everything above 1.0.

Think of it like a photographer choosing their film stock. Kodak Ektar and Fuji Velvia both capture the same scene but produce very different color renditions. ACES, Reinhard, and AgX are different "film stocks" — each tone mapping curve makes its own trade-offs between highlight preservation, shadow detail, and color saturation shift.

The `ToneMapping` operator (`Operators/Lib/Symbols/image/color/ToneMapping.cs`) provides six distinct modes:

| Mode | Characteristics |
|---|---|
| `Aces` | Academy Color Encoding System; filmic S-curve with strong contrast, industry standard for game/film pipelines |
| `Reinhard` | Classic `L / (1 + L)` per-channel or luminance mapping; simple, can desaturate highlights |
| `Filmic` | Empirical film emulation curve; soft rolloff in highlights, black crush in shadows |
| `Uncharted2` | John Hable's curve from the Uncharted 2 presentation; shoulder/toe control, warmer shadows |
| `AgX` | Björn Ottosson's perceptual tone mapper designed around OkLab gamut; preserves hue better under extreme exposure |
| `AgX_Punchy` | AgX with boosted contrast and saturation in the midtones |
| `None` | Pass-through; useful for debugging or when output goes to further processing |

Parameters beyond mode selection:

| Parameter | Type | Purpose |
|---|---|---|
| `CorrectGamma` | `bool` | Apply gamma correction (sRGB transfer function) after mapping |
| `Gamma` | `float` | Manual gamma exponent override |
| `Exposure` | `float` | Pre-mapping exposure multiplier in linear light |

The AgX modes stand out because they are built around the same perceptual color space used by `color-functions.hlsl` (OkLab), meaning highlight hue shifts that plague ACES with blue-purple metals are reduced. See the "Color Functions" section of this document and the companion `shared-hlsl-library.md` for the math behind OkLab.

## ColorGrade

Where tone mapping handles the gross remapping of HDR to display range, color grading is the fine aesthetic control that follows. It is the difference between getting a usable image and getting the image you intended. Tixl provides two color grading operators.

### ColorGrade

`ColorGrade` (`Operators/Lib/Symbols/image/color/ColorGrade.cs`) implements the classical Lift/Gamma/Gain model used in color correction software like DaVinci Resolve:

| Parameter | Type | Purpose |
|---|---|---|
| `PreSaturate` | `float` | Saturation applied before other corrections |
| `Lift` | `Vector4` | Per-channel shadow lift (shifts blacks) |
| `Gamma` | `Vector4` | Per-channel midtone power function |
| `Gain` | `Vector4` | Per-channel highlight gain (scales whites) |
| `VignetteColor` | `Vector4` | Color of the vignette overlay |
| `VignetteRadius` | `float` | Radius of clear area before vignette begins |
| `VignetteFeather` | `float` | Softness of the vignette edge |
| `VignetteCenter` | `Vector2` | Center of vignette in normalized UV space |
| `GenerateMipmaps` | `bool` | Generate mips for the output |
| `ClampResult` | `bool` | Clamp output to [0, 1] |

The Lift/Gamma/Gain model works as a three-zone correction. Lift adds a constant offset to all values, biasing the shadow zone. Gain multiplies values, scaling the highlight zone. Gamma applies a power function `x^(1/γ)` that nonlinearly adjusts midtones independently of the extremes. Composited together: `output = (Lift + input * Gain) ^ (1/Gamma)`. Providing these as `Vector4` values means R, G, B, and A can each be corrected independently, enabling color temperature and channel balance adjustments.

### ColorGradeDepth

`ColorGradeDepth` (`Operators/Lib/Symbols/image/color/ColorGradeDepth.cs`) extends `ColorGrade` with depth-aware color grading:

| Additional Parameter | Type | Purpose |
|---|---|---|
| `DepthBuffer` | `Texture2D` | Depth texture from RenderTarget |
| `Gradient` | `Gradient` | Color lookup along depth (e.g., haze or fog tint) |
| `GradientDepthRange` | `Vector2` | Near/far distances that map to the gradient ends |
| `CamNearFarClip` | `Vector2` | Camera clip planes for linearizing depth values |

This operator linearizes the non-linear depth buffer (which stores values in a hyperbolic distribution optimized for precision near the camera) using the near/far clip planes. The linearized depth then samples a gradient to produce a per-pixel color that is composited with the graded image. This is the mechanism for atmospheric haze, underwater fog gradients, and depth-keyed color shifts.

## AdjustColors

`AdjustColors` (`Operators/Lib/Symbols/image/color/AdjustColors.cs`) is a lighter alternative to `ColorGrade`, oriented toward per-shot photographic adjustments:

| Parameter | Type | Purpose |
|---|---|---|
| `Colorize` | `Vector4` | Multiply all pixels by a tint color |
| `Saturation` | `float` | HSL saturation adjustment |
| `Hue` | `float` | HSL hue rotation in degrees |
| `Contrast` | `float` | S-curve contrast adjustment around midpoint |
| `Exposure` | `float` | EV (linear) exposure |
| `Brightness` | `float` | Additive brightness offset |
| `OrangeTeal` | `float` | Stylized orange/teal LUT effect strength (film look) |
| `Vignette` | `float` | Radial darkening vignette strength |
| `PreventClamping` | `Vector2` | Minimum/maximum clamping guard |
| `Background` | `Vector4` | Background fill color for transparent areas |

The `OrangeTeal` parameter is a creative shortcut. The orange-teal grade is ubiquitous in blockbuster cinema — warm skin tones pushed orange, cool environments pushed teal — and having it as a single float parameter makes it one-click accessible without manual hue-saturation curves.

## ChannelMixer

`ChannelMixer` (`Operators/Lib/Symbols/image/color/ChannelMixer.cs`) provides matrix-style channel mixing: each output channel is a weighted sum of all input channels plus an additive constant.

| Parameter | Type | Meaning |
|---|---|---|
| `MultiplyR` | `Vector4` | How much R, G, B, A feed into output Red |
| `MultiplyG` | `Vector4` | How much R, G, B, A feed into output Green |
| `MultiplyB` | `Vector4` | How much R, G, B, A feed into output Blue |
| `MultiplyA` | `Vector4` | How much R, G, B, A feed into output Alpha |
| `Add` | `Vector4` | Per-channel additive offset |
| `GenerateMipmaps` | `bool` | Generate mips for output |
| `ClampResult` | `bool` | Clamp to [0, 1] |

This is a 4x4 color matrix, the same operation used by ICC color profiles and display calibration. Typical uses: swap channels for artistic effect, implement custom desaturation with specific channel weights, convert between color encodings.

## ConvertColors and HSE

`ConvertColors` (`Operators/Lib/Symbols/image/color/ConvertColors.cs`) and `HSE` (`Operators/Lib/Symbols/image/color/HSE.cs`) handle color space conversions and hue-saturation-exposure adjustments. HSE is a simpler per-channel tool compared to `AdjustColors`.

`RemapColor` (`Operators/Lib/Symbols/image/color/RemapColor.cs`) maps a specific source color to a target color with a configurable tolerance and falloff, useful for replacing specific hues (green screen keying or selective color changes).

`KeyColor` (`Operators/Lib/Symbols/image/color/KeyColor.cs`) implements chroma key extraction for compositing. `Tint` (`Operators/Lib/Symbols/image/color/Tint.cs`) applies a simple color multiply.

## OkLab-Based Color Operations

Tixl's `color-functions.hlsl` defines four functions that operate in the OkLab perceptual color space. These functions underpin the AgX tone mapper and any operator that needs perceptually uniform color manipulation. The mathematical details are documented in depth in `shared-hlsl-library.md`, but their post-processing relevance is worth noting here.

OkLab stores colors as `(L, a, b)` where L is perceptual lightness and a, b are opponent color axes. The crucial property is that equal changes in L, a, or b correspond to equal-looking visual differences, regardless of the original hue. This makes saturation adjustment, contrast, and hue rotation all behave more "correctly" than RGB math.

For example, adjusting brightness of an orange in RGB typically shifts it toward yellow or white. In OkLab you move along the L axis while holding a and b constant — the hue stays where you put it. This is why `AgX` tone mapping is preferred for scenes with intensely colored emissive materials.

## FXAA (Fast Approximate Anti-Aliasing)

Aliasing — the jagged staircase artifact on diagonal edges — emerges from rasterization's discrete pixel grid. MSAA (multisampling) solves this at render time by sampling each pixel multiple times, but it multiplies memory bandwidth and is inflexible for deferred shading. FXAA is the screen-space post-process alternative.

The operator `Fxaa` (`Operators/Lib/Symbols/image/use/Fxaa.cs`) applies FXAA to any input texture:

| Parameter | Type | Purpose |
|---|---|---|
| `Image` | `Texture2D` | Input texture (should be gamma-corrected/LDR) |
| `Preset` | `int` | Quality/performance trade-off preset |
| `KeepAlpha` | `bool` | Preserve alpha channel (useful for compositing) |

FXAA works by detecting edges based on local luminance contrast. At each pixel it computes the luminance of 5 neighbors in a plus pattern. If the contrast exceeds a threshold the pixel is on an edge; the algorithm then searches along the edge to find its endpoints, determines how far along the edge the current pixel falls, and blends it with the pixel on the other side of the edge. The result is smooth edges at the cost of slight blurring.

Important: FXAA should be applied after tone mapping and gamma correction. It operates in gamma-corrected space because luminance contrast detection is calibrated for display-referred values, not linear HDR. The typical chain is:

```
RenderTarget → ToneMapping → Fxaa → Output
```

Tixl supports MSAA in `RenderTarget` (up to 8x samples via the `Multisampling` parameter) as an alternative to FXAA. The two approaches serve different workflows: MSAA is higher quality but memory-intensive; FXAA is lighter and works on any final image including screenshots.

## Motion Blur

`RenderWithMotionBlur` (`Operators/Lib/Symbols/image/use/RenderWithMotionBlur.cs`) implements accumulation-based motion blur. Rather than an interframe velocity buffer approach, it accumulates multiple renders of the same scene with sub-frame timing offsets:

| Parameter | Type | Purpose |
|---|---|---|
| `Texture` | `Texture2D` | Source image |
| `Passes` | `int` | Number of accumulation samples |
| `Strength` | `float` | Temporal spread of samples |

This approach is simple and robust but requires re-executing the scene rendering multiple times per frame, making it expensive for complex scenes.

## Depth of Field

While no dedicated `DepthOfField` operator exists as a standalone in the analyzed codebase, depth-aware processing is accessible through `ColorGradeDepth`. That operator reads the depth buffer from a `RenderTarget` and can apply per-depth color gradients. Full circle-of-confusion depth of field would require a separate operator that uses the depth buffer to control blur radius, which would follow the same pattern as bloom (a bright pass replaced by a CoC calculation pass, followed by a depth-weighted blur).

## The Analyze Subdirectory

Beyond the direct post-processing operators, tixl provides analysis operators that extract information from images for use in control signals:

| Operator | Purpose |
|---|---|
| `CompareImages` | Compute a difference metric between two textures |
| `DetectMotion` | Extract a motion signal from frame-to-frame differences |
| `GetImageBrightness` | Return overall brightness as a float (useful for audio-reactive links) |
| `ImageLevels` | Compute histogram-like level information |
| `OpticalFlow` | Estimate per-pixel motion vectors between frames |
| `RemoveStaticBackground` | Background subtraction for camera input |
| `WaveForm` | Luminance waveform visualization for color grading reference |

These are not visually transformative operators — they convert texture data into signals that can drive other parameters. `GetImageBrightness` is especially useful for reactive visuals: run the camera feed through it, and the output float can drive a modulator that scales an effect based on ambient brightness.

## Complete Image Operator Catalog

The image operators are organized into six top-level subdirectories. What follows is a categorized inventory.

### color/ — Color Correction

| Operator | Key Parameters | Notes |
|---|---|---|
| `AdjustColors` | Saturation, Hue, Contrast, Exposure, OrangeTeal, Vignette | All-in-one photographic adjustments |
| `ChannelMixer` | MultiplyR/G/B/A, Add | Full 4×4 RGBA matrix |
| `ColorGrade` | Lift, Gamma, Gain, Vignette | Professional grade-style correction |
| `ColorGradeDepth` | Lift, Gamma, Gain, DepthBuffer, Gradient | Depth-keyed color grading with atmospheric grading |
| `ConvertColors` | ColorSpace | Color space conversion (sRGB, linear, etc.) |
| `ConvertFormat` | Format | Texture format conversion |
| `HSE` | Hue, Saturation, Exposure | Simple HSE adjustment |
| `KeyColor` | KeyColor, Tolerance | Chroma key extraction |
| `RemapColor` | Source, Target, Tolerance | Selective color replacement |
| `Tint` | Color | Simple color multiply overlay |
| `ToneMapping` | Mode, Exposure, Gamma | ACES/Reinhard/Filmic/Uncharted2/AgX |

### fx/blur/ — Blur and Frequency Operations

| Operator | Key Parameters | Notes |
|---|---|---|
| `Bloom` | Intensity, Threshold, MaxLevels, GlowGradient, GainAndBias | Multi-level pyramid bloom |
| `Blur` | Size, Samples, Offset, Wrap | Separable Gaussian blur |
| `DirectionalBlur` | Angle, Strength, Samples | Motion blur style directional blur |
| `Sharpen` | Strength | Unsharp mask sharpening |

### fx/distort/ — Geometric Distortion

| Operator | Key Parameters | Notes |
|---|---|---|
| `BubbleZoom` | Center, Radius, Strength | Spherical lens distortion at a point |
| `ChromaticDistortion` | Center, Size, Distort, Colorize, SampleCount | Radial chromatic aberration from a point |
| `Displace` | DisplaceMap, Strength | UV displacement via a displacement texture |
| `DistortAndShade` | DisplaceMap, Shade | Combined displacement and shading |
| `EdgeRepeat` | Mode, Strength | Edge sampling mode variation |
| `FieldToImage` | VectorField | Renders a vector field as an image |
| `KochKaleidoskope` | Iterations, Scale | Koch fractal kaleidoscope transformation |
| `PolarCoordinates` | Mode, Center | Cartesian ↔ polar UV mapping |
| `TimeDisplace` | History, Strength | Temporal displacement from a history buffer |

### fx/feedback/ — Temporal Feedback Effects

| Operator | Key Parameters | Notes |
|---|---|---|
| `AdvancedFeedback` | Displacement, Shade, BlurRadius, Zoom, Rotate, Twist, ShiftHue | Full recursive feedback with transform and color shift |
| `AdvancedFeedback2` | Similar to above, variant | Second variant with different internal pipeline |
| `AfterGlow` | Decay, Radius | Simple exponential glow decay feedback |
| `AfterGlow2` | Decay, Color | Variant of AfterGlow |
| `FluidFeedback` | Viscosity, Diffusion | Fluid-like distortion feedback |
| `SimpleLiquid` | Viscosity | Basic liquid distortion feedback |
| `SimpleLiquid2` | Viscosity, Turbulence | Turbulent liquid feedback variant |

### fx/glitch/ — Glitch and Corruption Effects

| Operator | Key Parameters | Notes |
|---|---|---|
| `GlitchDisplace` | Rate, Amplitude, TimeSpeed | Block-based displacement glitch |
| `RgbTV` | ScanLines, Noise, Skew | CRT television emulation |
| `SortPixelGlitch` | Threshold, Direction | Pixel sorting by luminance |
| `SubdivisionStretch` | Threshold, Stretch | Subdivision-based stretch corruption |

### fx/stylize/ — Artistic Stylization

| Operator | Key Parameters | Notes |
|---|---|---|
| `AsciiRender` | Font, CellSize, Brightness | Render image as ASCII art |
| `ChromaticAbberation` | Size, Strength, SampleCount, Distort | Lens chromatic aberration |
| `ColorPhysarum` | Agents, Decay, Speed | Physarum slime mold simulation |
| `DetectEdges` | SampleRadius, Strength, Color | Edge detection (Sobel-adjacent) |
| `Dither` | Threshold, Pattern | Ordered dithering for color reduction |
| `FakeLight` | Direction, Strength, NormalMap | Screen-space fake lighting from a bump map |
| `Glow` | Radius, Intensity, Threshold, Color, AmplifyCore | Artistic glow (simpler than Bloom) |
| `HoneyCombTiles` | Scale, Outline | Hexagonal tile stylization |
| `LightRaysFx` | Center, Samples, Decay, Weight | Screen-space light rays (god rays) |
| `MosiacTiling` | TileSize | Mosaic pixellation effect |
| `Pixelate` | BlockSize | Block-averaging pixelation |
| `ScreenCloseUp` | Center, Scale | Lens-like screen zoom |
| `StarGlowStreaks` | NumStreaks, Length | Star pattern glow streaks |
| `Steps` | Steps | Posterize / color quantization |
| `VoronoiCells` | Scale, Offset, Speed | Voronoi cell overlay |

### generate/ — Procedural Texture Generation

| Subdirectory | Operators |
|---|---|
| `basic/` | `Blob`, `BoxGradient`, `CheckerBoard`, `LinearGradient`, `NGon`, `NGonGradient`, `RadialGradient`, `RenderTarget`, `RoundedRect` |
| `fractal/` | `MandelbrotFractal` |
| `load/` | `ImageSequenceClip`, `LoadImage`, `LoadImageFromUrl` |
| `misc/` | `JumpFloodFill`, `Sketch`, `SlidingHistory`, `MunchingSquares2` |
| `noise/` | `FractalNoise`, `Grain`, `ShardNoise`, `TileableNoise`, `WorleyNoise` |
| `pattern/` | `FraserGrid`, `NumberPattern`, `Raster`, `Rings`, `RyojiPattern1`, `RyojiPattern2`, `SinForm`, `ValueRaster`, `ZollnerPattern` |

The noise operators all share the GPU implementations from `noise-functions.hlsl` (see companion document). `TileableNoise` and `FractalNoise` are the most general-purpose; `WorleyNoise` (cellular/Voronoi noise) is distinct from the simplex-based ones.

### analyze/ — Analysis and Signal Extraction

| Operator | Output Type | Purpose |
|---|---|---|
| `CompareImages` | `float` | Pixel-difference metric between two images |
| `DetectMotion` | `float` | Frame-to-frame motion energy |
| `GetImageBrightness` | `float` | Overall scene brightness scalar |
| `ImageLevels` | Histogram data | Level information for color grading reference |
| `OpticalFlow` | `Texture2D` | Per-pixel motion vector field |
| `RemoveStaticBackground` | `Texture2D` | Background-subtracted image |
| `WaveForm` | `Texture2D` | Luminance waveform visualization |

### transform/ — Image Geometry

| Operator | Key Parameters | Notes |
|---|---|---|
| `Crop` | Rect | Crop image to a sub-region |
| `MakeTileableImage` | Overlap | Mirror-blend edges for seamless tiling |
| `MakeTileableImageAdvanced` | Overlap, Angle | Advanced tileable with rotation |
| `MirrorRepeat` | Mode | Mirror-repeat sampling mode |
| `TransformImage` | Position, Scale, Rotation, Wrap | Full affine transform with wrapping |

### use/ — Compositing and Utility

| Operator | Key Parameters | Notes |
|---|---|---|
| `Blend` | ImageA, ImageB, BlendMode, AlphaMode | Layer blending with 9 RGB modes and 8 alpha modes |
| `BlendImages` | Images[], BlendMode | Multi-image blend |
| `BlendWithMask` | ImageA, ImageB, Mask | Mask-driven blend |
| `Combine3Images` | A, B, C, Modes | Three-way composite |
| `CombineMaterialChannels` | Albedo, Normal, ARM | Pack PBR channels into a single texture |
| `CustomPixelShader` | HLSL Source | Hot-reload custom HLSL pixel shader |
| `DepthBufferAsGrayScale` | DepthBuffer | Visualize depth buffer as grayscale |
| `FirstValidTexture` | Textures[] | Return first non-null texture |
| `Fxaa` | Preset, KeepAlpha | FXAA anti-aliasing |
| `KeepInTextureArray` | Index | Route texture into an array slot |
| `NormalMap` | SourceTexture, Strength | Generate normal map from heightmap |
| `PickTexture` | Textures[], Index | Select from a list by index |
| `RenderWithMotionBlur` | Passes, Strength | Accumulation motion blur |
| `SwapTextures` | A, B, Condition | Conditional texture switch |
| `UseFallbackTexture` | Primary, Fallback | Fallback if primary is null |
| `UseTextureReference` | Reference | Access a shared texture reference |

## The Blend Operator in Detail

`Blend` (`Operators/Lib/Symbols/image/use/Blend.cs`) is architecturally important because it demonstrates how tixl exposes the same blend modes as `blend-functions.hlsl` to graph users. The `RgbBlendModes` enum maps directly to the integer switch in `BlendColors()`:

| Enum Value | Integer | HLSL Case |
|---|---|---|
| `Normal` | 0 | Alpha composite |
| `Screen` | 1 | `1 - (1-A)(1-B)` |
| `Multiply` | 2 | `A * B` |
| `Overlay` | 3 | Light/dark conditional multiply |
| `Difference` | 4 | `abs(A - B)` |
| `UseImageA_RGB` | 5 | Pass A through |
| `UseImageB_RGB` | 6 | Pass B through |
| `Max` | 7 | `max(A, B)` |
| `Sub` | 8 | `A + B` (additive, labeled Sub in HLSL comments) |
| `MixUsingImageB_A` | 9 | Multiply alphas |

Alpha blending has an orthogonal set of modes: `Normal`, `Multiply`, `SetToOne`, `UseImageA_Alpha`, `UseImageB_Alpha`, `UseImageA_Brightness`, `UseImageB_Brightness`, `Additive`, `Max`.

The scale mode controls how mismatched resolutions are handled: `Stretch` (force both to output resolution), `Fit` (letterbox), `Cover` (crop to fill).

## How RenderTarget Feeds Post-Processing

The `RenderTarget` operator (`Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs`) is the source of all post-processing chains. Understanding its output pins clarifies what is available downstream:

| Output Pin | Type | Contents |
|---|---|---|
| `ColorBuffer` | `Texture2D` | MSAA-resolved color (HDR, configurable format) |
| `DepthBuffer` | `Texture2D` | Linearized depth (R32_Float after MSAA resolve) |
| `NormalBuffer` | `Texture2D` | World-space normals (R16G16B16A16_Float) |

The MSAA pipeline is handled automatically: when `Multisampling` is 2, 4, or 8, the internal render target is multisampled. After rendering, `ResolveSubresource()` collapses the samples to a single-sample texture before exposing the output pins. The depth buffer is resolved through a custom compute shader (`dx11/resolve-multisampled-depth-buffer-cs.hlsl`) because DirectX 11 does not natively resolve depth buffers the way it resolves color targets.

This means post-processing operators always receive clean single-sample textures, regardless of how many MSAA samples the scene used.

## Comparison with Other Frameworks

Understanding tixl's approach becomes clearer when set against alternatives.

**Three.js / WebGPU renderers** use an imperative `EffectComposer` pass list. Bloom, FXAA, and tone mapping are added in order to a list and processed sequentially. The pass order is a runtime concern managed in JavaScript code. Reordering requires code changes. Tixl's graph-based approach makes the same choices visible and interactive without touching code.

**Unreal Engine** uses a fixed post-processing stack with a well-defined order (Tonemapper → Bloom → Exposure → Depth of Field → etc.). Parameters are per-volume and blended spatially in the scene. The stack order is not user-configurable. Tixl trades this rigidity for full compositional freedom.

**Nannou (Rust/wgpu)** has no built-in post-processing system. Each effect is a user-authored render pass. This matches the "total control, zero convenience" philosophy of low-level graphics programming. Tixl occupies the opposite end: high-level, immediately composable operators at the cost of some transparency.

**Processing/p5.js** have fragment shader-based filters accessible via `filter()` calls, but with no explicit render target system. Post-effects are applied to the canvas inline. There is no multi-pass pipeline. Tixl's multi-pass bloom would require manual texture management that Processing does not expose cleanly.

The tixl design reflects its context as a live performance and VJing tool: operators that an artist can wire together in real time, inspecting intermediate results on each node, and reordering without recompiling anything.

## Key Design Patterns for a Future Rust Framework

Several patterns from tixl's post-processing system are worth carrying forward:

**Uniform image operator signature.** Every image op is `Texture2D → Texture2D`. This regularity enables composability. A Rust equivalent would be a trait: `trait ImageOp { fn apply(&self, input: &Texture, device: &Device) -> Texture; }`.

**Lazy resource initialization.** Tixl's bloom operator only allocates its texture pyramid when it first sees a valid input, and tears it down and rebuilds when resolution changes. This avoids allocation on node creation and handles dynamic resolution naturally.

**State save/restore around effects.** `D3D11StateBackup` saves and restores the full pipeline state before and after each post effect. A Rust equivalent would be a RAII guard that captures the relevant `wgpu::RenderPass` bindings and restores them on drop.

**Constant buffer structs with explicit layout.** Every shader parameter set is a C# struct with `[StructLayout(LayoutKind.Explicit)]` and explicit `[FieldOffset]` attributes, matching the HLSL constant buffer layout exactly. Rust with `bytemuck` can do this with `#[repr(C)]` and `Pod`/`Zeroable` derives.

**Level intensity distribution via gain/bias inversion.** The bloom level weighting uses bisection to invert the gain-bias curve rather than applying it directly. This is an elegant example of exposing a perceptual control (shape of the glow falloff) rather than raw per-level weights. Worth replicating for any multi-frequency effect.

---

Source files analyzed:
- `visual-programming/tixl/Operators/Lib/Symbols/image/fx/blur/Bloom.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/fx/_/_ExecuteBloomPasses.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/color/ToneMapping.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/color/ColorGrade.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/color/ColorGradeDepth.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/color/AdjustColors.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/color/ChannelMixer.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/use/Fxaa.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/use/Blend.cs`
- `visual-programming/tixl/Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/color-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/blend-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/dx11/fullscreen-texture.hlsl`
- All `Operators/Lib/image/*/` `.cs` files for catalog
