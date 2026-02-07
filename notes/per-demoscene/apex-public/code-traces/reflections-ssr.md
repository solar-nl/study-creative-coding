# Code Trace: Screen-Space Reflections in Clean Slate

> Tracing how Clean Slate achieves dynamic reflections by ray marching through screen space, reconstructing reflected geometry from the depth buffer without pre-baked data.

Screen-space reflections are the only technique in Clean Slate that can reflect arbitrary, dynamic geometry. Cubemaps capture frozen snapshots of the environment. Area lights with LTC only reflect the light sources themselves. But SSR reflects whatever the camera sees: animated meshes, procedural particles, moving lights—anything in the G-Buffer becomes reflectable.

The fundamental tradeoff is visibility. SSR can only reflect what's on screen. Objects behind the camera, beyond the screen edges, or occluded by foreground geometry simply vanish from reflections. This limitation is the price of real-time dynamic reflections without ray tracing hardware. The question this code trace answers: How does Clean Slate navigate this limitation to produce convincing reflections for a demo scene where every frame matters?

## The Mental Model: Reflections as Screen-Space Queries

Think of SSR like using a photograph to see what's behind you in a mirror. You're standing in front of a polished table, looking down at your reflection. But the reflection can only show what's also captured in a photograph taken from the same angle. If something is behind you but out of the photo's frame, the reflection goes dark.

This is the essence of screen-space techniques: they treat the framebuffer like a database, querying "what color is at this screen coordinate?" Each pixel becomes a data point. The depth buffer provides 3D structure. Together, they reconstruct the scene from the camera's single viewpoint. SSR uses this database to trace reflection rays, marching step-by-step through view space, projecting each position to screen coordinates, and checking whether the ray has intersected geometry.

The elegance: no additional geometry rendering. The limitation: only visible surfaces exist in the database.

## G-Buffer Inputs

**File**: `Projects/Clean Slate/cleanslate.apx:48268-48272`

SSR reads from three textures written during the deferred rendering passes:

```hlsl
Texture2D Textur:register(t0);      // Color buffer (RGB + Alpha = reflection mask)
Texture2D nz:register(t1);          // Normal (XYZ) + Roughness (W)
Texture2D depthtex:register(t7);    // Depth buffer (scene Z)
```

### t0: Color Buffer with Reflection Mask

The color buffer holds the scene's current appearance before reflections are added. The alpha channel serves double duty as a reflection mask. During the G-Buffer generation pass, materials write `alpha = 1.0` for reflective surfaces and `alpha = 0.0` for matte surfaces.

This mask enables an early exit optimization:

```hlsl
float4 background = Textur.Load(int3(p.xy, 0));
if (background.w <= 0) return background * (1 + dat.z);
```

Pixels with `mask = 0` skip the entire ray march, returning the background color immediately. The `dat.z` term is a "background boost" parameter that lets artists brighten non-reflective surfaces to compensate for the darkening that reflections add to reflective ones.

### t1: Normal and Roughness

World-space normals from the G-Buffer provide surface orientation. SSR transforms these to view space to calculate the reflection vector. The roughness value (alpha channel) controls how blurry the reflection appears. Rougher surfaces sample higher mip levels of the color buffer, creating physically plausible rough reflections without additional computation.

### t7: Depth Buffer

The depth buffer is the most critical input. SSR queries it twice per ray march step:

1. **Position reconstruction**: Convert the current pixel's depth to a 3D view-space position
2. **Intersection testing**: At each march step, compare the ray's depth against the scene depth to detect geometry hits

Without the depth buffer, SSR would be impossible—there's no way to reconstruct 3D structure from color alone.

## View-Space Position Reconstruction

**File**: `Projects/Clean Slate/cleanslate.apx:48289-48299`

Before ray marching, SSR must convert the 2D pixel coordinate into a 3D starting position. This uses the standard deferred rendering technique:

```hlsl
float3 getPosition(float depth, float2 uv)
{
    float4 a = mul(iprojmat, float4(uv * 2 - 1, depth, 1));
    return a.xyz / a.w;
}
```

The process reverses the GPU's built-in projection pipeline:

1. **UV to NDC**: Screen coordinates (0 to 1) are remapped to normalized device coordinates (-1 to 1)
2. **Inverse projection**: The inverse projection matrix transforms from clip space back to view space
3. **Perspective divide**: Dividing by `w` completes the homogeneous-to-Cartesian conversion

An overloaded version operates directly on pixel coordinates:

```hlsl
float3 getPosition(int2 uv)
{
    float4 a = mul(iprojmat, float4(uv / float2(xres, yres) * 2 - 1,
                                    depthtex.Load(int3(uv, 0)).x, 1));
    return a.xyz / a.w;
}
```

This version is used during ray marching to reconstruct the scene geometry at each sampled location. The `Load()` operation fetches depth without filtering, ensuring exact comparison against ray depth.

## Reflection Vector Setup

**File**: `Projects/Clean Slate/cleanslate.apx:48310-48319`

With the view-space position established, SSR calculates the reflection direction:

```hlsl
float4 dt = nz.Load(int3(p.xy, 0));
float4 normal = mul(transpose(iviewmat), float4(dt.xyz, 0));
normal.y *= -1;

float3 vpos = getPosition(p.xy);
float3 reflected = reflect(normalize(vpos), normalize(normal.xyz));
```

### Normal Transformation

The G-Buffer stores world-space normals. For view-space calculations, these must be transformed using the transpose of the inverse view matrix. For orthonormal matrices (which view matrices are), the transpose equals the inverse, making this operation equivalent to `mul(viewmat, normal)` with reversed multiplication order.

The `normal.y *= -1` line flips the Y component to match Phoenix's view-space convention. Different engines use different coordinate systems; Phoenix assumes Y-down in view space.

### Reflection Calculation

The `reflect()` function is HLSL's built-in implementation of the vector reflection formula:

```
R = I - 2 * dot(N, I) * N
```

Where `I` is the incident vector (direction TO the surface) and `N` is the surface normal. In view space, the camera is at the origin, so the direction from the camera to the pixel is simply the pixel's position: `normalize(vpos)`. The reflected vector points away from the surface along the mirror reflection direction.

This is the direction the ray will march to find reflected geometry.

## Ray March Parameters

**File**: `Projects/Clean Slate/cleanslate.apx:48325-48334`

SSR's quality and cost are controlled by two parameters:

```hlsl
float RADIUS = dat.x * 64 * radmult;
float STEPS = dat.y * 255;

float3 reflected_start = reflected;
float3 vpos_start = vpos;
reflected *= RADIUS / (float)STEPS;
```

### Radius

The maximum distance the ray will travel, in view-space units. Multiplying by 64 allows fine control via the `dat.x` parameter (typically 0-1 range). The `radmult` term provides an additional scaling factor, likely used for scene-specific tuning.

Larger radius allows reflections of distant objects but increases the chance of false hits and requires more steps to maintain quality.

### Steps

The number of discrete samples along the ray. Multiplying by 255 provides high-resolution control. Typical values range from 20 to 60. More steps improve accuracy (finer intersection detection) but linearly increase shader cost.

### Step Size

Dividing the reflection direction by step count creates the per-iteration advancement vector:

```hlsl
reflected *= RADIUS / (float)STEPS;
```

Each march iteration advances by this amount. A 10-unit radius with 50 steps means each step advances 0.2 units. Smaller steps detect thinner geometry; larger steps are faster but may miss small features.

## The Ray March Loop with Binary Refinement

**File**: `Projects/Clean Slate/cleanslate.apx:48340-48359`

This is the core of SSR: march along the reflection vector, testing each position for intersection with scene geometry.

```hlsl
for (int i = 0; i < STEPS; i++)
{
    vpos += reflected;
    view_projected = mul(projmat, float4(vpos, 1));
    view_projected.xyz /= view_projected.w;
    scr = view_projected.xy * 0.5 + 0.5;

    float depth2 = depthtex.Load(int3(scr * float2(xres, yres), 0)).x;
    float3 vpos_target = getPosition(scr * float2(xres, yres));

    if (length(vpos_target - vpos) < (RADIUS / (float)STEPS + dat.w * 0.1))
    {
        if (depth2 < view_projected.z)
        {
            vpos -= reflected;
            reflected *= 0.5;
        }
    }
}
```

### Linear March Phase

Each iteration starts by advancing the ray position:

```hlsl
vpos += reflected;
```

This moves forward by the step size calculated earlier. The ray walks through view space, treating it as a linear coordinate system (which it is).

### Projection to Screen Space

To check for intersection, the view-space position must be converted back to screen coordinates:

```hlsl
view_projected = mul(projmat, float4(vpos, 1));
view_projected.xyz /= view_projected.w;
scr = view_projected.xy * 0.5 + 0.5;
```

This is the forward projection pipeline:
1. Multiply by projection matrix to get clip-space position
2. Perspective divide to get normalized device coordinates (NDC)
3. Remap XY from [-1, 1] to [0, 1] for texture sampling

The result is a UV coordinate where the ray currently intersects the screen plane.

### Depth Comparison

At this screen coordinate, two depths are compared:

```hlsl
float depth2 = depthtex.Load(int3(scr * float2(xres, yres), 0)).x;
```

This is the scene's actual depth at this screen location—the depth of the geometry visible to the camera.

```hlsl
float3 vpos_target = getPosition(scr * float2(xres, yres));
```

This reconstructs the 3D position of that geometry point.

### Hit Detection Logic

The intersection test has two stages:

**Stage 1: Proximity Check**

```hlsl
if (length(vpos_target - vpos) < (RADIUS / (float)STEPS + dat.w * 0.1))
```

This calculates the 3D distance between the ray's current position (`vpos`) and the scene geometry at the projected screen coordinate (`vpos_target`). If this distance is less than the step size plus a tolerance bias, the ray is considered "near" the surface.

The threshold is `step_size + bias`:
- Step size (`RADIUS / STEPS`) ensures that rays don't skip over geometry within one step
- Bias (`dat.w * 0.1`) adds tolerance for floating-point error and thin geometry

**Stage 2: Depth Occlusion Check**

```hlsl
if (depth2 < view_projected.z)
```

This compares the scene depth with the ray's depth. If `depth2 < view_projected.z`, the ray has passed behind the surface—it's now occluded by geometry.

Why check both? The proximity check ensures the ray is geometrically close. The depth check ensures the ray has crossed from front to back of the surface. Together, they form a robust intersection test.

### Binary Refinement

When both conditions are true—the ray is near a surface AND behind it—the refinement kicks in:

```hlsl
vpos -= reflected;
reflected *= 0.5;
```

Instead of stopping, the ray takes a step BACK and then halves the step size. On the next iteration, it advances by half the distance. If it hits again, it steps back and halves again. This creates a binary search effect, narrowing in on the exact intersection point.

Key insight: This is NOT a full binary search. The loop continues linearly. The halving only happens when near-hits are detected. This hybrid approach handles complex geometry better than pure binary search because it doesn't commit to a single interval—it keeps advancing even after refinement, allowing it to find subsequent intersections.

After several hits and halvings, the ray converges to the surface with sub-pixel accuracy.

## Fadeout System

**File**: `Projects/Clean Slate/cleanslate.apx:48363-48375`

Reflections must gracefully fade out at boundaries to avoid harsh artifacts. Clean Slate implements three independent fadeout factors:

```hlsl
float2 fadeout_2 = saturate(abs(view_projected.xy));
float fs = saturate(1 - length(fadeout_2));

float fadeout_z = saturate(view_projected.z);

float fadeout_radius = 1.0 - saturate(pow(length(vpos_start - vpos) / RADIUS, 16));

float fadeout = min(min(fs, fadeout_z), fadeout_radius);
```

### Screen Edge Fadeout

```hlsl
float2 fadeout_2 = saturate(abs(view_projected.xy));
float fs = saturate(1 - length(fadeout_2));
```

In normalized device coordinates, screen edges occur at `xy = ±1`. Taking the absolute value and saturating maps this to [0, 1] where 0 is center, 1 is edge. Subtracting from 1 creates the fadeout: `1.0` at center, `0.0` at edges.

Using `length()` creates a radial falloff rather than axis-aligned. Reflections fade smoothly toward screen corners instead of hard edges along axes.

**Why this matters**: Rays that point toward screen edges will soon sample coordinates outside [0, 1], returning invalid data. Fading before this happens prevents abrupt "pop" as reflections disappear.

### Depth Fadeout

```hlsl
float fadeout_z = saturate(view_projected.z);
```

In view space, Z increases with distance from the camera. When `view_projected.z` approaches 1.0 (the far plane), depth precision degrades and artifacts increase. Saturating directly creates a fadeout for rays approaching the far plane.

This prevents flickering reflections for distant geometry where depth buffer precision is lowest.

### Distance Fadeout

```hlsl
float fadeout_radius = 1.0 - saturate(pow(length(vpos_start - vpos) / RADIUS, 16));
```

This fades reflections as the ray approaches its maximum travel distance. The formula has three components:

1. `length(vpos_start - vpos)` — Total distance traveled
2. `/ RADIUS` — Normalize to [0, 1] range
3. `pow(..., 16)` — Apply steep falloff curve

The exponent of 16 creates a sharp dropoff. At 90% of max radius, the factor is `pow(0.9, 16) = 0.185`, already faded. At 95%, it's `pow(0.95, 16) = 0.44`. This means reflections stay nearly full strength until close to the limit, then drop rapidly.

**Why not linear?** A linear fadeout would gradually dim reflections as they get farther, which looks unnatural. The sharp falloff maintains visual clarity until the reflection is about to fail, then hides the failure gracefully.

### Combined Fadeout

```hlsl
float fadeout = min(min(fs, fadeout_z), fadeout_radius);
```

Taking the minimum of all factors means ANY boundary condition triggers fadeout. If the ray is near the screen edge OR far from camera OR near max radius, the reflection fades. This is conservative but effective—better to fade early than show artifacts.

## Mip Level Selection for Rough Surfaces

**File**: `Projects/Clean Slate/cleanslate.apx:48377`

When sampling the reflected color, roughness controls blur:

```hlsl
float4 reflection = Textur.SampleLevel(sm, scr, dt.w * 16);
```

The third parameter to `SampleLevel` is the mip level. For a texture with 16 mip levels (4096×4096 → 1×1), `mip = 0` is full resolution and `mip = 16` is 1×1.

Multiplying roughness (`dt.w`, range 0-1) by 16 maps:
- `roughness = 0.0` → `mip = 0` (sharp, full-resolution reflection)
- `roughness = 0.5` → `mip = 8` (16× downsampled, blurred)
- `roughness = 1.0` → `mip = 16` (maximum blur)

This creates physically plausible rough reflections where microfacet scattering blurs the reflected image. The blur comes "for free" from the mipmap chain generated during post-processing or render target creation.

Key insight: This is NOT a true microfacet integration (which would require multiple samples per pixel). It's an approximation that leverages existing GPU hardware (mipmap filtering) to create perceptually correct roughness.

## Final Compositing

**File**: `Projects/Clean Slate/cleanslate.apx:48383`

The reflection is additively blended with the background:

```hlsl
return background + reflection * fadeout * background.w * (1 - dt.w);
```

Breaking down the modulation:

- `reflection` — The sampled color from the reflected screen coordinate
- `fadeout` — The combined boundary fadeout factor (0 to 1)
- `background.w` — The reflection mask (0 for matte, 1 for reflective)
- `(1 - dt.w)` — Roughness attenuation (rough surfaces get less sharp reflection)

The final term `(1 - dt.w)` is interesting. Rougher surfaces not only blur the reflection (via mip level) but also receive less of it. This simulates the energy loss in microfacet scattering—rough surfaces scatter light in many directions, reducing the intensity along any single reflection vector.

**Why additive?** Reflections add light to the scene. They don't replace the surface color; they augment it. This is physically correct for specular reflections, which are additional light bounces on top of the surface's direct illumination.

## Performance Characteristics

SSR's cost scales with several factors:

### Per-Pixel Cost

Only pixels with `mask > 0` execute the full shader. Matte surfaces exit early after one texture load and comparison. For a scene with 30% reflective surfaces, this saves 70% of the cost.

### Linear with Steps

Each ray march step requires:
1. Vector addition (ray advance)
2. Matrix multiply (projection)
3. Perspective divide (3 divisions)
4. Two texture fetches (depth, reconstruction)
5. Distance calculation and comparison

At 40 steps per pixel, this is 40× these operations. Modern GPUs execute this efficiently (texture fetches are highly optimized), but it's still the dominant cost.

### No Coherence

SSR exhibits poor cache coherence because adjacent pixels march in different directions, sampling scattered screen locations. This reduces texture cache efficiency compared to algorithms with spatial coherence.

### No Temporal Filtering

Clean Slate's SSR implementation has no temporal component. Each frame is independent. Modern game SSR implementations often use temporal accumulation to amortize cost (fewer steps per frame, accumulate across frames). This requires motion vectors and temporal filtering, adding complexity.

## Limitations and Artifacts

### Off-Screen Content

The most fundamental limitation: reflections can only show what's on screen. Objects behind the camera or beyond screen edges vanish from reflections. This creates the "screen edge artifact" where reflections disappear as surfaces angle toward screen edges.

The fadeout system masks this gracefully, but doesn't solve it. The only true solution is a different technique (ray tracing, cubemaps) for off-screen content.

### Thin Geometry

Thin objects (like foliage or wires) may be missed if the ray steps over them. The step size must be small enough to catch the thinnest important geometry, which drives up the step count.

The proximity threshold (`dat.w * 0.1`) provides some tolerance, but fundamentally, discrete sampling can miss features smaller than the step size.

### Self-Intersection

Rays starting from a surface may immediately intersect that same surface. The proximity and depth checks handle this by requiring the ray to pass BEHIND the surface (depth test), not just near it. But grazing angles can still cause artifacts.

The accept bias parameter (`dat.w`) is manually tuned per scene to balance false positives (self-intersection) against false negatives (missing actual geometry).

### Backface Reflections

The depth buffer doesn't distinguish front-facing from back-facing geometry. A ray might intersect the back side of a surface and reflect it. This is physically incorrect (you can't see through objects) but can't be detected without storing face orientation.

Clean Slate doesn't address this explicitly, relying on scene design to avoid pathological cases (e.g., not placing thin walls at reflection angles).

### Temporal Instability

Without temporal filtering, reflections can shimmer as ray march paths change frame-to-frame. Camera motion causes screen-space coordinates to shift, altering which geometry is hit. This is most visible on rough surfaces where mip level changes frame-to-frame.

Demos often use motion blur or careful camera work to hide this. Games use temporal accumulation and reprojection.

## Comparison to Other Reflection Techniques

### SSR vs Cubemaps

| Aspect | SSR | Cubemaps |
|--------|-----|----------|
| Dynamic content | Yes | No (pre-rendered) |
| Off-screen content | No | Yes |
| Cost | Ray march per pixel | Single lookup |
| Roughness | Free (mips) | Needs pre-filtering |

Cubemaps complement SSR: use SSR for on-screen, cubemap for off-screen fallback.

### SSR vs Ray Tracing

| Aspect | SSR | Hardware RT |
|--------|-----|-------------|
| Accuracy | Screen-limited | Full scene |
| Cost | Fixed (march steps) | Variable (scene complexity) |
| Availability | Any GPU | Modern only |

SSR is a screen-space approximation. Ray tracing is ground truth. For demos targeting broad hardware, SSR is the pragmatic choice.

### SSR vs Planar Reflections

| Aspect | SSR | Planar |
|--------|-----|--------|
| Surface type | Any | Flat only |
| Render cost | One pass | Two passes |
| Quality | Approximate | Exact |

Planar reflections require rendering the scene twice (normal + mirrored). SSR reuses existing G-Buffer data. For non-planar surfaces, SSR is the only screen-space option.

## Data Flow Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│ G-BUFFER PASS (Previous Render Stage)                              │
│                                                                    │
│   Geometry Rendering → t0: Color + Reflection Mask (RGBA)         │
│                       → t1: Normal + Roughness (RGBA)             │
│                       → t7: Depth (R)                             │
└────────────────────────────────────┬───────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│ SSR PASS (Post-Processing)                                         │
│                                                                    │
│   For each pixel:                                                  │
│                                                                    │
│   1. EARLY EXIT CHECK                                              │
│      if (mask == 0) return background * boost                     │
│                                                                    │
│   2. SETUP                                                         │
│      - Load normal, roughness from t1                             │
│      - Transform normal to view space                             │
│      - Reconstruct view-space position from t7                    │
│      - Calculate reflection vector: reflect(V, N)                 │
│                                                                    │
│   3. RAY MARCH                                                     │
│      position = viewPos                                           │
│      stepVec = reflectionDir * (RADIUS / STEPS)                   │
│                                                                    │
│      for step in 0..STEPS:                                        │
│        position += stepVec                                        │
│        screenUV = project(position)                               │
│        sceneDepth = sample_depth(screenUV)                        │
│        scenePos = reconstruct_position(screenUV, sceneDepth)      │
│                                                                    │
│        if distance(scenePos, position) < threshold:               │
│          if sceneDepth < position.z:                              │
│            position -= stepVec  // Step back                      │
│            stepVec *= 0.5       // Refine                         │
│                                                                    │
│   4. FADEOUT CALCULATION                                           │
│      edgeFade = 1 - length(abs(screenUV))                         │
│      depthFade = saturate(position.z)                             │
│      distFade = 1 - pow(distance / RADIUS, 16)                    │
│      fade = min(edgeFade, depthFade, distFade)                    │
│                                                                    │
│   5. SAMPLE REFLECTION                                             │
│      mipLevel = roughness * 16                                    │
│      reflectionColor = sample_color(screenUV, mipLevel)           │
│                                                                    │
│   6. COMPOSITE                                                     │
│      final = background + reflectionColor * fade * mask * (1-roughness) │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Key Architectural Observations

### 1. Deferred Rendering Dependency

SSR only works in a deferred context. It requires the G-Buffer (normal, roughness) and depth buffer from a previous pass. Forward renderers would need to write these explicitly, adding overhead. This tight coupling makes SSR a natural fit for deferred pipelines.

### 2. Binary Refinement, Not Binary Search

The refinement strategy is subtle. It's not a traditional binary search that commits to an interval and repeatedly halves. Instead, it's an opportunistic refinement: keep marching linearly, but when you detect a near-hit, back up and narrow in. This handles complex geometry (multiple intersections along a ray) better than pure binary search.

### 3. Fadeout as Artifact Mitigation

All three fadeout factors address specific failure modes:
- Screen edge fadeout → Hides off-screen sampling
- Depth fadeout → Masks far-plane precision loss
- Distance fadeout → Conceals max-radius cutoff

This is defensive rendering: anticipate where the algorithm breaks, fade before it fails.

### 4. Mipmap Blur for Roughness

Using mip levels to approximate microfacet blur is clever resource reuse. The mipmap chain already exists (for texture filtering), and `SampleLevel` is cheap. True microfacet integration (importance sampling the BRDF) would require multiple rays per pixel. This is the kind of approximation that enables real-time rendering.

### 5. The Mask as Performance Gatekeeper

Storing the reflection mask in the color buffer's alpha channel enables early exit without an additional texture. For scenes with large matte regions (floors, walls), this saves huge amounts of computation. It's a small data layout decision with big performance implications.

## Implications for Rust/WGPU Framework

### Adopt: Binary Refinement Strategy

The step-back-and-halve approach translates directly to WGSL. It's more robust than pure linear marching without the complexity of hierarchical ray marching. Implement it as a core SSR algorithm.

### Adopt: Unified Fadeout Model

The three-factor fadeout system is worth copying. Expose `edge_fade_distance`, `depth_fade_distance`, and `distance_fade_exponent` as parameters. Default values should work for most scenes, but artists should be able to tweak.

### Modify: Temporal Accumulation

Modern SSR implementations benefit greatly from temporal filtering. Consider adding:
- Motion vector generation during G-Buffer pass
- Temporal reprojection to reuse previous frame's results
- Confidence tracking to detect disocclusions

This amortizes cost (fewer steps per frame) and stabilizes reflections across frames.

### Modify: Hierarchical March

For large scenes or high-resolution rendering, consider hierarchical ray marching:
1. Generate a mipmap chain of the depth buffer
2. March with large steps using low-res depth
3. Refine with small steps using high-res depth when close

This reduces average march length without missing geometry.

### Avoid: Single-Resolution Depth Sampling

Clean Slate samples depth at full resolution every step. For 4K rendering at 40 steps, that's a lot of memory bandwidth. Pre-compute a min-max depth pyramid and use it to accelerate marching (skip empty space).

### Consider: Stochastic Sampling

For rough reflections, jittered ray directions (importance-sampled around the reflection vector) can provide better convergence than single-ray mip sampling. This requires temporal accumulation to hide noise but produces more accurate rough reflections.

## Related Documents

For comprehensive coverage of the rendering system and reflections, see:

- **[../rendering/lighting.md](../rendering/lighting.md)** — Reflection techniques overview (SSR, planar, IBL)
- **[../rendering/deferred.md](../rendering/deferred.md)** — G-Buffer layout and position reconstruction
- **[../rendering/shaders.md](../rendering/shaders.md)** — Shader utilities and patterns
- **[pbr-pipeline.md](pbr-pipeline.md)** — PBR pipeline context for SSR as a post-process
- **[ltc-area-lighting.md](ltc-area-lighting.md)** — LTC area lights for light-source reflections

## Source References

| File | Lines | Description |
|------|-------|-------------|
| **cleanslate.apx** | 48260-48449 | SSR render technique and shader |
| — Shader code | 48268-48384 | Main pixel shader with ray march |
| — Parameters | 48386-48449 | Radius, Steps, Background extra, Accept bias |
| **Annotated shader** | screen-space-reflections.hlsl:1-184 | Readable version with comments |

### Material Parameters

The SSR material exposes four parameters via the `dat` constant buffer:

| Parameter | Component | Range | Purpose |
|-----------|-----------|-------|---------|
| Radius | `dat.x` | 0.0-1.0 | Maximum ray travel distance (× 64 × radmult) |
| Steps | `dat.y` | 0.0-1.0 | Ray march step count (× 255) |
| Background extra | `dat.z` | 0.0-0.5 | Brightness boost for non-reflective pixels |
| Accept bias | `dat.w` | 0.0-1.0 | Hit detection threshold (× 0.1) |

Typical values:
- Radius: 0.25 (16 units in view space)
- Steps: 0.16 (40 steps)
- Background extra: 0.0 (no boost)
- Accept bias: 0.1 (threshold ≈ 0.01 units)

These values balance quality (accurate reflections) against performance (reasonable step count) for a 1080p demo scene.
