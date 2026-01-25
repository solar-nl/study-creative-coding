# apEx Shader Architecture

Shaders in Phoenix face a unique constraint: they must be sophisticated enough for production-quality PBR, yet compact enough to fit in a 64k executable after compression. This pushes toward mathematical elegance over brute-force techniques. Every line of HLSL must justify its bytes through visual impact.

The shader architecture organizes around conventions rather than frameworks. Constant buffers occupy specific slots. Textures bind to numbered registers. The Cook-Torrance BRDF implements in standalone functions reusable across materials. This convention-based approach enables shader authors to share code without linking overhead—just copy the functions you need.

Phoenix shaders divide into two categories: geometry shaders that write to the G-Buffer, and lighting shaders that read the G-Buffer and calculate illumination. Both categories share the same constant buffer layout and texture conventions. A lighting shader can be swapped without changing the G-Buffer shader, and vice versa.

## Constant Buffer Layout

### Scene Constant Buffer (Slot 0)

The scene buffer contains data shared across all objects in a render pass. It binds to register `b0` in all shader stages.

```hlsl
cbuffer SceneData : register(b0)
{
    // Camera matrices (64 bytes each)
    float4x4 viewmat;          // View matrix
    float4x4 projmat;          // Projection matrix

    // Camera position (16 bytes)
    float4 campos;             // World-space camera position

    // Light data (16 + 8 * 64 = 528 bytes)
    float4 lightcount;         // .x = active light count
    float4 lights[8 * 4];      // 8 lights × 4 float4s each

    // Render target info (16 bytes)
    float4 resolution;         // .xy = size, .zw = 1/size

    // Inverse matrices (64 bytes each)
    float4x4 iviewmat;         // Inverse view
    float4x4 iprojmat;         // Inverse projection
};
```

The light data packs into `float4` arrays for compatibility with older shader models. Each light occupies 4 `float4` slots:
- Position (or direction for directional lights)
- Ambient color
- Diffuse color
- Specular color + spot parameters

**Resolution reciprocals** are a micro-optimization. Instead of `uv / resolution.xy` in shaders, use `uv * resolution.zw`. Division was historically slower than multiplication on GPUs.

### Object Constant Buffer (Slot 1)

The object buffer contains per-draw-call data: transformation matrices and material parameters. It binds to register `b1`.

```hlsl
cbuffer ObjectData : register(b1)
{
    // Transformation matrices (64 bytes each)
    float4x4 worldmat;         // Object-to-world
    float4x4 itworldmat;       // Inverse-transpose (for normals)

    // Material parameters (variable size)
    float4 data;               // Generic material data
    // Additional parameters as needed...
};
```

The **inverse-transpose matrix** transforms normal vectors correctly under non-uniform scaling. Standard matrix multiplication would distort normals; the inverse-transpose preserves perpendicularity to surfaces.

Material-specific data packs into `float4` slots following the matrices. The exact layout depends on the material's parameter declarations. A PBR material might use:
- `data.x` — Roughness modifier
- `data.y` — Metalness modifier
- `data.z` — Normal flip flag
- `data.w` — Reserved

### Buffer Binding

Scene data binds once per layer. Object data binds per draw call.

```cpp
// Scene.cpp:136 — Once per layer
phxContext->VSSetConstantBuffers(0, 1, &SceneDataBuffer);
phxContext->GSSetConstantBuffers(0, 1, &SceneDataBuffer);
phxContext->PSSetConstantBuffers(0, 1, &SceneDataBuffer);

// RenderLayer.cpp:27 — Per draw call
phxContext->Map(ObjectMatrixBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
memcpy(map.pData, Matrices, 16 * 2 * 4);  // Two 4x4 matrices
memcpy(((unsigned char*)map.pData) + sizeof(Matrices), MaterialData, MATERIALDATASIZE);
phxContext->Unmap(ObjectMatrixBuffer, 0);
```

The `D3D11_MAP_WRITE_DISCARD` flag allocates fresh memory instead of waiting for the GPU to finish using previous data. This avoids stalls at the cost of increased memory allocation.

## Texture Slot Conventions

Phoenix uses consistent texture slot assignments across materials.

| Slot | Register | Common Usage | G-Buffer Lighting |
|------|----------|--------------|-------------------|
| t0 | `t_0` | Albedo + Metalness | RT0 (Albedo+Metal) |
| t1 | `t_1` | Normal + Roughness | RT1 (Normal+Rough) |
| t2 | `t_2` | Emissive / detail | Reserved |
| t3 | `t_3` | Shadow map | Shadow map |
| t4 | `t_4` | Reserved | Reserved |
| t5 | `t_5` | Reserved | Reserved |
| t6 | `t_6` | LTC Matrix (ltc_1) | LTC Matrix |
| t7 | `t_7` | LTC Fresnel (ltc_2) / Depth | Depth buffer |

**PBR texture packing** follows a common convention:
- Albedo.RGB in texture 0's RGB channels
- Metalness in texture 0's alpha channel
- Normal.XY in texture 1's RG channels (Z reconstructed)
- Roughness in texture 1's alpha channel

This packing halves texture memory and sampling costs compared to separate textures.

### Sampler Setup

Samplers configure filtering and addressing modes. Phoenix creates global samplers during engine initialization.

```cpp
// phxEngine.cpp initialization
static const D3D11_SAMPLER_DESC wrapSampler = {
    D3D11_FILTER_MIN_MAG_MIP_LINEAR,  // Trilinear filtering
    D3D11_TEXTURE_ADDRESS_WRAP,        // Wrap U
    D3D11_TEXTURE_ADDRESS_WRAP,        // Wrap V
    D3D11_TEXTURE_ADDRESS_WRAP,        // Wrap W
    0, 0,                              // Mip LOD bias, max aniso
    D3D11_COMPARISON_NEVER,            // No comparison
    {0}, 0, FLT_MAX                    // Border color, LOD clamp
};
```

Materials can override samplers for specific effects (clamping for edge masks, point filtering for pixelated looks), but the default linear-wrap sampler handles most cases.

## Vertex Shader Patterns

### Standard Mesh Transformation

The basic vertex shader transforms positions and normals to world space, projecting positions to clip space.

```hlsl
struct VSIN
{
    float3 Position : POSITION;
    float3 Normal : NORMAL;
    float2 UV : TEXCOORD0;
};

struct VSOUT
{
    float4 Position : SV_POSITION;  // Clip space for rasterizer
    float3 p : TEXCOORD0;           // World position for lighting
    float3 Normal : TEXCOORD1;      // World normal
    float2 uv : TEXCOORD2;          // UV for texturing
};

VSOUT v(VSIN x)
{
    VSOUT k;

    // Transform position to world space
    k.p = mul(worldmat, float4(x.Position, 1)).xyz;

    // Transform normal using inverse-transpose
    k.Normal = mul(itworldmat, float4(x.Normal, 0)).xyz;

    // Project to clip space
    k.Position = mul(projmat, mul(viewmat, float4(k.p, 1)));

    // Pass through UVs
    k.uv = x.UV;

    return k;
}
```

The inverse-transpose normal transformation is crucial. Under non-uniform scaling, regular matrix multiplication would distort normals. The inverse-transpose preserves the perpendicular relationship between normals and surfaces.

### Motion Blur Support

Phoenix stores current and previous frame matrices for velocity-based effects.

```hlsl
// Extended vertex output for motion blur
struct VSOUT_MOTION
{
    float4 Position : SV_POSITION;
    float4 currPos : TEXCOORD3;  // Current frame clip position
    float4 prevPos : TEXCOORD4;  // Previous frame clip position
};

VSOUT_MOTION v(VSIN x)
{
    VSOUT_MOTION k;

    float4 worldPos = mul(worldmat, float4(x.Position, 1));
    k.currPos = mul(projmat, mul(viewmat, worldPos));
    k.prevPos = mul(prevprojmat, mul(prevviewmat, worldPos));
    k.Position = k.currPos;

    return k;
}
```

The pixel shader computes per-pixel velocity as `(currPos.xy/currPos.w - prevPos.xy/prevPos.w)`, enabling motion blur without geometry-based velocity buffers.

## Pixel Shader Patterns

### G-Buffer Output

G-Buffer shaders write to multiple render targets simultaneously.

```hlsl
struct PSOUT
{
    float4 am : SV_TARGET1;  // Albedo.RGB + Metalness.A
    float4 nr : SV_TARGET2;  // Normal.RGB + Roughness.A
};

PSOUT p(VSOUT v)
{
    // Sample textures
    float4 albedo = t_0.Sample(Sampler, v.uv);
    float4 normalMap = t_1.Sample(Sampler, v.uv);

    // Normal mapping
    float3 normal = perturb_normal(normalize(v.Normal), v.p, v.uv, normalMap.xyz);

    // Apply material modifiers
    float roughness = ApplyModifier(normalMap.w, data.x);
    float metalness = ApplyModifier(albedo.w, data.y);

    // Write G-Buffer
    PSOUT o;
    o.am = float4(albedo.xyz, metalness);
    o.nr = float4(normal, roughness);
    return o;
}
```

The `SV_TARGET1` and `SV_TARGET2` outputs skip the main render target (TARGET0), which receives depth-only or color output depending on the pass configuration.

### Derivative-Based Tangent Reconstruction

Phoenix reconstructs tangent frames from screen-space derivatives, eliminating per-vertex tangent storage.

```hlsl
float3 perturb_normal(float3 N, float3 p, float2 uv, float3 map)
{
    // Screen-space derivatives of world position and UVs
    float3 dp1 = ddx(p);    // World position change per screen X pixel
    float3 dp2 = ddy(p);    // World position change per screen Y pixel
    float2 duv1 = ddx(uv);  // UV change per screen X pixel
    float2 duv2 = ddy(uv);  // UV change per screen Y pixel

    // Solve for tangent frame
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Normalize for consistent scale
    float invmax = rsqrt(max(dot(T, T), dot(B, B)));
    float3x3 TBN = float3x3(T * invmax, B * invmax, N);

    // Handle missing normal map
    if (dot(map, map) == 0) map = float3(0.5, 0.5, 1);

    // Convert from [0,1] to [-1,1] and transform
    map = map * 2 - 1;
    return normalize(mul(map, TBN));
}
```

This technique uses `ddx()` and `ddy()` to compute how world position and UV coordinates change across the screen. From these derivatives, it reconstructs tangent and bitangent vectors orthogonal to the normal. The math is elegant: screen-space derivatives relate world geometry to texture mapping, revealing the tangent frame implicitly.

The trade-off: derivative-based tangents cost extra ALU per pixel, but save vertex attribute storage and transfer. For 64k intros where data compression matters more than shader cycles, this is the right choice.

### Material Modifier Functions

Parameters can adjust base texture values bidirectionally.

```hlsl
float ApplyModifier(float value, float modifier)
{
    // Modifier in [0, 0.498]: multiply/darken
    if (modifier <= 127.0/255.0)
        return value * modifier / (127.0/255.0);

    // Modifier in [0.502, 1]: lerp toward 1/lighten
    else
        return lerp(value, 1, (modifier - 127.0/255.0) / (128.0/255.0));
}
```

A modifier of 0.5 (127/255) passes the value through unchanged. Values below 0.5 multiply (darkening roughness, reducing metalness). Values above 0.5 lerp toward 1 (increasing roughness, boosting metalness).

This encoding packs both "reduce" and "increase" into a single byte, saving material storage. Artists set modifiers in the demotool; the shader interprets them at runtime.

## BRDF Implementation

### Cook-Torrance Components

The physically-based BRDF splits into three functions: Distribution, Fresnel, and Geometry/Visibility.

#### GGX Distribution (D)

```hlsl
float D_GGX(float a2, float NoH)
{
    float d = (NoH * a2 - NoH) * NoH + 1;
    return a2 / (3.14159265 * d * d);
}
```

The GGX (Trowbridge-Reitz) distribution describes microfacet orientation probability. Given roughness squared (`a2`) and the angle between normal and half-vector (`NoH`), it returns the probability density of microfacets aligned for specular reflection.

GGX has a "long tail"—even at high roughness, some microfacets align with the half-vector, producing visible highlights. This matches real-world material behavior better than older distributions like Blinn-Phong.

#### Fresnel (F)

```hlsl
float3 F_Schlick(float3 SpecularColor, float VoH)
{
    float Fc = Pow5(1 - VoH);
    return saturate(50.0 * SpecularColor.g) * Fc + (1 - Fc) * SpecularColor;
}

float Pow5(float x) { return x * x * x * x * x; }
```

Schlick's approximation calculates Fresnel reflectance from viewing angle. At normal incidence (`VoH = 1`), reflectance equals `SpecularColor`. At grazing angles (`VoH → 0`), reflectance approaches 1 (total reflection).

The `50.0 * SpecularColor.g` term is an "edge tint" enhancement. Dielectric materials show slightly colored reflections at grazing angles. The multiplier uses the green channel as a proxy for brightness.

#### Visibility/Geometry (G)

```hlsl
float Vis_SmithJointApprox(float a2, float NoV, float NoL)
{
    float a = sqrt(a2);
    float Vis_SmithV = NoL * (NoV * (1 - a) + a);
    float Vis_SmithL = NoV * (NoL * (1 - a) + a);
    return 0.5 * rcp(Vis_SmithV + Vis_SmithL);
}
```

The visibility term accounts for microfacet self-shadowing and masking. Microfacets can block light from reaching other microfacets (shadowing) or block reflected light from reaching the viewer (masking). The Smith geometry function models this.

This approximation from Epic Games combines view and light direction terms efficiently. The `rcp()` instruction computes reciprocal on GPU hardware.

### Combined Specular BRDF

```hlsl
float3 SpecularGGX(float Roughness, float3 SpecularColor,
                   BxDFContext Context, float NoL, float SphereSinAlpha)
{
    float a2 = Pow4(Roughness);  // Squared twice for perceptual linearity

    // Energy normalization for area lights
    float Energy = EnergyNormalization(a2, Context.VoH, SphereSinAlpha);

    float D = D_GGX(a2, Context.NoH) * Energy;
    float Vis = Vis_SmithJointApprox(a2, Context.NoV, NoL);
    float3 F = F_Schlick(SpecularColor, Context.VoH);

    return (D * Vis) * F;
}
```

The multiplication order matters for efficiency: `D * Vis` are both scalars, producing a scalar. Then multiply by vector `F`. This avoids unnecessary vector operations.

The `Pow4(Roughness)` converts artist-friendly linear roughness to the squared-squared alpha that GGX expects. This provides perceptually linear roughness control.

### Diffuse BRDF

Phoenix uses simple Lambertian diffuse:

```hlsl
float3 DiffuseLambert(float3 DiffuseColor)
{
    return DiffuseColor / 3.14159265;
}
```

The `/ PI` normalization ensures energy conservation—diffuse reflection doesn't add more light than it receives. Combined with the metalness workflow, diffuse color is `Albedo * (1 - Metalness)`.

### BRDF Context

Frequently-used dot products cache in a context structure.

```hlsl
struct BxDFContext
{
    float NoV;  // Normal · View
    float NoL;  // Normal · Light
    float NoH;  // Normal · Half
    float VoH;  // View · Half
    float VoL;  // View · Light
};

BxDFContext InitBxDFContext(float3 N, float3 V, float3 L)
{
    BxDFContext c;
    float3 H = normalize(V + L);

    c.NoL = dot(N, L);
    c.NoV = dot(N, V);
    c.NoH = saturate(dot(N, H));
    c.VoH = saturate(dot(V, H));
    c.VoL = dot(V, L);

    return c;
}
```

Computing each dot product once and passing the context avoids redundant calculations. The same context feeds D, F, and G functions.

## World Position Reconstruction

Deferred lighting needs world position but only has screen UV and depth.

```hlsl
float3 getWorldPos(float depth, float2 uv)
{
    // Convert UV [0,1] to NDC [-1,1]
    float2 ndc = uv * 2 - 1;

    // Build clip-space position
    float4 clipPos = float4(ndc, depth, 1);

    // Unproject through inverse matrices
    float4 viewPos = mul(iprojmat, clipPos);
    float4 worldPos = mul(iviewmat, viewPos);

    // Perspective divide
    return worldPos.xyz / worldPos.w;
}
```

The reconstruction reverses the vertex shader's transformation:
1. Screen UV → NDC coordinates
2. NDC + depth → clip space position
3. Inverse projection → view space
4. Inverse view → world space
5. Perspective divide → final world position

This happens per-pixel in lighting shaders, reconstructing geometry position without additional G-Buffer storage.

## LTC Integration

Area lights use Linearly Transformed Cosines for analytical integration. See [lighting.md](lighting.md) for full details; here's the shader-side usage.

### LTC Table Sampling

```hlsl
LTCCommon InitLTC(LightingContext l)
{
    LTCCommon c;

    // Map roughness and viewing angle to texture coordinates
    // sqrt(1-NoV) converts cosine to angle-proportional
    float2 ltcUV = float2(l.roughness, sqrt(1 - l.NdotV)) * 15.0/16.0 + 1.0/32.0;

    // Sample LTC tables
    float4 t1 = ltc1.Sample(Sampler, ltcUV);  // Matrix coefficients
    float2 t2 = ltc2.Sample(Sampler, ltcUV).xy;  // Magnitude + Fresnel

    // Build tangent frame
    float3 T1 = normalize(l.V - l.N * l.NdotV);
    float3 T2 = cross(l.N, T1);
    c.ltcMatrixDiffuse = float3x3(T1, T2, l.N);

    // Expand 4 stored values into full 3x3 matrix
    float3x3 minv = float3x3(
        t1.x, 0,    t1.z,
        0,    1,    0,
        t1.y, 0,    t1.w
    );
    c.ltcMatrixSpecular = mul(minv, c.ltcMatrixDiffuse);

    // Fresnel interpolation
    c.specularModifier = lerp(t2.y, t2.x, l.f0);
    c.diffuseModifier = l.albedo * (1 - l.metallic);

    return c;
}
```

The LTC tables store pre-computed matrix coefficients that transform the GGX BRDF into a clamped cosine distribution. The 16×16 table resolution balances precision against storage.

### Polygon Edge Integration

```hlsl
float LTC_Evaluate(LightingContext l, float3x3 Minv, bool twoSided)
{
    float3 L[64];  // Clipped polygon vertices
    uint n = 0;

    // Transform and clip polygon to upper hemisphere
    for (uint i = 0; i < vertexCount; i++)
    {
        float3 current = mul(Minv, points[i]);
        float3 next = mul(Minv, points[(i+1) % vertexCount]);

        if (current.z > 0)
            L[n++] = normalize(current);

        if ((current.z > 0) != (next.z > 0))
            L[n++] = normalize(lerp(current, next, -current.z / (next.z - current.z)));
    }

    // Edge integration
    float sum = 0;
    for (uint j = 0; j < n; j++)
    {
        float3 v1 = L[j];
        float3 v2 = L[(j+1) % n];
        float x = dot(v1, v2);

        // Rational approximation to acos(x) * sin(acos(x))
        float y = abs(x);
        float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
        float b = 3.4175940 + (4.1616724 + y)*y;
        float v = a / b;

        float theta_sintheta = (x > 0) ? v : 0.5/sqrt(max(1-x*x, 1e-7)) - v;
        sum += cross(v1, v2).z * theta_sintheta;
    }

    return twoSided ? abs(sum) : max(0, -sum);
}
```

This implements the closed-form integral of a cosine distribution over a spherical polygon. The rational approximation avoids expensive `acos()` calls.

## Shader Minification

Phoenix uses modified Unreal Engine AST code to minify HLSL before compression.

### Techniques Applied

**Identifier shortening**: Variable and function names reduce to single characters.
```hlsl
// Before
float3 worldPosition = mul(worldMatrix, localPos).xyz;

// After
float3 a = mul(b, c).xyz;
```

**Whitespace removal**: Spaces, tabs, newlines strip except where syntactically required.

**Dead code elimination**: Unused variables and unreachable branches remove.

**Constant folding**: Compile-time computable expressions reduce to literals.
```hlsl
// Before
float pi = 3.14159265;
float x = y / pi;

// After
float x = y * 0.31830988;
```

### Why Minification Matters

Shader source code embeds in the executable for runtime compilation. Unlike C++ code that compiles to machine code, HLSL ships as text. Shorter source means smaller executable.

The kkrunchy packer compresses the final executable. Text with repeated patterns compresses well. Minified shaders with consistent short names produce better compression ratios than verbose code.

## Error Handling

Demo shaders typically omit error handling for size. However, certain defensive patterns appear:

```hlsl
// Avoid division by zero
float invmax = rsqrt(max(dot(T, T), dot(B, B)));

// Clamp to valid ranges
float NoH = saturate(dot(N, H));

// Handle missing textures
if (dot(map, map) == 0) map = float3(0.5, 0.5, 1);
```

These patterns prevent NaN propagation and GPU driver crashes without verbose error checking.

## Implications for Rust Framework

### Adopt: Constant Buffer Conventions

Separate scene-level and object-level data into distinct bind groups. Upload scene data once per pass; object data per draw. This matches wgpu's bind group model.

```rust
#[repr(C)]
#[derive(Pod, Zeroable)]
struct SceneUniforms {
    view: Mat4,
    projection: Mat4,
    camera_pos: Vec4,
    // ...
}
```

### Adopt: Derivative-Based Tangents

Modern GPUs compute derivatives efficiently. Eliminating tangent attributes saves vertex memory and simplifies mesh processing. WGSL supports `dpdx()` and `dpdy()` identically.

### Adopt: BRDF Context Pattern

Computing dot products once avoids redundant calculations. The context struct maps directly to Rust:

```rust
struct BrdfContext {
    n_dot_v: f32,
    n_dot_l: f32,
    n_dot_h: f32,
    v_dot_h: f32,
}
```

### Modify: Use Naga for Shader Minification

WGSL doesn't need string minification like HLSL—Naga compiles to SPIR-V bytecode. Instead, focus on eliminating dead code and constant propagation at the Rust/WGSL level.

### Modify: Consider Shader Modules

wgpu's shader module system allows runtime composition. Instead of monolithic shaders, compose BRDF functions from reusable modules. This enables customization without source code duplication.

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture
- **[materials.md](materials.md)** — Material parameter system
- **[lighting.md](lighting.md)** — Light types and LTC implementation
- **[deferred.md](deferred.md)** — G-Buffer details
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — BRDF trace with source

## Source References

Shader code extracts from Clean Slate project (`Projects/Clean Slate/cleanslate.apx`):

| Material/Shader | Lines | Purpose |
|-----------------|-------|---------|
| PBR Pure Deferred | 44393-44600 | G-Buffer generation |
| Area Sphere Light LTC | 41967-42137 | LTC area lighting |
| Deferred Ambient Light | 45502-45605 | IBL ambient pass |
| Standard Light | 42688-42909 | Point/spot lighting |

Engine source (`demoscene/apex-public/apEx/Phoenix/`):

| File | Relevant Code |
|------|---------------|
| Scene.cpp | Constant buffer setup (136-340) |
| RenderLayer.cpp | Object buffer binding (27-60) |
| phxEngine.cpp | Sampler creation, LTC texture upload |
