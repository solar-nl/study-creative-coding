# Code Trace: LTC Area Lighting in Clean Slate

> Deep dive into Linearly Transformed Cosines for physically accurate sphere light integration.

Sphere area lights are visually distinct from point lights: they produce soft shadows, diffuse highlights, and specular reflections that spread across the surface. But computing the integral of light arriving from every point on a sphere's surface is expensive. Monte Carlo sampling works but introduces noise. The Linearly Transformed Cosines (LTC) technique, pioneered by Heitz et al. at Unity Labs, provides an analytical solution for polygonal area lights that Phoenix adapts for spheres.

This document traces how Clean Slate implements LTC-based sphere lights, from pre-computed lookup tables through horizon clipping to the final edge integration. The technique transforms the BRDF into a clamped cosine distribution that has a closed-form solution for polygonal light sources.

## The Core Insight: BRDF Transformation

The fundamental problem with area light integration is that the BRDF (especially GGX specular) has no closed-form integral over arbitrary shapes. However, the clamped cosine distribution does:

```
∫ max(0, cos(θ)) dω = π (for hemisphere)
∫ max(0, cos(θ)) dω = solid_angle_formula (for polygon)
```

LTC's insight: find a 3×3 matrix M that transforms the GGX BRDF lobe into a cosine distribution. Then transform the polygon by M⁻¹, integrate the cosine over the transformed polygon, and you get the GGX integral over the original polygon.

The matrix M varies with roughness and viewing angle, so it's pre-computed into lookup tables indexed by these parameters.

## LTC Lookup Tables

### Table 1: Transformation Matrix (ltc_1.h)

**File**: `apEx/Phoenix/ltc_1.h:1-109`

```c
unsigned char raw_ltc_1[] =
{
  248,59,251,59,251,59,251,59,251,59,251,59,251,59,...
};
int raw_ltc_1_size = 2048;
```

This 2048-byte table stores a 16×16 grid of 3×3 matrices encoded as four 16-bit floats per entry. The matrix is stored in a compressed form because it's symmetric with specific zeros:

```
M = | m00   0   m02 |
    |  0    1    0  |
    | m10   0   m11 |
```

Only four unique values need storage: `m00`, `m02`, `m10`, `m11`. At 16×16 resolution with 4 values × 2 bytes each, that's 2048 bytes.

### Table 2: Magnitude and Fresnel (ltc_2.h)

**File**: `apEx/Phoenix/ltc_2.h:1-37`

```c
unsigned char raw_ltc_2[] =
{
  255,255,255,255,253,250,246,238,227,211,192,...
};
int raw_ltc_2_size = 512;
```

This 512-byte table stores two 8-bit values per texel:
- **Channel 0**: LTC magnitude (energy normalization factor)
- **Channel 1**: Fresnel scale factor

At 16×16 resolution with 2 values per entry, that's 512 bytes.

## Texture Upload and Format

**File**: `apEx/Phoenix/phxEngine.cpp:298-336`

Phoenix converts the raw byte arrays into GPU textures:

```cpp
#ifdef LTC1
  static const D3D11_TEXTURE2D_DESC ltctex16 = {
    16, 16, 1, 1,
    DXGI_FORMAT_R16G16B16A16_FLOAT,  // 4 × 16-bit floats
    1, 0,
    D3D11_USAGE_DEFAULT,
    D3D11_BIND_SHADER_RESOURCE, 0, 0
  };

  for (int x = 0; x < 16 * 16; x++)
  {
    for (int y = 0; y < 4; y++)
      ltcdata[x * 4 + y] = ((unsigned short*)(raw_ltc_1))[x + 16 * 16 * y];
  }
  phxDev->CreateTexture2D(&ltctex16, &subData, &ltc1);
#endif

#ifdef LTC2
  static const D3D11_TEXTURE2D_DESC ltctex8 = {
    16, 16, 1, 1,
    DXGI_FORMAT_R8G8B8A8_UNORM,  // 4 × 8-bit normalized
    1, 0,
    D3D11_USAGE_DEFAULT,
    D3D11_BIND_SHADER_RESOURCE, 0, 0
  };

  for (int x = 0; x < 16 * 16; x++)
  {
    for (int y = 0; y < 2; y++)
      ((unsigned char*)ltcdata)[x * 4 + y] = ((unsigned char*)(raw_ltc_2))[x + 16 * 16 * y];
  }
  phxDev->CreateTexture2D(&ltctex8, &subData, &ltc2);
#endif
```

The swizzling loop interleaves the data: the original arrays are planar (all m00 values, then all m02 values, etc.) but GPU textures need interleaved RGBA channels.

## Material Parameter Binding

**File**: `apEx/Phoenix/Material.h:63-64`

```cpp
enum MATERIALPARAMTYPE
{
  // ...
  PARAM_LTC1,  // LTC matrix texture
  PARAM_LTC2,  // LTC magnitude/Fresnel texture
  PARAM_COUNT,
};
```

These parameter types allow materials to request the LTC textures. When a material using LTC is bound, the engine automatically sets the corresponding texture slots.

## Shader: Lighting Context Initialization

**File**: `Projects/Clean Slate/cleanslate.apx:41967-42005`

The shader begins by unpacking the G-Buffer and setting up the lighting context:

```hlsl
struct LightingContext
{
    float3 albedo, P, V, N, f0, R;
    float  roughness, metallic;
    float  NdotV, NdotL;
};

inline LightingContext InitLighting(int2 pixel, float2 uv)
{
    float4 t0 = t_0.Load(int3(pixel, 0));  // Albedo + Metalness
    float4 t1 = t_1.Load(int3(pixel, 0));  // Normal + Roughness
    float   d = t_7.Load(int3(pixel, 0)).x; // Depth

    LightingContext l;

    // Reconstruct world position from depth
    float4 a = mul(iviewmat, mul(iprojmat, float4(uv * 2 - 1, d, 1)));
    l.P = a.xyz / a.w;
    l.V = normalize(campos.xyz - l.P);

    l.albedo    = t0.xyz;
    l.metallic  = t0.w;
    l.N         = normalize(t1.xyz);
    l.roughness = t1.w;

    // Fix normals pointing away from view
    float t = dot(l.N, l.V);
    if (t < 0)
        l.N = normalize(l.N - 1.01 * l.V * t);

    l.NdotV = dot(l.N, l.V);
    l.f0    = lerp(0.04, l.albedo, l.metallic);
    l.R     = reflect(l.V, l.N);

    return l;
}
```

The normal fixup (`if (t < 0)`) handles back-facing normals that can occur with normal mapping or thin geometry. Without this, LTC calculations would produce negative results.

## Shader: LTC Matrix Sampling

**File**: `Projects/Clean Slate/cleanslate.apx:42007-42036`

The LTC tables are indexed by roughness and viewing angle:

```hlsl
struct LTCCommon
{
    float3 diffuseModifier;
    float3 specularModifier;
    float3x3 ltcMatrixDiffuse;
    float3x3 ltcMatrixSpecular;
};

LTCCommon InitLTC(LightingContext l)
{
    LTCCommon c;

    // Map roughness and angle to texture coordinates
    float2 ltcUV = float2(l.roughness, sqrt(1 - l.NdotV)) * 15./16 + 1./32;
    float4 t1 = ltc1.Sample(Sampler, ltcUV);  // Matrix coefficients
    float2 t2 = ltc2.Sample(Sampler, ltcUV).xy;  // Magnitude + Fresnel

    // Build tangent frame (T1, T2, N)
    float3 T1 = normalize(l.V - l.N * l.NdotV);  // View projected onto tangent plane
    float3 T2 = cross(l.N, T1);
    c.ltcMatrixDiffuse = float3x3(T1, T2, l.N);

    // Expand the 4 stored values into the full matrix
    float3x3 minv = float3x3(
        t1.x, 0,    t1.z,
        0,    1,    0,
        t1.y, 0,    t1.w
    );
    c.ltcMatrixSpecular = mul(minv, c.ltcMatrixDiffuse);

    // Fresnel interpolation for specular modifier
    c.specularModifier = lerp(t2.y, t2.x, l.f0);
    c.diffuseModifier  = l.albedo * (1 - l.metallic);

    return c;
}
```

Key observations:

1. **UV mapping**: The `sqrt(1 - NdotV)` term converts the cosine of the viewing angle to an angle-proportional coordinate, providing better sampling at grazing angles where BRDF changes rapidly.

2. **Texel center offset**: The `* 15/16 + 1/32` maps the 0-1 range to texel centers, avoiding edge sampling artifacts.

3. **Diffuse matrix**: For Lambertian diffuse, no transformation is needed—the matrix is just the tangent frame rotation.

4. **Specular matrix**: The stored `minv` is multiplied into the tangent frame, creating a combined transformation that accounts for both BRDF shape and surface orientation.

## Shader: Sphere Discretization

**File**: `Projects/Clean Slate/cleanslate.apx:42115-42131`

LTC works on polygons, but Clean Slate's lights are spheres. The solution: approximate the sphere's visible disc as a polygon:

```hlsl
float4 p(VSOUT v) : SV_TARGET0
{
    // ... initialization ...

    // Transform shading point to light's local space
    float4x4 i = transpose(itworldmat);
    float3 p = mul(i, float4(l.P, 1)).xyz;
    float3 r = mul(i, float4(l.R, 0)).xyz;
    float3 nd = normalize(p);  // Direction from light center to shading point
    float d = length(p);       // Distance from light center

    // Calculate visible disc radius using horizon geometry
    float scale = d / sqrt(4*d*d - 1);

    // Build rotation matrix to orient disc toward shading point
    float3 y = float3(0, -1, 0);
    float3 nx = normalize(cross(-nd, y));
    float4x4 discrotmat = AngleAxis3x3(dot(nd, y), nx);

    // Generate polygon vertices approximating the disc
    vertexCount = 24;  // 24 vertices for smooth circle
    for (uint x = 0; x < vertexCount; x++)
    {
        float r = radians(360) * x / vertexCount;
        points[x] = mul(worldmat,
            float4(mul(discrotmat,
                float4(cos(r), 0, sin(r), 0) * scale).xyz, 1)).xyz - l.P;
    }

    // ... LTC evaluation ...
}
```

The `scale = d / sqrt(4*d*d - 1)` formula comes from the geometry of a unit sphere: given distance `d` from center, the visible disc has angular radius `sin(θ) = 1/(2d)`, and the projected disc radius in world space is `scale`.

Using 24 vertices creates a smooth polygon that closely approximates the sphere's silhouette from any viewing angle.

## Shader: Polygon Clipping (Horizon Test)

**File**: `Projects/Clean Slate/cleanslate.apx:42042-42057`

Before integration, the polygon must be clipped to the hemisphere above the surface. Points below the horizon (z < 0 in transformed space) contribute no light:

```hlsl
float LTC_Evaluate(LightingContext l, float3x3 Minv, bool twoSided)
{
    float3 L[64];  // Clipped polygon vertices
    uint   n = 0;  // Vertex count after clipping

    for (uint x = 0; x < vertexCount; x++)
    {
        // Transform polygon vertex by inverse LTC matrix
        float3 current = mul(Minv, points[x]);
        float3 next    = mul(Minv, points[(x+1) % vertexCount]);

        // Keep vertices above horizon
        if (current.z > 0)
            L[n++] = normalize(current);

        // If edge crosses horizon, compute intersection
        if ((current.z > 0) != (next.z > 0))
            L[n++] = normalize(lerp(current, next, -current.z / (next.z - current.z)));
    }
    // ...
}
```

This is Sutherland-Hodgman clipping against the z=0 plane:
1. Keep vertices where `z > 0`
2. When an edge crosses z=0, add the intersection point
3. Normalize all vertices to project onto the unit sphere

The result is a polygon on the upper hemisphere that represents the visible portion of the light.

## Shader: Edge Integration

**File**: `Projects/Clean Slate/cleanslate.apx:42059-42078`

The integral of a clamped cosine over a spherical polygon has a closed-form solution using edge integration:

```hlsl
    float sum = 0;

    // Integrate edges
    for (uint i = 0; i < n; i++)
    {
        float3 v1 = L[i];
        float3 v2 = L[(i+1) % n];

        float x = dot(v1, v2);
        float y = abs(x);

        // Rational polynomial approximation to acos(x)*sin(acos(x))
        float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
        float b = 3.4175940 + (4.1616724 + y)*y;
        float v = a / b;

        float theta_sintheta = (x > 0) ? v : 0.5/sqrt(max(1 - x*x, .0000001)) - v;
        sum += (cross(v1, v2) * theta_sintheta).z;
    }

    return twoSided ? abs(sum) : max(0, -sum);
}
```

This implements the formula from Heitz et al.:

```
∫_polygon cos(θ) dω = Σ_edges (v1 × v2).z × F(v1·v2)
```

Where `F(x) = acos(x) / sin(acos(x))` is approximated by the rational polynomial `a/b` for efficiency.

The `cross(v1, v2).z` term gives the signed area contribution of each edge when projected onto the z-axis (normal direction). The `theta_sintheta` term accounts for the spherical geometry—edges farther from the pole contribute differently than edges near it.

The sign convention: negative sum for diffuse/specular because of the polygon winding order, hence `max(0, -sum)` for one-sided lights.

## Final Lighting Composition

**File**: `Projects/Clean Slate/cleanslate.apx:42133-42137`

```hlsl
    LTCCommon c = InitLTC(l);
    float3 diff = LTC_Evaluate(l, c.ltcMatrixDiffuse,  true) * c.diffuseModifier;
    float3 spec = LTC_Evaluate(l, c.ltcMatrixSpecular, true) * c.specularModifier;

    return lightColor * float4(spec + diff, 1);
```

Two evaluations: one for diffuse (using the tangent-frame-only matrix) and one for specular (using the full LTC-transformed matrix). Each is modulated by its color/energy term.

## Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PRE-COMPUTATION (Offline)                                               │
│                                                                         │
│   GGX BRDF → Fit LTC matrices → Store in ltc_1.h, ltc_2.h              │
│                                                                         │
│   Table 1: 16×16 × 4 half-floats = 2KB (matrix coefficients)           │
│   Table 2: 16×16 × 2 bytes = 512B (magnitude + Fresnel)                │
└────────────────────────────────────────┬────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ ENGINE INITIALIZATION                                                   │
│                                                                         │
│   phxEngine.cpp:                                                       │
│     1. Swizzle planar data to interleaved RGBA                        │
│     2. Create ltc1 as R16G16B16A16_FLOAT texture                      │
│     3. Create ltc2 as R8G8B8A8_UNORM texture                          │
└────────────────────────────────────────┬────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PER-FRAME: Sphere Light LTC Shader                                      │
│                                                                         │
│   1. InitLighting()                                                     │
│      - Unpack G-Buffer (albedo, metallic, normal, roughness)           │
│      - Reconstruct world position from depth                           │
│      - Compute view vector, reflection vector                          │
│                                                                         │
│   2. InitLTC()                                                          │
│      - Sample ltc1, ltc2 using (roughness, angle) as UV               │
│      - Build tangent frame from view and normal                        │
│      - Construct diffuse matrix (identity in tangent space)            │
│      - Construct specular matrix (LTC transform × tangent frame)       │
│      - Compute diffuse/specular color modifiers                        │
│                                                                         │
│   3. Sphere Discretization                                              │
│      - Calculate visible disc scale from distance                      │
│      - Generate 24-vertex polygon approximating disc                   │
│      - Transform vertices to shading point's coordinate frame         │
│                                                                         │
│   4. LTC_Evaluate() × 2 (diffuse + specular)                           │
│      - Transform polygon by M⁻¹                                        │
│      - Clip polygon to upper hemisphere (z > 0)                        │
│      - Compute edge integral using rational approximation              │
│      - Return irradiance                                                │
│                                                                         │
│   5. Compose final color                                                │
│      - diffuse_irradiance × diffuse_modifier                           │
│      - specular_irradiance × specular_modifier                         │
│      - Multiply by light color                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Architectural Observations

### 1. Minimal Storage (2.5 KB Total)

The entire LTC apparatus requires only 2560 bytes of lookup tables. For a 64k intro, this is a worthwhile investment for physically accurate area lights without runtime noise or temporal instability.

### 2. Two-Pass Evaluation Pattern

The same `LTC_Evaluate()` function handles both diffuse and specular by accepting different matrices. This code reuse is elegant: the algorithm is identical, only the transformation differs.

### 3. Polygon Approximation Trade-off

Using 24 vertices for sphere discretization is a balance between accuracy (more vertices = rounder circle) and performance (fewer vertices = faster integration). For spheres, this is more than sufficient—the visual difference from a true sphere integral is imperceptible.

### 4. Analytical vs. Monte Carlo

LTC provides deterministic results every frame. There's no temporal noise requiring TAA or denoising. For demos where visual cleanliness matters and rendering budgets are tight, this determinism is valuable.

### 5. The Fresnel Interpolation

```hlsl
c.specularModifier = lerp(t2.y, t2.x, l.f0);
```

This interpolates between two pre-computed Fresnel-related values based on the surface's F0. The lookup table bakes in the Fresnel behavior, avoiding per-pixel Schlick evaluation in the integration loop.

## Comparison: LTC vs. Analytical Approximation

Clean Slate includes both approaches. The non-LTC sphere light (documented in pbr-pipeline.md) uses:
- `SphereHorizonCosWrap()` for horizon clipping
- `EnergyNormalization()` for representative point
- `SpecularGGX()` for point-evaluated BRDF

The LTC approach instead uses:
- Full polygon clipping
- Transformed polygon integration
- Pre-computed BRDF transformation

**When to use which:**
- LTC: Larger area lights, low roughness (sharp highlights), accuracy critical
- Analytical: Smaller lights, high roughness, performance critical

## Implications for Rust Implementation

1. **LTC tables**: Ship as embedded `include_bytes!()` data. The 2.5KB footprint is trivial for any modern application.

2. **Texture format**: WGPU supports both `Rgba16Float` and `Rgba8Unorm`. The upload logic is straightforward.

3. **Polygon representation**: A fixed-size array (e.g., `[Vec3; 64]`) works well. Consider a generic polygon type for other area light shapes (rectangles, arbitrary quads).

4. **Clipping**: The Sutherland-Hodgman clipper is simple to implement. Consider making it generic over the clip plane for reuse.

5. **Edge integration**: The rational approximation is just math—translates directly to Rust/WGSL with no architecture changes.

6. **Shader variants**: Consider whether to compile separate shaders for different light types or use dynamic branching. For a small number of area lights, separate shaders likely win on GPU occupancy.
