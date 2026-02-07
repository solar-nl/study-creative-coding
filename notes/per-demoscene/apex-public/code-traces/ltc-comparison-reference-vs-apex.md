# LTC Comparison: Reference Implementation vs. Apex/Phoenix Engine

Comparative analysis of the [selfshadow/ltc_code](https://github.com/selfshadow/ltc_code) reference implementation by Eric Heitz et al. versus Conspiracy's (boyc) implementation in the Apex/Phoenix 64kb intro engine for "Clean Slate".

## TL;DR

The core LTC algorithm is preserved nearly verbatim — identical edge integration coefficients, matrix reconstruction, and Fresnel handling. The 64kb simplifications are concentrated in three areas: **16x smaller LUT** (16x16 vs 64x64), **reduced precision for Fresnel/magnitude** (8-bit vs 16-bit), and **sphere-only light shapes** (discretized polygon vs native quad). A clever "optimized" variant further reduces polygon count from 24 to 8 vertices by orienting the disc based on roughness-weighted reflection direction.

## What is LTC?

Linearly Transformed Cosines (LTC) solves the area light integral by transforming the BRDF lobe into a simple cosine distribution that has a closed-form solution for polygonal lights. A 3x3 matrix M (varying with roughness and view angle) warps the BRDF shape; you then transform the light polygon by M⁻¹, integrate the cosine over the warped polygon using edge integrals, and recover the exact BRDF integral over the original polygon. This lets you evaluate physically accurate GGX specular highlights from quad/disk/sphere lights with zero noise and no Monte Carlo sampling.

## The 64kb Constraint

For context in a 64kb intro:

```
Total executable budget:          65,536 bytes

LTC data (Apex):                   3,072 bytes  (4.7%)
  - ltc_1 (matrix):               2,048 bytes
  - ltc_2 (fresnel):              1,024 bytes

LTC data (if reference):         65,536 bytes  (100% - impossible)

Shader code (estimated):          ~1,500 bytes  (before compression)
  - Standard variant:               ~800 bytes
  - Optimized variant:               ~700 bytes
```

The reference LUTs alone would consume the entire intro. Conspiracy's 21x reduction makes LTC viable for 64kb, with the 3 KB data cost being a reasonable trade for physically accurate area lighting with zero noise.

---

## 1. Lookup Table Comparison

This is where the largest size savings come from.

### Resolution

| | Reference | Apex |
|---|---|---|
| **Grid** | 64 x 64 | 16 x 16 |
| **Texels** | 4,096 | 256 |
| **Ratio** | 1x | 16x fewer |

The reference parameterizes by `(sqrt(alpha), sqrt(1 - cos(theta)))` across 64 steps each. Apex uses the same parameterization but with only 16 steps. Both use the scale/bias trick to map UV coordinates to texel centers:

```
Reference: uv * (63/64) + (1/128)     // LUT_SCALE, LUT_BIAS
Apex:      uv * (15/16) + (1/32)      // same formula, different N
```

At 16x16 the bilinear hardware interpolation does real work — every sample is a blend of 4 pre-fitted matrices. This works because the LTC matrix components vary smoothly across roughness and view angle. Discontinuities would cause visible banding, but the underlying BRDF (GGX) has no discontinuities in this parameter space.

### Format & Precision

**LTC Matrix (ltc_1):**

| | Reference | Apex |
|---|---|---|
| **Format** | R16G16B16A16_FLOAT | R16G16B16A16_FLOAT |
| **Per-texel** | 8 bytes | 8 bytes |
| **Total** | 32,768 bytes | 2,048 bytes |

Both store the same 4 matrix components at half-float precision. The matrix needs this precision because small differences in the off-diagonal terms (m02, m20) directly affect specular highlight shape.

**Fresnel/Magnitude (ltc_2):**

| | Reference | Apex |
|---|---|---|
| **Format** | R16G16B16A16_FLOAT | R8G8B8A8_UNORM |
| **Channels used** | 4 (magnitude, fresnel, unused, sphere) | 2 (magnitude, fresnel) |
| **Per-texel** | 8 bytes | 4 bytes |
| **Total** | 32,768 bytes | 1,024 bytes |

The reference stores an additional "sphere clipping" integral in the `.w` channel for its clipless approximation path. Apex drops this entirely (no clipless path) and uses 8-bit UNORM instead of 16-bit float for magnitude and Fresnel. This is safe because these values are smooth multipliers in [0, 1] — 256 levels of quantization is imperceptible.

### Total LUT Size

| | Reference | Apex | Savings |
|---|---|---|---|
| **ltc_1** | 32,768 B | 2,048 B | 16x |
| **ltc_2** | 32,768 B | 1,024 B | 32x |
| **Total** | 65,536 B (64 KB) | 3,072 B (3 KB) | ~21x |

For a 64kb intro, the reference LUTs alone would consume the entire executable. Apex's 3 KB is <5% of the budget.

---

## 2. Matrix Reconstruction

**Identical.** Both reconstruct the 3x3 inverse LTC matrix from 4 stored values:

Reference (GLSL):
```glsl
mat3 Minv = mat3(
    vec3(t1.x, 0, t1.y),
    vec3(  0,  1,    0),
    vec3(t1.z, 0, t1.w)
);
```

Apex (HLSL):
```hlsl
float3x3 minv = float3x3(
    t1.x, 0, t1.z,
    0,    1,    0,
    t1.y, 0, t1.w
);
```

The component swizzle differs (`t1.y`/`t1.z` swapped) because GLSL `mat3` is column-major while HLSL `float3x3` is row-major. The resulting matrix is mathematically identical.

Both exploit the fact that the fitted LTC matrix, when normalized by M[1][1], has a constrained structure with zeros in the y-row/column (due to isotropic BRDF symmetry), reducing 9 components to 4.

---

## 3. Edge Integration

**Identical coefficients.** This is the core of the LTC technique — integrating the cosine distribution over each polygon edge.

Reference (GLSL):
```glsl
float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
float b = 3.4175940 + (4.1616724 + y)*y;
float v = a / b;
float theta_sintheta = (x > 0.0) ? v : 0.5*inversesqrt(max(1.0 - x*x, 1e-7)) - v;
return cross(v1, v2)*theta_sintheta;
```

Apex (HLSL):
```hlsl
float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
float b = 3.4175940 + (4.1616724 + y)*y;
float v = a / b;
float theta_sintheta = (x > 0) ? v : 0.5/sqrt(max(1 - x*x, .0000001)) - v;
sum += (cross(v1, v2)*theta_sintheta).z;
```

The only differences are syntactic:
- `inversesqrt()` vs `1/sqrt()` (same operation)
- `1e-7` vs `.0000001` (same epsilon)
- Reference returns vec3, Apex extracts `.z` inline

The rational polynomial `a/b` approximates `acos(x)/sin(acos(x))` — the projected solid angle integral kernel. These 5 coefficients (0.8543985, 0.4965155, 0.0145206, 3.4175940, 4.1616724) are hand-fitted to the exact function and match to <0.1% relative error across [0,1].

---

## 4. Horizon Clipping

This is a **significant structural difference**.

### Reference: 16-Case Lookup Table (Quad Only)

The reference clips a 4-vertex quad to the z=0 horizon using a hardcoded 16-case bitmask:

```glsl
void ClipQuadToHorizon(inout vec3 L[5], out int n) {
    int config = 0;
    if (L[0].z > 0.0) config += 1;
    if (L[1].z > 0.0) config += 2;
    if (L[2].z > 0.0) config += 4;
    if (L[3].z > 0.0) config += 8;
    // ... 16 cases, each with hardcoded vertex interpolation
}
```

This produces at most 5 vertices (quad clipped to pentagon). It's branchless within each case and highly optimized — no loops, no dynamic allocation. But it **only works for quads**.

### Apex: Sutherland-Hodgman (N-vertex Polygon)

Apex needs to clip arbitrary N-gon polygons (sphere discretized to 24 or 8 vertices), so it uses a generic Sutherland-Hodgman loop:

```hlsl
for (uint x = 0; x < vertexCount; x++) {
    float3 current = mul(Minv, points[x]);
    float3 next    = mul(Minv, points[(x+1) % vertexCount]);

    if (current.z > 0)
        L[n++] = normalize(current);

    if ((current.z > 0) != (next.z > 0))
        L[n++] = normalize(lerp(current, next, -current.z/(next.z - current.z)));
}
```

Trade-offs:
- More flexible (any vertex count)
- Dynamic loop with modulo arithmetic (slightly less GPU-friendly)
- Normalizes vertices inside the clip loop (reference normalizes after)
- Uses 64-element arrays for worst-case polygon size
- `(x+1)%vertexCount` modulo is computed per-iteration (reference avoids modulo entirely)

### Clipless Path

The reference also offers a "clipless approximation" that skips clipping entirely, instead using the pre-computed sphere integral in `ltc_2.w` to normalize the result. This avoids all branching from the clip test. **Apex does not implement this path** — it always clips. The sphere integral data isn't even stored in Apex's ltc_2 table.

This omission is a non-issue. The clipless path is itself an approximation that trades accuracy for performance by skipping horizon tests. The clipped path is more accurate, and for sphere lights with proper geometry discretization (8-24 vertices), the clipping overhead is negligible. The 1KB saved by dropping the sphere integral channel is more valuable to a 64kb intro than the marginal performance gain from clipless evaluation.

---

## 5. Light Geometry

### Reference: Native Quad/Rect

The reference evaluates LTC over a **flat rectangular light** (4 corners). This is the natural geometric primitive for LTC — the polygon integral directly operates on the quad vertices.

Also includes separate shaders for **disk** and **line** lights with specialized math (ellipse eigenvalue decomposition for disk, closed-form line segment integrals).

### Apex: Sphere Discretized to Polygon

Apex only has sphere area lights, which it approximates by computing the visible disc and discretizing it:

```hlsl
float d = length(p);
float scale = d / sqrt(4*d*d - 1);  // visible disc radius from external tangent

for (uint x = 0; x < vertexCount; x++) {
    float r = radians(360) * x / vertexCount;
    points[x] = mul(worldmat, mul(discrotmat, float4(cos(r),0,sin(r),0) * scale)).xyz - l.P;
}
```

The formula `d / sqrt(4d^2 - 1)` computes the apparent disc radius of a unit sphere at distance `d`, as seen from the tangent point. The disc is oriented to face the shading point and sampled at 24 (standard) or 8 (optimized) evenly-spaced angles.

This is a **simplification that trades geometric fidelity for generality** — rather than implementing separate quad/disk/line shaders, one generic polygon evaluator handles everything. The trade-off: sphere → polygon approximation introduces slight faceting in specular reflections (more visible with 8 vertices than 24).

---

## 6. The "Optimized" Variant

Apex has a unique optimization not present in the reference: **roughness-aware polygon rotation**.

### Standard (24 vertices)
Simple uniform sampling of the disc — all vertices evenly spaced.

### Optimized (8 vertices)
With only 8 vertices, the octagon's flat edges would be visible in sharp specular reflections. To mitigate this, the optimized variant rotates the polygon to align one edge with the dominant reflection direction:

```hlsl
// Transform to disc-local space
p = mul(ir, float4(p, 1)).xyz;
r = mul(ir, float4(r, 0)).xyz;

// Intersect reflection ray with disc plane
r = p - r * p.y / r.y;
p.y = 0;

// Blend between reflection point and center based on roughness
float3 it = lerp(r, p, l.roughness);
float addRot = -atan2(it.x, it.z);

// Apply rotation to polygon generation
float r = radians(360) * x / vertexCount + addRot;
```

At low roughness, `lerp(r, p, roughness)` approaches `r` (the reflection point), so the polygon rotates to place an edge perpendicular to the specular peak. At high roughness it approaches `p` (the center), where rotation doesn't matter because the highlight is diffuse. This is a classic demoscene trick — spending ALU to compensate for reduced geometry.

---

## 7. Tangent Frame Construction

**Identical approach, different integration point.**

Reference (inside `LTC_Evaluate`):
```glsl
T1 = normalize(V - N*dot(V, N));
T2 = cross(N, T1);
Minv = mul(Minv, transpose(mat3(T1, T2, N)));
// Then: L[i] = mul(Minv, points[i] - P);
```

Apex (in `InitLTC`, pre-multiplied):
```hlsl
T1 = normalize(V - N * NdotV);
T2 = cross(N, T1);
ltcMatrixDiffuse  = float3x3(T1, T2, N);
ltcMatrixSpecular = mul(minv, ltcMatrixDiffuse);
// Then in LTC_Evaluate: current = mul(Minv, points[x]);
```

The reference computes the tangent frame per-evaluation inside `LTC_Evaluate`. Apex pre-multiplies the LTC matrix with the tangent frame once in `InitLTC`, then the evaluate function just does `mul(Minv, points[x])`. This avoids recomputing the same tangent frame for both diffuse and specular evaluations.

For diffuse, the reference passes `mat3(1)` (identity), while Apex passes `ltcMatrixDiffuse` which is the tangent frame itself (identity times tangent frame = tangent frame). Mathematically identical.

---

## 8. Fresnel & Energy Conservation

**Mathematically identical, written differently.**

Reference:
```glsl
spec *= scol*t2.x + (1.0 - scol)*t2.y;
```

Apex:
```hlsl
specularModifier = lerp(t2.y, t2.x, f0);
```

Where `scol` = specular color (reference) and `f0` = Fresnel reflectance at normal incidence (Apex). Both compute `lerp(fresnel_scale, magnitude, F0)`. The reference uses explicit form `a*x + (1-a)*y`; Apex uses HLSL `lerp(y, x, a)`. Same result.

The reference applies this per-evaluation. Apex stores it as `specularModifier` and multiplies after evaluation — minor structural difference, same output.

---

## 9. Feature Comparison Matrix

| Feature | Reference | Apex Standard | Apex Optimized |
|---|:---:|:---:|:---:|
| **LUT Resolution** | **64x64** | **16x16** | **16x16** |
| **LUT Total Size** | **64 KB** | **3 KB** | **3 KB** |
| **Matrix Precision** | float16 | float16 | float16 |
| **Fresnel Precision** | float16 | uint8 | uint8 |
| **Light Shapes** | Quad, Disk, Line | Sphere | Sphere |
| **Polygon Vertices** | **4 (native quad)** | **24** | **8** |
| **Clipping Method** | 16-case bitmask | Sutherland-Hodgman | Sutherland-Hodgman |
| **Clipless Path** | Yes (sphere LUT) | No | No |
| **Roughness-Aware Rotation** | **No** | **No** | **Yes** |
| **Tone Mapping** | ACES (in shader) | External (engine) | External (engine) |
| **Rendering Path** | Forward (ray-floor) | Deferred (G-buffer) | Deferred (G-buffer) |
| **Normal Fixup** | No | Yes | Yes |
| **Edge Integration Coefficients** | 5 fitted constants | Same 5 constants | Same 5 constants |
| **BRDFs Fitted** | GGX, Beckmann, Disney | GGX only | GGX only |
| **Accumulation/MIS** | Yes (demo) | No (single frame) | No (single frame) |

---

## 10. What's Preserved vs. Simplified

### Preserved Verbatim
- LTC matrix structure (4 of 9 components, normalized by M[1][1])
- Edge integration rational polynomial (all 5 coefficients)
- Tangent frame construction formula
- LUT parameterization: `(roughness, sqrt(1 - NdotV))`
- Fresnel blending formula
- Half-float precision for matrix components

### Simplified for 64kb
- **LUT resolution**: 64x64 → 16x16 (16x fewer entries, relying on bilinear interpolation)
- **Fresnel/magnitude precision**: float16 → uint8 (negligible quality impact)
- **Clipless path removed**: Always clips, never uses sphere integral approximation
- **Light shape**: Quad → sphere-only (discretized to N-gon polygon)
- **Fitting code eliminated**: Pre-baked LUT embedded as raw bytes in C header
- **Single BRDF**: Only GGX (no Beckmann, no Disney Diffuse fitting)
- **Disk/line shaders removed**: No specialized closed-form integrals

### Added by Apex (Not in Reference)
- **Roughness-aware polygon rotation** (optimized variant) — compensates for 8-vertex coarseness
- **Normal fixup for back-facing normals** — prevents artifacts from normal mapping
- **NaN guard for light body rendering** — uses NaN as sentinel for "draw the light itself"
- **Deferred rendering integration** — G-buffer unpacking, depth reconstruction

---

## 11. Quality Impact Assessment

| Simplification | Visual Impact | When Noticeable |
|---|---|---|
| 16x16 LUT | Very low | Only at extreme grazing angles with rapid roughness transitions |
| 8-bit Fresnel | Negligible | Never in practice — smooth multiplier with 256 levels |
| 24-vertex sphere | Low | Very smooth circles, minimal faceting |
| 8-vertex sphere | Moderate | Sharp specular on smooth surfaces (mitigated by rotation trick) |
| No clipless path | None | Clipless is an approximation anyway; clipped path is more accurate |
| No disk/line lights | Feature gap | Artistic constraint, not quality loss for spheres |

The 16x16 LUT is the biggest potential quality concern. At critical angles (highly glossy surface, grazing view), the bilinear interpolation between 16 samples might produce slightly softer specular transitions than 64 samples. In practice, for a demoscene production with carefully art-directed scenes, this is imperceptible — the camera angles and material roughness values are chosen by the artist.

---

## 12. Implications for Framework Design

Key takeaways for a Rust-based creative coding framework implementing LTC:

- **Ship 64x64 LUTs by default, but make resolution configurable.** The reference 64x64 tables provide highest quality and are only 64 KB — trivial for desktop/web. Expose a build-time or runtime option to substitute 16x16 tables for embedded/mobile targets where storage matters.

- **Implement generic polygon clipping, not quad-only.** Sutherland-Hodgman is more flexible than hardcoded bitmask clipping and only slightly slower. This future-proofs the API for disk lights (discretized polygons), line lights (degenerate quads), and arbitrary convex light shapes.

- **Offer both quality levels as an explicit choice.** Expose "Standard" (24 vertices) and "Performance" (8 vertices with rotation) as named presets rather than magic numbers. Let users benchmark and choose based on their target platform and artistic requirements.

- **Consider clipless as an opt-in fast path.** For very high-poly scenes with many small area lights, the clipless approximation can be a useful optimization. Store the sphere integral channel in the LUT and provide a separate evaluation function that skips clipping.

- **Document the precision trade-offs.** Make it clear that Fresnel/magnitude can safely use 8-bit (or even lower for extreme size constraints) without visual degradation, but matrix components need at least 16-bit float to avoid specular highlight distortion.

---

## References

- Heitz, E., Dupuy, J., Hill, S., & Neubelt, D. (2016). "Real-Time Polygonal-Light Shading with Linearly Transformed Cosines." ACM SIGGRAPH 2016.
- [selfshadow/ltc_code](https://github.com/selfshadow/ltc_code) — Reference implementation
- `area-sphere-light-ltc.hlsl` — Apex standard LTC shader (246 lines)
- `area-sphere-light-ltc-optimized.hlsl` — Apex optimized variant (257 lines)
- `ltc_1.h`, `ltc_2.h` — Apex pre-baked LUT data (Phoenix engine)
