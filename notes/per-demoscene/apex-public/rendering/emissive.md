# apEx Emissive Materials

Emissive materials in Phoenix are both more and less than they appear. Visually, they're the brightest objects in the scene — glowing spheres, self-lit surfaces, and the cores of area lights. Architecturally, they're self-contained: an emissive surface illuminates only itself. It doesn't bounce light onto nearby walls, doesn't cast colored light onto the floor, doesn't contribute to the global illumination of the scene. The brightness you see is a local property, not a light source.

This is the core tension the user spotted: "just having bright spheres that only interact with themselves is kinda meh." And it's architecturally correct. Phoenix's emissive system is designed for a specific visual result in a choreographed 64k demo, not for physically accurate light transport. The trick is that Phoenix compensates for this limitation through three indirect mechanisms — screen-space reflections, bloom, and G-Buffer compositing — that together create the *illusion* of emissive surfaces influencing their surroundings without the cost of actual indirect illumination.

## Mixed Rendering: The Emissive Mechanism

Emissive capability exists exclusively in Phoenix's **mixed rendering** path — a hybrid forward+deferred technique that is the engine's most complex material shader. Pure deferred materials (`pbr-pure-deferred.hlsl`) cannot emit light at all; they write only G-Buffer data with no forward-lit color output.

The distinction is fundamental:

| Property | Pure Deferred | Mixed Rendering |
|----------|--------------|-----------------|
| Render targets | RT1 (albedo+metalness), RT2 (normal+roughness) | RT0 (lit color), RT1 (albedo+metalness), RT2 (normal+roughness) |
| Lighting | Deferred only (separate pass) | Forward + deferred |
| Emissive | Not supported | Emissive texture initializes radiance |
| Reflection mask | Not written (RT0 untouched) | Alpha = 1.0 enables SSR |
| Texture slots | t0 (albedo), t1 (normal) | t0 (albedo), t1 (normal), t2 (emissive), t3 (shadow map) |

The mixed rendering shader writes to three render targets simultaneously via MRT (Multiple Render Targets). This is the key: it performs forward lighting (including emissive) and writes the result to RT0, while *also* writing G-Buffer data to RT1 and RT2 so that deferred lighting passes can add additional contributions later.

## Emissive in the Light Loop

The emissive contribution enters the lighting calculation at a specific, deliberate point:

```hlsl
// Start the light accumulator with emissive
float3 Lo = emissiveMap.xyz;

// Then add direct light contributions
for (int i = 0; i < lightCount[0]; ++i)
{
    // ... Cook-Torrance BRDF evaluation ...

    float NdotL = max(dot(N, L), 0.0);
    if (i == 0)
        NdotL *= shadow;  // Shadow only on primary light

    Lo += (kD * albedo.xyz / PI + specular) * radiance * NdotL;
}

// Write to render targets
output.radiance = float4(Lo, 1.0);
output.albedoMetalness = float4(albedo.xyz, metallic);
output.normalRoughness = float4(N, roughness);
```

The emissive texture (register `t2`) provides both the emissive color (RGB) and an alpha mask (A). The alpha channel serves double duty: it's used for alpha testing (`if (shdParams.y < emissiveMap.w) discard;`), enabling cutout geometry like foliage or decals, while the RGB channels initialize `Lo` before any light contributions.

This design means:

1. **Emissive is additive to direct lighting** — a surface can be both emissive and receive light from scene lights. The emissive color and direct lighting accumulate in `Lo` together.

2. **Emissive has no special falloff** — the emissive texture value is the final contribution. There's no distance attenuation, no inverse-square law. The texture's brightness *is* the emissive brightness. Artists control intensity by painting brighter textures.

3. **Emissive bypasses the BRDF entirely** — it adds directly to `Lo` without going through Cook-Torrance. This is physically correct: emission is radiance leaving the surface independent of viewing angle, while the BRDF describes how incoming light is reflected.

## Emissive Texture Bindings in Clean Slate

The `material_instances.json` file reveals exactly which objects bind emissive textures in Clean Slate. The emissive slot (`t2`, formally named "Emissive Map (Alpha is alpha)") appears in over 30 material instances — but the slot's dual-purpose `RGB=emissive, A=alpha` format means roughly half of those bindings use it primarily for alpha masking, not for glow.

### Genuinely Emissive Objects

These objects bind dedicated emissive textures with meaningful RGB content — surfaces that actually glow:

| Object | Emissive Texture | Visual Role |
|--------|-----------------|-------------|
| Zebra | `zebra/emissive` | Glowing pattern on zebra stripes |
| Card | `card/emissive` | Self-lit playing card elements |
| Bandloop | `bandloop/emissive` | Glowing band loop geometry |
| Balloon | `balloon/emissive` | Self-lit balloon surface |
| Popcorn kernels | `popcorn/popcornemissive` | Glowing kernels |
| Popcorn box | `popcorn/poopcornboxemal` | Box glow (note the typo in the texture name) |
| License plate | `license plate/emissive` | Self-lit plate text |
| CNS Logo (line) | `CNS Logo Parts/line` | Conspiracy logo edge glow |
| CNS Logo (blue) | `CNS Logo Parts/blue` | Logo blue accent |
| CNS Logo (line2) | `CNS Logo Parts/line2` | Logo secondary line glow |
| CNS Logo (white) | `CNS Logo Parts/white` | Logo white highlight |
| BoyC's Borg | `BoyC's Stuff/borg lights` | Light pattern on BoyC's model |

The CNS (Conspiracy) logo is the most emissive-heavy object in the demo — four separate material instances, each with different emissive textures for different parts of the logo. This makes the group branding moment the brightest, most visually prominent emissive display in Clean Slate.

### Alpha-Only Slot Usage

Many material instances bind textures to the emissive slot purely for the alpha channel. The RGB is black or negligible — no visible glow — while the alpha drives cutout geometry:

| Object | Texture | Purpose |
|--------|---------|---------|
| Reel-to-reel | `reel2reel/reelalpha` | Tape reel cutout shape |
| Cassette (×2) | `casette/tapealpha` | Tape cutout |
| Floppy disk | `BoyC's Stuff/floppy alpha` | Disk silhouette |
| Floppy center | `BoyC's Stuff/floppy center alpha` | Center label cutout |
| BoyC's cards (×4) | `BoyC's Stuff/Card Alpha` | Card shape cutout |
| Butterfly | `butterfly/wing_alpha` | Wing transparency |
| Donut | `donut/alpha` | Donut shape mask |
| Tile dissolve | `tile dissolve/tile dissolve` | Animated dissolve effect |
| Background stripes (×3) | `bglines/stripe dissolve` | Stripe dissolve animation |
| Dissolve sphere | `colors & gradients/red dissolve` | Red dissolve transition |
| Globe | `globe/globe` | Globe texture mask |
| Record label | `record label/record label` | Label shape |

This dual-purpose pattern is a classic demoscene texture slot optimization. The emissive map format `RGB=emissive, A=alpha` lets one texture slot serve two independent functions. Materials that need alpha cutouts but no glow bind a mask texture — the dark RGB contributes nothing to `Lo`, but the alpha channel drives the `discard` test. Materials that need glow bind a bright RGB texture. Some materials need both (the CNS logo glows *and* has cutout alpha).

### Texture Reuse Patterns

Two notable reuse patterns appear in the bindings:

**License plate uses the same texture as both albedo and emissive.** The material binds `license plate/emissive` to *both* the `albedo_metalness` slot (t0) and the `emissive_alpha` slot (t2). The entire surface is self-lit — the plate text is both the base color and the glow source. This is efficient (one texture, two purposes) and makes the license plate text read clearly regardless of scene lighting.

**Procedural emissive textures.** The `emissive-alpha.json` texture definition shows these aren't bitmaps. They're built from apEx's procedural texture generator using operator chains:

```
Gradient → Rectangle → Loop → Invert → Colorize
```

The two named outputs — `emissive alpha/line` and `emissive alpha/stripes` — are generated at runtime from ~240 bytes of operator definitions rather than stored as image data. These procedural patterns serve as both emissive glow and alpha masks for generic mixed-rendering materials. This is a key 64k optimization: procedural textures save executable bytes while providing resolution-independent results.

### Material Techniques That Support Emissive

Only two material techniques in `materials.json` support the emissive texture slot:

| Technique | GUID | Emissive Support |
|-----------|------|-----------------|
| `[PBR Mixed Rendering]` | `E398C0C938180A8EE97E87517E6E986B` | Yes — t2 emissive |
| `[PBR Mixed Rendering with vertex offset]` | `AECBA6264493E2316649DA3F4DF38344` | Yes — t2 emissive |

All other techniques (pure deferred, area lights, particles, wireframe, mapped fresnel, colored texture) lack the emissive slot entirely. This confirms that emissive capability is exclusive to the mixed rendering path.

## The Reflection Mask

The `1.0` alpha in `output.radiance = float4(Lo, 1.0)` is not arbitrary. It serves as the **reflection mask** that gates screen-space reflections:

```hlsl
// In the SSR shader:
float4 background = colorTexture.Load(int3(pixelPos.xy, 0));

if (background.w <= 0)
{
    return background * (1 + ssrParams.z);  // No SSR for non-reflective pixels
}
```

By writing `alpha = 1.0`, mixed rendering materials opt into SSR. Pure deferred materials don't write to RT0 at all, so their Main RT alpha remains whatever was cleared to (typically 0), and SSR skips them. This creates a clean architectural boundary: materials that do their own forward lighting (mixed rendering) also participate in reflections, while materials that defer everything to the lighting pass (pure deferred) don't.

## How Emissive Interacts with Other Systems

### Screen-Space Reflections

SSR reads the Main RT's color buffer, which already contains the emissive contribution. When SSR marches a reflection ray and hits an emissive surface, it samples that surface's full radiance — emissive color plus any direct lighting — from the color buffer:

```hlsl
float4 reflection = colorTexture.SampleLevel(pointSampler, screenCoord, mipLevel);
return background + reflection * combinedFadeout * background.w * (1 - normalData.w);
```

This means **emissive surfaces can be reflected** by other objects. A glowing sphere next to a polished metal floor will appear in the floor's reflection. The reflected color includes the emissive contribution because SSR reads post-forward-lighting color, not raw G-Buffer data.

However, this is image-based reflection, not energy-based. The reflection captures the visual appearance of the emissive surface, but it doesn't add any energy to the reflecting surface's lighting. A bright red emissive sphere reflected in a metal floor doesn't make the floor redder — it just shows a bright red spot in the reflection.

### Bloom

The 7-pass progressive downsampling bloom shader (`glow.hlsl`) extracts pixels above a brightness threshold:

```hlsl
float4 aboveThreshold = sampleColor >= threshold;
color += ((sampleColor - threshold) * (1 + power * 1000) + threshold) * aboveThreshold;
```

Emissive surfaces naturally exceed this threshold because their radiance starts from the emissive texture value *before* any lighting is added. Even if direct lighting contributes nothing (e.g., a surface in shadow), the emissive component alone can trigger bloom.

The bloom cascade runs:
1. **Pass 1**: Threshold extraction + horizontal blur (full res → half width)
2. **Passes 2-6**: Alternating horizontal/vertical blur at progressively smaller resolutions (half → quarter → eighth)
3. **Pass 7**: Color tint and final output

This creates a soft glow halo around emissive surfaces that spreads across a significant portion of the screen. At one-eighth resolution, even a small emissive area produces a wide, soft bloom. The tint color (Pass 7) is animated per-material via splines, so artists can shift bloom color over time.

Bloom is the primary mechanism by which emissive surfaces appear to influence their surroundings. The glow bleed makes it *look* like the surface is casting colored light, even though no actual light contribution occurs. In a carefully art-directed demo, this is often more effective than real indirect illumination because artists have direct control over the bloom's color, intensity, and radius.

### Deferred Lighting Passes

After mixed rendering writes to the G-Buffer (RT1, RT2), deferred lighting passes — point lights, area lights (LTC and non-LTC), ambient IBL, and the fake cubemap — read the G-Buffer and add their contributions to the Main RT via additive blending.

These passes use the albedo, metalness, normal, and roughness from the G-Buffer, which mixed rendering materials provide alongside their forward-lit color. So an emissive surface can *also* receive additional deferred lighting contributions (area light highlights, ambient light, IBL reflections) on top of its emissive + forward-lit color.

This layered accumulation is the advantage of mixed rendering: the surface gets both its own forward-calculated lighting (including emissive) and any deferred contributions, without double-counting. The forward pass handles the primary directional light with shadows, while deferred passes handle fill lights, area lights, and environment lighting.

### Area Light Bodies

The area light body shader (`area-body-sphere-light-body.hlsl`) is a subtle detail. Area lights in Clean Slate have visible sphere geometry — the light source itself is a rendered object. But this shader writes **only depth**, not color:

```hlsl
float p(VSOUT v) : SV_DEPTH
{
    // Transform camera and pixel to object's local space
    float4x4 i = transpose(itworldmat);
    float3 cp = -mul(i, float4(campos.xyz, 1)).xyz;
    float3 pos = mul(i, float4(getWorldPos(1, v.uv), 1)).xyz;
    float3 d = normalize(pos - cp);

    // Ray-sphere intersection (unit sphere, radius 0.5)
    float b = dot(cp, d);
    float c = dot(cp, cp) - 0.25;
    float discr = b * b - c;
    if (discr < 0)
        discard;

    // Find front intersection point
    float t = -b + sqrt(discr);
    float3 p = -cp.xyz - d * t;

    // Project to clip space for depth output
    float4 vp = mul(projmat, mul(viewmat, mul(worldmat, float4(p, 1))));
    return vp.z / vp.w;
}
```

The shader performs analytical ray-sphere intersection in local space (cheaper than rasterizing a tessellated sphere) and outputs only the resulting depth. No color is written — the sphere body is invisible in the color buffer. Its purpose is:

1. **Depth occlusion**: The sphere establishes correct depth so that objects behind the light source are properly occluded
2. **SSR interaction**: When SSR rays hit the light body's depth, they stop marching — but since there's no color written by this shader, what SSR actually samples at that location depends on what was previously in the Main RT at those pixels

The area light's visible glow comes from the LTC or non-LTC lighting shaders that operate in the Lighting Layer, not from the body shader. This separation — body writes depth, lighting shaders write specular contributions — keeps the pipeline clean.

## What Emissive Doesn't Do

The architectural gap is clear when you trace what emissive surfaces *cannot* do:

### No Indirect Illumination

An emissive surface does not contribute to the scene's lighting in any physics-based way. No light is added to the light data structure (`LIGHTDATA lights[8]`). No photons bounce from the emissive surface to nearby geometry. The deferred lighting passes (point light, area light, ambient) have no knowledge that a surface is emissive — they only see the G-Buffer's albedo, metalness, normals, and roughness.

### No Light Probes

There's no mechanism to capture an emissive surface's contribution into the environment. The fake cubemap IBL shader samples from static panoramic textures, not from the scene's rendered content. An emissive surface inside a room doesn't affect the IBL that illuminates other surfaces.

### No Emissive Shadow Casting

Emissive surfaces don't cast shadows because they aren't lights. The shadow system renders a single shadow map for the primary directional light (`lights[0]`). There's no concept of an emissive surface occluding its own "light."

### No Energy Conservation Concern

Because emissive is purely additive and doesn't feed back into the lighting system, there's no need for energy conservation between emissive and reflected light. The BRDF's energy conservation (`kD = 1 - kS; kD *= 1 - metallic`) applies only to the direct lighting portion of `Lo`, not the emissive initialization.

## The Complete Interaction Map

```
Emissive Surface
    │
    ├── Direct: emissiveMap.xyz → Lo (radiance accumulator)
    │       Additive, view-independent, no BRDF
    │
    ├── SSR Reflection: Main RT color contains emissive
    │       Other reflective surfaces can see the glow
    │       Image-based only, no energy contribution
    │
    ├── Bloom: Emissive exceeds brightness threshold
    │       7-pass progressive downsample creates halo
    │       Primary mechanism for "emissive lights the scene" illusion
    │
    ├── Deferred Compositing: G-Buffer enables additional lighting
    │       Area lights, IBL, ambient add on top of emissive
    │       Emissive surface receives light (doesn't emit it)
    │
    └── NOT: Indirect illumination, light probes, radiosity,
            photon mapping, voxel GI, RSM, or any other GI technique
```

## Pure Deferred: The Non-Emissive Baseline

For contrast, `pbr-pure-deferred.hlsl` shows what a material looks like without emissive capability:

```hlsl
struct PixelOutput
{
    float4 albedoMetalness : SV_TARGET1;  // Only RT1
    float4 normalRoughness : SV_TARGET2;  // Only RT2
};

PixelOutput PixelMain(VertexOutput input)
{
    // ... sample textures, perturb normal ...
    output.normalRoughness = float4(worldNormal, roughness);
    output.albedoMetalness = albedo;
    return output;
}
```

No RT0 output. No emissive texture binding. No forward lighting. The material writes only surface properties and relies entirely on deferred lighting passes for illumination. This is appropriate for static geometry, architectural surfaces, and anything that doesn't need to glow.

The absence of RT0 output means:
- No reflection mask written → SSR skips these pixels
- No forward-lit color → all lighting comes from deferred passes
- No emissive → surfaces can only be lit by scene lights

## Key Observations

### 1. Emissive is a Forward Rendering Feature

This is subtle but important. Deferred rendering decomposes lighting into geometry (G-Buffer) and light evaluation (separate passes). Emissive doesn't fit this decomposition because it's not a response to incoming light — it's self-generated radiance. Phoenix solves this by making emissive-capable materials use mixed rendering (forward + deferred), where the forward pass handles emissive and the primary light, and deferred handles everything else.

A purely deferred engine would need a separate emissive channel in the G-Buffer. Phoenix avoids this by routing emissive materials through a different shader entirely.

### 2. Bloom is the Cheap GI Substitute

The 7-pass bloom is doing double duty: it's both a lens simulation (bright things bloom in real cameras) and a cheap approximation of indirect illumination (bright things light up nearby surfaces). This works because bloom bleeds color from emissive pixels into surrounding pixels, visually mimicking light scatter. The effect is strongest close to the emissive surface and falls off with distance — exactly what indirect illumination would do.

Artists exploit this by adjusting bloom threshold, power, and tint per-frame. A lower threshold captures more of the emissive contribution. Higher power amplifies the bleed. The tint color can shift the bloom to warm or cool tones independent of the emissive texture color. This is more flexible than real GI because every parameter is directly controllable.

### 3. The Emissive Texture is Multi-Purpose

Register `t2` serves three roles:
- **RGB**: Emissive color and intensity
- **A**: Alpha mask for cutout geometry (alpha test)
- **Implicit**: Any non-black pixel signals "this surface glows"

The `material_instances.json` data confirms this dual-purpose design in practice: of the 30+ material instances that bind the emissive slot, roughly half use it for genuine emissive glow (zebra, card, balloon, CNS logo, etc.) while the other half use it purely for alpha masking (butterfly wings, cassette tape cutouts, dissolve effects). The format `RGB=emissive, A=alpha` lets one texture slot serve both purposes, avoiding a wasted slot for a separate alpha map.

There's no separate emissive intensity parameter — the texture values *are* the intensity. This constrains what artists can do (no HDR emissive beyond the texture's range) but simplifies the material interface. The license plate works around this by binding its emissive texture to the albedo slot simultaneously, ensuring the glow pattern matches the surface color exactly.

### 4. Area Light Bodies and Emissive Are Decoupled

The sphere light body shader and the emissive material shader serve different purposes:
- **Area light body**: Writes depth for the light source geometry (ray-sphere intersection)
- **Emissive material**: Writes color for self-luminous surfaces

An area light's visible appearance comes from its LTC/non-LTC lighting contribution to *other* surfaces, not from a self-lit material. The body is invisible in color space — it only establishes depth for occlusion and SSR hit testing. This means if you want the light source itself to be visible, you'd need to render it separately with an emissive material, or the glow from the lighting contribution on surrounding surfaces implies the light's presence.

### 5. SSR Reflects Emissive Before Deferred Lighting

SSR runs within the Solid Layer, after G-Buffer geometry but before the Lighting Layer. This means SSR captures the Main RT color as written by mixed rendering's forward pass — emissive + primary light + shadow — but not the deferred lighting contributions (area lights, IBL, ambient) that come later.

A reflected emissive surface in SSR shows its emissive + forward-lit color, not its final fully-lit appearance. In practice this is rarely noticeable because the emissive component dominates the reflected color for bright surfaces, and the deferred contributions (ambient, fill lights) are subtle by comparison.

## Implications for Rust Framework Design

### Adopt: Mixed Rendering for Emissive

The hybrid forward+deferred approach is the right architectural choice for emissive materials. A purely deferred path would need an extra G-Buffer channel (wasteful) or a separate emissive pass (extra draw calls). Mixed rendering handles emissive naturally as part of the geometry pass.

```rust
pub enum MaterialPath {
    /// G-Buffer only: albedo, normal, roughness, metalness
    PureDeferred,
    /// Forward lighting + G-Buffer: emissive, primary light, shadows
    /// Plus G-Buffer output for deferred passes
    MixedRendering { emissive: bool },
}
```

### Adopt: Bloom as Emissive Enhancement

Multi-pass progressive downsampling bloom is cheap and effective. Combine it with per-material emissive to create the illusion of light scatter without GI:

```rust
pub struct BloomSettings {
    pub threshold: f32,       // Brightness cutoff
    pub intensity: f32,       // Power multiplier
    pub tint: [f32; 3],       // Color shift
    pub passes: u32,          // Downsample iterations (3-7)
}
```

### Consider: Emissive as Light Source

For a general-purpose framework (not a 64k demo), emissive surfaces that actually illuminate their surroundings are increasingly expected. Options:

1. **Reflective Shadow Maps (RSM)**: Render the scene from emissive surfaces' perspective, treat visible pixels as virtual point lights. Medium cost, reasonable quality.
2. **Light Propagation Volumes (LPV)**: Propagate light through a 3D grid. Handles diffuse GI from emissive surfaces.
3. **Screen-Space Global Illumination (SSGI)**: Like SSR but for diffuse bounces. Samples nearby emissive pixels and treats them as light sources.
4. **Voxel-based GI**: Voxelize the scene, inject emissive radiance, cone-trace for indirect illumination.

Each has significant cost. Phoenix's approach — skip all of this and use bloom — is valid for demos but insufficient for general-purpose rendering.

### Avoid: Separate Emissive Pass

Some engines render emissive as a separate fullscreen pass that reads an emissive G-Buffer channel. This wastes a G-Buffer channel on data that's non-zero for only a fraction of pixels. Phoenix's approach (emissive materials use a different shader path that writes RT0) is more efficient because it costs nothing for non-emissive materials.

## Related Documents

- **[reflections.md](reflections.md)** — SSR reflection of emissive surfaces, reflection mask
- **[shadows.md](shadows.md)** — Shadow integration in the mixed rendering light loop
- **[lighting.md](lighting.md)** — Light types, area light evaluation
- **[deferred.md](deferred.md)** — G-Buffer layout, pure vs mixed rendering paths
- **[pipeline.md](pipeline.md)** — Render layer system
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — Full PBR pipeline walkthrough

## Source References

### Clean Slate Shaders

| Shader | Path | Purpose |
|--------|------|---------|
| PBR Mixed Rendering | `extracted/shaders/materials/pbr-mixed-rendering.hlsl` | Emissive + forward lighting + G-Buffer output |
| PBR Mixed + Offset | `extracted/shaders/materials/pbr-mixed-rendering-with-vertex-offset.hlsl` | Same with vertex displacement |
| PBR Pure Deferred | `extracted/shaders/materials/pbr-pure-deferred.hlsl` | G-Buffer only, no emissive capability |
| Glow (Bloom) | `extracted/shaders/materials/glow.hlsl` | 7-pass bloom extracting bright emissive pixels |
| Screen-Space Reflections | `extracted/shaders/materials/screen-space-reflections.hlsl` | SSR reflecting emissive via Main RT color |
| Area Sphere Light Body | `extracted/shaders/materials/area-body-sphere-light-body.hlsl` | Depth-only sphere body, no color |
| Deferred Fake Cubemap | `extracted/shaders/materials/deferred-fake-cubemap.hlsl` | IBL (no emissive awareness) |
| Deferred Ambient Light | `extracted/shaders/materials/deferred-ambient-light.hlsl` | Ambient pass (no emissive awareness) |

### Material Data (Clean Slate)

| File | Purpose |
|------|---------|
| `extracted/material_instances.json` | All material instances with texture bindings — shows which objects bind emissive textures |
| `extracted/materials.json` | Material technique definitions — confirms only PBR Mixed Rendering supports emissive |
| `extracted/textures/emissive-alpha.json` | Procedural texture generator definition for emissive alpha patterns |

### Phoenix Engine

| File | Purpose |
|------|---------|
| `Scene.h:131-137` | LIGHTDATA structure (emissive not present — no emissive lights) |
| `phxEngine.cpp` | Material rendering dispatch between pure deferred and mixed rendering |
