# tixl PBR Rendering Pipeline

Real-time physically-based rendering is a game of controlled approximations. The goal is not to simulate light correctly — that would require path-tracing every photon — but to produce plausible results at 60 fps using mathematical shortcuts that the eye cannot distinguish from the real thing. tixl's PBR pipeline, adapted from Michał Siejak's reference implementation of "Real Shading in Unreal Engine 4," makes a specific set of bets about which shortcuts are safe to take. Understanding those bets is the key to understanding every line of shader code in the system.

The pipeline solves a concrete problem that creative coding artists hit the moment they move beyond flat-shaded primitives: how do you make a metallic sphere look different from a plastic sphere that happens to be the same color? The answer is the Cook-Torrance microfacet BRDF, a model that treats every surface as a landscape of microscopic facets, each one a tiny mirror. Rough surfaces scatter those facets randomly, spreading reflections wide. Smooth surfaces align them, producing sharp highlights. The metalness parameter controls whether the surface absorbs diffuse light at all — metals do not, because their electrons convert incoming light directly to reflected light rather than scattering it through the bulk of the material.

The pipeline splits rendering into two conceptually separate contributions: analytical lights (the point lights in a scene, rendered in a loop) and image-based lighting (an environment cubemap that fills in the ambient hemisphere). Neither path is complete on its own. Analytical lights give you sharp highlights and shadows. IBL gives you the rich environment reflections that make materials look like they belong in a scene. The final pixel is the sum of both, filtered through fog and an optional emissive layer. This document traces both paths from the vertex shader to the pixel output, grounding each step in the actual HLSL source.

## The Problem This Solves

A rendering system for creative coding faces a different constraint from a game engine. In a game engine, content is authored once and optimized offline. In tixl's node-graph environment, users assemble rendering pipelines live, connecting mesh nodes to material nodes to light nodes while a preview window updates in real time. The PBR layer must therefore be both correct enough to produce professional results and flexible enough to be parameterized entirely through connected inputs.

The answer tixl arrives at is a shared header architecture. The BRDF math lives in `shared/pbr.hlsl`, the full lighting evaluation lives in `shared/pbr-render.hlsl`, and mesh-specific vertex fetching lives in `mesh-Draw.hlsl`. Any shader that wants full PBR lighting includes these headers in order. The `FragmentMaterial` static struct acts as the shared communication channel — the vertex shader and pixel setup code fill its fields, and `ComputePbr()` consumes them.

## Source Files

The pipeline spans four source files:

- `Operators/Lib/Assets/shaders/shared/pbr.hlsl` — BRDF functions, `PbrVertex` struct, `FragmentMaterial` static struct
- `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl` — `ComputePbr()`, IBL sampling, fog blending
- `Operators/Lib/Assets/shaders/shared/point-light.hlsl` — `PointLight` struct definition
- `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl` — Full VS/PS with cbuffer declarations, vertex fetch, TBN construction, dual render target output

## Vertex Layout: PbrVertex

Every mesh in tixl stores its geometry as a `StructuredBuffer<PbrVertex>`, a GPU-side array of vertex records. The shader reads from this buffer directly using the `SV_VertexID` semantic, bypassing the traditional vertex input assembler. This choice — called a pull-model vertex shader — gives the pipeline more flexibility: mesh data can be reinterpreted, procedurally modified, or sourced from compute shaders without changing the draw call itself.

The `PbrVertex` struct is defined in `pbr.hlsl`:

```hlsl
struct PbrVertex
{
    float3 Position;
    float3 Normal;
    float3 Tangent;
    float3 Bitangent;
    float2 TexCoord;
    float2 TexCoord2;
    float Selected;
    float3 __padding;
};
```

The presence of both `Tangent` and `Bitangent` as precomputed fields is deliberate. Normal mapping requires a per-vertex tangent space basis — three orthogonal vectors that describe "which way is up on this triangle." Recomputing those at runtime from positions and UVs is expensive and numerically fragile. Storing them precomputed in the vertex buffer costs memory but eliminates the per-fragment basis construction that older PBR implementations required.

## cbuffer Layout

Before examining the vertex shader, it is worth understanding the constant buffer register map. These registers are where the CPU-side `PbrMaterial` C# class pushes its data each frame. Think of cbuffers like slots in a mixing board: each slot has a fixed purpose, and the GPU's shader programs know exactly which slot to reach into for each piece of data.

The cbuffer layout in `mesh-Draw.hlsl` uses five registers:

```hlsl
cbuffer Transforms : register(b0)
{
    float4x4 CameraToClipSpace;
    float4x4 ClipSpaceToCamera;
    float4x4 WorldToCamera;
    float4x4 CameraToWorld;
    float4x4 WorldToClipSpace;
    float4x4 ClipSpaceToWorld;
    float4x4 ObjectToWorld;
    float4x4 WorldToObject;
    float4x4 ObjectToCamera;
    float4x4 ObjectToClipSpace;
};

cbuffer Params : register(b1)
{
    float4 Color;
    float AlphaCutOff;
    float UseFlatShading;
};

cbuffer FogParams : register(b2)
{
    float4 FogColor;
    float FogDistance;
    float FogBias;
}

cbuffer PointLights : register(b3)
{
    PointLight Lights[8];
    int ActiveLightCount;
}

cbuffer PbrParams : register(b4)
{
    float4 BaseColor;
    float4 EmissiveColor;
    float Roughness;
    float Specular;
    float Metal;
}
```

Register `b0` is the transform matrix block, always present for any 3D draw. The `b1` slot holds per-draw color tinting and alpha cutoff, things that change per-object. Fog occupies `b2`, keeping atmospheric parameters separate from material parameters so fog can be updated independently. The `b3` slot is the light array — up to eight `PointLight` entries with an `ActiveLightCount` integer to tell the shader loop where to stop. PBR material scalars land at `b4`.

A sixth cbuffer at register `b5` is special:

```hlsl
cbuffer Params : register(b5)
{
    /*{FLOAT_PARAMS}*/
}
```

This is an empty-by-default slot that tixl's shader generation system can inject additional parameters into. It is a template hook, discussed further in the Template Injection section.

## The C# Side: PbrMaterial

On the CPU, the `PbrMaterial` class in `Core/Rendering/Material/PbrMaterial.cs` owns the data that feeds into `b4`. It uses explicit struct layout to guarantee the bytes align with what HLSL expects:

```csharp
[StructLayout(LayoutKind.Explicit, Size = Stride)]
public struct PbrParameters
{
    [FieldOffset(0)]
    public Vector4 BaseColor;

    [FieldOffset(4 * 4)]
    public Vector4 EmissiveColor;

    [FieldOffset(8 * 4)]
    public float Roughness;

    [FieldOffset(9 * 4)]
    public float Specular;

    [FieldOffset(10 * 4)]
    public float Metal;

    [FieldOffset(11 * 4)]
    private float __padding;

    public const int Stride = 12 * 4;
}
```

The `FieldOffset` annotations mirror HLSL's 16-byte alignment rules: `BaseColor` at byte 0, `EmissiveColor` at byte 16, then scalar floats packed together. The `Stride = 12 * 4 = 48` bytes produces a constant buffer that matches the HLSL layout exactly. When `UpdateParameterBuffer()` is called, `ResourceManager.SetupConstBuffer` marshals this struct into a DirectX 11 constant buffer and uploads it to the GPU.

The `CreateDefault()` static method reveals the default material state: `Roughness = 0.5`, `Specular = 10`, `Metal = 0`, `BaseColor = Vector4.One` (white). It also creates fallback textures for when no maps are connected: a `(0, 0, 1, 0)` color for the RMO map (roughness=0, metalness=0, occlusion=1) and a `(0.5, 0.5, 1, 0)` flat normal. This means a bare mesh with no textures connected will still shade correctly, just without surface detail.

## Texture Registers

The mesh draw shader binds eight textures:

```hlsl
StructuredBuffer<PbrVertex> PbrVertices : register(t0);
StructuredBuffer<int3> FaceIndices    : register(t1);

Texture2D<float4> BaseColorMap        : register(t2);
Texture2D<float4> EmissiveColorMap    : register(t3);
Texture2D<float4> RSMOMap             : register(t4);
Texture2D<float4> NormalMap           : register(t5);

TextureCube<float4> PrefilteredSpecular : register(t6);
Texture2D<float4>   BRDFLookup          : register(t7);
```

Registers `t0` and `t1` are not textures in the traditional sense — they are structured buffers holding vertex data and face indices. The actual geometry lookup happens in the vertex shader:

```hlsl
int faceIndex = id / 3;
int faceVertexIndex = id % 3;
PbrVertex vertex = PbrVertices[FaceIndices[faceIndex][faceVertexIndex]];
```

`FaceIndices` stores one `int3` per triangle, where each component is a vertex index. Dividing the `SV_VertexID` by three gives the triangle, and taking the remainder gives which corner of that triangle this invocation handles. This indexed geometry scheme allows vertices to be shared across triangles, reducing memory bandwidth.

The `RSMOMap` at `t4` is a packed texture encoding four material channels in a single sample: Roughness in red, Specular Metalness in green, Occlusion in blue, and an unused alpha. Packing these together saves texture bandwidth and sampler slots.

Registers `t6` and `t7` are the IBL resources: a prefiltered specular cubemap and a BRDF lookup table. Both are precomputed offline and treated as read-only data. Their role in the lighting equation is covered in the IBL section below.

## Vertex Shader: TBN Construction

The vertex shader's main job beyond projecting position is constructing the TBN matrix — the tangent/bitangent/normal basis that allows the pixel shader to transform sampled normal map vectors into world space.

```hlsl
psInput vsMain(uint id : SV_VertexID)
{
    psInput output;

    int faceIndex = id / 3;
    int faceVertexIndex = id % 3;

    PbrVertex vertex = PbrVertices[FaceIndices[faceIndex][faceVertexIndex]];

    float4 posInObject = float4(vertex.Position, 1);
    float4 posInClipSpace = mul(posInObject, ObjectToClipSpace);
    output.pixelPosition = posInClipSpace;

    float2 uv = vertex.TexCoord;
    output.texCoord = float2(uv.x, 1 - uv.y);

    // Pass tangent space basis vectors (for normal mapping).
    float3x3 TBN = float3x3(vertex.Tangent, vertex.Bitangent, vertex.Normal);
    TBN = mul(TBN, (float3x3)ObjectToWorld);

    output.tbnToWorld = float3x3(
        normalize(TBN._m00_m01_m02),
        normalize(TBN._m10_m11_m12),
        normalize(TBN._m20_m21_m22));

    output.worldPosition = mul(posInObject, ObjectToWorld).xyz;
    ...
}
```

The `float3x3 TBN` rows are the tangent, bitangent, and normal vectors in object space. Multiplying this 3x3 block by the upper-left 3x3 of `ObjectToWorld` rotates and scales it into world space. The subsequent per-row normalization corrects for non-uniform scaling: if an object is stretched on one axis, the TBN vectors would become non-unit after the world transform, which would break the normal map decode. Normalizing each row independently prevents that.

The UV flip (`1 - uv.y`) converts from the OpenGL convention (origin at bottom-left) to the DirectX convention (origin at top-left). This is a common friction point when sharing textures across APIs.

## Pixel Shader: FragmentMaterial Setup

The `psInput` struct carries the interpolated per-fragment data from the rasterizer to the pixel shader. The pixel shader's first act is to fill the `FragmentMaterial` static struct `frag`, which `ComputePbr()` reads:

```hlsl
psOutput psMain(psInput pin) : SV_TARGET
{
    psOutput output;

    float4 roughnessMetallicOcclusion = RSMOMap.Sample(WrappedSampler, pin.texCoord);

    frag.Roughness  = saturate(roughnessMetallicOcclusion.x + Roughness);
    frag.Metalness  = saturate(roughnessMetallicOcclusion.y + Metal);
    frag.Occlusion  = roughnessMetallicOcclusion.z;
    frag.albedo     = BaseColorMap.Sample(WrappedSampler, pin.texCoord);
    frag.uv         = pin.texCoord;
    frag.N          = ComputeNormal(pin, pin.tbnToWorld);
    frag.fog        = pin.fog;
    frag.worldPosition = pin.worldPosition;

    float4 eyePosition = mul(float4(0, 0, 0, 1), CameraToWorld);
    frag.Lo = normalize(eyePosition.xyz - frag.worldPosition);

    float4 litColor = ComputePbr();
    ...
}
```

Notice that roughness and metalness from the RMO texture are *added* to the `Roughness` and `Metal` scalar parameters from the cbuffer, then clamped to [0,1]. This allows an artist to bias the map's values up or down with a slider while the map still provides per-texel variation. Setting `Roughness = 0` and connecting a detailed roughness map gives full map control. Setting `Roughness = 1.0` with no map forces everything to maximum roughness regardless of the map.

The `FragmentMaterial` static struct itself is defined in `pbr.hlsl` and guarded by a define flag:

```hlsl
#ifndef __frag_static
struct FragmentMaterial
{
    float Roughness;
    float Metalness;
    float Occlusion;
    float cosLo;
    float3 worldPosition;
    float4 albedo;
    float2 uv;
    float3 N;
    float fog;
    float3 Lo;
};

static FragmentMaterial frag;
#define __frag_static
#endif
```

The `static` keyword in HLSL creates a per-thread instance with file scope. This means `frag` is not a global shared between shader invocations — each pixel shader thread has its own private copy. The `#ifndef` guard prevents double-definition when both `pbr.hlsl` and `pbr-render.hlsl` are included by the same shader.

## Normal Computation: Flat Shading Toggle

One interesting capability in `mesh-Draw.hlsl` is the `UseFlatShading` parameter, which switches between smooth interpolated normals and geometric face normals at runtime. The function that handles this uses screen-space derivatives:

```hlsl
float3 ComputeNormal(psInput pin, float3x3 tbnToWorld)
{
    float3 N;
    if (UseFlatShading > 0.5)
    {
        // Flat shading: calculate geometric normal from world position derivatives
        float3 dpdx = ddx(pin.worldPosition);
        float3 dpdy = ddy(pin.worldPosition);
        float3 geometricNormal = normalize(cross(dpdy, dpdx));

        // Apply normal map details on top of flat normal
        float4 normalMap = NormalMap.Sample(WrappedSampler, pin.texCoord);
        float3 normalDetail = normalize(2.0 * normalMap.rgb - 1.0);

        // Create TBN basis using geometric normal and derivatives
        float3 T = normalize(dpdx);
        float3 B = normalize(cross(geometricNormal, T));
        T = cross(B, geometricNormal); // Reorthogonalize
        float3x3 flatTBN = float3x3(T, B, geometricNormal);

        N = normalize(mul(normalDetail, flatTBN));
    }
    else
    {
        float4 normalMap = NormalMap.Sample(WrappedSampler, pin.texCoord);
        N = normalize(2.0 * normalMap.rgb - 1.0);
        N = normalize(mul(N, tbnToWorld));
    }
    return N;
}
```

The `ddx()` and `ddy()` intrinsics return the partial derivatives of a value across a 2x2 block of neighboring pixels. The cross product of world-space position derivatives gives the geometric face normal — the actual physical normal of the triangle, regardless of what the vertex normals say. This produces the faceted, low-poly aesthetic that many motion graphics artists want. Notice that even in flat shading mode, normal map details can still be applied on top by constructing a new TBN from the geometric basis.

## BRDF Functions

The core physics lives in three functions in `pbr.hlsl`. These implement the Cook-Torrance specular microfacet BRDF:

$$f_r = \frac{D \cdot F \cdot G}{4 \cdot (\mathbf{N} \cdot \mathbf{L}) \cdot (\mathbf{N} \cdot \mathbf{V})}$$

### GGX Normal Distribution Function

The NDF controls how wide or narrow the specular highlight is. Think of it as the probability that a given microfacet is oriented to reflect light toward the camera. GGX (also called Trowbridge-Reitz) produces highlights with long tails — bright at the center, fading more slowly to zero than older Blinn-Phong. tixl uses Disney's reparameterization where $\alpha = \text{roughness}^2$, which makes the visual effect of adjusting roughness more perceptually linear.

```hlsl
// GGX/Towbridge-Reitz normal distribution function.
// Uses Disney's reparametrization of alpha = roughness^2.
float ndfGGX(float cosLh, float roughness)
{
    float alpha   = roughness * roughness;
    float alphaSq = alpha * alpha;

    float denom = (cosLh * cosLh) * (alphaSq - 1.0) + 1.0;
    return alphaSq / (PI * denom * denom);
}
```

$$D_{GGX} = \frac{\alpha^2}{\pi \left( (\mathbf{N} \cdot \mathbf{H})^2 (\alpha^2 - 1) + 1 \right)^2}$$

At `roughness = 0` the NDF collapses to a near-delta function (almost a mirror), and at `roughness = 1` it spreads to a near-uniform hemisphere.

### Schlick-GGX Geometric Attenuation

The geometry term accounts for self-shadowing and self-masking between microfacets. Without it, rough surfaces would be unrealistically bright at grazing angles because the denominator `4 * NdotL * NdotV` would approach zero. The Smith method factors the geometry term into two separate visibility functions — one for the light direction, one for the view direction — and multiplies them.

```hlsl
// Single term for separable Schlick-GGX below.
float gaSchlickG1(float cosTheta, float k)
{
    return cosTheta / (cosTheta * (1.0 - k) + k);
}

// Schlick-GGX approximation of geometric attenuation function using Smith's method.
float gaSchlickGGX(float cosLi, float cosLo, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0; // Epic suggests using this roughness remapping for analytic lights.
    return gaSchlickG1(cosLi, k) * gaSchlickG1(cosLo, k);
}
```

The remapping `k = (roughness + 1)^2 / 8` is specific to analytical lights. For IBL, the IBL-specific remapping `k = roughness^2 / 2` would be used instead. This distinction matters for getting matching appearance between lit and ambient contributions.

### Fresnel Schlick

The Fresnel term answers: what fraction of incoming light is reflected versus refracted? At near-normal incidence (straight-on view) most light enters a dielectric (plastic, glass). At grazing angles, almost all light is reflected regardless of the material. The Schlick approximation captures this with a polynomial:

```hlsl
// Shlick's approximation of the Fresnel factor.
float3 fresnelSchlick(float3 F0, float cosTheta)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
```

$$F(\theta) = F_0 + (1 - F_0)(1 - \cos\theta)^5$$

`F0` is the reflectance at normal incidence — how reflective the surface is when you look directly at it. For dielectrics, this is the constant `Fdielectric = 0.04`, meaning 4% reflectance. For metals, `F0` is the albedo color: copper's reddish tint at normal incidence comes from this value.

## The Fdielectric Constant

The constant `#define Fdielectric 0.04` encodes a physical fact: most non-metallic materials reflect approximately 4% of incoming light at normal incidence. Water reflects about 2%, glass about 4-8%, most plastics land near 4%. This number was measured empirically by Dontnod Entertainment and Epic Games and has become the de facto standard in game engine PBR implementations.

When `Metalness = 0`, `F0 = lerp(0.04, albedo, 0) = 0.04` — pure dielectric behavior. When `Metalness = 1`, `F0 = lerp(0.04, albedo, 1) = albedo` — the albedo color becomes the specular color, and diffuse light is zero (metals absorb rather than scatter subsurface light).

## Direct Lighting: The 8-Light Loop

The `ComputePbr()` function in `pbr-render.hlsl` implements the full direct lighting calculation. It loops over up to eight `PointLight` entries:

```hlsl
float4 ComputePbr()
{
    float3 N  = frag.N;
    float3 V  = frag.Lo;
    float3 Lo = frag.Lo;

    frag.cosLo = abs(dot(N, Lo));
    float3 Lr  = 2.0 * frag.cosLo * N - Lo; // Specular reflection vector

    float3 F0 = lerp(Fdielectric, frag.albedo.rgb, frag.Metalness);

    float3 directLighting = 0.0;
    for (uint i = 0; i < (uint)ActiveLightCount; ++i)
    {
        float3 Lvec = Lights[i].position - frag.worldPosition;
        float  dist  = length(Lvec);
        float3 L     = Lvec / max(dist, 1e-4);

        float intensity = Lights[i].intensity / (pow(dist / Lights[i].range, Lights[i].decay) + 1);

        float3 Lradiance = Lights[i].color.rgb * intensity;

        float NdotV = saturate(dot(N, V));
        float NdotL = saturate(dot(N, L));
        float3 H    = normalize(L + V);
        float NdotH = saturate(dot(N, H));

        float3 F = fresnelSchlick(F0, saturate(dot(H, V)));
        float  D = ndfGGX(NdotH, frag.Roughness);
        float  G = gaSchlickGGX(NdotL, NdotV, frag.Roughness);

        float3 kd          = lerp(1.0 - F, 0.0, frag.Metalness);
        float3 diffuseBRDF = kd * frag.albedo.rgb;
        float3 specularBRDF = ((F * D * G) / max(Epsilon, 4.0 * NdotL * NdotV)) * Specular;

        directLighting += (diffuseBRDF + specularBRDF) * Lradiance * NdotL;
    }
    ...
}
```

The light attenuation model is:

$$\text{intensity} = \frac{I_0}{\left(\frac{d}{r}\right)^{\text{decay}} + 1}$$

where `d` is the distance from fragment to light, `r` is the light's range, and `decay` controls how fast the falloff happens. At `d = r` (exactly at the range boundary), the divisor becomes `1^decay + 1 = 2`, so intensity halves. This is a modified inverse-power law that avoids the singularity at `d = 0` while still giving physically-plausible falloff. The `decay` exponent lets artists adjust between slow linear falloff (decay=1) and rapid quadratic falloff (decay=2).

The diffuse weight `kd = lerp(1.0 - F, 0.0, frag.Metalness)` is the energy conservation term. When Fresnel `F` is high (grazing angle or high-F0 material), less light reaches the diffuse layer. When metalness is 1, `kd = 0` entirely — metals have no diffuse component. The Lambertian diffuse term itself skips the `1/PI` normalization for artistic convenience, following the pattern established by Sébastien Lagarde's work.

The specular BRDF output is additionally scaled by the `Specular` parameter from `b4`, which defaults to 10.0. This is a non-physical artistic multiplier that gives artists extra control over specular intensity without affecting the underlying BRDF shape.

## PointLight Struct

```hlsl
struct PointLight
{
    float3 position;
    float  intensity;
    float4 color;
    float  range;
    float  decay;
    float2 __padding;
};
```

All eight lights occupy a `PointLight[8]` array in the `b3` cbuffer, consuming `8 * (3+1+4+1+1+2) * 4 = 384` bytes plus the `ActiveLightCount` integer. The `__padding` field aligns the struct to 16-byte HLSL cbuffer boundaries. `ActiveLightCount` tells the loop how many of the eight slots are currently populated, so unused slots do not contribute to the lighting calculation.

## Ambient Lighting: Image-Based Lighting

The IBL path in `ComputePbr()` replaces the direct lighting analytical model with precomputed environment data. Think of IBL as a photograph of the sky and surroundings, pre-integrated to answer two specific questions: "What is the average irradiance coming from the direction this normal points?" and "What is the prefiltered specular environment for a surface with this roughness?"

```hlsl
// Ambient lighting (IBL).
float3 ambientLighting = 0;
{
    uint width, height, levels;
    PrefilteredSpecular.GetDimensions(0, width, height, levels);

    // Sample diffuse irradiance (lowest mip level = fully blurred)
    float3 irradiance = PrefilteredSpecular.SampleLevel(WrappedSampler, N, 0.6 * levels).rgb;

    float3 F  = fresnelSchlick(F0, frag.cosLo);
    float3 kd = lerp(1.0 - F, 0.0, frag.Metalness);

    float3 diffuseIBL = kd * frag.albedo.rgb * irradiance;

    // Sample prefiltered specular at roughness-appropriate mip
    float3 specularIrradiance = PrefilteredSpecular.SampleLevel(
        WrappedSampler, Lr, frag.Roughness * levels).rgb;

    // Split-sum approximation factors
    float2 specularBRDF = BRDFLookup.SampleLevel(
        ClampedSampler, float2(frag.cosLo, frag.Roughness), 0).rg;

    // Total specular IBL
    float3 specularIBL = (F0 * specularBRDF.x + specularBRDF.y) * specularIrradiance;

    ambientLighting = (diffuseIBL + specularIBL) * frag.Occlusion;
}
```

The split-sum approximation, introduced by Epic Games, separates the specular IBL integral into two precomputed terms that can be stored cheaply. The first term is the prefiltered environment map itself, where mip level 0 is a sharp reflection (roughness = 0) and higher mips correspond to blurrier reflections (higher roughness). The second term is the BRDF integration LUT stored at `t7`, which maps `(cosLo, roughness)` to two scale factors `(x, y)` that represent the bias and gain of the Fresnel response averaged over all incoming directions.

The formula `F0 * specularBRDF.x + specularBRDF.y` reconstructs the full specular IBL contribution from these precomputed factors. The `x` channel scales `F0` (the surface-specific Fresnel base) and `y` adds a constant offset. Together they approximate the complete split-sum integral:

$$L_{\text{spec,IBL}} = (F_0 \cdot A + B) \cdot L_{\text{prefiltered}}(\mathbf{L_r}, \text{roughness})$$

where $A$ and $B$ are read from the 2D BRDF LUT.

The diffuse IBL uses the same cubemap but samples at `0.6 * levels` — about 60% of the way to the most-blurred mip. This is a pragmatic approximation: a true diffuse irradiance would require a separate convolved cubemap, but sampling a mid-level mip of the specular cubemap produces visually acceptable results at zero additional texture cost.

## Fog and Emissive Post-Processing

After the lighting sum, two final contributions modify the output:

```hlsl
float4 litColor = float4(directLighting + ambientLighting, 1.0) * BaseColor * Color;

litColor += float4(EmissiveColorMap.Sample(WrappedSampler, frag.uv).rgb * EmissiveColor.rgb, 0);
litColor.rgb = lerp(litColor.rgb, FogColor.rgb, frag.fog * FogColor.a);
litColor.a  *= frag.albedo.a;
```

The emissive term adds to the lit color rather than multiplying it, allowing surfaces to appear to glow beyond the normal reflectance budget. `EmissiveColorMap` is sampled and multiplied by the `EmissiveColor` parameter — setting both gives full artist control over glowing surfaces.

Fog blends the lit color toward `FogColor` by a factor computed in the vertex shader: `pow(saturate(-posInCamera.z / FogDistance), FogBias)`. The negative `posInCamera.z` converts DirectX's right-handed view space (where the camera looks down -Z) into a positive depth value. The `FogBias` power curve lets artists control whether fog onset is gradual (bias < 1) or abrupt (bias > 1).

## Dual Render Target Output

The pixel shader outputs to two render targets simultaneously:

```hlsl
struct psOutput
{
    float4 Color  : SV_Target0;
    float4 Normal : SV_Target1;
};
```

`SV_Target0` receives the final lit color. `SV_Target1` receives the world-space normal vector, which deferred rendering and post-processing passes can use for effects like SSAO, outline detection, or normal-based edge sharpening. The normal output enables downstream nodes in tixl's graph to consume surface orientation data without recomputing it.

## Field Injection and Template Hooks

The pipeline supports runtime code injection through several template comment markers. These are not comments in the generated HLSL — they are replaced with actual code by tixl's shader compilation system before the HLSL is sent to the DX11 compiler.

```hlsl
cbuffer Params : register(b5)
{
    /*{FLOAT_PARAMS}*/
}

//=== Global functions ==============================================
/*{GLOBALS}*/

//=== Additional Resources ==========================================
/*{RESOURCES(t8)}*/

//=== Field functions ===============================================
/*{FIELD_FUNCTIONS}*/
```

The `/*{FLOAT_PARAMS}*/` hook populates the `b5` cbuffer with float parameters defined by connected field operator nodes. `/*{GLOBALS}*/` injects helper function declarations. `/*{RESOURCES(t8)}*/` injects additional texture declarations starting at register `t8` — safely above the PBR system's reserved range of `t0` through `t7`. `/*{FIELD_FUNCTIONS}*/` injects the field function bodies, and the `GetField()` function in the shader calls them to modulate the final pixel:

```hlsl
litColor.rgba *= GetField(float4(pin.worldPosition.xyz, 0)).rgba;
```

This line applies a field operator's output as an RGBA multiplier on the final lit color. It is how tixl's procedural generation connects to the PBR pipeline: a noise field can modulate opacity, a distance field can carve holes in geometry, a gradient field can tint specific regions. The field evaluation happens after all lighting, so it affects the fully-lit color rather than any individual lighting component.

## Alpha Testing

After the field pass, the pixel shader performs alpha testing:

```hlsl
if (AlphaCutOff > 0 && litColor.a < AlphaCutOff)
{
    discard;
}
```

The `discard` instruction discards the current pixel entirely, preventing it from writing to any render target or depth buffer. This is how transparency cutouts work in PBR pipelines without requiring sorted transparency rendering. Setting `AlphaCutOff = 0` disables the test entirely (the `if` short-circuits), so the default material has no alpha cutout behavior.

## Implications for Rust Framework Design

Several patterns here merit attention for a future Rust-based framework.

The static `frag` communication struct is a DX11-era workaround for the lack of function parameters between included files. In a Rust framework with a proper shader module system (or in WebGPU), this pattern would be replaced with explicit function signatures, making data flow clearer and preventing accidental aliasing.

The template injection system (`/*{FLOAT_PARAMS}*/`) is a string-substitution metaprogramming system. It works but has no type safety. A Rust framework could model this more cleanly as a trait-based extension point, where material operators implement a `MaterialExtension` trait that declares their parameter types, and the shader compilation system generates typed cbuffer declarations from those declarations.

The dual RT output (Color + Normal) is a lightweight forward-rendering approximation of deferred shading. It is sufficient for the creative coding use case, which rarely involves thousands of lights, but worth noting as a design choice that constrains later rendering features (screen-space effects that read both buffers simultaneously require a deferred setup).

The `Specular` parameter as a non-physical multiplier on the Cook-Torrance denominator is a pragmatic concession to artistic control. A physically correct implementation would not have it. Future framework implementations should consider whether to preserve this artistic override or enforce energy conservation.

## References

- `Operators/Lib/Assets/shaders/shared/pbr.hlsl` — BRDF functions, `PbrVertex`, `FragmentMaterial`
- `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl` — `ComputePbr()`, IBL, fog
- `Operators/Lib/Assets/shaders/shared/point-light.hlsl` — `PointLight` struct
- `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl` — Full VS/PS, cbuffer declarations, dual RT output
- `Core/Rendering/Material/PbrMaterial.cs` — C# material parameters, default values
- Nadrin PBR reference: https://github.com/Nadrin/PBR/blob/master/data/shaders/hlsl/pbr.hlsl
- Epic Games S2013 course notes: http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
- Sébastien Lagarde on PI normalization: https://seblagarde.wordpress.com/2012/01/08/pi-or-not-to-pi-in-game-lighting-equation/
- Sébastien Lagarde on IBL Fresnel: https://seblagarde.wordpress.com/2011/08/17/hello-world/
