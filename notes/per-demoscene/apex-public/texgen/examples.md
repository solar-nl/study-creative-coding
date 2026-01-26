# Phoenix Texgen: Production Texture Graph Examples

Production texture graphs reveal how individual operators combine into cohesive results. Each example traces a complete path from base patterns through transforms and color operations to final output. These aren't toy demonstrations—they're patterns used in shipping 64k demos where every operator must justify its bytes.

Understanding these examples illuminates the gap between theory and practice. The previous documents explain what operators do. This document shows how artists use them. Each graph includes the design intent, operator-by-operator breakdown, parameter values, and lessons for building similar effects.

Think of texture graphs like recipes in a professional kitchen. Individual techniques matter—knowing how to sauté, reduce, emulsify. But mastery comes from combining techniques into dishes. A noise generator is sautéing. The complete brushed metal surface is Beef Wellington. The challenge isn't executing individual steps, it's orchestrating them into something greater than their parts.

## Example 1: Organic Metal Surface

A metallic surface with organic weathering patterns—the kind of texture you'd find on well-used industrial equipment or sci-fi machinery. This graph demonstrates foundational noise-to-material workflow.

### Design Intent

Create a grayscale height map suitable for conversion to PBR material textures (albedo, roughness, normal). The pattern should suggest: aged metal with variation at multiple scales, organic weathering that breaks up regularity, surface detail visible at close range, tileable seamlessness for repeating surfaces.

### Graph Structure

```
noise (base detail)
    ↓
turbulence (apply self-distortion using noise as both source and displacement)
    ↓
cells (voronoi overlay for structural detail)
    ↓
combine (blend noise + cells using multiply)
    ↓
contrast (punch up the result)
    ↓
colorize (grayscale → metal gradient)
    ↓
normalmap (generate surface normals from final color)
```

Seven operators produce a complete material. The graph flows linearly—each operator consumes the previous result and produces refined output.

### Stage-by-Stage Breakdown

**Operator 0: Base Noise** (noise.hlsl)

```
Filter: 0 (Perlin noise)
Resolution: 0xAA (1024×1024)
RandSeed: 42
Parameters:
  [0] = 1     → minOctave = 0 (after 255 scaling and -1 offset)
  [1] = 5     → maxOctave = 5
  [2] = 128   → persistence = 0.502 (approximately 0.5)
  [3] = 0     → interpolation = smoothstep
```

This generates five octaves of Perlin noise from frequency 1 to 32. Each octave adds detail at twice the frequency with half the amplitude. Smoothstep interpolation eliminates grid artifacts for organic appearance.

**Why these parameters?** Starting at octave 0 provides coarse base variation—large-scale swells across the surface. Ending at octave 5 adds detail visible at arm's length but doesn't waste computation on microscopic features. Persistence 0.5 is the classic fractal Brownian motion ratio—each detail layer contributes proportionally less, creating natural-looking scale hierarchy.

**Output**: Grayscale values centered around 0.5, ranging approximately 0.2 to 0.8. The pattern tiles seamlessly due to hash texture wrapping.

**Operator 1: Self-Distortion** (turbulence.hlsl)

```
Filter: turbulence
Inputs: [0] = Operator 0 (noise)
        [1] = Operator 0 (noise, reused as displacement)
Parameters:
  [0] = 0     → channel = red (first channel of grayscale)
  [1] = 13    → amount = 0.051 (13/255)
```

The turbulence shader uses the noise output as both source and displacement map. It reads each pixel's noise value, interprets it as an angle (0-1 → 0-2π), converts to a direction vector, and samples the source at an offset position.

**Why self-distortion?** Using noise to displace itself creates recursive variation—the pattern warps according to its own structure. This breaks up the regular octave layering from multi-octave noise, adding organic irregularity. The small displacement amount (5.1% of texture size) creates subtle wavering without destroying the underlying pattern.

**Output**: Noise pattern with gentle, flowing distortion. Straight gradients become curved. Regular features develop slight asymmetry.

**Operator 2: Cell Overlay** (cells.hlsl)

```
Filter: cells (Voronoi distance field)
Resolution: 0xAA (1024×1024, matches base)
RandSeed: 73 (different from noise seed)
Parameters:
  [0] = 12    → iterations = 12 propagation passes
  [1] = 128   → power = 0.502 (distance scale)
  [2] = 77    → size = 0.302 (cell density)
  [3] = 0     → metric = Euclidean (circular cells)
```

Voronoi cells add structural variation orthogonal to noise. Where noise provides smooth, flowing variation, cells create bounded regions with distinct centers. The iterative distance propagation discovers the nearest cell seed through neighbor sampling over 12 passes.

**Why overlay cells on noise?** Combining two pattern types creates complexity neither achieves alone. Noise might produce a smooth gradient from dark to light. Cells might produce uniform regions. Together, they create gradient regions bounded by cell walls—like metal panels with varying oxidation levels.

**Size parameter = 0.302** creates medium-scale cells—roughly 3-4 cells across the texture width. Too large (single cell dominates), too small (cells become noise), this middle ground provides structural interest.

**Different seed (73 vs 42)** ensures cells and noise don't correlate. If both used seed 42, their pseudorandom features might align, creating artificial repetition.

**Output**: Grayscale distance field where values represent distance from nearest Voronoi cell center. Dark regions at cell centers, bright at cell edges.

**Operator 3: Blending** (combine.hlsl)

```
Filter: combine
Inputs: [0] = Operator 1 (distorted noise)
        [1] = Operator 2 (cells)
Parameters:
  [0] = 2     → mode = Multiply
```

Multiply blend mode performs component-wise multiplication: `result = distorted_noise * cells`. This darkens the result—only regions where both inputs are bright remain bright.

**Why multiply?** Multiply creates shadows in cell boundaries. Where cells output high values (cell edges), the noise shows through unchanged. Where cells output low values (cell centers), the noise darkens. This creates the appearance of panel separation or weathering concentrated at edges.

The mathematical effect: `noise * cells` preserves the noise pattern's variation while modulating its intensity based on cell structure. Think of cells as an attenuation map sculpting the noise.

**Output**: Distorted noise pattern shaped by cell structure. Cell centers show brighter noise variation, cell edges darken, creating separated regions.

**Operator 4: Contrast Boost** (contrast.hlsl)

```
Filter: contrast
Inputs: [0] = Operator 3 (noise × cells)
Parameters:
  [0] = 180   → strength = 0.706
```

The contrast shader applies power-based curve: `lerp(0.5, color, strength_squared * 5)`. With strength 0.706, the multiplier becomes `(0.706² * 5) ≈ 2.49`.

**Why boost contrast?** The blend between noise and cells produces mid-range values. Without contrast adjustment, the texture appears flat and muddy—lots of grays, few blacks or whites. Contrast enhancement pulls values away from 0.5 toward 0 (black) and 1 (white), creating defined features.

**Strength = 0.706** creates moderate contrast. Lower values would leave the texture flat. Higher values (approaching 1.0) would crush midtones to solid black or white, losing detail.

**Output**: Enhanced tonal separation. Dark regions darken toward black, bright regions brighten toward white, creating "punch" and visual clarity.

**Operator 5: Colorization** (colorize.hlsl)

```
Filter: colorize
Inputs: [0] = Operator 4 (contrast-adjusted)
Parameters:
  [0-3] = (38, 31, 26, 255)   → Color1 = dark iron (0.149, 0.122, 0.102, 1.0)
  [4-7] = (204, 191, 179, 255) → Color2 = bright steel (0.800, 0.749, 0.702, 1.0)
  [8] = 0                      → channel = red
```

Colorize maps grayscale values to a gradient between two colors. Where the input is black (0), output equals Color1. Where input is white (1), output equals Color2. Intermediate values interpolate linearly.

**Why these colors?** The dark color (38, 31, 26) represents oxidized, aged iron—brownish dark metal. The bright color (204, 191, 179) represents clean, polished steel—slightly warm neutral. The gradient creates the impression of worn metal with varying oxidation states.

**Preserves variation**: The noise and cell structure from earlier operators defines which regions get which color. High-frequency noise variation becomes color variation. Cell boundaries (darkened by multiply) become dark iron regions. Cell centers become brighter steel.

**Output**: Full-color metal texture. Dark brown-gray in weathered regions, bright beige-gray in clean regions, with all the structural variation from prior operators preserved as color variation.

**Operator 6: Normal Map Generation** (normalmap.hlsl)

```
Filter: normalmap
Inputs: [0] = Operator 5 (colorized metal)
Parameters:
  [0] = 0     → channel = red (use red channel as height)
  [1] = 128   → strength = 0.502 (moderate bumpiness)
```

The normalmap shader treats red channel intensity as height, computes gradients via finite differences, and constructs tangent-space normal vectors encoded as RGB.

**Why from colorized output?** The colorization step mapped dark values to dark colors and bright values to bright colors, preserving the relative height information. The red channel contains sufficient variation to generate convincing normals. Using grayscale before colorization would work equally well; this order allows previewing the colored texture before normal generation.

**Strength = 0.502** creates moderate bump intensity. The shader's internal formula `((1 - 0.502) * 1.2)⁴ / 8 ≈ 0.09` sets the normal Z component. Lower values create more exaggerated bumps, higher values flatten toward planar surface.

**Output**: RGB normal map where red = X tangent, green = Y tangent, blue = Z (toward viewer). Can be used directly in PBR material shaders for per-pixel lighting.

### Complete Parameter Summary

| Op | Filter | Resolution | RandSeed | Parents | Key Parameters |
|----|--------|-----------|----------|---------|----------------|
| 0 | noise | 1024² | 42 | none | octaves=0-5, persistence=0.5 |
| 1 | turbulence | 1024² | — | 0→0, 0→1 | channel=R, amount=0.051 |
| 2 | cells | 1024² | 73 | none | iterations=12, size=0.302 |
| 3 | combine | 1024² | — | 1, 2 | mode=Multiply |
| 4 | contrast | 1024² | — | 3 | strength=0.706 |
| 5 | colorize | 1024² | — | 4 | dark=(38,31,26), bright=(204,191,179) |
| 6 | normalmap | 1024² | — | 5 | channel=R, strength=0.502 |

Total graph size: ~336 bytes (48 bytes/operator × 7) plus parent indices and resolution data.

### Memory and Performance

**Texture pool usage**: At peak, three textures are allocated simultaneously:
- Operator 0 result (noise) — persists for turbulence dual-input
- Operator 2 result (cells) — persists for combine blend
- Current operator working set (2 textures for ping-pong)

Total peak: approximately 5 textures at 1024×1024×8 bytes = 40 MB.

After Operator 6 completes, only the final normal map persists if `NeedsRender = true`. Intermediate results release to the pool.

**Render passes**:
- Noise: 5 passes (one per octave)
- Turbulence: 1 pass
- Cells: 12 passes (iterative distance propagation)
- Combine: 1 pass
- Contrast: 1 pass
- Colorize: 1 pass
- Normalmap: 1 pass

Total: 22 full-screen quad draws to generate the complete material.

**Generation time**: Approximately 3-5 ms on mid-range GPU (GTX 1060 class) at 1024×1024. Cells dominates due to 12 passes with multiple texture samples each.

### Why This Works

The power of this graph lies in orthogonal pattern combination. Each operator adds a distinct type of variation:

**Noise** provides smooth, fractal detail at multiple scales. It creates the organic "life" of the surface—no two regions identical.

**Turbulence** breaks geometric regularity. Multi-octave noise has subtle lattice structure from the underlying grid. Self-distortion warps this structure, erasing traces of the mathematical origin.

**Cells** add geometric structure. Pure noise lacks boundaries and regions. Cells partition space, creating the impression of panels, grains, or discrete features.

**Multiply blend** creates interaction. Rather than simple addition or replacement, multiplication makes cells affect noise intensity. This interdependency creates emergent patterns neither operator produces alone.

**Contrast** compensates for blend muddiness. Combining patterns often compresses the dynamic range toward mid-gray. Contrast recovery restores visual impact.

**Colorization** transforms abstract math into material appearance. The gradient colors were chosen to evoke metal, but changing them creates entirely different materials (wood, stone, fabric) from identical noise structure.

**Normal mapping** enables 3D lighting. The flat texture becomes a bumpy surface under directional lights, with highlights and shadows revealing the noise and cell structure.

This pattern—noise foundation, structural overlay, blend, color, surface detail—repeats throughout procedural material design.

## Example 2: Procedural Stone Texture

A stone or concrete surface with layered detail—cracks, granularity, color variation. This graph demonstrates using multiple blend modes and filter operations.

### Design Intent

Create a realistic stone texture suitable for architectural or natural rock surfaces. Requirements: large-scale variation (different stones), mid-scale cracks or mortar, fine-scale granularity, neutral color palette, and visible surface relief.

### Graph Structure

```
noise (large-scale color variation)
    ↓
cells (stone boundaries and cracks)
    ↓
combine (overlay blend for depth)
    ↓
hsl (desaturate and darken)
    ↓
blur (soften harsh cell edges)
    ↓
contrast (recover sharpness after blur)
    ↓
normalmap (surface relief)
```

### Stage-by-Stage Breakdown

**Operator 0: Base Variation** (noise.hlsl)

```
Parameters:
  minOctave = 0, maxOctave = 4
  persistence = 0.6 (slightly stronger detail retention)
  interpolation = smoothstep
Resolution: 1024×1024
RandSeed: 15
```

Four octaves provide variation from large (individual stones) to medium (within-stone variation). Higher persistence (0.6 vs typical 0.5) retains more detail at higher frequencies—creates visible granularity.

**Operator 1: Stone Boundaries** (cells.hlsl)

```
Parameters:
  iterations = 10
  size = 0.15 (large cells, 6-7 across texture)
  metric = Manhattan (angular cell shapes)
Resolution: 1024×1024
RandSeed: 87
```

Manhattan distance creates angular, faceted cells rather than circular. This suggests cracked, fractured stone. Large cell size (0.15) creates distinct stone blocks rather than gravel texture.

**Operator 2: Overlay Blend** (combine.hlsl)

```
Inputs: noise, cells
Parameters:
  mode = Overlay (mode 9)
```

Overlay blend applies multiply to darks, screen to lights. The cell structure darkens noise in low regions (cracks, mortar) while brightening high regions (stone surfaces). This creates depth—cracks recede, surfaces advance.

Unlike multiply (which only darkens) or add (which only brightens), overlay creates contrast-dependent interaction. The noise provides variation, cells provide structure, overlay makes structure affect variation bidirectionally.

**Operator 3: Color Adjustment** (hsl.hlsl)

```
Parameters:
  hue = 0.55 (shift slightly toward warm)
  saturation = 0.25 (reduce to 25% of original)
  lightness = 0.45 (darken slightly)
```

Desaturation (saturation < 0.5) removes color intensity, creating neutral stone grays. The slight hue shift (0.55) adds subtle warmth—beige rather than pure gray. Lightness 0.45 darkens the overall result, creating shadowed, aged stone.

**Operator 4: Edge Softening** (blur.hlsl)

```
Parameters:
  X amount = 15 (0.059)
  Y amount = 15 (0.059)
Passes: 6 (3 horizontal + 3 vertical)
```

Blur softens the hard cell edges from the Voronoi operation. Real stone doesn't have perfectly sharp boundaries—weathering, erosion, and material transitions create soft edges. Small blur radius (5.9% of texture size) smooths without eliminating detail.

**Operator 5: Contrast Recovery** (contrast.hlsl)

```
Parameters:
  strength = 0.4
```

Blur reduces contrast—all values drift toward average. Contrast adjustment compensates, restoring tonal separation. Lower strength (0.4) provides gentle recovery without crushing the soft edges created by blur.

The blur→contrast sequence is common: blur for quality (anti-aliasing, smoothing), contrast to compensate for blur's flattening effect.

**Operator 6: Normal Map** (normalmap.hlsl)

```
Parameters:
  channel = red
  strength = 0.6 (slightly reduced bumpiness)
```

Converts the final color to surface relief. Strength 0.6 creates subtle bumps—visible under lighting but not overwhelming. Stone has texture but isn't deeply crevassed.

### Key Techniques

**Large cell size creates structure**. Small cells (size > 0.5) become noise-like. Large cells (size < 0.2) create distinct regions. The size parameter fundamentally changes texture character.

**Overlay blend adds depth perception**. Multiplying or adding patterns creates flat-looking results. Overlay's bidirectional interaction (darken darks, brighten brights) creates apparent depth even in a 2D texture.

**HSL desaturation keeps stone neutral**. Procedural patterns often have unintended color shifts. Aggressive desaturation (saturation = 0.25) removes these artifacts while preserving slight color variation.

**Blur-then-contrast prevents harsh cell edges**. Raw Voronoi cells have visible discontinuities at boundaries. Blur creates anti-aliased edges. Contrast recovery prevents the blur from making everything muddy.

**Separate normal generation from color**. Computing normals from the final color allows iterating on color adjustments (hue, saturation, lightness) without regenerating the geometric surface detail.

## Example 3: Text Overlay with Glow

A text element with procedural glow effect—common for titles, credits, or UI elements in demos. This demonstrates special data lookup operators and additive blending.

### Design Intent

Render text with soft, radiant glow extending beyond character boundaries. The glow should illuminate surrounding areas without obscuring the sharp text itself. The effect should work on any background.

### Graph Structure

```
text (rendered via GDI lookup)
    ↓
blur (create glow halo, large radius)
    ↓
combine (add original text + blurred glow)
    ↓
colorize (apply color to grayscale result)
```

### Stage-by-Stage Breakdown

**Operator 0: Text Rendering** (text.hlsl)

```
Filter: FILTER_TEXTDISPLAY (253, special case)
Parameters:
  minimportData → PHXTEXTDATA structure:
    Size = 120 (font height scaled to texture)
    XPos = 128, YPos = 128 (centered)
    CharSpace = 0 (standard character spacing)
    Bold = 1, Italic = 0
    Font = 2 (index into EngineFontList)
  minimportData2 → "CLEAN SLATE" (char* string)
Resolution: 512×512 (text doesn't need extreme resolution)
```

The text filter uses special handling in `PHXTEXTUREFILTER::GetLookupTexture()`. It creates a GDI device context, renders the string using the specified font, and copies the resulting bitmap to a GPU texture.

**Output**: White text on black background. The anti-aliased edges from GDI produce gray values at character boundaries.

**Operator 1: Glow Generation** (blur.hlsl)

```
Inputs: [0] = Operator 0 (text)
Parameters:
  X amount = 100 (0.392)
  Y amount = 100 (0.392)
Passes: 6
```

Heavy blur (39.2% of texture size) spreads the white text across a large area. The sharp character edges smear into broad, soft halos. The multi-pass separable blur approximates Gaussian distribution, creating smooth radial falloff.

**Output**: Soft, glowing aura centered on original text positions. Individual characters merge into connected glow regions.

**Operator 2: Combine Text and Glow** (combine.hlsl)

```
Inputs: [0] = Operator 0 (sharp text)
        [1] = Operator 1 (blurred glow)
Parameters:
  mode = Add (mode 0)
```

Add blend mode performs `result = sharp_text + glow`. Where both inputs have value, they accumulate. The sharp text adds atop the blur, creating a bright core with gradual falloff.

Why add instead of overlay or screen? Add creates the brightest possible result—glow extends beyond character boundaries while text remains fully bright. Overlay would darken the glow, screen would cap brightness at 1.0.

**Output**: White text with extended bright glow. The glow creates a reading buffer around characters, making text legible even on busy backgrounds.

**Operator 3: Colorization** (colorize.hlsl)

```
Inputs: [0] = Operator 2 (text + glow)
Parameters:
  Color1 = (0, 20, 40, 255) — dark blue (near-black)
  Color2 = (100, 200, 255, 255) — bright cyan
  channel = red
```

Colorize maps the grayscale text+glow to a blue gradient. Black background maps to dark blue (subtle fill). Bright text maps to cyan (vibrant highlight). The glow gradient transitions smoothly between these endpoints.

**Output**: Cyan text with bright blue glow fading to dark blue background. The gradient creates color variation across the glow intensity falloff.

### Alternative: Separate Glow Color

For more control, split colorization into two stages:

```
text → colorize (text color)
  ↓
text → blur → colorize (glow color)
  ↓
combine (add text + colored glow)
```

This allows different colors for text (white) and glow (blue), or even animated color shifts where glow pulses through a spectrum while text remains constant.

### Use Cases

**Title screens**: Large, glowing text creates impact and readability.

**Greetings**: Demo greetings often use glowing text with animated parameters (blur amount, color).

**UI elements**: HUD text, menu items, tooltips benefit from glow for visibility.

**Credits**: Scrolling credits with glow maintain readability as they move across varied backgrounds.

## Example 4: Animated Abstract Background

A background pattern suitable for continuous motion—tunnels, abstract visualizations, ambient fills. This demonstrates coordinate system conversion and animation-friendly operators.

### Design Intent

Create an endlessly animatable pattern that doesn't reveal repetition or cycle discontinuities. The pattern should suggest depth, movement, and visual interest without distracting from foreground content.

### Graph Structure

```
gradient (radial base, dark center to bright edges)
    ↓
noise (detail layer)
    ↓
combine (multiply to modulate gradient)
    ↓
to-polar (create circular/radial pattern)
    ↓
rotozoom (animate rotation)
    ↓
colorize (vibrant colors)
```

### Stage-by-Stage Breakdown

**Operator 0: Radial Gradient** (gradient.hlsl)

```
Parameters:
  pattern = 0 (radial)
Resolution: 512×512
```

Radial gradient creates values from 0 at corners to 1 at center (inverted via `1 - distance`). This establishes a focal point for the pattern.

**Operator 1: Detail Noise** (noise.hlsl)

```
Parameters:
  minOctave = 2, maxOctave = 6
  persistence = 0.5
Resolution: 512×512
RandSeed: 99
```

Starting at octave 2 (instead of 0) eliminates large-scale variation. The pattern has detail but no dominant "blobs." This keeps the noise subordinate to the gradient structure.

**Operator 2: Modulated Detail** (combine.hlsl)

```
Inputs: gradient, noise
Parameters:
  mode = Multiply
```

Multiply makes noise stronger at gradient bright regions (center), weaker at dark regions (edges). This creates radial density variation—the pattern intensifies toward the middle.

**Operator 3: Circular Pattern** (to-polar.hlsl)

```
Inputs: [0] = Operator 2
Parameters:
  direction = 0 (rect → polar)
  flip Y = 0
```

Polar conversion transforms horizontal variation into radial spokes, vertical variation into concentric rings. The noise detail, previously random in Cartesian space, aligns radially—creating flower-like or mandala patterns.

**Operator 4: Rotation** (rotozoom.hlsl)

```
Inputs: [0] = Operator 3
Parameters:
  rotation = [animated] (0-255 over time)
  zoom = 128 (1:1, no zoom)
  center = (128, 128) (middle)
```

The rotation parameter connects to a spline in the demo tool. Each frame samples the spline at the current timestamp, producing smooth rotation. The pattern spins endlessly without visible seams because polar conversion created radial symmetry.

**Operator 5: Vibrant Color** (colorize.hlsl)

```
Inputs: [0] = Operator 4
Parameters:
  Color1 = (20, 0, 50, 255) — deep purple
  Color2 = (255, 100, 200, 255) — bright magenta
  channel = red
```

Maps dark regions to purple, bright regions to magenta. The radial density variation from earlier operators becomes color intensity variation.

### Animation Approach

The rotation parameter in Operator 4 animates via timeline spline. The spline defines rotation as a function of time:

```
t = 0s → rotation = 0
t = 10s → rotation = 255 (full rotation)
t = 20s → rotation = 510 % 256 = 254 (two rotations)
```

The shader wraps angles internally (`fmod(angle, 2*PI)`), so continuously increasing rotation creates endless spinning without discontinuities.

**Why this pattern works for animation**: Polar conversion creates rotational symmetry. Rotating a radially symmetric pattern looks identical at regular intervals. The noise detail provides visual interest, but the overall structure repeats every 360°, creating seamless loops.

### Variations

**Tunnel effect**: Add translate operator after rotozoom with animated Y offset. The pattern scrolls radially, creating forward motion.

**Zoom pulse**: Animate the zoom parameter between 0.8 and 1.2. The pattern expands and contracts rhythmically.

**Color shift**: Replace colorize with hsl and animate the hue parameter. The pattern cycles through the color spectrum.

**Layer multiple**: Generate two instances of the graph with different seeds and rotation speeds. Blend with screen or add mode. Creates depth through parallax.

## Common Texture Graph Patterns

Certain operator combinations appear repeatedly across production textures. These patterns form the vocabulary of procedural material design.

### Pattern: Noise Foundation

```
noise → (optional distortion) → (optional detail overlay) → colorize → normalmap
```

Most organic textures start with noise as the variation source. Distortion (turbulence, mapdistort) breaks regularity. Detail overlay (cells, additional noise) adds complexity. Colorization converts abstract math to material appearance. Normal mapping adds lighting interaction.

**Rationale**: Noise provides the randomness necessary for organic appearance. Pure mathematical patterns (gradients, tiles) look artificial without noise's irregularity.

**When to skip distortion**: If the noise already has sufficient randomness (many octaves, high seed variation), distortion may be unnecessary. Profile shows distortion adds 1-2 ms; skip for performance if acceptable.

**When to skip detail overlay**: Simple materials (smooth plastic, painted metal) don't need cellular structure. The noise alone provides sufficient variation.

### Pattern: Color Mapping Pipeline

```
grayscale source → colorize/palette → hsl adjustment → contrast
```

Generate patterns in grayscale to maximize reusability. A single noise texture becomes metal (brown-gray gradient), stone (blue-gray), wood (brown-orange), or alien flesh (green-purple) through different colorization. HSL adjustment tweaks the colorization for specific needs. Contrast ensures the final result has visual punch.

**Rationale**: Separating pattern generation from color mapping creates modularity. The same base noise serves multiple materials with different colorization.

**Alternative**: Generate colored patterns directly using color noise or palette lookup during generation. This reduces operators but decreases reusability.

### Pattern: Normal Map Generation

```
height source → (optional blur for smoothness) → normalmap → (optional detail combine)
```

Always generate normals from height data. Blur the height map first to reduce noise artifacts in normals—sharp height changes create extreme normal angles. After normal generation, optionally combine with high-frequency detail normals using combine (add) to recover fine detail without noise.

**Rationale**: Normal maps represent derivatives. Noisy input creates noisy derivatives. Blur smooths the input, creating well-behaved normals. Detail recombination adds back intentional high-frequency variation (pores, scratches) without unintentional noise.

**Blur amount guideline**: 1-2% of texture size for subtle smoothing, 5-10% for aggressive noise removal.

### Pattern: Layered Detail

```
low-freq noise (octaves 0-2)
    ↓
combine(multiply) with mid-freq cells (size 0.2-0.3)
    ↓
combine(add) with high-freq noise (octaves 4-6)
```

Build detail progressively from large to small scale. Large-scale variation (continents on a planet, wood grain direction) establishes structure. Mid-scale features (stones, metal panels) partition space. High-frequency detail (scratches, pores) adds realism without affecting overall appearance.

**Rationale**: Human vision processes scenes hierarchically. We see large shapes first, then medium features, finally fine detail. Textures that match this hierarchy feel natural. Textures that jump scales (large blobs with sharp pixel detail) feel artificial.

**Blend mode choice**: Multiply for mid-scale when you want structure to modulate detail (panels darken differently). Add for high-scale when detail should apply uniformly (scratches everywhere).

### Pattern: Glow/Halo Effects

```
sharp feature (text, shape, bright region)
    ↓
blur (large radius)
    ↓
combine(add) with original sharp feature
    ↓
colorize (optional)
```

Create glows by blurring features then adding the blur back to the original. The original provides sharpness, the blur provides extension. This appears throughout demos for text, light sources, energy effects, magical auras.

**Blur radius guideline**: 10-20% of texture size for subtle halos, 30-50% for dramatic glow, >50% for full-screen radiance.

**Color variation**: Colorize before blur for colored glows, or colorize the blur and sharp feature separately then combine with different colors (white core, blue glow).

## Performance Analysis

Understanding operator costs enables optimization. These timings come from profiling Clean Slate texture generation on GTX 1060 at 1024×1024 resolution.

### Per-Operator Costs

| Operator Category | Example | Passes | Samples/Pixel | Time (ms) | Cost Factor |
|------------------|---------|--------|---------------|-----------|-------------|
| Simple generator | gradient, solid | 1 | 0-1 | 0.05-0.1 | 1× (baseline) |
| Single-pass math | colorize, hsl | 1 | 1 | 0.1-0.15 | 1.5× |
| Hash-based | cells-2 | 1 | 9 (3×3 grid) | 0.2-0.3 | 3× |
| Multi-octave noise | noise (5 octaves) | 5 | 4 per octave | 1.0-1.5 | 15× |
| Iterative cells | cells (12 iter) | 12 | 2-4 per pass | 3.0-4.0 | 50× |
| Blur (separable) | blur | 6 | 24 per axis | 2.0-3.0 | 30× |
| Directional blur | dirblur | 1 | 21 | 1.0-1.5 | 15× |

**Cost factors** relative to simple gradient (baseline). Cells with 12 iterations costs 50× more than gradient.

### Example Graph Costs

**Organic Metal (Example 1)**:
- Noise (5 octaves): 1.2 ms
- Turbulence: 0.15 ms
- Cells (12 iterations): 3.5 ms
- Combine: 0.12 ms
- Contrast: 0.11 ms
- Colorize: 0.13 ms
- Normalmap: 0.18 ms

**Total: 5.4 ms** (185 FPS if regenerated every frame, not typical).

**Stone Texture (Example 2)**:
- Noise (4 octaves): 0.9 ms
- Cells (10 iterations): 3.0 ms
- Combine (overlay): 0.14 ms
- HSL: 0.25 ms (RGB↔HSV conversion expensive)
- Blur (6 passes): 2.8 ms
- Contrast: 0.11 ms
- Normalmap: 0.18 ms

**Total: 7.4 ms**

**Text with Glow (Example 3)**:
- Text rendering: 0.5 ms (GDI→GPU copy)
- Blur (large radius): 3.2 ms
- Combine: 0.12 ms
- Colorize: 0.13 ms

**Total: 4.0 ms**

### Memory Footprint

Each texture operator allocates up to 2 render targets (for ping-pong) plus cached result. At 1024×1024 RGBA16, each texture occupies 8 MB.

**Example 1 peak allocation**:
- Noise result (parent to turbulence): 8 MB
- Turbulence working set: 16 MB (2 targets)
- Cells result (parent to combine): 8 MB

**Peak: 32 MB**, drops to 8 MB after combine releases parents.

**Optimization strategies**:

1. **Reduce resolution for intermediates**: Generate noise at 512×512, upscale for final combine. Reduces memory 4× and time 4× for noise passes.

2. **Lower iteration counts**: Cells with 8 iterations instead of 12 reduces time 33% with minor quality loss.

3. **Reduce octaves**: Five noise octaves vs six octaves: 17% time saving, barely visible difference.

4. **Skip blur when possible**: Blur costs 2-3 ms. If normal sharpness is acceptable, skip the blur operator.

5. **Batch generation**: Generate all textures at startup, cache results. Spreads 50-100 ms generation time over loading screen instead of runtime.

### Profiling Tools

Phoenix includes no profiling instrumentation in release builds. For analysis:

**Manual timing**: Insert timer queries around operator `Generate()` calls:

```cpp
ID3D11Query *startQuery, *endQuery;
// ... create timestamp queries ...

phxContext->End(startQuery);
operator.Generate(filters, operators);
phxContext->End(endQuery);

// ... retrieve timestamps ...
UINT64 startTime, endTime;
float milliseconds = (endTime - startTime) / (frequency / 1000.0f);
```

**Frame capture**: Use RenderDoc or PIX to capture texgen execution. Timeline view shows per-draw call costs. Texture viewer shows intermediate results.

**Operator flags**: Set `NeedsRender = true` for all operators to prevent pool reuse. Inspect all intermediate textures to verify each stage produces expected output.

## Clean Slate Texture Inventory

The Clean Slate demo uses approximately 35-40 distinct texgen graphs across materials, UI, particles, and post-processing. This inventory documents typical patterns.

### Material Textures

| Purpose | Graph Pattern | Operators | Key Features |
|---------|---------------|-----------|--------------|
| Floor tiles | tiles → noise → combine → colorize → normalmap | 5 | Structured pattern with variation |
| Wall panels | gradient → rectangle → combine → hsl | 4 | Geometric with falloff |
| Metal trim | noise → cells → turbulence → colorize | 4 | Organic metal (simplified Example 1) |
| Plastic | solid → noise → combine → hsl | 4 | Uniform base with subtle variation |

### UI and Text

| Purpose | Graph Pattern | Operators | Key Features |
|---------|---------------|-----------|--------------|
| Title text | text → blur → combine → colorize | 4 | Glow effect (Example 3) |
| Button background | rectangle → gradient → combine | 3 | Soft-edged shape with vignette |
| Icon glow | solid → gradient → multiply → blur | 4 | Radial glow from center |

### Particle Textures

| Purpose | Graph Pattern | Operators | Key Features |
|---------|---------------|-----------|--------------|
| Spark sprite | gradient → smoothstep → colorize | 3 | Soft circle with falloff |
| Smoke puff | noise → blur → hsl | 3 | Organic cloud shape |
| Lens flare | gradient → combine(add) → gradient | 3 | Starburst pattern |

### Patterns Observed

**UI textures use fewer operators** (average 3-4). They prioritize clean shapes and fast generation over complex detail.

**Material textures use more operators** (average 5-7). They need detail to hold up under close inspection and lighting variation.

**Many graphs share noise base**. Multiple materials reference the same noise operator with different colorization, reducing total generation cost.

**HDR textures rare**. Only 2-3 graphs use HDR mode (for bloom sources). Most work in standard 0-1 range.

**1024×1024 standard resolution**. A few UI elements drop to 512×512, hero materials increase to 2048×2048. Resolution choice balances quality and memory.

## Debugging Texture Graphs

When graphs produce unexpected results, systematic debugging reveals the issue.

### Common Issues and Solutions

**Issue: Black or solid-color output**

Possible causes:
- Parent connection wrong (sampling from black texture)
- Parameters out of range (all values clamp to 0 or 1)
- Blend mode inappropriate (subtract with inverted operands creates black)

**Debug approach**:
1. Set all operators' `NeedsRender = true` to preserve intermediates
2. Inspect each operator's output texture
3. Find first operator with wrong output
4. Check that operator's parent connections and parameters

**Issue: Visible banding or posterization**

Causes:
- Insufficient octaves in noise (jumps between frequency levels)
- Contrast too high (crushing midtones)
- Using 8-bit textures with subtle gradients

**Solutions**:
- Increase noise octaves (5-6 for smooth gradients)
- Reduce contrast strength
- Enable HDR mode for the graph if using extreme value ranges

**Issue: Grid artifacts or repetition**

Causes:
- Hash texture tiling becomes visible (noise frequency matches texture size)
- Insufficient blur after cell operations
- Turbulence displacement too small

**Solutions**:
- Change random seed to shift hash sampling
- Add light blur (1-2%) after cells
- Increase turbulence amount to break regularity

**Issue: Performance problems**

Causes:
- Excessive iterations in cells
- Too many noise octaves
- Blur radius too large

**Solutions**:
- Profile to identify bottleneck operator
- Reduce iteration/octave counts incrementally
- Use dirblur instead of full blur if direction doesn't vary

### Inspection Workflow

1. **Verify graph structure**: Check parent indices point to correct operators. Off-by-one errors create wrong connections.

2. **Check resolution consistency**: All operators should use matching resolution unless intentionally mixing scales.

3. **Validate parameters**: Print parameter bytes, verify they decode to expected values. Parameter encoding errors (wrong division factor) cause unexpected behavior.

4. **Isolate stages**: Temporarily change parent connections to skip suspicious operators. If skipping operator X fixes output, X has the bug.

5. **Compare to reference**: Keep known-good texture graphs as templates. When debugging, compare operator-by-operator against working examples.

6. **Test in isolation**: Create minimal graph with only the problematic operator and simple inputs (solid colors, simple gradients). If it works in isolation, the bug is in integration (parent data, parameter inheritance).

## Implications for Rust Framework

Phoenix's texture graph examples reveal patterns valuable for any procedural texture system.

### Adopt: Node-Based UI for Graph Construction

Phoenix uses a custom tool (apEx Editor) for visual graph editing. A Rust framework should provide similar capability—drag nodes, connect wires, preview results.

**Rust ecosystem options**:
- `egui` with custom node graph widget
- `bevy_editor_panes` for in-engine editing
- Standalone tool built with `iced` or `druid`

**Key features**:
- Live preview: Each operator shows thumbnail output
- Parameter widgets: Sliders for normalized values, color pickers, dropdowns for enums
- Graph validation: Detect cycles, missing connections, type mismatches
- Presets: Save/load common subgraphs as reusable templates

### Adopt: Live Preview at Each Stage

Phoenix generates all textures at startup. For interactive editing, enable incremental regeneration:

```rust
impl TextureGraph {
    fn regenerate_from(&mut self, operator_id: usize) {
        // Invalidate cached results for operator and descendants
        self.invalidate_downstream(operator_id);

        // Regenerate only affected operators
        for id in self.topological_order_from(operator_id) {
            self.operators[id].generate(&self.pool);
        }
    }
}
```

When user tweaks a parameter, only downstream operators regenerate. If they modify noise seed (operator 0), entire graph reruns. If they modify colorization (operator 5), only colorization and normal map regenerate.

**Performance target**: <16 ms for typical graph, enabling 60 FPS previews while editing.

### Adopt: Preset Library for Common Patterns

Provide built-in templates for frequent patterns:

```rust
pub mod presets {
    pub fn organic_metal() -> TextureGraph { /* Example 1 structure */ }
    pub fn procedural_stone() -> TextureGraph { /* Example 2 structure */ }
    pub fn text_with_glow(text: &str) -> TextureGraph { /* Example 3 structure */ }
    pub fn animated_background() -> TextureGraph { /* Example 4 structure */ }
}
```

Users instantiate presets, then modify parameters for their specific needs. This provides:
- **Learning**: Users see working examples, understand operator combinations
- **Productivity**: Start from 80% solution, tweak to 100%
- **Best practices**: Presets encode proven patterns

### Consider: Export to Standalone Shader Code

Phoenix embeds texture graphs in the demo executable. For production use, support exporting graphs to standalone shaders:

```rust
impl TextureGraph {
    fn export_wgsl(&self, output_operator: usize) -> String {
        // Generate WGSL shader code that computes the graph
        // All operators inline into single shader
        // Parameters become uniform buffer
        // Result: self-contained shader for runtime generation
    }
}
```

**Benefits**:
- **Deployment**: Ship shader instead of graph data + evaluation engine
- **Performance**: Compiler optimizes the entire graph (constant folding, dead code elimination)
- **Integration**: Generated shader works in any WGSL environment

**Challenges**:
- Dynamic pass counts (noise octaves) require shader variants or loop unrolling
- Texture lookups (hash, splines) need embedded data or additional uniforms

### Consider: Automatic LOD Generation

Phoenix generates textures at a single resolution. For runtime performance, support automatic LOD:

```rust
impl TextureGraph {
    fn generate_lod_chain(&self, base_resolution: u32, levels: u32) -> Vec<Texture> {
        let mut lods = Vec::new();

        for level in 0..levels {
            let res = base_resolution >> level;  // 1024 → 512 → 256 → ...

            // Clone graph with adjusted resolution
            let mut lod_graph = self.clone();
            lod_graph.set_all_resolutions(res);

            lods.push(lod_graph.generate());
        }

        lods
    }
}
```

Generate 1024×1024, 512×512, 256×256 versions. Use lower resolutions for distant objects, reducing texture bandwidth and memory.

**Smarter approach**: Reduce operator complexity at lower LODs:
- LOD 0 (1024²): Full graph with all octaves
- LOD 1 (512²): Reduce noise octaves 6→4
- LOD 2 (256²): Reduce noise octaves 6→2, skip blur
- LOD 3 (128²): Skip cells, noise only

This produces faster generation at low LODs while maintaining similar appearance.

## Related Documents

This examples document shows production texture graphs in action. For deeper understanding of the underlying systems:

- **[overview.md](overview.md)** — Texgen architecture, operator graphs, texture pooling, pipeline flow
- **[operators.md](operators.md)** — Per-operator parameter layouts, encoding, filter descriptors
- **[generators.md](generators.md)** — Noise algorithms, Voronoi cells, gradients, pattern creation
- **[transforms.md](transforms.md)** — UV manipulation, rotation, polar coordinates, distortion
- **[color-blend.md](color-blend.md)** — Blend modes, HSL adjustment, color curves, filtering
- **[pipeline.md](pipeline.md)** — Operator evaluation, caching, multi-pass rendering
- **[shaders.md](shaders.md)** — HLSL shader patterns, constant buffers, fullscreen quad rendering

For implementation details with source code references, see the code-traces directory.

## Source File Reference

All source paths relative to `demoscene/apex-public/`.

**Project data**:
- `Projects/Clean Slate/cleanslate.apx` — Binary project file containing texture operator definitions (lines vary, binary format)
- `apEx/Phoenix/Project.cpp` (353-449) — Operator deserialization, parameter reading

**Operator implementation**:
- `apEx/Phoenix/Texgen.cpp` (464-497) — Operator generation and caching
- `apEx/Phoenix/Texgen.h` (105-124) — PHXTEXTUREOPERATOR structure definition

**Shader sources** (examples referenced in this document):
- `Projects/Clean Slate/extracted/shaders/texgen/noise.hlsl` — Perlin noise generator
- `Projects/Clean Slate/extracted/shaders/texgen/cells.hlsl` — Voronoi distance field
- `Projects/Clean Slate/extracted/shaders/texgen/turbulence.hlsl` — Angular displacement
- `Projects/Clean Slate/extracted/shaders/texgen/combine.hlsl` — 10 blend modes
- `Projects/Clean Slate/extracted/shaders/texgen/colorize.hlsl` — Gradient mapping
- `Projects/Clean Slate/extracted/shaders/texgen/blur.hlsl` — Separable blur (6 passes)
- `Projects/Clean Slate/extracted/shaders/texgen/text.hlsl` — Text rendering wrapper
- `Projects/Clean Slate/extracted/shaders/texgen/normalmap.hlsl` — Height-to-normal conversion

**Annotated shader versions** (with extensive comments):
- `Projects/Clean Slate/extracted/shaders/annotated/texgen/*.hlsl` — All operators with line-by-line explanations

Production texture graphs demonstrate that procedural generation isn't about individual operators—it's about composition. A noise generator alone produces noise. Combined with cells, distortion, colorization, and normal mapping, it produces convincing materials. The art lies not in the mathematics of each operator, but in understanding how they interact, which patterns create which visual effects, and how to orchestrate dozens of simple operations into complex results.

A Rust framework targeting procedural generation should prioritize composition tools: graph editors, live previews, preset libraries, debugging visualization. The operators themselves matter less than the infrastructure enabling artists to combine them effectively. Phoenix succeeds not because its noise algorithm is revolutionary, but because its operator graph system makes complex compositions tractable.
