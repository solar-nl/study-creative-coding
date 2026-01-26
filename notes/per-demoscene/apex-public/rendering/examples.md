# Clean Slate PBR Examples

Clean Slate, released at Revision 2017, showcases Phoenix's PBR pipeline through carefully crafted materials and lighting. This document examines specific production techniques, providing concrete examples of how the material system, shaders, and lighting work together.

Understanding these examples illuminates the gap between theory and practice. The previous documents explain *what* Phoenix can do. This document shows *how* artists use it. Each example includes the design intent, implementation details, and lessons for framework design.

## Material Inventory

Clean Slate uses approximately 15 distinct materials organized by visual purpose.

| Category | Materials | Technique |
|----------|-----------|-----------|
| Metals | Chrome sphere, Coin, Test metallic | High metalness, varying roughness |
| Dielectrics | Plastic sphere, Rubber | Low metalness, varying roughness |
| Special | Glitter sphere, Donut | Procedural normal perturbation |
| Environment | Floor, Background | Large-scale tiling, ambient contribution |
| Lights | Sphere lights | LTC or analytical area lights |
| Post-process | Bloom, Color grade | Full-screen effect passes |

Each material category demonstrates different aspects of the PBR system.

## Example 1: Chrome Sphere

The chrome sphere demonstrates ideal metal behavior—high metalness, low roughness, sharp reflections.

### Design Intent

Create a mirror-like metallic sphere that reflects the environment and area lights with sharp, coherent highlights.

### Material Configuration

```
Technique: PBR Pure Deferred
Layer: Solid Layer (G-Buffer)

Parameters:
  - Albedo texture: Solid white (255, 255, 255)
  - Metalness: 1.0 (texture alpha or modifier)
  - Normal texture: Flat (128, 128, 255 default)
  - Roughness: 0.05 (very low)
  - Roughness modifier: 0.5 (pass-through, no adjustment)
```

### G-Buffer Output

When the chrome sphere renders to the G-Buffer:

- **RT0.RGB**: White (1.0, 1.0, 1.0)
- **RT0.A**: 1.0 (full metalness)
- **RT1.RGB**: Sphere normal (varies per pixel)
- **RT1.A**: 0.05 (very smooth)

### Lighting Behavior

The lighting pass unpacks this as:
- **DiffuseColor**: (1, 1, 1) × (1 - 1) = (0, 0, 0) — no diffuse
- **SpecularColor**: lerp(0.04, (1, 1, 1), 1) = (1, 1, 1) — white specular

With roughness 0.05, the GGX distribution produces a tight, bright specular lobe. Area lights reflect as coherent shapes rather than diffuse blurs.

### Key Observations

1. **Pure specular**: Metalness 1.0 eliminates all diffuse contribution. The sphere only shows specular reflections.

2. **Roughness sensitivity**: At roughness 0.05, even small increases create visible highlight spread. The chrome material is at the extreme low end.

3. **Fresnel edge**: At grazing angles, the Fresnel term pushes reflectance toward 1.0. Chrome already starts at 1.0, so there's no visible edge brightening—it's uniformly reflective.

4. **Color from environment**: The sphere's apparent color comes entirely from reflected light. With white albedo, it reflects light colors unchanged.

## Example 2: Glitter Sphere

The glitter sphere demonstrates procedural normal perturbation for sparkling effects.

### Design Intent

Create a surface that sparkles with thousands of tiny, randomly-oriented facets, each catching light independently.

### Material Configuration

```
Technique: PBR Pure Deferred (modified)
Layer: Solid Layer

Parameters:
  - Albedo texture: Base color with metalness in alpha
  - Normal texture: High-frequency procedural noise
  - Roughness: 0.1-0.2 (low enough for visible highlights)
  - Normal perturbation: Extreme (noise → tangent space)
```

### Normal Mapping Strategy

The glitter effect comes from a normal map with extreme high-frequency variation:

```hlsl
// Conceptual: generating glitter normals
float3 glitterNormal = noise3D(worldPos * glitterScale);
glitterNormal = normalize(glitterNormal * 2 - 1);

// Perturb the geometric normal
float3 finalNormal = perturb_normal(geoNormal, worldPos, uv, glitterNormal);
```

Each pixel gets a semi-random normal direction. When this normal happens to align with the half-vector for a light, that pixel produces a bright specular highlight. Since the normals vary per-pixel, different pixels catch different lights at different angles—creating the sparkle effect.

### Key Observations

1. **Per-pixel variation**: The sparkle effect emerges from normal variation, not geometry. The sphere remains smooth; only shading creates the faceted appearance.

2. **Temporal stability**: With consistent noise (position-based, not random per-frame), sparkles stay in place as the camera moves. They appear to "flip" on and off as viewing angle changes, which matches real glitter.

3. **Roughness trade-off**: Lower roughness creates sharper sparkles but fewer visible at once. Higher roughness creates more visible but softer sparkles. Around 0.1-0.2 balances impact and coverage.

4. **Metalness choice**: Metallic glitter (metalness 1.0) produces colored sparkles from the albedo. Dielectric glitter (metalness 0.0) produces white sparkles with 4% reflectance. The demo uses metallic for more vibrant effect.

## Example 3: Coin Material

The coin demonstrates mixed metalness—metal surfaces with painted or tarnished regions.

### Design Intent

Create a coin with metallic unpainted areas and non-metallic painted/enameled details.

### Material Configuration

```
Technique: PBR Pure Deferred
Layer: Solid Layer

Parameters:
  - Albedo texture: Gold color in coin areas, paint color in details
  - Metalness texture: 1.0 in metal, 0.0-0.3 in painted areas
  - Normal texture: Coin relief, engravings
  - Roughness texture: Slight variation, ~0.3 overall
```

### Texture Authoring

The metalness texture is key. In image editing:
- White (1.0) for exposed metal surfaces
- Black/gray (0.0-0.3) for paint, enamel, tarnish
- Smooth gradients where paint transitions to metal

### Lighting Behavior

Mixed metalness creates two distinct shading regions:

**Metal areas (M ≈ 1.0)**:
- DiffuseColor ≈ 0
- SpecularColor = gold albedo
- Reflections tinted gold

**Painted areas (M ≈ 0.0)**:
- DiffuseColor = paint albedo
- SpecularColor = 0.04 (neutral specular)
- Diffuse-dominated appearance

The transition regions blend smoothly, creating natural-looking edges between materials.

### Key Observations

1. **Two looks, one material**: Mixed metalness achieves the look of two different materials (paint over metal) with a single shader and G-Buffer footprint.

2. **Normal map continuity**: The normal map spans both regions, providing surface detail that reads across the metalness boundary. Relief carvings show in both metal and painted areas.

3. **Roughness coordination**: Painted areas might have higher roughness (matte paint) or lower (glossy enamel). The roughness texture should coordinate with metalness for believable results.

## Example 4: Donut Material

The donut material suggests subsurface scattering through carefully tuned diffuse and ambient settings.

### Design Intent

Create a soft, organic-looking material that hints at subsurface light transport without implementing full SSS.

### Material Configuration

```
Technique: PBR Pure Deferred
Layer: Solid Layer

Parameters:
  - Albedo texture: Warm base color (beige/brown)
  - Metalness: 0.0 (pure dielectric)
  - Normal texture: Subtle bumpiness
  - Roughness: 0.5-0.7 (moderately rough)
  - Ambient contribution: Elevated
```

### Subsurface Approximation

Phoenix doesn't implement true subsurface scattering. Instead, the donut material fakes it:

1. **High ambient**: Elevated ambient contribution fills shadow areas with warm color, simulating light scattering through the material.

2. **Soft normals**: Gentle normal variation avoids harsh shadow boundaries that would break the soft look.

3. **Diffuse-dominated**: Zero metalness and moderate roughness keep the material firmly in diffuse territory, where soft lighting reads as organic.

4. **Warm color**: The beige/tan albedo naturally suggests translucent materials like dough, skin, or wax.

### Key Observations

1. **Ambient as SSS proxy**: For materials that "glow" in shadow areas, simply elevating ambient contribution approximates subsurface scattering visually.

2. **Roughness hides lack of SSS**: Rough surfaces blur specular reflections that would otherwise look too hard for organic materials. The diffuse-roughness combination reads as "soft" without explicit SSS.

3. **Lighting design**: The scene's lighting emphasizes the material's softness. Rim lights and fill lights positioned to minimize harsh shadows complement the material design.

## Example 5: Emissive Material

Clean Slate uses emissive materials for glowing elements, light sources, and UI highlights.

### Design Intent

Create self-illuminating surfaces that glow independently of scene lighting while still integrating with reflections.

### Material Configuration

```
Technique: PBR Mixed Rendering
Layer: Solid Layer

Parameters:
  - Albedo texture: Base color + metalness (slot 0)
  - Normal texture: Normal + roughness (slot 1)
  - Emissive texture: Glow color + alpha mask (slot 2)
  - Shadow threshold: Controls alpha cutout sensitivity
```

### Emissive Texture Layout

| Channel | Purpose |
|---------|---------|
| RGB | Emissive color and intensity |
| Alpha | Cutout mask (< threshold = discard) |

### Shader Integration

The mixed rendering shader initializes light accumulation with the emissive value:

```hlsl
// Sample emissive texture
float4 emissiveMap = t_2.Sample(Sampler, v.uv.xy);

// Alpha cutout
if (shdw.y < emissiveMap.w)
    discard;

// Initialize with emissive, then add lighting
float3 Lo = emissiveMap.xyz;
for (int i = 0; i < lightcount; i++) {
    Lo += CalculateBRDF(...) * radiance * NdotL;
}

// Output lit color AND G-Buffer data
p.c  = float4(Lo, 1.0);
p.am = float4(albedo.xyz, metallic);
p.nr = float4(N, roughness);
```

### Key Observations

1. **Self-illumination**: Emissive adds directly to output before the lighting loop. Even in complete darkness, emissive surfaces glow.

2. **G-Buffer participation**: Despite forward lighting, the material writes G-Buffer data. Other surfaces can reflect this material correctly via deferred passes.

3. **Alpha cutout**: The emissive alpha channel enables complex shapes—text, patterns, decals—without geometry. The `shdw.y` parameter provides animated threshold control.

4. **HDR ready**: Emissive values can exceed 1.0 for bloom and HDR effects. The RGB channels directly encode intensity, not clamped to display range.

5. **Texture-driven animation**: Animating the emissive texture (or using procedural generation) creates pulsing, flowing, or flickering effects without shader changes.

### Use Cases in Clean Slate

- **Light source geometry**: Visible sphere lights use emissive to represent the glowing source
- **UI elements**: Text and interface elements use emissive for visibility regardless of scene lighting
- **Accent lighting**: Glowing details on objects (LEDs, screens, indicators)
- **Alpha-masked decals**: Complex shapes that need cutout without transparent sorting

## Example 6: Area Light Sphere

Clean Slate uses physical area lights extensively. The lighting materials demonstrate both LTC and analytical approaches.

### Design Intent

Create soft, physically plausible light sources with visible light shapes and proper falloff.

### LTC Light Configuration

```
Technique: Area Sphere Light LTC
Layer: Lighting Layer

Parameters:
  - Light color: Variable (animated)
  - Light radius: Physical sphere size
  - LTC1 texture: Matrix lookup (slot 6)
  - LTC2 texture: Magnitude/Fresnel lookup (slot 7)
```

### LTC Workflow

The lighting shader:

1. **Discretizes the sphere** into a 24-vertex polygon approximating the visible disc
2. **Transforms the polygon** using the LTC matrix sampled from roughness/viewing angle
3. **Clips to horizon** removing vertices below the surface plane
4. **Integrates edges** using the closed-form cosine integral
5. **Modulates by Fresnel** for specular contribution

### Analytical Light Configuration

For smaller lights or rougher surfaces, the analytical approximation suffices:

```
Technique: Area Sphere Light Non-LTC
Layer: Lighting Layer

Parameters:
  - Light color: Variable
  - Light radius: Physical sphere size
  - No LTC textures required
```

### Choosing LTC vs. Analytical

| Condition | Recommendation |
|-----------|---------------|
| Large sphere, low roughness | LTC (accurate reflections) |
| Small sphere, high roughness | Analytical (cheaper, sufficient quality) |
| Many lights | Analytical (lower per-light cost) |
| Close-up hero shot | LTC (maximum quality) |

### Key Observations

1. **Soft shadows from size**: Area lights naturally produce soft shadow edges proportional to their angular size. Larger lights (or closer lights) create softer shadows.

2. **Specular shape**: With LTC, specular reflections of sphere lights appear as circular/elliptical shapes on glossy surfaces. Analytical approximation blurs this into a bright spot.

3. **Energy conservation**: Both methods ensure the total light contribution respects energy conservation. Larger lights don't become infinitely bright.

## Technique Composition Patterns

### Multi-Pass Materials

Some Clean Slate materials use multiple passes for complex effects.

**Pattern: G-Buffer + Emissive**
```
Technique 1: PBR Pure Deferred (Solid Layer)
  - Writes albedo, normal, roughness, metalness
  - Standard G-Buffer generation

Technique 2: Additive Emissive (Lighting Layer)
  - Reads emissive texture
  - Adds glow without PBR calculations
```

**Pattern: Shadow + G-Buffer**
```
Technique 1: Shadow Only (Shadow Layer)
  - Writes depth only
  - No color output

Technique 2: PBR Pure Deferred (Solid Layer)
  - Full G-Buffer output
  - Separate pass for main rendering
```

### Render Priority Usage

Within a layer, render priority controls draw order.

```
Priority 0: Sky dome (draw first, behind everything)
Priority 100: Opaque geometry (standard)
Priority 200: Decals (after geometry, before transparency)
Priority 900: Transparent objects (sorted back-to-front within this range)
Priority 1000: HUD/overlay (draw last)
```

Clean Slate uses careful priority assignment to ensure correct compositing without explicit sorting code.

## Frame Breakdown

A typical Clean Slate frame executes these passes:

### Pass 1: Shadow Map
- **Target**: Shadow Map RT (depth only)
- **Content**: All shadow-casting geometry
- **Purpose**: Generate shadow depth for key light

### Pass 2: G-Buffer Generation
- **Target**: Main RT + Albedo+Metal RT + Normal+Rough RT
- **Content**: All opaque geometry with PBR materials
- **Purpose**: Capture surface properties for deferred lighting

### Pass 3: Deferred Lighting
- **Target**: Main RT (additive)
- **Content**: Full-screen quad per light
- **Purpose**: Accumulate lighting contributions
- **Lights**: 4-8 area lights, each a separate draw

### Pass 4: Ambient/IBL
- **Target**: Main RT (additive)
- **Content**: Full-screen quad
- **Purpose**: Add ambient fill lighting

### Pass 5: Transparent Objects
- **Target**: Main RT (alpha blend)
- **Content**: Any transparent materials (particles, glass)
- **Purpose**: Forward-shade transparency over lit scene

### Pass 6: Post-Processing
- **Target**: Ping-pong between RTs
- **Content**: Full-screen effects
- **Passes**: Bloom extraction → blur → combine → color grade → output

Total draw calls: ~50-100 depending on object count and light count.

## Experimentation Guide

For artists exploring Phoenix's PBR system, here are experiments that reveal material behavior.

### Roughness Sweep

Create a row of spheres with roughness 0.0, 0.25, 0.5, 0.75, 1.0. Observe:
- Specular highlight size and intensity
- Reflection sharpness with area lights
- Fresnel edge visibility

### Metalness Comparison

Create pairs of spheres with identical roughness but metalness 0 vs 1. Observe:
- Diffuse vs. specular balance
- Reflected light color (neutral vs. albedo-tinted)
- Edge brightness (strong Fresnel on dielectric, weak on metal)

### Normal Map Intensity

Animate normal map intensity from 0 to 2×. Observe:
- Surface detail appearance
- Specular highlight breakup
- Silhouette (unchanged—normals don't affect geometry)

### Area Light Size

Create identical materials lit by sphere lights of increasing radius. Observe:
- Highlight size and softness
- Shadow edge softness
- Total illumination (energy-conserved: larger isn't brighter)

## Example 7: Particle System

Clean Slate uses a dedicated particle rendering system for atmospheric effects like sparks, dust, and glows.

### Design Intent

Render thousands of billboard sprites efficiently with per-particle color, size, and rotation that vary over the particle's lifetime.

### Default Particle Configuration

```
Technique: Default Particle
Type: Particle
Layer: Transparent Layer

Parameters:
  - Texture: Sprite texture (soft gradients, sparks)
  - RGBA + Size: Lifetime curves (via ParticleLifeFloat)
  - Chaos variants: Per-particle randomization
  - Alpha Test: Threshold for cutout
```

### Rendering Pipeline

The particle shader uses a geometry shader to expand point primitives into camera-facing quads:

```hlsl
// Vertex shader: Transform particle position to view space
VSOUT v(VSIN x)
{
    VSOUT k;
    k.Position = mul(viewmat, x.Position);  // View space

    // Sample lifetime curves with per-particle chaos
    k.Color.x = pdatachaos(0, 5, x.Data.z, x.Data.x);  // Red + chaos
    k.Color.y = pdatachaos(1, 6, x.Data.z, x.Data.x);  // Green + chaos
    // ... size, alpha similarly
    return k;
}

// Geometry shader: Expand point to rotated quad
[maxvertexcount(4)]
void g(point VSOUT input[1], inout TriangleStream<GSOUT> OutputStream)
{
    float r = 0.1 * input[0].Data.y;  // Rotation angle
    float4 x = float4(sin(r), cos(r), 0, 0);
    float4 y = float4(-x.y, x.x, 0, 0);

    // Emit 4 vertices forming a rotated quad
    vx[0].Position = mul(projmat, p + (-x-y) * scale);
    vx[0].UV = float2(1, 1);
    // ... remaining corners
}
```

### Lifetime Curve System

Particle properties animate via 2048×N lookup textures where each row is a different property:
- Row 0-3: RGBA color components
- Row 4: Size
- Row 5-9: Chaos modifiers (added randomization)
- Row 10: Alpha test threshold

The `pdatachaos` function adds deterministic noise based on particle ID:

```hlsl
float pdatachaos(int id, int cid, float c, float l)
{
    return pdata(id, l) + pdata(cid, l) * GetNoise(c + cid);
}
```

### Point Sprite Variant

For simpler effects, `pointsprites.hlsl` converts triangle meshes to billboards:

```hlsl
// Geometry shader averages triangle vertices for centroid
float4 p = (input[0].Position + input[1].Position + input[2].Position) / 3.0f;

// Offset along face normal
float3 n = cross(a, b);
p += float4(n, 0) * offset;

// Emit camera-facing quad
```

This technique places sprites at mesh face centers—useful for glowing point decorations on geometry.

### Key Observations

1. **Geometry shader expansion**: Point → quad expansion happens on GPU, avoiding CPU vertex generation for thousands of particles.

2. **Curve-driven properties**: All visual parameters come from texture lookups, enabling complex behaviors (grow-shrink, color shifts) without shader changes.

3. **Chaos for variety**: Deterministic per-particle randomization prevents particles from looking identical while maintaining reproducible results.

4. **Transparent layer**: Particles render after deferred lighting, blending over the lit scene. No G-Buffer participation—particles don't receive reflections.

## Example 8: Wireframe Material

Clean Slate includes a wireframe material for debug visualization and stylized effects.

### Design Intent

Render mesh edges as smooth, controllable-width lines with optional animated reveal.

### Configuration

```
Technique: Wireframe
Layer: Solid Layer

Parameters:
  - Color: Line color (animated)
  - Width: Line thickness (screen-space)
  - Contrast: Edge softness
  - Animation: Reveal progress (0-1)
  - Animation Control Texture: Per-vertex reveal timing
```

### Geometry Shader Approach

Unlike typical wireframe modes (rasterizer state), this shader generates actual geometry from lines:

```hlsl
[maxvertexcount(6)]
void g(line VSOUT input[2], inout TriangleStream<GSOUT> OutputStream)
{
    // Calculate animated clip point
    float tc = saturate((t.x - avgAnim) / 0.05);
    float4 p2 = lerp(p1, p2, tc);  // Partially reveal edge

    // Screen-space perpendicular for line width
    float2 d = normalize((p2/p2.w).xy - (p1/p1.w).xy);
    float4 n = float4(-d.y, d.x, 0, 0) * width * 0.05;

    // Emit two triangles forming a quad
}
```

### Animated Reveal

The animation texture stores per-vertex reveal timing. Combined with the global animation parameter, edges appear progressively—creating a "drawing" effect as geometry reveals.

### Key Observations

1. **Geometry shader lines**: Takes `line` primitive input (not triangles), enabling true edge rendering.

2. **Screen-space width**: Line width specified in screen pixels, not world units—lines stay readable regardless of distance.

3. **Soft edges**: The `pow(abs(1-abs(v.t)), contrast)` falloff creates anti-aliased line edges without MSAA.

## Lessons for Framework Design

These production examples reveal practical requirements for creative coding frameworks.

### Material Presets

Provide preset materials for common looks: chrome, gold, plastic, rubber, skin. Artists start from presets and modify, rather than building from scratch.

### Visual Debugging

Visualize G-Buffer channels (albedo-only, normal-only, roughness-only views). When materials look wrong, seeing intermediate values identifies the problem.

### Live Parameter Tuning

Enable real-time parameter adjustment. The difference between roughness 0.3 and 0.35 is subtle. Artists need immediate feedback to find the right values.

### Reference Matching

Provide tools to match reference photographs. Import a photo, overlay the render, adjust parameters until they match. This grounds abstract parameters in real-world targets.

### Lighting Consistency

Scene lighting dramatically affects material appearance. Provide consistent studio lighting for material authoring, separate from production lighting. This ensures materials look right before lighting artists adjust the scene.

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture
- **[materials.md](materials.md)** — Material parameter system
- **[shaders.md](shaders.md)** — BRDF implementation
- **[lighting.md](lighting.md)** — Area lights and shadows
- **[deferred.md](deferred.md)** — G-Buffer pipeline
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — Implementation trace

## Source References

Clean Slate project (`Projects/Clean Slate/cleanslate.apx`):

| Section | Lines | Purpose |
|---------|-------|---------|
| Materials | 44000-46000 | Material definitions |
| Render layers | 41457-41497 | Pass configuration |
| Scene objects | 47000+ | Object placement and animation |

Material analysis based on shader code and render layer configuration. Specific material parameters may vary from described values—these examples illustrate patterns rather than exact replication.
