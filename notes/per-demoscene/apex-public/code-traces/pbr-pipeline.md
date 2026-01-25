# Code Trace: PBR Pipeline in Clean Slate

> Tracing physically based rendering from G-Buffer generation through deferred lighting in the apEx/Phoenix engine.

Clean Slate is Conspiracy's 64k intro released at Revision 2017. Despite the extreme size constraints, it implements a full physically based rendering pipeline with deferred shading, area lights using Linearly Transformed Cosines (LTC), and energy-conserving BRDFs. This document traces how a mesh goes from geometry to final lit pixel.

The question this code trace answers: In a 64k demo where every byte matters, how do you implement physically accurate lighting without the luxury of middleware or bloated shader libraries? The answer reveals a carefully balanced architecture that achieves visual quality through mathematical precision rather than brute-force computation.

## The Mental Model: G-Buffer as Material Property Cache

Think of deferred rendering like a photography studio setup. First, you photograph every object against a reference background, recording not just their color but also surface properties: how smooth they are, whether they're metallic, which direction they're facing. These "material property photos" become reference sheets.

Then, separately, you design your lighting. You bring in lights of different types: sphere lights, directional lights, ambient illumination. For each light, you consult your reference sheets, calculating how light would bounce off each surface. The final image composites all these lighting calculations together.

This separation is the G-Buffer. Phoenix writes material properties to multiple render targets during the geometry pass. Later, the lighting pass reads these properties and calculates illumination without re-rendering geometry. One geometry pass, many light calculations.

## Render Layer Architecture

**File**: `Projects/Clean Slate/cleanslate.apx:41457-41497`

Clean Slate defines four render layers that execute in sequence:

```xml
<renderlayer>
    <Name>Shadow Layer</Name>
    <RenderTarget>Shadow Map</RenderTarget>
</renderlayer>

<renderlayer>
    <Name>Solid Layer</Name>
    <RenderTarget>Main RT</RenderTarget>
    <RenderTarget>Albedo and Metalness</RenderTarget>
    <RenderTarget>Normal and Roughness</RenderTarget>
</renderlayer>

<renderlayer>
    <Name>Lighting Layer</Name>
    <OmitDepthBuffer>1</OmitDepthBuffer>
    <ClearRenderTargets>0</ClearRenderTargets>
    <RenderTarget>Main RT</RenderTarget>
</renderlayer>

<renderlayer>
    <Name>Transparent Layer</Name>
    <RenderTarget>Main RT</RenderTarget>
</renderlayer>
```

The G-Buffer layout encodes four channels of material data into two render targets:

| Render Target | RGB Channels | Alpha Channel |
|---------------|--------------|---------------|
| RT0 (Albedo + Metalness) | Albedo color | Metalness |
| RT1 (Normal + Roughness) | World-space normal | Roughness |

This packing is efficient: metalness and roughness are single scalars that fit naturally into alpha channels, leaving full RGB for color and normal vector data.

## Phase 1: G-Buffer Generation

**File**: `Projects/Clean Slate/cleanslate.apx:44393-44600` (`[PBR Pure Deferred]` material)

The G-Buffer pass runs first, writing material properties to multiple render targets. Each mesh uses this material's pixel shader:

```hlsl
struct PSOUT
{
    float4 am:SV_TARGET1;  // Albedo (RGB) + Metalness (A)
    float4 nr:SV_TARGET2;  // Normal (RGB) + Roughness (A)
};

PSOUT p(VSOUT v)
{
    float normmult = 1;
    if (data.z > 0.5) normmult = -1;

    float4 albedo = t_0.Sample(Sampler, v.uv.xy);
    float4 normalMap = t_1.Sample(Sampler, v.uv.xy);

    float3 normal = perturb_normal(normalize(v.Normal) * normmult,
                                   v.p, v.uv.xy, normalMap.xyz);
    albedo.w = ApplyModifier(albedo.w, data.y);

    PSOUT p;
    p.nr = float4(normal, ApplyModifier(normalMap.w, data.x));
    p.am = albedo;
    return p;
}
```

The vertex shader transforms positions and normals to world space:

```hlsl
VSOUT v(VSIN x)
{
    VSOUT k;
    k.p = mul(worldmat, float4(x.Position, 1)).xyz;
    k.Normal = mul(itworldmat, float4(x.Normal, 0)).xyz;
    k.Position = mul(projmat, mul(viewmat, float4(k.p, 1)));
    k.uv = x.UV;
    return k;
}
```

### Tangent-Space Normal Mapping Without Pre-computed Tangents

**File**: `Projects/Clean Slate/cleanslate.apx:44446-44468`

Phoenix reconstructs tangent frames from screen-space derivatives, avoiding the need to store per-vertex tangent vectors:

```hlsl
float3 perturb_normal(float3 N, float3 p, float2 uv, float3 map)
{
    float3 dp1 = ddx(p);    // World position derivative in screen X
    float3 dp2 = ddy(p);    // World position derivative in screen Y
    float2 duv1 = ddx(uv);  // UV derivative in screen X
    float2 duv2 = ddy(uv);  // UV derivative in screen Y

    // Solve the linear system for tangent frame
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = rsqrt(max(dot(T,T), dot(B,B)));
    float3x3 tangentFrame = float3x3(T * invmax, B * invmax, N);

    // Default to flat if no normal map
    if (dot(map, map) == 0) map = float3(0.5, 0.5, 1);

    map = map * 2 - 1;
    return normalize(mul(map, tangentFrame));
}
```

This technique, sometimes called "derivative-based tangent reconstruction," uses `ddx()` and `ddy()` to derive tangent and bitangent vectors at runtime. The trade-off: slightly more shader math, but zero additional vertex data. For a 64k intro, this is a clear win.

### Roughness and Metalness Modifiers

**File**: `Projects/Clean Slate/cleanslate.apx:44471-44477`

Artists can adjust material properties beyond what textures provide:

```hlsl
float ApplyModifier(float value, float modifier)
{
    if (modifier <= 127/255.0)
        return value * modifier / (127/255.0);  // Darken
    else
        return lerp(value, 1, (modifier - 127/255.0) / (128/255.0));  // Lighten
}
```

This maps a 0-255 modifier to a bidirectional adjustment. Values below 127 multiply (making surfaces rougher or less metallic), while values above 127 lerp toward 1 (making surfaces smoother or more metallic). The midpoint (127) passes through unchanged.

## Phase 2: Deferred Lighting

The lighting layer renders full-screen quads for each light source. Instead of re-rendering geometry, it reads the G-Buffer and calculates per-pixel illumination.

### Unpacking the G-Buffer

**File**: `Projects/Clean Slate/cleanslate.apx:42688-42694`

Each lighting shader declares the same G-Buffer structure:

```hlsl
struct FGBufferData
{
    float3 WorldNormal;
    float3 DiffuseColor;
    float3 SpecularColor;
    float Roughness;
};
```

The unpacking converts packed metalness to physically-based diffuse/specular colors:

```hlsl
FGBufferData GBuffer;
GBuffer.WorldNormal = N;
GBuffer.DiffuseColor = t0.xyz * (1 - t0.w);           // Albedo * (1 - metalness)
GBuffer.SpecularColor = lerp(0.04, t0.xyz, t0.w);    // F0 blend
GBuffer.Roughness = t1.w;
```

This is the metalness workflow interpretation:
- **Diffuse**: Metals have no diffuse reflection, so diffuse color is `albedo * (1 - metalness)`
- **Specular F0**: Non-metals have ~4% reflectance at normal incidence (0.04), metals reflect their albedo color

### Reconstructing World Position from Depth

**File**: `Projects/Clean Slate/cleanslate.apx:41567-41571`

With only a depth buffer, world position must be reconstructed:

```hlsl
float3 getWorldPos(float depth, float2 uv)
{
    float4 a = mul(iviewmat, mul(iprojmat, float4(uv * 2 - 1, depth, 1)));
    return a.xyz / a.w;
}
```

The process reverses the render pipeline:
1. Convert UV (0-1) to NDC (-1 to 1)
2. Combine with depth to get clip-space position
3. Apply inverse projection to get view-space
4. Apply inverse view to get world-space
5. Perspective divide to complete the reconstruction

## Phase 3: The BRDF Components

**File**: `Projects/Clean Slate/cleanslate.apx:42732-42759`

Phoenix implements the standard Cook-Torrance microfacet BRDF with three core functions.

### Fresnel: F_Schlick

```hlsl
float3 F_Schlick(float3 SpecularColor, float VoH)
{
    float Fc = Pow5(1 - VoH);
    return saturate(50.0 * SpecularColor.g) * Fc + (1 - Fc) * SpecularColor;
}
```

Schlick's Fresnel approximation calculates how much light reflects vs. refracts at a surface. The `50.0 * SpecularColor.g` term adds an "edge tint" that's particularly visible on dielectrics, making edge reflections slightly brighter. This is a subtle physically-motivated enhancement.

### Distribution: D_GGX

```hlsl
float D_GGX(float a2, float NoH)
{
    float d = (NoH * a2 - NoH) * NoH + 1;
    return a2 / (3.14159265 * d * d);
}
```

The GGX (Trowbridge-Reitz) distribution describes how microfacets are oriented. The `a2` term is roughness squared (squared again from linear roughness, so `roughness^4`). This distribution has a "long tail" that creates realistic specular highlights even on rough surfaces.

### Visibility: Vis_SmithJointApprox

```hlsl
float Vis_SmithJointApprox(float a2, float NoV, float NoL)
{
    float a = sqrt(a2);
    float Vis_SmithV = NoL * (NoV * (1 - a) + a);
    float Vis_SmithL = NoV * (NoL * (1 - a) + a);
    return 0.5 * rcp(Vis_SmithV + Vis_SmithL);
}
```

The geometry/visibility term accounts for microfacet self-shadowing and masking. This approximation (from Epic's UE4) combines the view and light direction terms into a single efficient calculation.

### Combined Specular BRDF

```hlsl
float3 SpecularGGX(float Roughness, float3 SpecularColor, BxDFContext Context,
                   float NoL, float SphereSinAlpha)
{
    float a2 = Pow4(Roughness);
    float Energy = EnergyNormalization(a2, Context.VoH, SphereSinAlpha);
    float D = D_GGX(a2, Context.NoH) * Energy;
    float Vis = Vis_SmithJointApprox(a2, Context.NoV, NoL);
    float3 F = F_Schlick(SpecularColor, Context.VoH);
    return (D * Vis) * F;
}
```

The multiplication order is deliberate: `D * Vis` first because both are scalar, then multiply by the vector `F`. The `EnergyNormalization` factor compensates for area light approximations.

## Phase 4: Sphere Area Light Integration

**File**: `Projects/Clean Slate/cleanslate.apx:42762-42909`

For sphere lights, the simple "point at center" approximation breaks down. Phoenix uses an analytical approach that accounts for the light's solid angle.

### Horizon Clipping

```hlsl
float SphereHorizonCosWrap(float NoL, float SinAlphaSqr)
{
    float SinAlpha = sqrt(SinAlphaSqr);

    if (NoL < SinAlpha)
    {
        NoL = max(NoL, -SinAlpha);
        // Accurate sphere irradiance formula
        float CosBeta = NoL;
        float SinBeta = sqrt(1 - CosBeta * CosBeta);
        float TanBeta = SinBeta / CosBeta;

        float x = sqrt(1 / SinAlphaSqr - 1);
        float y = -x / TanBeta;
        float z = SinBeta * sqrt(1 - y*y);

        NoL = NoL * acos(y) - x * z + atan(z / x) / SinAlphaSqr;
        NoL /= 3.14152965;
    }
    return saturate(NoL);
}
```

When a sphere light's edge dips below the horizon (the surface plane), only part of the light is visible. This function computes the exact irradiance from the visible portion, using the geometric relationship between the surface normal, light direction, and sphere angular radius.

### Final Lighting Calculation

```hlsl
float4 p(VSOUT v) : SV_TARGET0
{
    // ... G-Buffer unpacking ...

    float3 ToLight = mul(worldmat, float4(0,0,0,1)).xyz - P;
    float DistSqr = dot(ToLight, ToLight);
    float Falloff = rcp(DistSqr + 1);

    float SinAlphaSqr = saturate(Square(lightRadius) * Falloff);
    float NoL = dot(N, ToLight * rsqrt(DistSqr));

    NoL = SphereHorizonCosWrap(NoL, SinAlphaSqr);

    // ... BxDFContext setup and representative point calculation ...

    float3 diffuseResult = (Falloff * NoL) * GBuffer.DiffuseColor / 3.14159265;
    float3 specularResult = (Falloff * NoL) * SpecularGGX(GBuffer.Roughness,
                                                          GBuffer.SpecularColor,
                                                          Context, NoL, SinAlpha);

    return float4((diffuseResult + specularResult) * sqrt(lightRadius) * color.xyz, 1);
}
```

The diffuse term is Lambertian (`/ PI`) while specular uses the full GGX BRDF. Both are modulated by the computed falloff and the adjusted NoL from horizon clipping. The `sqrt(lightRadius)` term provides a visually pleasing energy scaling for different light sizes.

## Phase 5: Ambient / IBL Pass

**File**: `Projects/Clean Slate/cleanslate.apx:45502-45605` (`Deferred Ambient Light`)

The ambient pass adds image-based lighting contribution:

```hlsl
float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

float3 DiffuseIBL(float3 N, float3 V, float3 F0, float3 albedo, float metallic)
{
    float3 H = normalize(V + N);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    return (1 - F) * (1.0 - metallic) * lightColor.xyz * albedo / PI;
}
```

This simplified IBL assumes a uniform environment (no cubemap), using only the light color as ambient. The Fresnel term modulates how much diffuse ambient reaches the surface: at grazing angles, more light reflects (handled by direct specular), leaving less for ambient diffuse.

## Phase 6: Shadow Mapping

**File**: `Projects/Clean Slate/cleanslate.apx:43547-43578`

Shadows use percentage-closer filtering (PCF) with a 5x5 kernel:

```hlsl
float VSM(float2 TexBase, float LightCompare, float shdw)
{
    float shadow = 0;

    for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++)
            shadow += t_3.SampleCmpLevelZero(Sampler3,
                                             TexBase + float2(x-2, y-2) * 0.02 * shdw,
                                             LightCompare);

    return shadow / 25.0f;
}
```

The `SampleCmpLevelZero` operation performs hardware-accelerated depth comparison, returning 0 or 1 per sample. Averaging 25 samples produces soft shadow edges. The `shdw` parameter controls shadow softness by scaling the sample offsets.

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 1: SHADOW MAP                                                      │
│   Shadow Layer → Depth-only render → Shadow Map RT                       │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 2: G-BUFFER GENERATION                                             │
│                                                                          │
│   [Mesh] → [PBR Pure Deferred] vertex shader                            │
│                ↓                                                         │
│         Transform to world space                                        │
│         Compute tangent frame from derivatives                          │
│                ↓                                                         │
│   [PBR Pure Deferred] pixel shader                                      │
│                ↓                                                         │
│   ┌─────────────────────────────────────────┐                           │
│   │ RT0: Albedo.RGB + Metalness.A           │                           │
│   │ RT1: Normal.RGB + Roughness.A           │                           │
│   │ Depth Buffer: Z                         │                           │
│   └─────────────────────────────────────────┘                           │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 3: DEFERRED LIGHTING (Lighting Layer)                              │
│                                                                          │
│   For each light:                                                        │
│     ┌─────────────────────────────────────────────────────────────┐     │
│     │ Read G-Buffer → Reconstruct world pos from depth           │     │
│     │                       ↓                                     │     │
│     │ Unpack: DiffuseColor = Albedo * (1 - Metalness)            │     │
│     │         SpecularColor = lerp(0.04, Albedo, Metalness)      │     │
│     │                       ↓                                     │     │
│     │ Calculate light direction, distance, falloff               │     │
│     │                       ↓                                     │     │
│     │ ┌─────────────────────────────────────────────────────┐   │     │
│     │ │ BRDF Evaluation:                                    │   │     │
│     │ │   D = D_GGX(roughness, NoH)                        │   │     │
│     │ │   F = F_Schlick(SpecularColor, VoH)                │   │     │
│     │ │   G = Vis_SmithJointApprox(roughness, NoV, NoL)    │   │     │
│     │ │   Specular = D * F * G                              │   │     │
│     │ │   Diffuse = DiffuseColor / PI                       │   │     │
│     │ └─────────────────────────────────────────────────────┘   │     │
│     │                       ↓                                     │     │
│     │ Accumulate: Color += (Diffuse + Specular) * Radiance      │     │
│     └─────────────────────────────────────────────────────────────┘     │
│                                                                          │
│   Add ambient IBL contribution                                          │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 4: TRANSPARENCY & POST-PROCESSING                                  │
│   Transparent Layer → Alpha-blended objects                             │
│   Post-process chain → Bloom, tonemapping, etc.                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Architectural Observations

### 1. Packed G-Buffer Minimizes Bandwidth

Two render targets instead of four. Metalness and roughness are scalars packed into alpha channels. This halves memory bandwidth during the lighting pass, critical for GPU-limited scenes with many lights.

### 2. No Pre-computed Tangents

Using `ddx()`/`ddy()` for tangent reconstruction trades vertex data for shader ALU. For a 64k intro with procedural geometry, this eliminates the need to store tangent vectors entirely.

### 3. Energy Conservation Throughout

The metalness workflow ensures diffuse + specular energy sums to (at most) the incident light. Metals have no diffuse; dielectrics have specular F0 of ~0.04. This prevents the "overlit" look common in non-PBR rendering.

### 4. Area Light Approximations

Rather than Monte Carlo integration, Phoenix uses analytical approximations for sphere lights (horizon clipping, representative point method). These are cheaper and deterministic, avoiding temporal noise that would need temporal filtering to resolve.

### 5. Shared Lighting Context Pattern

The `LightingContext` and `BxDFContext` structures centralize dot products that multiple functions need. Computing `NoL`, `NoV`, `NoH`, `VoH` once and passing the struct avoids redundant calculations.

## Implications for Rust Implementation

1. **G-Buffer layout** is a classic space/quality tradeoff. The two-RT approach here works well for the standard metalness workflow. Consider whether additional material features (subsurface, clearcoat) justify more RTs.

2. **Derivative-based tangents** work well in WGSL via `dpdx()`/`dpdy()`. No change needed from the HLSL approach.

3. **BRDF functions** should be standalone utilities, not tied to any particular shading model. The D/F/G separation shown here allows mixing different distribution or geometry terms.

4. **Area lights** benefit greatly from LTC (documented separately). The analytical approximation shown here is a reasonable fallback when LTC textures aren't available.

5. **The lighting layer pattern** maps directly to wgpu render passes. Each light type can have its own pipeline with additive blending to the HDR buffer.
