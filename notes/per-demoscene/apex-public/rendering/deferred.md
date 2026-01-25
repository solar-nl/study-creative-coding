# apEx Deferred Rendering

Deferred rendering separates geometry rasterization from lighting calculation. Instead of computing lighting during the geometry pass, you write surface properties to intermediate buffers—the G-Buffer—then calculate lighting in subsequent full-screen passes. This decoupling makes the lighting cost proportional to screen resolution, not geometry complexity.

For 64k demos, deferred rendering offers a compelling trade-off. The additional memory for G-Buffer render targets is fixed and small. The lighting shaders can be sophisticated—area lights, multiple shadow maps, complex BRDFs—without that complexity multiplying by triangle count. Eight lights evaluating every pixel is manageable. Eight lights evaluating every triangle in every mesh is not.

Phoenix implements a minimal deferred pipeline. Two render targets capture all PBR surface properties. The depth buffer provides world position reconstruction. Lighting accumulates additively through full-screen passes. Transparency falls back to forward rendering because transparent surfaces can't participate in the G-Buffer.

## Why Deferred for 64k

Several factors make deferred rendering attractive for demos.

**Light count flexibility**: Forward rendering evaluates all lights per-triangle in the geometry shader. Adding lights adds cost to every triangle. Deferred evaluates all lights per-pixel in screen space. Adding lights adds fixed-cost full-screen passes. For scenes with 4-8 dynamic lights, deferred often wins.

**Shader complexity**: Complex BRDFs (area lights, anisotropic materials, subsurface scattering) execute once per pixel, not once per triangle. The BRDF cost is "paid" at screen resolution regardless of geometry density.

**Code reuse**: Lighting shaders are independent of geometry shaders. Add a new material? Write a G-Buffer shader. Add a new light type? Write a lighting shader. Neither affects the other.

**Memory predictability**: G-Buffer memory is fixed: `width × height × channels × precision`. For 1080p with RGBA8 targets, that's about 16MB. This is predictable and fits comfortably in VRAM.

**Bandwidth trade-off**: Writing the G-Buffer consumes bandwidth during the geometry pass. Reading it during lighting consumes bandwidth again. For simple scenes with few lights, this overhead exceeds forward rendering. For complex scenes with many lights, it's worthwhile.

## G-Buffer Layout

Phoenix uses a compact two-target G-Buffer that captures all PBR inputs.

### Render Targets

| Target | Format | RGB Channels | Alpha Channel |
|--------|--------|--------------|---------------|
| RT0 | RGBA8 | Albedo color | Metalness |
| RT1 | RGBA8 or RGBA16F | World normal | Roughness |

**Albedo** stores the base surface color. For non-metals, this is the diffuse color. For metals, it's the specular color. The metalness workflow uses the same data for both.

**Metalness** ranges [0, 1]. Values near 0 represent dielectrics (plastic, ceramic, skin). Values near 1 represent conductors (gold, copper, aluminum). Mixed values represent layered materials or dirt on metal.

**World normal** stores the perturbed surface normal in world space. Using world normals instead of view normals simplifies the lighting pass—light positions are already in world space.

**Roughness** ranges [0, 1]. Low values produce sharp reflections (mirrors, polished chrome). High values produce diffuse-like broad highlights (concrete, fabric).

### Precision Considerations

8-bit channels provide 256 levels per component. For normals, this can cause visible banding on smooth surfaces. Phoenix accepts this for most materials but uses RGBA16F for hero objects where quality matters.

8-bit roughness rarely shows banding because roughness variations are subtle and smooth in texture. 8-bit metalness is adequate because most surfaces are either clearly metallic or clearly dielectric.

### Alternative Layouts

More sophisticated engines use additional G-Buffer targets:

- **RT2**: Emissive color (self-illumination)
- **RT3**: Material ID or subsurface parameters
- **RT4**: Motion vectors (for temporal AA)

Phoenix handles emissive differently—through "mixed rendering" rather than a dedicated G-Buffer channel. See the Mixed Rendering section below. Motion vectors compute from position derivatives. The minimal two-target approach keeps bandwidth and memory low.

## G-Buffer Generation

### Render Layer Setup

The Solid Layer configures multiple render targets for G-Buffer output.

```xml
<!-- Clean Slate render layer definition -->
<renderlayer>
    <Name>Solid Layer</Name>
    <RenderTarget>Main RT</RenderTarget>           <!-- RT0 -->
    <RenderTarget>Albedo and Metalness</RenderTarget> <!-- RT1 -->
    <RenderTarget>Normal and Roughness</RenderTarget> <!-- RT2 -->
</renderlayer>
```

Note: The XML uses RT1/RT2 indices, but shaders write to `SV_TARGET1` and `SV_TARGET2`. Target 0 receives the main color output (or may be unused for depth-only pre-passes).

### G-Buffer Shader

The PBR deferred material writes to multiple render targets.

```hlsl
struct PSOUT
{
    float4 am : SV_TARGET1;  // Albedo.RGB + Metalness.A
    float4 nr : SV_TARGET2;  // Normal.RGB + Roughness.A
};

Texture2D<float4> t_0 : register(t0);  // Albedo + Metalness texture
Texture2D<float4> t_1 : register(t1);  // Normal + Roughness texture

PSOUT p(VSOUT v)
{
    // Determine front/back face normal flip
    float normmult = (data.z > 0.5) ? -1 : 1;

    // Sample textures
    float4 albedo = t_0.Sample(Sampler, v.uv.xy);
    float4 normalMap = t_1.Sample(Sampler, v.uv.xy);

    // Perturb normal using derivative-based tangent frame
    float3 normal = perturb_normal(
        normalize(v.Normal) * normmult,
        v.p,
        v.uv.xy,
        normalMap.xyz);

    // Apply material modifiers
    float metalness = ApplyModifier(albedo.w, data.y);
    float roughness = ApplyModifier(normalMap.w, data.x);

    // Write G-Buffer
    PSOUT o;
    o.am = float4(albedo.xyz, metalness);
    o.nr = float4(normal, roughness);
    return o;
}
```

**Normal flip** (`data.z`) enables two-sided materials. Back-facing triangles flip their normal to face the camera. Without this, back faces would render incorrectly lit.

**Material modifiers** (`data.x`, `data.y`) adjust texture values at runtime. Artists can increase roughness or decrease metalness via timeline animation without creating new textures.

### Depth Buffer

The depth buffer captures Z values during G-Buffer generation. Phoenix uses the hardware depth buffer (`D24_S8` or `D32F`) rather than writing depth to a color target.

During lighting, the depth buffer binds as a shader resource (texture slot 7). This enables world position reconstruction without an additional render target.

```cpp
// Binding depth for lighting pass (conceptual)
ID3D11ShaderResourceView* depthSRV = depthBuffer->GetShaderResourceView();
phxContext->PSSetShaderResources(7, 1, &depthSRV);
```

## World Position Reconstruction

Lighting needs world position to calculate light direction and distance. Instead of storing position in the G-Buffer (12 bytes per pixel for XYZ), Phoenix reconstructs it from depth.

### The Math

Screen position + depth → clip space → view space → world space.

```hlsl
float3 getWorldPos(float depth, float2 uv)
{
    // Screen UV [0,1] to NDC [-1,1]
    float2 ndc = uv * 2 - 1;

    // NDC + depth = clip space position
    float4 clipPos = float4(ndc.x, -ndc.y, depth, 1);

    // Inverse projection: clip → view
    float4 viewPos = mul(iprojmat, clipPos);

    // Inverse view: view → world
    float4 worldPos = mul(iviewmat, viewPos);

    // Perspective divide
    return worldPos.xyz / worldPos.w;
}
```

**NDC Y-flip**: DirectX NDC has Y pointing up, but screen UV has Y pointing down. The `-ndc.y` corrects this.

**Perspective divide**: Matrix multiplication produces homogeneous coordinates. Dividing by `w` yields Cartesian world position.

### Performance

Reconstruction costs ~20 ALU operations per pixel. Storing world position would cost 12 bytes per pixel in G-Buffer bandwidth. For 1080p, that's 24MB bandwidth per lighting pass. The ALU cost is usually cheaper.

### Precision

Depth precision varies across the view frustum. Near the camera, small depth differences represent large position differences. Far from the camera, depth values cluster together. This can cause position artifacts for distant geometry.

Phoenix uses linear depth or reversed-Z to improve precision. See the depth buffer configuration in `phxEngine.cpp`.

## Normal Unpacking

G-Buffer normals store in [0,1] range for 8-bit textures but represent [-1,1] vectors.

### Standard Encoding

```hlsl
// Write (G-Buffer shader)
float3 normalToStore = normal * 0.5 + 0.5;  // [-1,1] → [0,1]

// Read (Lighting shader)
float3 normal = normalFromTexture * 2 - 1;  // [0,1] → [-1,1]
```

### Octahedral Encoding (Not Used)

More sophisticated engines use octahedral normal encoding to pack XYZ into RG channels, freeing B for other data. Phoenix skips this for simplicity—the RGB storage is adequate.

### Normal Quality

8-bit normal precision (256 levels per axis) can produce visible banding on smooth surfaces. This manifests as "stepping" in specular highlights. Solutions:

- Use RGBA16F for the normal target (doubles bandwidth)
- Use higher-frequency normal maps to mask quantization
- Accept the artifact (it's subtle in most scenes)

Phoenix generally accepts the artifact, using 16F only for close-up hero shots.

## Metalness Workflow Conversion

The G-Buffer stores albedo and metalness. Lighting shaders need diffuse color and specular F0. The conversion happens during G-Buffer unpacking.

```hlsl
FGBufferData UnpackGBuffer(float4 albedoMetal, float4 normalRough)
{
    FGBufferData g;

    g.WorldNormal = normalize(normalRough.xyz * 2 - 1);
    g.Roughness = normalRough.w;

    // Metalness workflow conversion
    float metalness = albedoMetal.w;
    float3 albedo = albedoMetal.xyz;

    // Non-metals: diffuse = albedo, specular F0 = 0.04
    // Metals: diffuse = black, specular F0 = albedo
    g.DiffuseColor = albedo * (1 - metalness);
    g.SpecularColor = lerp(float3(0.04, 0.04, 0.04), albedo, metalness);

    return g;
}
```

**Why 0.04?** Most dielectric materials (plastic, glass, ceramic) have ~4% Fresnel reflectance at normal incidence. This is the "F0" value—the specular color when looking straight at the surface.

**Metals have no diffuse**: In metals, free electrons absorb and re-emit light immediately, producing only specular reflection. Setting `DiffuseColor = albedo * (1 - metalness)` ensures metals have zero diffuse.

## Mixed Rendering for Emissive

Phoenix supports emissive (self-illuminating) materials through "mixed rendering"—a hybrid approach that computes lighting during the geometry pass while still writing G-Buffer data.

### Why Mixed Rendering?

Pure deferred rendering can't handle emissive elegantly:
- Storing emissive in a G-Buffer channel wastes bandwidth for non-emissive surfaces
- Emissive needs to add directly to output, not participate in BRDF calculations
- Alpha cutout (common with emissive) requires early fragment discard

Mixed rendering solves these by doing forward-style lighting in materials that need emissive, while preserving deferred's benefits for other surfaces.

### Mixed Rendering Output

Emissive materials write to three render targets simultaneously:

```hlsl
struct PSOUT
{
    float4 c  : SV_TARGET0;  // Lit color (including emissive)
    float4 am : SV_TARGET1;  // Albedo.RGB + Metalness.A
    float4 nr : SV_TARGET2;  // Normal.RGB + Roughness.A
};
```

The shader samples the emissive texture (slot t2) and uses it to initialize the light accumulator:

```hlsl
float3 Lo = emissiveMap.xyz;  // Start with emissive
for (int i = 0; i < lightcount; i++) {
    // BRDF calculations...
    Lo += (kD * albedo / PI + specular) * radiance * NdotL;
}
p.c = float4(Lo, 1.0);
```

### Benefits of Mixed Rendering

| Aspect | Benefit |
|--------|---------|
| Self-illumination | Emissive contributes even in darkness |
| Reflections | G-Buffer written, so emissive surfaces reflect correctly |
| Alpha cutout | `discard` works naturally in geometry pass |
| No extra RT | No dedicated emissive G-Buffer channel needed |
| Selective use | Only emissive materials pay the forward lighting cost |

### When to Use Each Approach

| Material Type | Rendering Approach |
|---------------|-------------------|
| Opaque, no emissive | Pure deferred (G-Buffer only) |
| Opaque with emissive | Mixed rendering |
| Transparent | Forward rendering |

This hybrid pipeline keeps the G-Buffer compact for the common case (non-emissive materials) while supporting the full range of material effects.

## Lighting Layer Configuration

The lighting layer reads the G-Buffer and accumulates light contributions.

```xml
<renderlayer>
    <Name>Lighting Layer</Name>
    <OmitDepthBuffer>1</OmitDepthBuffer>
    <ClearRenderTargets>0</ClearRenderTargets>
    <RenderTarget>Main RT</RenderTarget>
</renderlayer>
```

**OmitDepthBuffer**: Lighting doesn't write depth. Full-screen quads would overwrite the scene's depth values.

**ClearRenderTargets**: Don't clear before lighting. The G-Buffer pass already wrote initial values (or black for unrendered pixels). Clearing would erase ambient contribution.

### Blend State

Lighting uses additive blending to accumulate multiple light contributions.

```cpp
D3D11_BLEND_DESC blendDesc = {};
blendDesc.RenderTarget[0].BlendEnable = TRUE;
blendDesc.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
blendDesc.RenderTarget[0].DestBlend = D3D11_BLEND_ONE;
blendDesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
```

Each light adds its contribution: `Final = Previous + Light`. The first light adds to black (or ambient). Subsequent lights accumulate.

## Transparency Handling

Transparent objects can't use deferred rendering because:

1. **Multiple layers**: Deferred stores one surface per pixel. Transparent objects stack.
2. **Order dependence**: Alpha blending requires back-to-front ordering.
3. **No depth write**: Transparent objects shouldn't write depth, but G-Buffer needs depth.

Phoenix handles transparency with a forward rendering pass after lighting.

```xml
<renderlayer>
    <Name>Transparent Layer</Name>
    <RenderTarget>Main RT</RenderTarget>
</renderlayer>
```

Transparent materials:
- Skip G-Buffer output
- Compute lighting in the pixel shader (forward style)
- Use alpha blending with the lit scene
- Sort objects back-to-front (by render priority)

This limits transparent object complexity. Each transparent object re-evaluates all lights. For a few transparent objects with a few lights, this is acceptable.

## Forward vs. Deferred Trade-offs

| Aspect | Forward | Deferred |
|--------|---------|----------|
| Light cost | Per-triangle × lights | Per-pixel × lights |
| Transparency | Native | Separate pass |
| MSAA | Native | Complex |
| Material flexibility | Full | G-Buffer constraints |
| Memory | Low | G-Buffer overhead |
| Bandwidth | Lower | Higher |

Phoenix uses deferred for opaque geometry (the majority of scene content) and forward for transparency. This hybrid approach captures most benefits of both.

## Performance Characteristics

### G-Buffer Write

The geometry pass writes 8+ bytes per pixel (2 RGBA8 targets). For 1080p, that's ~16MB bandwidth. With depth, ~20MB. This is the "cost" of deferred—forward rendering would write only color + depth (~8MB).

### G-Buffer Read

Each lighting pass reads 8+ bytes per pixel from G-Buffer targets. With 8 lights, that's 8 × ~20MB = ~160MB read bandwidth. This seems expensive, but texture caches handle repeated reads efficiently.

### GPU Occupancy

Full-screen lighting passes have excellent GPU occupancy. Every pixel executes the same shader with similar control flow. No divergence from geometry variations. GPUs love this.

### Overdraw

Deferred eliminates overdraw for lighting. Each pixel evaluates each light exactly once, regardless of how many triangles covered that pixel. Forward rendering would re-light overlapping triangles.

## Implications for Rust Framework

### Adopt: Compact G-Buffer

Two render targets capture full PBR state. Don't over-engineer with extra targets unless the application demands them. The metalness workflow's scalar properties pack naturally.

### Adopt: Depth Reconstruction

Storing world position wastes G-Buffer space. Reconstruct from depth in the lighting shader. wgpu/WGSL support the same inverse-matrix math.

### Modify: Consider F16 for Quality

8-bit normals produce visible quantization. Offer RGBA16F as an option for quality-sensitive applications. The bandwidth cost doubles but visual quality improves.

### Modify: Support Transparency Better

Simple back-to-front sorting works for demos but fails for complex transparency (overlapping, particle systems). Consider order-independent transparency (OIT) for general use.

### Avoid: Fixed G-Buffer Layout

Phoenix's two-target layout is optimal for basic PBR. But some applications need more:
- Subsurface scattering requires additional parameters
- Anisotropic materials need tangent vectors
- Motion blur needs velocity

Design G-Buffer layout as configurable, not hardcoded.

## Data Flow Summary

```
G-Buffer Generation (Solid Layer)
    │
    ├─ For each opaque object:
    │     │
    │     ├─ Vertex shader: transform to world/clip space
    │     ├─ Pixel shader:
    │     │     ├─ Sample albedo + metalness texture → RT0
    │     │     ├─ Sample normal + roughness texture
    │     │     ├─ Perturb normal via tangent frame
    │     │     ├─ Apply material modifiers
    │     │     └─ Write RT0 (albedo+metal) + RT1 (normal+rough)
    │     └─ Depth buffer written automatically
    │
    └─ G-Buffer complete
           │
           ▼
Lighting Accumulation (Lighting Layer)
    │
    ├─ Bind G-Buffer as textures (t0=RT0, t1=RT1)
    ├─ Bind depth buffer as texture (t7)
    ├─ Set additive blend, no depth write
    │
    ├─ For each light:
    │     │
    │     ├─ Pixel shader (full-screen quad):
    │     │     ├─ Sample G-Buffer → unpack material properties
    │     │     ├─ Sample depth → reconstruct world position
    │     │     ├─ Calculate light direction and distance
    │     │     ├─ Evaluate BRDF (diffuse + specular)
    │     │     ├─ Apply shadow (if applicable)
    │     │     └─ Output light contribution
    │     │
    │     └─ Additive blend accumulates contribution
    │
    └─ Main RT contains fully lit scene
           │
           ▼
Transparency (Transparent Layer, forward rendering)
    │
    └─ Forward-shade transparent objects over lit scene
```

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture
- **[shaders.md](shaders.md)** — G-Buffer shader implementation
- **[lighting.md](lighting.md)** — Lighting passes that read G-Buffer
- **[pipeline.md](pipeline.md)** — Render layer organization
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — G-Buffer trace with source

## Source References

Clean Slate project (`Projects/Clean Slate/cleanslate.apx`):

| Section | Lines | Purpose |
|---------|-------|---------|
| Render layers | 41457-41497 | G-Buffer target setup |
| PBR Pure Deferred | 44393-44600 | G-Buffer generation shader |
| Lighting shaders | 42688-42909 | G-Buffer unpacking |
| Position reconstruction | 41567-41571 | Depth to world position |

Phoenix engine (`demoscene/apex-public/apEx/Phoenix/`):

| File | Purpose |
|------|---------|
| Scene.cpp:136 | Layer rendering, constant buffer setup |
| RenderLayer.cpp | Blend state configuration |
| phxEngine.cpp | Depth buffer format configuration |
