# apEx Lighting System

Lighting in Phoenix serves a specific purpose: create compelling visuals for choreographed demo scenes with a handful of carefully placed lights. This isn't the clustered lighting of open-world games or the thousands-of-lights scenarios that modern engines optimize for. It's eight lights maximum, each artistically positioned, each contributing to a coherent visual story.

The lighting system supports three light types: point lights for local illumination, directional lights for sun and moon, and spot lights for focused beams. Beyond basic lights, Phoenix implements area light extensions using Linearly Transformed Cosines (LTC) for physically accurate soft reflections. Shadow mapping provides shadow casting for key lights. Image-based lighting (IBL) adds ambient fill without explicit light sources.

This focused scope enables Phoenix to implement sophisticated lighting math—Cook-Torrance BRDFs, proper Fresnel, area light integration—without the infrastructure overhead of general-purpose lighting systems. Every light evaluates every visible pixel, but with only eight lights, that's acceptable.

## Light Data Structure

The `LIGHTDATA` structure (Scene.h:131) holds all parameters for a single light.

```cpp
struct LIGHTDATA
{
    D3DXVECTOR4 Position;       // World position (w=1) or direction (w=0)
    D3DXVECTOR4 Ambient;        // Ambient contribution color
    D3DXVECTOR4 Diffuse;        // Diffuse/specular color × intensity
    D3DXVECTOR4 Specular;       // Specular color (often = Diffuse)
    D3DXVECTOR4 SpotDirection;  // Spot cone axis (normalized)
    D3DXVECTOR4 SpotData;       // x=exponent, y=cutoff, z=linear, w=quadratic
};
```

**Position** stores world-space coordinates for point and spot lights. For directional lights, it stores the light direction with `w=0` to distinguish from positions.

**Ambient/Diffuse/Specular** follow the classic Phong model naming, though Phoenix uses them for PBR. Diffuse provides the light's primary color and intensity. Specular can differ for tinted specular highlights. Ambient adds constant contribution regardless of surface orientation.

**SpotDirection** defines the cone axis for spot lights. Combined with SpotData's cutoff angle, this creates directional falloff.

**SpotData** packs attenuation and spot parameters:
- `x` = Spot exponent (falloff sharpness at cone edge)
- `y` = Cutoff angle (cosine of half-angle)
- `z` = Linear attenuation coefficient
- `w` = Quadratic attenuation coefficient

## Light Collection

The scene collects lights during scene graph traversal, building an array for shader consumption.

```cpp
// Scene.cpp conceptual flow
void CphxScene::CollectLights(CphxScene* sceneToCollectFrom)
{
    LightCount = 0;

    for (int i = 0; i < ObjectCount && LightCount < MAX_LIGHT_COUNT; i++)
    {
        CphxObject* obj = Objects[i];
        if (obj->ObjectType != Object_Light) continue;

        LIGHTDATA& light = Lights[LightCount++];

        // Position from accumulated world transform
        light.Position = D3DXVECTOR4(obj->WorldPosition, 1);

        // Colors from animated spline results
        light.Ambient = D3DXVECTOR4(
            obj->SplineResults[Spline_Light_AmbientR],
            obj->SplineResults[Spline_Light_AmbientG],
            obj->SplineResults[Spline_Light_AmbientB],
            1);

        light.Diffuse = D3DXVECTOR4(
            obj->SplineResults[Spline_Light_DiffuseR],
            obj->SplineResults[Spline_Light_DiffuseG],
            obj->SplineResults[Spline_Light_DiffuseB],
            1);

        // Spot direction from target object
        if (obj->Target)
        {
            D3DXVECTOR3 dir = obj->Target->WorldPosition - obj->WorldPosition;
            D3DXVec3Normalize(&dir, &dir);
            light.SpotDirection = D3DXVECTOR4(dir, 0);
        }

        // Spot parameters from splines
        light.SpotData = D3DXVECTOR4(
            obj->SplineResults[Spline_Light_Exponent],
            obj->SplineResults[Spline_Light_Cutoff],
            obj->SplineResults[Spline_Light_Attenuation_Linear],
            obj->SplineResults[Spline_Light_Attenuation_Quadratic]);
    }
}
```

**MAX_LIGHT_COUNT** is 8, matching the constant buffer's light array size. Additional lights are ignored—demos are authored knowing this limit.

**Spline animation** drives all light parameters. Color, intensity, position (via transforms), and spot parameters animate via timeline curves. This enables dynamic lighting synchronized with music and visuals.

**Target objects** simplify spot light aiming. Instead of manually specifying direction vectors, artists parent a "target" object to the spot light. The engine calculates direction from light to target each frame.

## Light Types

### Point Lights

Point lights emit omnidirectionally from a position, with intensity falling off by distance.

```hlsl
// Shader: point light evaluation
float3 ToLight = lightPos.xyz - P;
float DistSqr = dot(ToLight, ToLight);
float3 L = ToLight * rsqrt(DistSqr);

// Distance attenuation: 1 / (d² + 1)
float Falloff = rcp(DistSqr + 1);

float NoL = saturate(dot(N, L));
float3 diffuse = Falloff * NoL * GBuffer.DiffuseColor / PI;
float3 specular = Falloff * NoL * SpecularGGX(roughness, specColor, context, NoL);

return (diffuse + specular) * lightColor.xyz;
```

The `+ 1` in the falloff denominator prevents division by zero at the light's center. It also provides a softer falloff than pure inverse-square, which can look harsh at close range.

Point lights have no directional component—they illuminate equally in all directions. This makes them simple but limits their artistic control compared to spot lights.

### Directional Lights

Directional lights represent infinitely distant sources like the sun. All rays are parallel, with no distance attenuation.

```hlsl
// Shader: directional light evaluation
float3 L = normalize(-lightDir.xyz);  // Negate: direction TO light

float NoL = saturate(dot(N, L));
float3 diffuse = NoL * GBuffer.DiffuseColor / PI;
float3 specular = NoL * SpecularGGX(roughness, specColor, context, NoL);

return (diffuse + specular) * lightColor.xyz;
```

Without attenuation, directional lights provide uniform illumination across the scene. They're typically used for primary lighting with shadow mapping.

The light direction stores negated (pointing toward the source) because the BRDF calculations use the direction *from* the surface *to* the light.

### Spot Lights

Spot lights combine point light falloff with angular attenuation, creating focused beams.

```hlsl
// Shader: spot light evaluation
float3 ToLight = lightPos.xyz - P;
float DistSqr = dot(ToLight, ToLight);
float3 L = ToLight * rsqrt(DistSqr);

// Distance attenuation
float Falloff = rcp(DistSqr + 1);

// Angular attenuation
float spotCos = dot(-L, spotDir.xyz);
float spotAtten = pow(saturate((spotCos - cutoff) / (1 - cutoff)), exponent);

float NoL = saturate(dot(N, L));
float3 diffuse = Falloff * spotAtten * NoL * GBuffer.DiffuseColor / PI;
float3 specular = Falloff * spotAtten * NoL * SpecularGGX(...);

return (diffuse + specular) * lightColor.xyz;
```

**cutoff** is the cosine of the spot cone's half-angle. Outside this angle, `spotCos < cutoff` and the attenuation goes to zero.

**exponent** controls edge softness. Higher values create sharper cone edges; lower values create gradual falloff.

The formula `(spotCos - cutoff) / (1 - cutoff)` normalizes the angular range to [0, 1] within the cone, then `pow()` with exponent shapes the falloff curve.

## Area Lights

Phoenix extends point lights with physical size for realistic area light behavior. Two implementations exist.

### Analytical Sphere Approximation

The simpler approach treats the sphere light as a point light with horizon clipping and energy normalization.

```hlsl
float SphereHorizonCosWrap(float NoL, float SinAlphaSqr)
{
    float SinAlpha = sqrt(SinAlphaSqr);

    if (NoL < SinAlpha)
    {
        // Surface tilted enough that sphere partially dips below horizon
        NoL = max(NoL, -SinAlpha);

        // Accurate sphere irradiance formula for partial visibility
        float CosBeta = NoL;
        float SinBeta = sqrt(1 - CosBeta * CosBeta);
        float TanBeta = SinBeta / CosBeta;

        float x = sqrt(1 / SinAlphaSqr - 1);
        float y = -x / TanBeta;
        float z = SinBeta * sqrt(1 - y * y);

        NoL = NoL * acos(y) - x * z + atan(z / x) / SinAlphaSqr;
        NoL /= PI;
    }

    return saturate(NoL);
}
```

**SinAlphaSqr** is the squared sine of the sphere's angular radius as seen from the shading point. Larger spheres (or closer spheres) have larger angular radius.

When the surface tilts away enough that the sphere's edge dips below the horizon (the surface plane), only part of the sphere is visible. This function computes the exact irradiance from the visible portion using solid geometry.

```hlsl
// Usage in lighting shader
float SinAlphaSqr = saturate(lightRadius * lightRadius * Falloff);
float NoL = dot(N, L);
NoL = SphereHorizonCosWrap(NoL, SinAlphaSqr);

// Energy normalization for representative point
float Energy = EnergyNormalization(a2, VoH, sqrt(SinAlphaSqr));
```

**Energy normalization** compensates for using a single representative point instead of integrating over the sphere's surface. The approximation works well for rough surfaces and small-to-medium sphere radii.

### LTC (Linearly Transformed Cosines)

For larger area lights or lower roughness where reflections are sharper, LTC provides more accurate results.

LTC's insight: transform the GGX BRDF lobe into a clamped cosine distribution, transform the light polygon by the inverse, integrate the cosine (which has a closed form), and you get the GGX integral over the original polygon.

#### Pre-computed Tables

Phoenix embeds two lookup tables totaling 2.5KB:

**ltc_1** (2048 bytes): 16×16 grid of 3×3 transformation matrices, stored as 4 half-floats per entry (the matrix has known zeros).

**ltc_2** (512 bytes): 16×16 grid of magnitude and Fresnel factors, stored as 2 bytes per entry.

These tables index by (roughness, viewing angle). See [shaders.md](shaders.md) for the sampling code.

#### Sphere Discretization

LTC works on polygons. Phoenix approximates spheres as 24-vertex polygons:

```hlsl
// Generate polygon approximating visible sphere disc
float scale = distance / sqrt(4 * distance * distance - 1);

vertexCount = 24;
for (uint i = 0; i < vertexCount; i++)
{
    float angle = 2 * PI * i / vertexCount;
    float3 localPos = float3(cos(angle), 0, sin(angle)) * scale;

    // Rotate to face shading point, transform to world space
    points[i] = mul(discRotation, localPos);
    points[i] = mul(worldmat, float4(points[i], 1)).xyz - P;
}
```

The `scale` formula comes from sphere geometry: given distance `d` from center to a unit sphere, the visible disc radius is `d / sqrt(4d² - 1)`.

24 vertices provide a smooth circle approximation. Fewer vertices would create visible polygon edges in reflections.

#### Polygon Clipping and Integration

```hlsl
float LTC_Evaluate(float3x3 Minv, float3 points[], uint vertexCount)
{
    float3 L[64];
    uint n = 0;

    // Transform and clip to upper hemisphere
    for (uint i = 0; i < vertexCount; i++)
    {
        float3 curr = mul(Minv, points[i]);
        float3 next = mul(Minv, points[(i+1) % vertexCount]);

        if (curr.z > 0) L[n++] = normalize(curr);
        if ((curr.z > 0) != (next.z > 0))
            L[n++] = normalize(lerp(curr, next, -curr.z / (next.z - curr.z)));
    }

    // Edge integration
    float sum = 0;
    for (uint j = 0; j < n; j++)
    {
        float3 v1 = L[j];
        float3 v2 = L[(j+1) % n];
        sum += IntegrateEdge(v1, v2);
    }

    return max(0, -sum);
}
```

The clipping removes polygon vertices below the horizon (z < 0 in transformed space). The integration sums contributions from each edge, using the closed-form cosine integral formula.

#### When to Use Which

| Condition | Recommended |
|-----------|-------------|
| Small light, high roughness | Analytical approximation |
| Large light, low roughness | LTC |
| Many lights | Analytical (cheaper) |
| Quality critical | LTC |

LTC costs more ALU (polygon clipping, integration loop) but provides accurate area light reflections. Analytical approximation is faster and sufficient for rough surfaces where reflections blur anyway.

## Shadow Mapping

Phoenix implements shadow mapping for directional and spot lights using a single shadow map texture.

### Shadow Map Generation

The Shadow Layer renders geometry from the light's perspective, writing only depth.

```cpp
// Conceptual: Setting up shadow map render
void SetupShadowPass(CphxObject_Light* light)
{
    // Orthographic projection for directional light
    float orthoX = light->SplineResults[Spline_Light_OrthoX];
    float orthoY = light->SplineResults[Spline_Light_OrthoY];

    D3DXMatrixOrthoLH(&shadowProj, orthoX, orthoY, 0.1f, 100.0f);

    // View matrix from light's transform
    D3DXMatrixLookAtLH(&shadowView,
                       &light->WorldPosition,
                       &(light->WorldPosition + light->TargetDirection),
                       &D3DXVECTOR3(0, 1, 0));

    SetRenderTarget(shadowMapRT);
    Clear(depth = 1.0);
}
```

**Orthographic projection** provides uniform shadow resolution across the scene. Perspective projection would waste resolution on nearby geometry.

**OrthoX/OrthoY** define the projection bounds, animated via splines. Artists size the shadow frustum to cover the visible scene.

### Shadow Sampling

During the lighting pass, each pixel transforms to light space and tests visibility.

```hlsl
float VSM(float2 shadowUV, float lightDepth, float softness)
{
    float shadow = 0;

    // 5×5 PCF kernel
    for (int x = 0; x < 5; x++)
    {
        for (int y = 0; y < 5; y++)
        {
            float2 offset = float2(x - 2, y - 2) * 0.02 * softness;
            shadow += shadowMap.SampleCmpLevelZero(
                ShadowSampler, shadowUV + offset, lightDepth);
        }
    }

    return shadow / 25.0;
}
```

**SampleCmpLevelZero** performs hardware-accelerated depth comparison. The sampler is configured with a comparison function (less-equal), returning 0 or 1 per sample.

**PCF (Percentage-Closer Filtering)** averages 25 binary shadow tests to produce soft edges. The `softness` parameter scales the sample spread.

The 5×5 kernel provides pleasing soft shadows at reasonable cost. Larger kernels would blur more but cost more texture samples.

### Shadow Coordinate Calculation

```hlsl
float3 GetShadowCoord(float3 worldPos)
{
    // Transform to light clip space
    float4 lightClip = mul(shadowViewProj, float4(worldPos, 1));

    // Perspective divide and bias
    float3 shadowCoord;
    shadowCoord.xy = lightClip.xy / lightClip.w * 0.5 + 0.5;
    shadowCoord.y = 1 - shadowCoord.y;  // Flip Y for texture space
    shadowCoord.z = lightClip.z / lightClip.w - 0.001;  // Depth bias

    return shadowCoord;
}
```

**Depth bias** (0.001) prevents shadow acne—self-shadowing artifacts from floating-point precision. The value is scene-dependent; too much causes "peter-panning" where shadows detach from objects.

### Variance Shadow Maps (VSM)

Some materials use Variance Shadow Maps for even softer shadows:

```hlsl
// Shadow map stores depth AND depth²
float2 moments = shadowMap.Sample(Sampler, shadowUV).xy;
float E_x2 = moments.y;
float Ex_2 = moments.x * moments.x;
float variance = E_x2 - Ex_2;

float mD = lightDepth - moments.x;
float pMax = variance / (variance + mD * mD);

return max(pMax, lightDepth <= moments.x ? 1.0 : 0.0);
```

VSM uses Chebyshev's inequality to estimate visibility from statistical moments. The advantage is hardware-filterable shadows—bilinear filtering of the moment texture produces soft shadows without PCF.

## Image-Based Lighting (IBL)

The ambient pass adds image-based lighting contribution without explicit light sources.

### Simplified IBL

Clean Slate uses a simplified IBL model without environment cubemaps:

```hlsl
float3 DiffuseIBL(float3 N, float3 V, float3 F0, float3 albedo, float metallic)
{
    float3 H = normalize(V + N);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

    // Ambient light color substitutes for environment map
    return (1 - F) * (1 - metallic) * ambientColor.xyz * albedo / PI;
}
```

**Fresnel modulation** reduces ambient contribution at grazing angles where specular reflection dominates. The `(1 - F)` term ensures energy conservation.

**Metalness factor** reduces diffuse ambient for metals, which should only receive specular ambient (not implemented in this simplified version).

This approximation works because demos control their lighting precisely. A uniform ambient color is sufficient when artists design scenes knowing the ambient behavior.

### Full IBL (Not Implemented)

A complete IBL implementation would include:
- Prefiltered environment map for specular (roughness-dependent mip levels)
- Irradiance map for diffuse (spherical harmonics or cubemap)
- Split-sum approximation with BRDF LUT

Phoenix omits full IBL for size reasons. The 64k constraint favors analytical lighting over baked environment data. However, Phoenix does support several reflection techniques as post-processing effects.

## Reflection Techniques

While Phoenix doesn't use traditional cubemap environment reflections, it provides several alternative techniques for reflective surfaces.

### Screen-Space Reflections (SSR)

Clean Slate implements SSR as a post-processing pass, ray-marching in screen space to find reflected geometry.

```hlsl
// screen-space-reflections.hlsl (conceptual)
float4 SSR(float2 texCoord, float4 pixelPos)
{
    float4 background = colorTexture.Load(pixelPos.xy);

    // Early exit for non-reflective pixels
    if (background.w <= 0)
        return background * (1 + backgroundBoost);

    // Get view-space position and normal
    float3 viewPos = GetViewPosition(pixelPos.xy);
    float3 viewNormal = LoadNormal(pixelPos.xy);

    // Calculate reflection vector
    float3 reflectionDir = reflect(normalize(viewPos), viewNormal);

    // Ray march along reflection
    float3 hitPos = viewPos;
    for (int i = 0; i < STEPS; i++)
    {
        hitPos += reflectionDir * stepSize;

        // Project to screen space
        float2 screenUV = ProjectToScreen(hitPos);
        float sceneDepth = SampleDepth(screenUV);

        // Check for intersection
        if (hitPos.z > sceneDepth)
        {
            // Binary refinement for accuracy
            for (int j = 0; j < 4; j++)
            {
                hitPos -= reflectionDir * stepSize;
                stepSize *= 0.5;
                // Re-test and adjust...
            }

            // Sample reflection color
            float4 reflection = colorTexture.SampleLevel(sampler, screenUV, mipLevel);
            return background + reflection * fadeout * mask;
        }
    }

    return background;
}
```

**SSR characteristics:**
- **Pros**: No pre-baked data, reflects dynamic content, roughness-aware (mip selection)
- **Cons**: Only reflects visible geometry, artifacts at screen edges, costly ray march

**Parameters exposed:**
- `radius` — Maximum ray march distance
- `steps` — Number of march steps (quality vs. performance)
- `acceptBias` — Hit detection tolerance

### Fake Cubemap / Importance-Sampled Environment

For ambient reflections without a real cubemap, Clean Slate uses importance sampling:

```hlsl
// deferred-fake-cubemap.hlsl (conceptual)
float3 FakeEnvironmentReflection(float3 N, float3 V, float roughness)
{
    float3 R = reflect(-V, N);
    float3 color = 0;

    // Sample environment in importance-weighted directions
    for (int i = 0; i < SAMPLES; i++)
    {
        float2 Xi = Hammersley(i, SAMPLES);
        float3 H = ImportanceSampleGGX(Xi, N, roughness);
        float3 L = reflect(-V, H);

        // Sample environment at this direction
        float mipLevel = roughness * MAX_MIP;  // Rougher = blurrier
        color += SampleEnvironment(L, mipLevel);
    }

    return color / SAMPLES;
}
```

This technique samples a simple environment texture (gradient, procedural sky) in multiple directions weighted by the GGX distribution. Rougher surfaces sample more spread-out directions with higher mip levels.

### Spherical Environment Mapping

A classic technique for simple environment reflections using a 2D texture:

```hlsl
// base-material.hlsl spherical mapping
float2 SphereMapUV(float3 viewReflection)
{
    // Map 3D reflection vector to 2D UV
    float m = 2.0 * sqrt(viewReflection.x * viewReflection.x +
                         viewReflection.y * viewReflection.y +
                         (viewReflection.z + 1) * (viewReflection.z + 1));
    return viewReflection.xy / m + 0.5;
}

float4 EnvironmentColor(float3 N, float3 V)
{
    float3 viewPos = mul(viewMatrix, float4(worldPos, 1)).xyz;
    float3 viewNormal = mul(viewMatrix, float4(N, 0)).xyz;
    float3 R = reflect(normalize(viewPos), normalize(viewNormal));

    float2 envUV = SphereMapUV(R);
    return environmentTexture.Sample(sampler, envUV);
}
```

This maps the 3D reflection vector to a 2D texture coordinate using spherical projection. Simple but limited to single-bounce, fixed environment images.

### Planar Reflections

For flat surfaces like floors or water, planar reflection renders the scene from a mirrored viewpoint:

```hlsl
// mirror.hlsl planar reflection
float4 PlanarReflection(float2 uv, float2 mirrorPoint, float2 mirrorNormal)
{
    // Check which side of mirror line we're on
    float2 toPixel = uv - mirrorPoint;
    float side = dot(toPixel, mirrorNormal);

    if (side < 0)
        return originalTexture.Sample(sampler, uv);

    // Reflect UV across the mirror line
    float2 projectedPoint = mirrorPoint + mirrorNormal * dot(toPixel, mirrorNormal);
    float2 reflectedUV = 2 * projectedPoint - uv;

    return reflectedTexture.Sample(sampler, reflectedUV);
}
```

This is a 2D technique operating in screen space. The scene is rendered twice—once normally, once with a flipped view matrix—and composited.

### Reflection Technique Comparison

| Technique | Use Case | Data Required | Dynamic Content | Quality |
|-----------|----------|---------------|-----------------|---------|
| SSR | General reflections | G-Buffer, color | Yes | High but limited |
| Fake Cubemap | Ambient/sky reflections | Simple environment | Limited | Medium |
| Spherical Mapping | Simple static reflections | Environment texture | No | Low |
| Planar | Floors, water | Second render pass | Yes | High |
| LTC Area Lights | Light reflections | LTC tables | Yes | High |

### When to Use Each

- **SSR**: Primary reflection technique for dynamic scenes. Falls back to ambient when rays miss.
- **Fake Cubemap**: Ambient fill for SSR misses or distant reflections.
- **Planar**: Special case for large flat surfaces where SSR quality isn't sufficient.
- **LTC**: Handles area light reflections specifically (covered in Area Lights section).

## Light Rendering Flow

The lighting layer processes lights as full-screen passes with additive blending.

```
Lighting Layer Start
    │
    ├─ Bind G-Buffer as textures (t0, t1)
    ├─ Bind depth buffer as texture (t7)
    ├─ Set additive blend mode (ONE, ONE)
    ├─ Disable depth write
    │
    ├─ For each light type in scene:
    │     │
    │     ├─ Bind light-specific shader
    │     ├─ Set light parameters to constant buffer
    │     │
    │     ├─ Draw full-screen quad
    │     │   Each pixel:
    │     │     ├─ Read G-Buffer (albedo, normal, roughness, metalness)
    │     │     ├─ Reconstruct world position from depth
    │     │     ├─ Calculate light direction and distance
    │     │     ├─ Evaluate BRDF (diffuse + specular)
    │     │     ├─ Apply shadow (if applicable)
    │     │     └─ Output light contribution
    │     │
    │     └─ Contributions accumulate via additive blend
    │
    ├─ Ambient pass (similar, but no shadow)
    │
    └─ Main RT contains accumulated lighting
```

Each light type can have its own specialized shader. Point lights skip spot calculations. Area lights include LTC or analytical integration. This per-light-type approach avoids branching within shaders.

## Light Animation

All light parameters animate via the spline system. The `PHXSPLINETYPE` enum (Scene.h:17) defines animatable properties:

```cpp
// Light color splines
Spline_Light_AmbientR = 12,
Spline_Light_AmbientG = 13,
Spline_Light_AmbientB = 14,
Spline_Light_DiffuseR = 16,
Spline_Light_DiffuseG = 17,
Spline_Light_DiffuseB = 18,
Spline_Light_SpecularR = 20,
Spline_Light_SpecularG = 21,
Spline_Light_SpecularB = 22,

// Spot parameters
Spot_Direction_X = 24,
Spot_Direction_Y = 25,
Spot_Direction_Z = 26,
Spline_Light_Exponent = 28,
Spline_Light_Cutoff = 29,
Spline_Light_Attenuation_Linear = 30,
Spline_Light_Attenuation_Quadratic = 31,

// Shadow projection size
Spline_Light_OrthoX = 48,
Spline_Light_OrthoY = 49,
```

During scene graph traversal, `CalculateAnimation()` evaluates these splines at the current timestamp, storing results in `SplineResults[]`. The light collection phase reads these evaluated values into `LIGHTDATA` structures.

This enables:
- Pulsing lights synchronized with music beats
- Color-shifting mood lighting
- Spot lights tracking moving targets
- Shadow bounds adjusting for camera movement

## Performance Considerations

### 8-Light Limit

The constant buffer holds 8 `LIGHTDATA` structures. This is a hard limit—additional lights are ignored. Demos work within this constraint by:
- Strategic light placement (one key, two fill, one rim)
- Using emissive materials for ambient glow without light objects
- Baking static lighting into vertex colors

### Full-Screen Passes

Each light renders a full-screen quad, evaluating every pixel. For 1080p at 8 lights, that's 8 × 2M = 16M pixel shader invocations per frame. Modern GPUs handle this easily, but it doesn't scale to hundreds of lights.

### No Culling

Lights don't cull against geometry. A light at the scene's edge still evaluates every pixel, even those it doesn't illuminate. For demo scenes where lights are carefully placed, this waste is minimal.

## Implications for Rust Framework

### Adopt: Animated Light Parameters

Make all light properties animatable. Store parameters in a format compatible with spline evaluation. This enables expressive lighting without hard-coded keyframe systems.

### Adopt: LTC for Area Lights

The 2.5KB LTC tables provide excellent area light quality. Ship them as embedded data (`include_bytes!`). The implementation translates directly to WGSL.

### Modify: Dynamic Light Count

Don't hardcode `MAX_LIGHT_COUNT = 8`. Use dynamic arrays or storage buffers. For simple demos, 8 lights is fine. For games, support more.

### Modify: Light Culling

For larger scenes, implement tiled or clustered lighting. Compute shaders can bin lights spatially, reducing per-pixel light iteration.

### Avoid: Full-Scene Shadow Map

Single shadow maps work for demos but limit game-scale lighting. Consider cascaded shadow maps for directional lights, point light shadow atlases for omnis.

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture
- **[shaders.md](shaders.md)** — BRDF implementation, LTC shader code
- **[deferred.md](deferred.md)** — G-Buffer that lighting reads
- **[../code-traces/ltc-area-lighting.md](../code-traces/ltc-area-lighting.md)** — Detailed LTC trace
- **[../code-traces/pbr-pipeline.md](../code-traces/pbr-pipeline.md)** — Lighting in context

## Source References

| File | Purpose | Key Lines |
|------|---------|-----------|
| Scene.h | LIGHTDATA, PHXSPLINETYPE | 131-137, 17-91 |
| Scene.cpp | CollectLights, light collection | |
| phxEngine.cpp | LTC texture creation | 298-336 |
| Phoenix/ltc_1.h | LTC matrix table | 2048 bytes |
| Phoenix/ltc_2.h | LTC magnitude table | 512 bytes |

Shader references from Clean Slate (`Projects/Clean Slate/cleanslate.apx`):

| Shader | Lines | Purpose |
|--------|-------|---------|
| Area Sphere Light LTC | 41967-42137 | LTC implementation |
| Area Sphere Light Non-LTC | 42688-42909 | Analytical approximation |
| Deferred Ambient Light | 45502-45605 | IBL pass |
| Shadow sampling | 43547-43578 | PCF shadow lookup |
