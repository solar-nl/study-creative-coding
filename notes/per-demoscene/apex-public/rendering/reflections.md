# apEx Reflection Systems

Clean Slate employs five distinct reflection techniques, each optimized for specific scenarios. Unlike general-purpose engines that commit to one dominant approach—typically screen-space reflections (SSR) or cubemap-based image-based lighting (IBL)—a 64k demo meticulously selects the cheapest sufficient technique for each visual requirement. A planar floor needs simple 2D UV flipping, not expensive ray marching. A brushed metal surface needs sharp specular from area lights, not blurred environment sampling.

This multi-technique approach enables Phoenix to deliver convincing reflections across varied materials and lighting conditions without the memory overhead of baked environment maps or the uniform cost of applying SSR to every surface. The G-Buffer's reflection mask gates expensive techniques to reflective materials only. Area lights contribute specular highlights through either analytical integration or LTC-based polygon evaluation. Post-processing layers add dynamic reflections from visible geometry and planar mirrors for water and floors.

The result is a layered reflection pipeline where techniques compose rather than compete. The lighting layer adds area light specular. The ambient pass contributes diffuse and specular IBL from fake cubemaps. Post-processing applies SSR to reflective surfaces and mirror reflections to designated planes. Each technique operates on what it handles best, with the final frame accumulating all contributions.

## Reflection Technique Inventory

Phoenix implements five reflection methods, each with distinct mathematical foundations and use cases.

### 1. Screen-Space Reflections (SSR)

**Shader**: `screen-space-reflections.hlsl` (136 lines)

SSR operates as a post-processing pass on the G-Buffer, ray-marching in view space along the reflection vector. For each reflective pixel, it steps through 3D view space, projecting sample points to screen coordinates and comparing depths to detect intersections with scene geometry.

**Algorithm**:
1. Reconstruct view-space position and normal from G-Buffer
2. Calculate reflection vector: `reflect(normalize(viewPos), viewNormal)`
3. March along reflection ray in fixed steps (configurable, typically 255)
4. At each step, project to screen space and sample depth buffer
5. When ray depth exceeds scene depth, potential hit detected
6. Binary refinement: step backward, halve step size, re-test (4 iterations)
7. Sample color buffer at hit location with mip level based on roughness

**Fadeout factors** (all multiplied together):
- **Screen edge**: Fades as projected coordinates approach clip boundaries `[-1,1]`
- **Depth**: Fades for samples behind the far plane
- **Distance**: `1 - saturate(pow(travelDistance / maxRadius, 16))` for sharp falloff
- **Roughness**: Multiplies final contribution by `(1 - roughness)` to reduce reflections on rough surfaces

**Parameters** (exposed via material data):
- `radius` — Maximum ray march distance (× 64)
- `steps` — Number of march iterations (× 255)
- `backgroundBoost` — Brightness multiplier for non-reflective pixels
- `acceptBias` — Hit detection tolerance (× 0.1)
- `radiusMultiplier` — Scale factor for radius

**Reflection mask**: The G-Buffer's color buffer alpha channel stores a reflection mask. SSR early-exits for pixels with `alpha <= 0`, avoiding computation on matte surfaces.

**Roughness-aware sampling**: The shader selects mip level as `roughness × 16`, blurring reflections on rough surfaces to approximate the increased solid angle of the reflection cone.

**Key limitation**: SSR can only reflect geometry visible in the current frame. Off-screen objects, back-facing surfaces, and occluded geometry don't contribute. This causes artifacts at screen edges and when reflecting objects outside the view frustum.

### 2. Fake Cubemap / Image-Based Lighting (IBL)

**Shader**: `deferred-fake-cubemap.hlsl` (231 lines)

Rather than using true cubemap textures, this technique implements full PBR image-based lighting with 2D panoramic textures. The `DeCube()` function unwraps a 3D direction vector to 2D UV coordinates by projecting onto the dominant axis face.

**DeCube projection**:
```hlsl
float3 absDir = abs(direction);
float maxAxis = max(max(absDir.x, absDir.y), absDir.z);

float2 uv = direction.zy;
if (maxAxis == absDir.y) uv = direction.xz;
if (maxAxis == absDir.z) uv = direction.xy;

return 0.5 * (uv / maxAxis + 1);
```

This maps each direction to a face (X, Y, or Z) and computes UV as the perpendicular coordinates normalized to `[0,1]`.

**Two-phase sampling**:

**Phase 1 — Diffuse Irradiance** (32 Hammersley samples):
- Constructs a tangent frame aligned with the surface normal
- Samples 32 directions in a cosine-weighted hemisphere
- Uses Hammersley sequence for quasi-random phi angles
- Samples environment at mip 8 (blurred) for diffuse irradiance
- Weights by `kD = (1 - Fresnel) × (1 - metallic)` for energy conservation

**Phase 2 — Specular Reflections** (64 GGX importance samples):
- Generates 64 half-vectors distributed according to GGX normal distribution
- Computes reflection directions: `L = 2 × dot(V,H) × H - V`
- Selects mip level based on PDF: `mipLevel = 0.5 × log2(omegaS / omegaP)`
  - `omegaS` = solid angle of sample (from PDF)
  - `omegaP` = solid angle of texel
- Evaluates full Cook-Torrance BRDF: Fresnel-Schlick F, Smith geometry G, GGX NDF D

**Three environment textures**: The shader supports separate textures for sides, top, and bottom. This enables asymmetric environments (e.g., ground plane below, sky above) without requiring a full cubemap.

**Cook-Torrance BRDF components**:
- **Fresnel**: Schlick approximation `F0 + (1-F0) × pow(1-cosTheta, 5)`
- **Geometry**: Smith GGX with Schlick approximation `G1(V) × G1(L)`
- **Normal Distribution**: GGX `α² / (π × (cos²θ × (α²-1) + 1)²)`

**Mip level formula derivation**: The solid angle of a GGX sample is `1 / (N × PDF)` where N is sample count and PDF is the GGX probability density. The solid angle of a texel is `4π / (6 × w × h)` for a cubemap. The mip level balances these: higher PDF (sharper samples) uses lower mip (sharper texture), lower PDF (broader samples) uses higher mip (blurred texture).

### 3. Mirror / Planar Reflections

**Shader**: `mirror.hlsl` (76 lines)

This technique performs simple 2D geometric reflection across an arbitrary line, operating entirely in screen space. It's computationally cheap—a single texture sample per pixel—making it ideal for large flat surfaces like floors, water, or mirrors.

**Mathematical foundation**: Given a mirror line through point P with direction D, the reflection of point A is:
```
X = P + D × dot(A - P, D)    // Closest point on line to A
A' = 2X - A                   // Reflection of A across X
```

**Parameters**:
- `direction` (0-1) — Maps to mirror angle 0-90° (0 to π/2 radians)
- `centerX`, `centerY` — A point on the mirror line in UV coordinates

**Aspect ratio correction**: The shader converts UV coordinates to square space before computing reflection, preventing distortion on non-square screens. The aspect ratio is hardcoded to 16:9 in the shader (matching Clean Slate's target resolution).

**Side test**: Determines which pixels lie on the reflected side using the perpendicular to the mirror direction:
```hlsl
float2 perpendicular = float2(-D.y, D.x);
if (dot(A - P, perpendicular) > 0)
    return originalTexture;  // Non-reflected side
```

**Bounds checking**: After computing the reflected UV, the shader checks if it falls within `[0,1]`. Out-of-bounds reflections return black (no valid reflection source).

**Use cases**: Perfect for large, flat reflective surfaces. Water reflections, polished floors, and architectural mirrors all benefit from this approach. The reflection is geometrically correct for planar surfaces but wouldn't work for curved reflectors.

### 4. LTC Area Light Reflections

**Shader**: `area-sphere-light-ltc.hlsl` (246 lines), optimized variant (257 lines)

Linearly Transformed Cosines provide analytical integration of area light reflections. LTC's insight: the GGX BRDF has no closed-form integral over polygonal lights, but a clamped cosine distribution does. By transforming the GGX lobe into a cosine via a 3×3 matrix, integrating, and transforming back, you get noise-free area light evaluation.

**See also**: [LTC Area Lighting Code Trace](../code-traces/ltc-area-lighting.md) for detailed implementation walkthrough and [LTC Library Notes](../../per-library/universal/ltc/README.md) for original research papers and reference implementations.

**Pre-computed lookup tables** (2.5KB total):
- **ltc_1** (2048 bytes): 16×16 grid of 3×3 transformation matrices
  - Stored as 4 half-floats per entry (matrix has known zeros and symmetries)
  - Indexed by `(roughness, sqrt(1 - NdotV))` for better sampling at grazing angles
- **ltc_2** (512 bytes): 16×16 grid of magnitude and Fresnel factors
  - Stored as 2 bytes per entry

**Sphere discretization**: LTC operates on polygons, so Phoenix approximates the visible sphere disc as a 24-vertex polygon. The optimized variant uses 8 vertices for faster evaluation on rough surfaces where precision matters less.

The disc scale formula comes from sphere geometry:
```hlsl
float scale = distance / sqrt(4 * distance * distance - 1);
```

For a unit sphere at distance `d`, the visible disc radius is `d / sqrt(4d² - 1)`.

**Sutherland-Hodgman clipping**: After transforming the polygon by the inverse LTC matrix, the algorithm clips it against the horizon plane (z=0). This ensures only the visible portion contributes to lighting.

**Edge integration**: The clipped polygon integrates via edge summation using a rational polynomial approximation to avoid trigonometric functions:
```hlsl
sum += IntegrateEdge(v1, v2);  // For each edge
```

The integration formula computes the solid angle subtended by each edge in the transformed space, which maps back to the GGX integral in the original space.

**Evaluated twice per light**:
1. **Diffuse**: Identity matrix transformation (cosine lobe)
2. **Specular**: Full LTC matrix transformation (GGX lobe)

**Optimized variant**: Rotates the disc toward an estimated reflection point, weighted by roughness. At roughness 0, the disc faces the reflection ray exactly. At roughness 1, it faces the shading point directly. This reduces artifacts for highly anisotropic viewing angles.

### 5. Non-LTC Representative Point Method

**Shader**: `area-sphere-light-non-ltc.hlsl` (292 lines)

For smaller lights or rougher surfaces where LTC's overhead isn't justified, the representative point method approximates the sphere integral with a single carefully chosen point. This trades accuracy for performance.

**Representative point selection**: Find the closest point on the sphere to the reflection ray. This point "best represents" the light's contribution for the viewer's reflection direction.

**Energy normalization**: Compensates for using a single point instead of integrating over the surface. The effective roughness increases based on the sphere's solid angle:
```hlsl
a2_modified = a2 + 0.25 × sinAlpha × (3√a2 + sinAlpha) / (VoH + 0.001)
energy = a2_original / a2_modified
```

This formula, from the Frostbite paper (Lagarde & de Rousiers, SIGGRAPH 2014), ensures energy conservation while approximating the blurred highlight from a finite area source.

**Sphere horizon cosine wrapping**: For diffuse evaluation, when the surface tilts enough that the sphere partially dips below the horizon, a specialized formula computes the exact irradiance from the visible portion. This is geometrically accurate for spheres, unlike simple Lambert cosine which assumes point sources.

**Modified half-vector calculations**: The half-vector H is computed between the view vector and the direction to the representative point, not the sphere center. Similarly, NoH and VoH account for the sphere's extent.

**Use cases**: Best for rough surfaces (roughness > 0.3) or small lights where the solid angle is small. LTC provides superior quality for smooth surfaces and large lights but costs more ALU.

**Reference**: Based on the "Moving Frostbite to PBR" paper and Unreal Engine 4's sphere light implementation.

## When Each Technique Is Used

| Technique | Render Phase | Target Layer | Use Case | Cost | Quality |
|-----------|-------------|--------------|----------|------|---------|
| SSR | Post-processing | Solid Layer | Dynamic scene reflections of visible geometry | Medium (ray march) | High (limited by visibility) |
| Fake Cubemap | Lighting | Lighting Layer | Ambient/sky fill, distant reflections | High (96 samples) | Medium (2D unwrap artifacts) |
| Mirror | Post-processing | Solid Layer | Flat surfaces (floors, water, architectural mirrors) | Low (single sample) | High (for planes) |
| LTC Area Lights | Lighting | Lighting Layer | Soft area light reflections, smooth surfaces | Medium (polygon clip + integrate) | Very High (analytical) |
| Non-LTC Area Lights | Lighting | Lighting Layer | Small/rough area lights | Low (single point) | Medium (approximation) |

**SSR**: Applied selectively to reflective surfaces gated by the G-Buffer alpha mask. Provides dynamic reflections of animated objects and moving geometry but misses off-screen content.

**Fake Cubemap**: Runs during the lighting layer for ambient fill. Contributes both diffuse irradiance and specular reflections from the environment. Acts as fallback for SSR misses.

**Mirror**: Applied in post-processing to specific UV regions defined by the mirror parameters. Used for large, flat reflective surfaces where geometric correctness matters.

**LTC Area Lights**: Evaluated per-light during the lighting layer. Provides physically accurate area light reflections with soft highlights. Preferred for smooth surfaces and large lights.

**Non-LTC Area Lights**: Alternative to LTC when performance is critical or roughness is high. Faster but less accurate.

## How They Compose Together

The reflection pipeline operates in layers, with techniques accumulating contributions at different stages.

### 1. G-Buffer Pass (Solid Layer)

Materials write albedo, metalness, normal, and roughness to the G-Buffer. The color buffer's alpha channel stores the **reflection mask**—a per-pixel weight indicating how reflective the surface is. Matte surfaces write 0, mirrors write 1, intermediate materials write fractional values.

### 2. Lighting Layer: Area Lights

For each area light in the scene, the engine selects either LTC or Non-LTC based on light size and surface roughness. The shader:
- Reads G-Buffer properties
- Reconstructs world position from depth
- Evaluates the area light's specular contribution
- Additively blends the result to the lighting buffer

This adds sharp or soft specular highlights from physical light sources.

### 3. Lighting Layer: Fake Cubemap IBL

The ambient pass runs once per scene, sampling the environment in 96 directions (32 diffuse + 64 specular). It:
- Contributes diffuse irradiance weighted by `kD = (1-F) × (1-metallic)`
- Contributes specular reflections weighted by Fresnel and geometry terms
- Acts as the "baseline" ambient lighting for the entire scene

This provides the global illumination and distant reflections that area lights don't capture.

### 4. Solid Layer Post-Processing: SSR

SSR runs as a full-screen pass after lighting completes. For each pixel:
- Check reflection mask in color buffer alpha
- If mask > 0, perform ray march
- Sample color buffer at hit location with roughness-based mip
- Blend reflection onto the background weighted by fadeout and mask

SSR adds reflections of nearby geometry—other objects, floor tiles, walls—that the fake cubemap doesn't capture because it's static.

### 5. Solid Layer Post-Processing: Mirror

The mirror effect runs after SSR for designated surfaces. It:
- Tests if the pixel lies on the reflected side of the mirror line
- Computes the reflected UV
- Samples the color buffer (which now includes lighting + SSR)
- Replaces the pixel color if within bounds

This provides pixel-perfect planar reflections for water and floors.

### Compositing Order Summary

```
G-Buffer
    ↓
Lighting: Area Lights (LTC or Non-LTC)
    ↓ (additive blend)
Lighting: Fake Cubemap IBL
    ↓ (additive blend)
Post: Screen-Space Reflections
    ↓ (additive blend, masked)
Post: Mirror
    ↓ (replace for reflected pixels)
Final Frame
```

The reflection mask in the G-Buffer alpha channel controls SSR participation. This prevents the expensive ray march from running on surfaces that don't need dynamic reflections, saving GPU cycles for where it matters.

## Shared Mathematical Foundations

Despite their different approaches, the reflection techniques share common BRDF math.

### Fresnel-Schlick

Appears in Fake Cubemap, LTC, and Non-LTC:
```hlsl
F0 + (1 - F0) × pow(1 - cosTheta, 5)
```

**F0** is the specular reflectance at normal incidence. For dielectrics, this is ~0.04. For metals, it's the albedo color.

### GGX Normal Distribution

Appears in Fake Cubemap, LTC (implicitly via transformation), and Non-LTC:
```hlsl
float D_GGX(float alpha, float NoH)
{
    float a2 = alpha * alpha;
    float cos2 = NoH * NoH;
    return (1.0 / PI) * sqr(alpha / (cos2 * (a2 - 1) + 1));
}
```

**Alpha** is the roughness parameter, typically `roughness × roughness`. The distribution peaks when NoH = 1 (half-vector aligned with normal) and spreads based on roughness.

### Smith Geometry Term

Appears in Fake Cubemap and Non-LTC:
```hlsl
float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}
```

Models the self-shadowing and masking of microfacets. Reduces highlights at grazing angles where microfacets occlude each other.

### View-Space Position Reconstruction from Depth

Appears in SSR and all deferred lighting techniques:
```hlsl
float4 clipPos = mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1));
float3 viewPos = clipPos.xyz / clipPos.w;

float4 worldPos = mul(inverseViewMatrix, float4(viewPos, 1));
return worldPos.xyz / worldPos.w;
```

This saves 12 bytes per pixel in the G-Buffer by reconstructing position instead of storing it.

### Roughness → Mip Level Mapping

Appears in SSR and Fake Cubemap:
- **SSR**: `mipLevel = roughness × 16`
- **Fake Cubemap**: `mipLevel = 0.5 × log2(omegaS / omegaP)`

Both map rougher surfaces to higher mip levels (blurrier reflections), approximating the increased solid angle of the reflection cone for rough surfaces.

## Reflection Technique Decision Flow

Here's how a Rust framework could decide which technique to use:

```
For each reflective surface:

    If surface is a large, flat plane (floor, water):
        → Use Mirror (cheapest, geometrically correct for planes)

    If material has low roughness (< 0.3) and area lights present:
        → Use LTC Area Lights (analytical, high quality)

    If material has high roughness (> 0.3) and area lights present:
        → Use Non-LTC Area Lights (approximation, faster)

    If material is metallic or has reflection mask > 0:
        → Use SSR (captures dynamic geometry)
        → Use Fake Cubemap as fallback for SSR misses

    Otherwise:
        → Use Fake Cubemap only (ambient fill)
```

This decision tree minimizes cost while preserving visual quality where it's most noticeable.

## Implications for Rust Framework

### Adopt: Layered Reflection Approach

Don't force one reflection technique on all materials. Compose multiple techniques, each handling what it's best at:
- SSR for dynamic reflections
- Cubemap IBL for ambient and distant reflections
- Planar reflections for specific surfaces
- Area lights for direct specular highlights

This mirrors Phoenix's multi-technique approach and avoids the pitfalls of one-size-fits-all solutions.

### Adopt: LTC for Area Lights

The 2.5KB lookup tables provide exceptional quality for area light reflections. Embed them as `include_bytes!` in the Rust binary:
```rust
const LTC_MATRIX: &[u8] = include_bytes!("ltc_1.bin");
const LTC_MAG_FRESNEL: &[u8] = include_bytes!("ltc_2.bin");
```

The WGSL shader translation is straightforward—the algorithm is graphics API agnostic.

### Adopt: Reflection Mask in G-Buffer Alpha

Gate expensive reflection techniques (SSR, complex IBL) with a per-pixel mask. Materials declare their reflectivity, and the G-Buffer pass writes it to the color buffer alpha channel. Post-processing reads the mask to early-exit on non-reflective pixels.

This provides fine-grained control over where GPU cycles are spent without requiring separate render passes or stencil masking.

### Modify: Use Actual Cubemaps for IBL

The "fake cubemap" 2D unwrapping is a size optimization for 64k demos. For a general-purpose framework, use real cubemaps:
- Pre-filtered environment maps for specular (roughness-based mip chain)
- Irradiance maps for diffuse (spherical harmonics or low-res cubemap)
- Split-sum approximation with BRDF LUT

This avoids the seam artifacts and limited resolution of 2D unwrapping while providing higher quality reflections.

### Modify: Hi-Z SSR Tracing

Phoenix's SSR uses linear ray marching with binary refinement. Modern engines use hierarchical Z-buffer (Hi-Z) tracing for faster convergence:
1. Build a mipmap chain of the depth buffer (min/max depths)
2. Ray march through the Hi-Z pyramid, stepping by larger distances at higher mips
3. Descend to lower mips as the ray approaches surfaces

This reduces the number of depth samples from 255+ to ~20-30 while maintaining accuracy.

### Avoid: Hardcoded Aspect Ratio in Mirror Shader

Phoenix's mirror shader hardcodes 16:9 aspect ratio for angle correction. Pass aspect ratio as a uniform instead:
```rust
struct MirrorParams {
    direction: f32,      // 0-1 → 0-90°
    center: Vec2,        // UV of point on mirror line
    aspect_ratio: f32,   // Screen width / height
}
```

This makes the shader resolution-independent and supports arbitrary aspect ratios.

## Performance Characteristics

### SSR

- **Cost**: O(steps × pixels_with_mask)
- **Bandwidth**: Depth buffer reads (255× per ray), color buffer reads (1× per hit)
- **Bottleneck**: Ray marching ALU, divergent control flow (variable step counts)
- **Optimization**: Use reflection mask to skip matte surfaces, reduce step count for distant pixels

### Fake Cubemap IBL

- **Cost**: O(samples × pixels) = 96 samples × 2M pixels = 192M shader invocations (1080p)
- **Bandwidth**: Environment texture reads (96× per pixel), high mip caching
- **Bottleneck**: Sampling overhead, trigonometry for tangent frame construction
- **Optimization**: Run at half resolution and upscale, use prefiltered environment maps instead of Monte Carlo sampling

### Mirror

- **Cost**: O(pixels_in_mirror_region)
- **Bandwidth**: Color buffer reads (1× per pixel)
- **Bottleneck**: None (very cheap)
- **Optimization**: None needed

### LTC Area Lights

- **Cost**: O(lights × pixels) with polygon clipping and edge integration per light
- **Bandwidth**: LTC table reads (2× per light per pixel), G-Buffer reads
- **Bottleneck**: Clipping geometry (Sutherland-Hodgman), edge integration loop
- **Optimization**: Use Non-LTC for rough surfaces, reduce polygon vertex count (8 vs 24)

### Non-LTC Area Lights

- **Cost**: O(lights × pixels) with representative point calculation
- **Bandwidth**: G-Buffer reads
- **Bottleneck**: BRDF evaluation (geometry term, Fresnel)
- **Optimization**: Use lookup tables for geometry and Fresnel terms

## Related Documents

- **[lighting.md](lighting.md)** — Lighting system and area lights
- **[deferred.md](deferred.md)** — G-Buffer layout and reflection mask storage
- **[shaders.md](shaders.md)** — BRDF implementation details
- **[../code-traces/ltc-area-lighting.md](../code-traces/ltc-area-lighting.md)** — LTC implementation walkthrough
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — Reflections in context of full PBR pipeline
- **[../../per-library/universal/ltc/README.md](../../per-library/universal/ltc/README.md)** — LTC research papers and reference implementations

## Source References

### Shader Files (Clean Slate)

| Shader | Lines | Purpose | Location |
|--------|-------|---------|----------|
| Screen-Space Reflections | 136 | SSR ray marching and fadeout | `extracted/shaders/materials/screen-space-reflections.hlsl` |
| Deferred Fake Cubemap | 231 | IBL with 2D panoramic textures | `extracted/shaders/materials/deferred-fake-cubemap.hlsl` |
| Mirror | 76 | 2D line-based reflection | `extracted/shaders/materials/mirror.hlsl` |
| Area Sphere Light LTC | 246 | LTC area light integration | `extracted/shaders/materials/area-sphere-light-ltc.hlsl` |
| Area Sphere Light LTC Optimized | 257 | LTC with 8-vertex disc | `extracted/shaders/materials/area-sphere-light-ltc-optimized.hlsl` |
| Area Sphere Light Non-LTC | 292 | Representative point method | `extracted/shaders/materials/area-sphere-light-non-ltc.hlsl` |

### Engine Files (Phoenix)

| File | Purpose |
|------|---------|
| `Phoenix/ltc_1.h` | LTC transformation matrix table (2048 bytes) |
| `Phoenix/ltc_2.h` | LTC magnitude and Fresnel table (512 bytes) |
| `phxEngine.cpp:298-336` | LTC texture creation and upload |
| `Scene.h:131-137` | LIGHTDATA structure with area light radius |

### Research Papers

| Paper | Authors | Conference | Key Contribution |
|-------|---------|------------|------------------|
| Real-Time Polygonal-Light Shading with Linearly Transformed Cosines | Heitz, Dupuy, Hill, Neubelt | SIGGRAPH 2016 | LTC method for area lights |
| Moving Frostbite to PBR | Lagarde & de Rousiers | SIGGRAPH 2014 | Representative point method, energy normalization |
| Efficient GPU Screen-Space Ray Tracing | Morgan McGuire | Journal of Computer Graphics Techniques 2014 | SSR algorithm and optimizations |
| Real Shading in Unreal Engine 4 | Brian Karis | SIGGRAPH 2013 | GGX importance sampling for IBL |
