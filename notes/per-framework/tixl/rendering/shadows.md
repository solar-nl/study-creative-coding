# tixl Shadow Rendering

A shadow is a lie told by the GPU. The real world produces shadows through occlusion — a photon that hits a wall simply never reaches the floor behind it. The GPU cannot track individual photons, so it approximates the answer by asking a different question: from the light's point of view, can it "see" this fragment? Shadow mapping answers that question with a two-pass scheme. First, render the scene from the light's perspective and record how far each surface is from the light. Then, during the main render pass, project each fragment back into the light's coordinate system and compare its depth against what the light could see. If the light could not see this point — because something closer blocked it — the fragment is in shadow.

In tixl, this scheme is exposed to the artist through a pair of operators: `SetShadow`, which orchestrates the shadow map generation pass, and `DrawMeshWithShadow`, which uses that shadow map during the main lighting evaluation. The system is single-shadow-caster, single-perspective — appropriate for creative coding scenes where the dramatic effect of a strong directional shadow matters more than physically accurate multi-light shadow coverage.

The key mental model is that tixl's shadow system adds a fourth cbuffer slot — the light transform — to the standard PBR cbuffer layout. Every fragment now knows both where the camera sees it (the standard view-projection transform) and where the light sees it (the shadow transform stored in `b1`). The fragment shader uses the shadow coordinates to look up the shadow map and decide whether this point was visible from the light's perspective.

## The Two-Pass Architecture

Shadow rendering requires two complete traversals of scene geometry. The first pass renders from the light's point of view, writing depth values to a dedicated texture. The second pass renders from the camera's point of view, with the shadow texture available as a shader resource. tixl models this as a command-graph pattern: the `SetShadow` operator wraps a command subtree, runs it twice with different render targets, and makes the result available downstream.

Looking at the internal structure of `SetShadow` (from `SetShadow.t3`), the shadow pass uses these components:

- Two `Texture2d` resources: a color target with format `R16G16B16A16_Float` and a depth stencil with format `R32_Typeless` bound as both `DepthStencil` and `ShaderResource`
- A `Camera` or `OrthographicCamera` positioned at the `LightPosition` looking toward `LightTarget`
- A `Viewport` and `Rasterizer` configured for the shadow map dimensions
- `SetIntVar` calls that toggle the `__IsShadowPassId` variable before and after the geometry render
- `SetMatrixVar` that stores the light's `WorldToClipSpace` matrix under the name `_WorldToLightClipSpace`
- `SetContextTexture` that registers the completed depth buffer as `ShadowMap`

The depth stencil format `R32_Typeless` is significant. The same memory can be interpreted as a depth buffer during the shadow pass (using `DXGI.Format.D32_Float`) and as a shader resource during the main pass (using `DXGI.Format.R32_Float`). This typeless format trick is a DirectX 11 pattern for reusing GPU memory without copying.

The default shadow map resolution is 512x512 pixels, derived from the `ShadowMapSize` node in the operator graph. The `Resolution` input allows artists to increase this to 1024, 2048, or higher values when shadow sharpness matters. Larger shadow maps reduce aliasing but increase memory and fill rate costs.

## SetShadow Operator Inputs

The `SetShadow.cs` operator exposes these inputs to the node graph:

```csharp
[Input(Guid = "be6dc055...")]
public readonly InputSlot<Command> Command = new InputSlot<Command>();

[Input(Guid = "6196074f...")]
public readonly InputSlot<Vector3> LightPosition = new InputSlot<Vector3>();

[Input(Guid = "76a6a0e4...")]
public readonly InputSlot<Vector3> LightTarget = new InputSlot<Vector3>();

[Input(Guid = "3ee1e726...")]
public readonly InputSlot<int> Resolution = new InputSlot<int>();

[Input(Guid = "5fb309a1...")]
public readonly InputSlot<Vector2> DepthRange = new InputSlot<Vector2>();

[Input(Guid = "bbec0f5e...")]
public readonly InputSlot<bool> ShowDebug = new InputSlot<bool>();
```

`DepthRange` defaults to `(0.01, 100.0)` — the near and far clip planes of the light camera. These values critically affect shadow precision. The depth buffer stores values in `[0, 1]` that are distributed non-linearly (more precision near the camera). A very wide depth range like `(0.01, 1000.0)` compresses most of the precision into the near region, causing depth fighting artifacts on surfaces far from the light. Artists need to set `DepthRange.Y` as tightly as possible around their scene bounds.

`ShowDebug` enables a picture-in-picture overlay that shows the shadow map as a grayscale thumbnail in the preview window. This is the debugging tool that reveals whether the light camera is positioned correctly and whether scene geometry falls within the light frustum.

## Shadow Map cbuffer Layout

The shadow variant of the mesh draw shader — `mesh-DrawWithShadows.hlsl` — changes `b1` from the standard per-draw params to a shadow-aware layout:

```hlsl
cbuffer Params : register(b1)
{
    float4x4 WorldToLightClipSpace;
    float4   Color;
    float4   ShadowColor; // RGB for color, A for intensity
    float    ShadowBias;
    float    ShadowOffset;
    float    AlphaCutOff;
};
```

The `WorldToLightClipSpace` matrix is the critical addition. It transforms any world-space position into the light's clip space, where depth values can be compared against the shadow map. This matrix is filled in by the `SetMatrixVar` node that stores the light camera's `WorldToClipSpace` output under the key `_WorldToLightClipSpace`.

`ShadowColor` uses its RGB components for the shadow tint color and its alpha for shadow intensity. An `ShadowColor` of `(0, 0, 0, 1)` produces pure black shadows. `(0.2, 0.1, 0.3, 0.8)` produces semi-transparent violet shadows — useful for stylized scenes where shadows serve as a visual design element rather than a physically accurate occlusion cue.

`ShadowBias` and `ShadowOffset` address the two classic shadow mapping artifacts. Their roles are distinct and both are necessary.

## Normal Offset Bias

Shadow acne — the self-shadowing noise pattern that covers every surface at certain angles — has two related causes. The first is depth bias: the shadow map stores a discretized depth, and the fragment being compared against it may round to slightly the wrong depth bin, causing it to shadow itself. The second is surface slope: a polygon at a steep angle to the light has a large difference in depth across a single shadow map texel.

tixl attacks both problems, but uses different mechanisms. The `ShadowBias` parameter addresses depth precision by adding a constant offset to the shadow map comparison:

```hlsl
if (shadowCoord.z > sampleDepth + bias)
{
    shadow += 1.0;
}
```

The `ShadowOffset` parameter uses a geometrically different approach — it moves the shadow-receiver position along the surface normal before computing shadow coordinates. This normal offset method is more robust for surfaces at varying slopes because the offset is always perpendicular to the surface rather than along the light direction. The vertex shader applies this offset:

```hlsl
// Compute normal in world space
float3 worldNormal = normalize(mul(float4(vertex.Normal, 0), (float4x4)ObjectToWorld).xyz);

// Offset position along normal for shadow mapping
float4 posInWorldOffset = posInWorld;
posInWorldOffset.xyz += worldNormal * ShadowOffset;
output.positionInLightClipSpace = mul(posInWorldOffset, WorldToLightClipSpace);
```

The key observation is that `positionInLightClipSpace` is computed from the offset position, but `output.worldPosition` continues to use the unmodified position. The shadow lookup uses the biased light-space coordinates, but the shading calculation — diffuse, specular, IBL — uses the true world position. This ensures that shadow bias does not misplace the light and dark regions of the surface.

## The PCF Shadow Kernel

After a single shadow map lookup, shadows have hard, pixelated edges. Percentage Closer Filtering (PCF) softens those edges by sampling the shadow map multiple times in a neighborhood and averaging the results. tixl uses a 3x3 PCF kernel:

```hlsl
inline float ComputeShadowFactor(float3 shadowCoord, float2 texelSize, float bias)
{
    float shadow  = 0.0;
    int   samples = 0;
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            float2 offset    = float2(x, y) * texelSize;
            float2 sampleUV  = shadowCoord.xy + offset;

            // Sample only if sampleUV is within [0,1]
            if (sampleUV.x >= 0 && sampleUV.x <= 1 &&
                sampleUV.y >= 0 && sampleUV.y <= 1)
            {
                float sampleDepth = ShadowMap.Sample(clampedSampler, sampleUV);

                if (shadowCoord.z > sampleDepth + bias)
                {
                    shadow += 1.0;
                }
            }
            samples++;
        }
    }
    return 1.0 - (shadow / samples);
}
```

The 3x3 grid runs nine taps centered on the shadow coordinate. Each tap offsets by one texel in each direction using `texelSize = 1.0 / (shadowMapWidth, shadowMapHeight)`. The in-bounds check prevents edge artifacts when a shadow coordinate lands near the border of the shadow map — samples outside `[0,1]` are simply skipped, though they still increment the `samples` counter. This means border fragments receive a slightly reduced shadow contribution rather than a hard-clipped one.

The function returns a `shadowFactor` in `[0, 1]`: 1.0 means fully lit, 0.0 means fully shadowed. The number of lit samples divided by total samples gives the fractional illumination — hence "percentage closer filtering." The name is slightly counterintuitive: you are not filtering the depth values (that would be incorrect), you are filtering the binary shadow test results.

## Shadow Coordinate Projection

The pixel shader computes shadow UV coordinates from the light-space position passed through from the vertex shader:

```hlsl
// Compute shadow coordinates
float3 shadowCoord = pin.positionInLightClipSpace.xyz / pin.positionInLightClipSpace.w;
shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
shadowCoord.y  = 1 - shadowCoord.y;
```

The perspective divide `/ .w` converts from homogeneous clip space to NDC (Normalized Device Coordinates). In DirectX NDC, X and Y range from -1 to +1, and Z ranges from 0 to 1. The `* 0.5 + 0.5` remapping converts X and Y into UV coordinates in `[0, 1]`. The Y flip `1 - shadowCoord.y` accounts for the DirectX texture coordinate convention where V=0 is at the top of the texture, while NDC Y=+1 corresponds to the top of the projection.

The depth comparison `shadowCoord.z > sampleDepth + bias` uses the already-normalized Z value from NDC, which matches the `[0, 1]` range stored in the shadow depth buffer. No additional remapping is needed for the depth comparison.

## Spotlight Cone Masking

Beyond the basic shadow test, `mesh-DrawWithShadows.hlsl` applies a spotlight cone falloff at the border of the shadow map's coverage area:

```hlsl
// Spotlight cone effect
float coneSize = Lights[0].range;
float d    = length((float2(0.5, 0.5) - shadowCoord.xy) / .25);
float cone = 1.0 - smoothstep(0.8, 1.0, d);
```

This computes a normalized distance from the center of the shadow map (`0.5, 0.5`) and applies a `smoothstep` falloff between 80% and 100% of the shadow map radius. Fragments near the shadow map boundary fade from fully shadowed to fully unaffected, preventing the hard cutoff that would otherwise appear at the edge of the light frustum.

The `/ .25` divisor scales the coordinate so that `d = 1` corresponds to the outer edge of the inscribed square within the shadow map. The comment `// TODO: allow to use a texture instead` suggests this hard-coded cone mask is a placeholder for a projected texture (a gobo or cookie) that could pattern the light output arbitrarily.

## Shadow Color Blending

The shadow factor multiplied by the cone mask feeds directly into the final color blend:

```hlsl
float4 litColor = float4(directLighting + ambientLighting, 1.0) * BaseColor * Color;
litColor.rgb = lerp(litColor.rgb, ShadowColor.rgb, (1 - shadowFactor * cone) * ShadowColor.a);
litColor += float4(EmissiveColorMap.Sample(texSampler, pin.texCoord).rgb * EmissiveColor.rgb, 0);
litColor.rgb = lerp(litColor.rgb, FogColor.rgb, pin.fog * FogColor.a);
```

The shadow contribution `(1 - shadowFactor * cone)` is 1 in fully shadowed regions and 0 in fully lit regions. The `ShadowColor.a` alpha channel scales the overall intensity of the shadow effect — setting it to 0 disables shadows entirely without changing the shader. The `lerp` toward `ShadowColor.rgb` replaces lit color with the shadow color, rather than simply darkening it, which enables stylized non-black shadows.

Notice that the shadow blend happens after the PBR lighting calculation but before emissive and fog. This ordering means emissive surfaces glow through shadows — physically incorrect but artistically useful.

## DrawMeshWithShadow Operator

The `DrawMeshWithShadow.cs` operator is the entry point from the graph. Its inputs reveal the full set of artist-facing controls:

```csharp
public readonly InputSlot<MeshBuffers> Mesh         = new InputSlot<MeshBuffers>();
public readonly InputSlot<Vector4>     Color         = new InputSlot<Vector4>();
public readonly InputSlot<float>       AlphaCutOff   = new InputSlot<float>();
public readonly InputSlot<int>         BlendMode     = new InputSlot<int>();
public readonly InputSlot<int>         FillMode      = new InputSlot<int>();
public readonly InputSlot<CullMode>    Culling       = new InputSlot<CullMode>();
public readonly InputSlot<bool>        EnableZTest   = new InputSlot<bool>();
public readonly InputSlot<bool>        EnableZWrite  = new InputSlot<bool>();
public readonly InputSlot<Vector4>     ShadowColor   = new InputSlot<Vector4>();
public readonly InputSlot<float>       ShadowBias    = new InputSlot<float>();
public readonly InputSlot<float>       ShadowOffset  = new InputSlot<float>();
```

The separation of `ShadowBias` and `ShadowOffset` as distinct inputs reflects the fact that scenes require different tuning for different geometries. Flat planes parallel to the light need almost no bias. Complex curved objects with fine surface detail may need substantial normal offset to clear the surface. Exposing both separately allows artists to tune each without interfering with the other.

## ShadowPlane Operator

Separate from the mesh draw system, tixl provides a `ShadowPlane` operator that takes a different approach: rather than integrating shadows into the main PBR loop, it renders a dedicated soft shadow plane beneath an object. `ShadowPlane.cs` exposes:

```csharp
public readonly InputSlot<float>   PlaneSize          = new InputSlot<float>();
public readonly InputSlot<float>   FieldOfView        = new InputSlot<float>();
public readonly InputSlot<int>     Resolution         = new InputSlot<int>();
public readonly InputSlot<Vector4> Color              = new InputSlot<Vector4>();
public readonly InputSlot<float>   BlurRadius         = new InputSlot<float>();
public readonly InputSlot<Vector2> BlurDistribution   = new InputSlot<Vector2>();
public readonly InputSlot<Vector3> Center             = new InputSlot<Vector3>();
public readonly InputSlot<Vector3> Rotation           = new InputSlot<Vector3>();
```

The `BlurRadius` and `BlurDistribution` inputs indicate this operator renders a projected shadow and then blurs it as a screen-space post-process — a simpler alternative to PCF that gives more artistic control over softness. Resolutions available via the `Resolutions` enum are 128, 256, 512, 1024, 2048, and 4096. The default for `ShadowMapSize` in `SetShadow` is 512x512, consistent with the common resolution choice.

## Particle Shadow Maps

The codebase also contains a research implementation of particle shadow maps, which encodes particle depth into a cascaded opacity structure. The fragment shader `research-DrawParticleShadowMap-ps.hlsl` reads from four separate shadow maps covering depth ranges `[0, 0.25]`, `[0.25, 0.5]`, `[0.5, 0.75]`, and `[0.75, 1.0]`:

```hlsl
float getOcclusion(Texture2D<float4> shadowMap, float2 uv, float z)
{
    float4 om   = shadowMap.SampleLevel(texSampler, uv, 0);
    float4 mask = saturate((float4(sz,sz,sz,sz) - float4(0.00, 0.25, 0.50, 0.75)) * 4.0);
    om  *= mask;
    float occlusion = om.x + om.y + om.z + om.w;
    return occlusion;
}

float4 psMain(Input input) : SV_TARGET
{
    float4 scsPparticlePos = mul(input.posInWorld, Shadow_WorldToClipSpace);
    scsPparticlePos.xyz /= scsPparticlePos.w;
    scsPparticlePos.xy   = scsPparticlePos.xy * 0.5 + 0.5;
    scsPparticlePos.y    = 1.0 - scsPparticlePos.y;

    float occlusion = 0.0;
    occlusion += getOcclusion(ShadowMap0, scsPparticlePos.xy, ...);
    occlusion += getOcclusion(ShadowMap1, scsPparticlePos.xy, ...);
    occlusion += getOcclusion(ShadowMap2, scsPparticlePos.xy, ...);
    occlusion += getOcclusion(ShadowMap3, scsPparticlePos.xy, ...);
    occlusion *= 0.25;
    occlusion  = 1.0 - saturate(occlusion);
    ...
}
```

Each shadow map stores four channels of opacity information representing four sub-ranges within one depth quarter. The `mask` computation isolates the relevant depth sub-range from the channel packing. This cascaded approach handles the transparency and depth ambiguity inherent to particles, which do not have a well-defined single depth value the way solid meshes do.

This particle shadow system uses a separate `ShadowTransforms` cbuffer at `b1` carrying a full duplicate set of camera matrices from the shadow camera's perspective:

```hlsl
cbuffer ShadowTransforms : register(b1)
{
    float4x4 Shadow_CameraToClipSpace;
    float4x4 Shadow_WorldToCamera;
    float4x4 Shadow_CameraToWorld;
    float4x4 Shadow_WorldToClipSpace;
    // ... etc
};
```

## Integration with the PBR Pipeline

The standard shadow system integrates at the output of the PBR lighting calculation rather than inside the `ComputePbr()` loop. This is a deliberate architectural choice: `ComputePbr()` in `pbr-render.hlsl` has no shadow knowledge. The shadow modulation happens after it returns, in the `mesh-DrawWithShadows.hlsl` pixel shader. The shadow factor multiplies the entire lit result including both direct and indirect (IBL) contributions:

```
litColor.rgb = lerp(litColor.rgb, ShadowColor.rgb, (1 - shadowFactor * cone) * ShadowColor.a)
```

Integrating shadow inside the direct lighting loop would be more physically correct — only direct light should be shadowed, not ambient IBL — but would require `ComputePbr()` to accept shadow parameters, coupling the two systems. The current architecture keeps `pbr-render.hlsl` shadow-free and composable, at the cost of slightly incorrect ambient shadowing.

The shadow map texture itself binds at register `t8`:

```hlsl
Texture2D<float> ShadowMap : register(t8);
```

This placement is significant: the PBR system's reserved texture range is `t0` through `t7`. Shadow is the first "extension" resource at `t8`, following the same convention as the `/*{RESOURCES(t8)}*/` template hook in the standard mesh draw shader. Shadow functionality is cleanly layered on top of the base PBR system.

## Relationship Between SetShadow and DrawMeshWithShadow

The two operators cooperate through tixl's context variable system. `SetShadow` stores the shadow map texture under the string key `"ShadowMap"` and the light transform matrix under `"_WorldToLightClipSpace"`. `DrawMeshWithShadow` retrieves these context values when constructing its draw call. The graph wiring between these operators does not need to carry the shadow texture explicitly — the context system acts as a render-pass-scoped blackboard.

This is analogous to how OpenGL's `glActiveTexture` and `glBindTexture` work: rather than threading the texture handle through every function call, it is stored in named slots that the draw call reads from implicitly. tixl generalizes this into a named-variable system that any operator can write to or read from within the current command execution scope.

The `__IsShadowPassId` integer variable written by `SetIntVar` nodes serves as a mode flag for geometry operators: when `__IsShadowPassId = 1`, operators that are not shadow-compatible can skip their draw calls entirely. This prevents screen-space effects, skyboxes, and other non-occluder geometry from corrupting the shadow map with spurious depth values.

## Implications for Rust Framework Design

The tixl shadow system reveals several patterns relevant to a future Rust framework.

The split between `SetShadow` (pass orchestration) and `DrawMeshWithShadow` (shadow consumer) is clean from a user perspective but requires careful lifetime management. The shadow texture must outlive the draw call that produced it and be accessible to every consumer in the same render group. In a Rust ownership model, this maps naturally to `Arc<Texture>` shared between the pass setup and the draw calls.

The `__IsShadowPassId` context flag is a runtime mechanism for what is fundamentally a compile-time dispatch problem. A Rust framework with a trait-based operator system could model this as a `ShadowPass` marker trait that operators implement to declare shadow-casting capability, enabling the framework to automatically skip non-casters during shadow map generation.

The PCF kernel is hard-coded at 3x3 taps. Modern shadow implementations use Poisson disk sampling or interleaved gradient noise to spread taps more efficiently, achieving softer edges with fewer samples. A Rust framework targeting Vulkan or WebGPU could offer configurable kernel sizes and sampling patterns as shader specialization constants rather than requiring separate shader variants.

The normal offset bias approach (`ShadowOffset`) is more robust than constant depth bias for organic geometry and deserves to be a first-class feature rather than a secondary parameter. The slope-scale depth bias from DirectX's rasterizer state is another option, but the normal offset approach gives artists more intuitive control — they think in object-space surface geometry rather than shadow-space depth gradients.

## References

- `Operators/Lib/Assets/shaders/3d/mesh/mesh-DrawWithShadows.hlsl` — Full shadow-aware VS/PS with PCF kernel
- `Operators/Lib/Symbols/render/shading/SetShadow.cs` — Shadow pass orchestration operator
- `Operators/Lib/Symbols/render/shading/SetShadow.t3` — Internal graph: camera, RTV, DSV, context texture setup
- `Operators/Lib/Symbols/mesh/draw/DrawMeshWithShadow.cs` — Shadow consumer operator inputs
- `Operators/Lib/Symbols/render/basic/ShadowPlane.cs` — Soft shadow plane with blur
- `Operators/Lib/Assets/shaders/dx11/research-DrawParticleShadowMap-ps.hlsl` — Cascaded particle opacity shadow maps
- `Operators/Lib/Assets/shaders/shared/pbr.hlsl` — `FragmentMaterial` struct (shadow-free base)
- `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl` — `ComputePbr()` (shadow integration point is after this call)
