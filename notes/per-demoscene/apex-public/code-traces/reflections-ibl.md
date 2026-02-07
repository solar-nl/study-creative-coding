# Code Trace: Fake Cubemap IBL Reflections in Clean Slate

> Tracing how Clean Slate achieves image-based lighting using 2D panoramic textures and importance-sampled Monte Carlo integration — a cubemap-quality result without cubemap infrastructure.

In a 64k demo, every byte of asset data matters. A proper cubemap pipeline requires six 2D textures (or a cubemap format), mipmaps for roughness filtering, and potentially capture infrastructure for dynamic reflections. Clean Slate sidesteps this entirely with "fake cubemaps" — 2D panoramic textures that the `DeCube()` function samples as if they were cubemaps. Combined with physically-based importance sampling using the Hammersley sequence, this produces convincing ambient reflections at a fraction of the storage cost.

The question this code answers: How do you provide environment-based reflections in a demo where you can't afford real cubemap infrastructure? The answer reveals a Monte Carlo approach that trades runtime computation for asset size, using quasi-random sampling to achieve quality comparable to pre-filtered environment maps.

## The Mental Model: Flattening a 3D Skybox

Think of this like trying to reconstruct a 360° panoramic view from a flat photo. A traditional cubemap stores six separate views (front, back, left, right, up, down). The fake cubemap takes a 3D direction vector and figures out which part of a flat 2D texture corresponds to that direction.

It's not perfect — different cube faces overlay each other in the same 2D texture space, creating blending artifacts at seams. But for blurred environment lighting where samples are averaged across many directions, these artifacts disappear into the averaging. For sharp reflections on rough surfaces, the technique is more than sufficient.

The key enabling technique: importance sampling. Instead of sampling the environment uniformly (which would require thousands of samples to converge), we sample more heavily in directions where the BRDF is strongest. For diffuse surfaces, that means more samples near the normal. For specular, it means sampling around the reflection vector with spread controlled by roughness.

## The DeCube Trick: 3D to 2D Projection

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:103-111`

The `DeCube()` function is the heart of the fake cubemap technique. It projects a 3D direction vector onto a 2D texture coordinate as if the texture were a cubemap face.

```hlsl
float2 DeCube(float3 v2)
{
    float3 absUV = abs(v2);
    float maxAxis = max(max(absUV.x, absUV.y), absUV.z);
    float2 uvc = v2.zy;
    if (maxAxis == absUV.y) uvc = v2.xz;
    if (maxAxis == absUV.z) uvc = v2.xy;
    return 0.5 * (uvc / maxAxis + 1);
}
```

**Axis selection**: The function determines which axis the direction vector points most strongly toward. If `absUV.x` is largest, the vector points toward the +X or -X face. If `absUV.y` is largest, it's +Y or -Y. If `absUV.z` is largest, it's +Z or -Z.

**UV coordinate selection**: Based on the dominant axis, it selects the two perpendicular axes as UV coordinates. For X-dominant (sides), use Z and Y. For Y-dominant (top/bottom), use X and Z. For Z-dominant (front/back), use X and Y.

**Projection**: Dividing by `maxAxis` projects the 3D direction onto the unit cube face. The vector `(x, y, z)` where `z` is largest becomes `(x/z, y/z, 1)` on the Z-face.

**Remapping to [0,1]**: The division produces coordinates in [-1, 1]. Multiplying by 0.5 and adding 0.5 remaps to texture space [0, 1].

**The trade-off**: Different cube faces map to overlapping regions of the 2D texture. A +X direction and a -X direction both map to the same general area, distinguished only by the sign of the coordinates. This creates seams and discontinuities. For blurred sampling (high mip levels), these artifacts average out. For sharp reflections, the shader uses separate textures for top/bottom to avoid the worst discontinuities.

## Hammersley Quasi-Random Sampling

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:94-101`

Monte Carlo integration requires random samples across the hemisphere. Pure random sampling converges slowly — it takes thousands of samples to achieve smooth results. Quasi-random sequences provide much better stratification: each new sample fills gaps left by previous samples.

```hlsl
float radicalInverse_VdC(uint bits)
{
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}
```

**Van der Corput sequence**: This function implements the radical inverse in base 2, a fundamental building block of low-discrepancy sequences. It takes an integer and reverses its binary representation.

**Bit reversal**: The sequence of operations interleaves and swaps bits. The first line swaps the upper and lower 16 bits. Each subsequent line swaps progressively smaller chunks (8 bits, 4 bits, 2 bits, 1 bit). The result: `bits` becomes its bit-reversed self.

**Example**: `5` in binary is `00000000000000000000000000000101`. After reversal, it becomes `10100000000000000000000000000000`. In decimal, that's `2684354560`.

**Normalization**: The magic constant `2.3283064365386963e-10` is exactly `1.0 / 2^32`. It converts the 32-bit integer to a float in [0, 1].

**Hammersley sequence**: Combining the radical inverse with a regular sequence produces 2D points: `Hammersley(i, N) = (i/N, VdC(i))`. These points are much more evenly distributed than random samples. For N=32 samples, Hammersley provides coverage comparable to hundreds of random samples.

**Why it works**: Low-discrepancy sequences minimize "clumping." Random samples often cluster in some areas while leaving gaps in others. Hammersley points are guaranteed to spread evenly — the first point, the first two points, the first four points, etc., are all well-distributed.

## Phase 1: Diffuse Irradiance Integration

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:166-186`

The diffuse pass integrates incoming light from all directions across the hemisphere, weighted by the Lambertian BRDF (which is just cosine).

```hlsl
int NumSamples = 32;

// Build tangent frame from surface normal
float3 UpVector = abs(N.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
float3 X = normalize(cross(N, UpVector));
float3 Y = normalize(cross(X, N));
float3x3 mat = float3x3(X, Y, N);

float3 light = 0;

for (int i = 0; i < NumSamples; i++)
{
    float uv = radicalInverse_VdC(i);
    float phi = uv * 2.0 * PI;
    float cosTheta = 1.0 - i / 32.;
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    float3 v = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    float3 v2 = mul(v, mat);
    light += t_2.SampleLevel(Sampler, DeCube(v2), 8).rgb / NumSamples * kD * albedo / PI;
}
```

**Tangent frame construction**: The cross products build an orthonormal basis around the surface normal N. The `UpVector` selection avoids degeneracy when N points straight up (if N is nearly parallel to Z-up, use X-up instead).

**Cosine-weighted hemisphere sampling**: The formula `cosTheta = 1 - i/32` distributes samples with cosine weighting. Samples near the pole (theta = 0, pointing along N) are more frequent than samples near the horizon (theta = 90°). This is importance sampling for the Lambertian BRDF, which falls off as `cos(theta)`.

**Why cosine weighting?** The diffuse BRDF is `albedo / π`, and the geometric term is `cos(theta)`. Together, they form `(albedo / π) * cos(theta)`. If we sample uniformly, we'd need to multiply each sample by `cos(theta)`. By sampling with cosine distribution, that factor is already baked into the PDF, simplifying the math.

**Azimuthal distribution**: The angle `phi` uses the Van der Corput radical inverse for the first component of Hammersley. This spreads samples evenly around the azimuth (the circle at each elevation angle).

**Spherical to Cartesian**: `v = (sin(theta)*cos(phi), sin(theta)*sin(phi), cos(theta))` converts spherical coordinates to a 3D direction in tangent space.

**Tangent to world space**: `mul(v, mat)` rotates the tangent-space direction into world space, where N is the Z-axis of the local frame.

**High mip level**: `SampleLevel(..., 8)` samples a heavily blurred version of the environment texture. Diffuse irradiance should be smooth — sharp details don't contribute to overall ambient fill. High mip also reduces texture cache misses, making the shader faster.

**Energy conservation**: The factor `kD * albedo / PI` applies the Lambertian BRDF. `kD = (1 - F) * (1 - metallic)` ensures that energy not reflected specularly goes into diffuse. The division by `PI` is the standard Lambertian normalization.

**Sample averaging**: Dividing by `NumSamples` averages the 32 samples into a single irradiance value. Because we're using importance sampling, 32 samples are sufficient for smooth results.

## Phase 2: Specular Reflections with GGX Sampling

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:188-226`

The specular pass is more sophisticated. It importance-samples the GGX normal distribution, selecting half-vectors (microfacet normals) according to how likely they are to contribute to the final reflection.

```hlsl
int w, h;
t_2.GetDimensions(w, h);
NumSamples = 64;
float NoV = saturate(dot(N, V)) + 0.0001;

for (int ii = 0; ii < NumSamples; ii++)
{
    float Xi = radicalInverse_VdC(ii);

    float Phi = PI * ii / 32.;
    float CosTheta = sqrt((1 - Xi) / (1 + (Roughness^4 - 1) * Xi));
    float SinTheta = sqrt(1 - CosTheta * CosTheta);
    float3 H = mul(float3(SinTheta * cos(Phi), SinTheta * sin(Phi), CosTheta), mat);

    float3 L = 2 * dot(V, H) * H - V;  // Reflect V around H
    float NoL = saturate(dot(N, L));
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));

    // Mip level from PDF
    float fPdf = D_ggx(Roughness, NoH) * NoH / (4.0 * VoH);
    float fOmegaS = 1.0 / (NumSamples * fPdf);
    float fOmegaP = 4.0 * PI / (6.0 * w * h);
    float mipLevel = max(0.5 * log2(fOmegaS / fOmegaP), 0.0);
    if (Roughness == 0)
        mipLevel = 0;

    // Face selection: sides vs top/bottom
    float3 SampleColor = t_2.SampleLevel(Sampler, DeCube(L), mipLevel).rgb;
    float3 absUV = abs(L);
    float maxAxis = max(max(absUV.x, absUV.y), absUV.z);
    if (maxAxis == absUV.y)
        SampleColor = L.y > 0 ? t_3.SampleLevel(Sampler, DeCube(L), mipLevel)
                              : t_4.SampleLevel(Sampler, DeCube(L), mipLevel);

    // Cook-Torrance BRDF evaluation
    float G = GeometrySmith(N, V, L, Roughness);
    float Fc = pow(1 - VoH, 5);
    float3 F = (1 - Fc) * F0 + Fc;
    if (NoL > 0)
        light += SampleColor * F * G * VoH / (NoH * NoV) / NumSamples;
}
```

### GGX Importance Sampling

The formula for `CosTheta` deserves close attention:

```hlsl
float CosTheta = sqrt((1 - Xi) / (1 + (Roughness^4 - 1) * Xi));
```

This inverts the GGX cumulative distribution function (CDF). Given a uniform random variable `Xi` in [0, 1], it produces a `CosTheta` distributed according to the GGX normal distribution.

**How it works**: GGX defines a probability distribution over microfacet normals (half-vectors). The distribution is concentrated around the macro normal N for smooth surfaces (low roughness) and spread broadly for rough surfaces. The CDF tells you, "what fraction of microfacets have an angle less than theta?" Inverting the CDF answers, "given a random fraction Xi, what angle theta does it correspond to?"

**Roughness term**: `Roughness^4` is the squared alpha term. GGX uses `alpha = Roughness^2` in most formulations, so `alpha^2 = Roughness^4`. This controls how concentrated the distribution is. When `Roughness = 0`, the denominator becomes `1 + (0 - 1)*Xi = 1 - Xi`, and the square root simplifies to `sqrt((1 - Xi) / (1 - Xi)) = 1` — all samples point directly along N, producing a perfect mirror.

**Phi distribution**: Unlike diffuse, specular uses a simple linear progression `Phi = PI * ii / 32`. This creates a spiral pattern around the reflection vector. The Hammersley sequence is still at work (via `Xi` for the theta distribution), providing good stratification.

### Adaptive Mip Level Selection

The mip level calculation is the most sophisticated part of the shader:

```hlsl
float fPdf = D_ggx(Roughness, NoH) * NoH / (4.0 * VoH);
float fOmegaS = 1.0 / (NumSamples * fPdf);
float fOmegaP = 4.0 * PI / (6.0 * w * h);
float mipLevel = max(0.5 * log2(fOmegaS / fOmegaP), 0.0);
```

**PDF (Probability Density Function)**: The GGX distribution gives us `D_ggx(Roughness, NoH)` — the probability density of this particular half-vector. We also need the Jacobian of the transformation from half-vector space to light direction space, which is `NoH / (4 * VoH)`. Together, they form the PDF for sampling the light direction L.

**Solid angle per sample (omegaS)**: If we have `NumSamples` samples and each has probability `fPdf`, the solid angle covered by a single sample is `1 / (NumSamples * fPdf)`. High PDF means the sample is concentrated (small solid angle). Low PDF means the sample is spread out (large solid angle).

**Solid angle per texel (omegaP)**: A cubemap has 6 faces, each with `w * h` texels. The total solid angle of a sphere is `4π` steradians. So each texel covers approximately `4π / (6 * w * h)` steradians.

**Mip level**: Comparing `omegaS` to `omegaP` tells us how many texels a single sample covers. If `omegaS` is large (rough surface, spread-out samples), we should sample from a higher mip level (blurrier texture). The `log2` converts the ratio to mip levels, and the `0.5` factor provides a conservative bias (slightly sharper reflections).

**Why this works**: This is essentially automatic roughness filtering. On smooth surfaces, samples concentrate tightly around the reflection vector, so we sample low mips (sharp detail). On rough surfaces, samples spread widely, so we sample high mips (pre-blurred). The result approximates what a properly pre-filtered environment map would provide.

### Three-Texture Environment Strategy

```hlsl
float3 SampleColor = t_2.SampleLevel(Sampler, DeCube(L), mipLevel).rgb;
float3 absUV = abs(L);
float maxAxis = max(max(absUV.x, absUV.y), absUV.z);
if (maxAxis == absUV.y)
    SampleColor = L.y > 0 ? t_3.SampleLevel(Sampler, DeCube(L), mipLevel)
                          : t_4.SampleLevel(Sampler, DeCube(L), mipLevel);
```

**Default sides texture**: `t_2` provides the environment for horizontal directions (X and Z axes dominant). This texture can represent the horizon and surrounding environment.

**Separate top and bottom**: When the Y axis is dominant, the shader selects either `t_3` (top, for `L.y > 0`) or `t_4` (bottom, for `L.y < 0`). This allows the environment to have a clear sky above and a different ground appearance below, without seam artifacts from the fake cubemap projection.

**Why three textures?** The DeCube projection has its worst artifacts at the cube edges and corners. By using separate textures for the vertical axis, the shader avoids blending between upward and downward reflections, which would create unnatural color mixing.

## BRDF Evaluation Functions

### Fresnel: Schlick Approximation

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:89-92`

```hlsl
float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
```

Fresnel describes how much light reflects versus refracts at a surface. At glancing angles (theta near 90°), all materials become highly reflective. At normal incidence (theta = 0°), materials reflect according to their F0 value.

**F0**: The "base reflectivity" at normal incidence. Dielectrics (non-metals) have F0 around 0.04 (4% reflectance). Metals have colored F0 values corresponding to their albedo.

**The power-of-5**: `(1 - cosTheta)^5` is Schlick's approximation to the full Fresnel equations. It's accurate enough for real-time graphics while being much cheaper to compute.

### Geometry: Smith GGX

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:113-132`

```hlsl
float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;

    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}
```

The geometry term accounts for microfacet self-shadowing. Rough surfaces have tall microfacets that can block light (shadowing) or block the view to reflected light (masking).

**Smith approximation**: The geometry function is evaluated separately for the view direction (V) and light direction (L), then multiplied. This is the "separable" Smith approximation.

**k parameter**: The formula `k = ((roughness + 1)^2) / 8` is the Disney/Epic remapping of roughness to the Smith term. The `+1` and `/8` factors come from empirical fitting to measured material data.

**Why multiply?** The Smith model assumes that shadowing and masking are statistically independent. The probability that a microfacet is both visible to the eye and illuminated by the light is the product of the individual probabilities.

### Distribution: GGX

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:139-145`

```hlsl
float sqr(in float x)
{
    return x * x;
}

float D_ggx(in float alpha, in float NoH)
{
    float a2 = alpha * alpha;
    float cos2 = NoH * NoH;

    return (1.0 / PI) * sqr(alpha / (cos2 * (a2 - 1) + 1));
}
```

GGX (also called Trowbridge-Reitz) defines how microfacet normals are distributed around the macro normal.

**Alpha**: The roughness parameter. `alpha = Roughness`, and `a2 = alpha^2`. Some formulations use `alpha = Roughness^2`, so be careful with conversion when comparing implementations.

**The formula**: The denominator `(cos2 * (a2 - 1) + 1)` reaches its minimum when `NoH = 1` (half-vector aligned with normal), producing the peak of the distribution. As `NoH` decreases (half-vector tilts away), the denominator grows, reducing the probability density.

**Long tail**: GGX is famous for its "long tail" — even at grazing angles, there's still significant probability density. This produces the bright edges and "halos" characteristic of GGX, especially visible on rough metals.

## Energy Conservation and the kD Factor

**File**: `Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl:159-164`

```hlsl
float3 F0 = lerp(0.04, albedo, metallic);

float3 H = normalize(V + N);
float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

float3 kD = (1 - F) * (1 - metallic);
```

**F0 calculation**: Non-metals (metallic = 0) use F0 = 0.04, a typical value for dielectrics. Metals (metallic = 1) use their albedo color as F0, since metals have colored reflectance.

**Fresnel at normal**: Using `H = normalize(V + N)` approximates the half-vector for ambient lighting. This isn't the true half-vector for each sample (which would be computed per-sample), but it provides a reasonable average Fresnel factor for the entire hemisphere.

**kD derivation**: Energy that reflects specularly (governed by Fresnel F) can't also contribute to diffuse. So diffuse gets `(1 - F)` of the remaining energy. Additionally, metals have no diffuse component at all, so we multiply by `(1 - metallic)`. The result: `kD = (1 - F) * (1 - metallic)`.

**Effect on materials**:
- **Dielectrics** (metallic = 0): Have both diffuse and specular. At grazing angles, F approaches 1, so kD approaches 0 — the surface becomes all specular.
- **Metals** (metallic = 1): The `(1 - metallic)` factor zeroes out kD. No diffuse component, only specular reflections.

## Performance and Quality Trade-offs

### Sample Counts

- **Diffuse**: 32 samples
- **Specular**: 64 samples

Why the difference? Specular reflections are more sensitive to noise, especially on smooth surfaces where the BRDF is concentrated. Diffuse reflections are blurry by nature, so fewer samples suffice. The Hammersley sequence ensures that even these modest sample counts produce smooth results.

### Temporal Stability

Unlike techniques like temporal accumulation (accumulating more samples over multiple frames), this shader computes all samples in a single frame. The sample pattern is deterministic (Hammersley, not random), so the result is temporally stable — no flickering or noise accumulation over time.

### Comparison to Pre-filtered Environment Maps

A traditional IBL pipeline would:
1. Capture a cubemap (6 textures)
2. Pre-filter each mip level for different roughness values (convolution over the hemisphere)
3. Store a BRDF integration LUT (2D texture)
4. At runtime, sample two mip levels and interpolate

The fake cubemap approach:
1. Store 2-3 simple 2D textures (much smaller than a cubemap mip chain)
2. At runtime, compute the integration via Monte Carlo

**Trade-off**: More shader ALU (the sampling loops) in exchange for much less texture memory. For a 64k demo, this is the right trade. For a game with many materials, pre-filtered cubemaps would be more efficient.

## Data Flow Diagram

```
┌────────────────────────────────────────────────────────────────┐
│ INPUT: G-Buffer (Albedo, Normal, Roughness, Metallic, Depth)  │
└───────────────────────────────┬────────────────────────────────┘
                                │
                ┌───────────────┴──────────────┐
                │                              │
                ▼                              ▼
    ┌───────────────────────┐      ┌─────────────────────┐
    │  DIFFUSE IRRADIANCE   │      │ SPECULAR REFLECTIONS│
    │  32 cosine samples    │      │ 64 GGX samples      │
    └───────────────────────┘      └─────────────────────┘
                │                              │
                │                              │
    ┌───────────▼────────────┐     ┌──────────▼──────────┐
    │ Hammersley sequence    │     │ Hammersley sequence │
    │ Cosine-weighted        │     │ GGX-weighted        │
    │ hemisphere samples     │     │ half-vectors        │
    └───────────┬────────────┘     └──────────┬──────────┘
                │                              │
                │                              │
    ┌───────────▼────────────┐     ┌──────────▼──────────┐
    │ Tangent frame          │     │ Tangent frame       │
    │ Transform to world     │     │ Transform to world  │
    └───────────┬────────────┘     └──────────┬──────────┘
                │                              │
                │                              │
    ┌───────────▼────────────┐     ┌──────────▼──────────┐
    │ DeCube(direction)      │     │ Reflect V around H  │
    │ 3D → 2D projection     │     │ Compute L direction │
    └───────────┬────────────┘     │ DeCube(L)           │
                │                  │ Select top/bottom   │
                │                  └──────────┬──────────┘
                │                              │
                │                              │
    ┌───────────▼────────────┐     ┌──────────▼──────────┐
    │ SampleLevel(tex, UV, 8)│     │ Compute mip from PDF│
    │ High mip (blurred)     │     │ SampleLevel adaptive│
    └───────────┬────────────┘     └──────────┬──────────┘
                │                              │
                │                              │
    ┌───────────▼────────────┐     ┌──────────▼──────────┐
    │ Multiply by:           │     │ Multiply by:        │
    │ kD * albedo / PI       │     │ F * G * VoH /       │
    │ Average 32 samples     │     │    (NoH * NoV)      │
    └───────────┬────────────┘     │ Average 64 samples  │
                │                  └──────────┬──────────┘
                │                              │
                └───────────────┬──────────────┘
                                │
                                ▼
                ┌───────────────────────────────┐
                │ OUTPUT: Combined IBL lighting │
                │ float4(diffuse + specular, 1) │
                └───────────────────────────────┘
```

## Key Architectural Observations

### 1. Quasi-Random Sampling is Critical

Using the Hammersley sequence instead of random numbers reduces the sample count by an order of magnitude. 32 Hammersley samples provide quality comparable to 300+ random samples. For real-time rendering, this is the difference between practical and unusable.

### 2. Importance Sampling Reduces Variance

By sampling directions weighted by the BRDF, we concentrate samples where they matter most. For diffuse, that's around the normal. For specular, that's around the reflection vector, with spread controlled by roughness. This is why 64 samples can produce smooth specular reflections — we're not wasting samples on directions that contribute little.

### 3. Fake Cubemaps Trade Quality for Size

The DeCube projection has visible seams and overlaps. But for blurred environment lighting, these artifacts average out. The three-texture approach (sides, top, bottom) mitigates the worst cases. For a 64k demo, saving 90% of the texture memory is worth the minor quality loss.

### 4. Adaptive Mip Selection is Sophisticated

The mip level calculation based on PDF solid angle is mathematically rigorous. It approximates the ideal of pre-filtering the environment map for each roughness level, but computes it on-the-fly per-sample. This is computationally expensive (the shader has to evaluate GGX, compute the PDF, take a logarithm), but eliminates the need to store multiple pre-filtered mip chains.

### 5. BRDF Structure is Modular

The Fresnel, geometry, and distribution functions are separate, callable functions. This makes the code easier to understand and allows mixing different BRDF components (e.g., switching from GGX to Beckmann would only require changing `D_ggx()`).

### 6. Energy Conservation Pervades the Design

Every multiplication by kD, every division by PI, every inclusion of Fresnel — these aren't arbitrary. They ensure that the total outgoing light never exceeds incoming light. Metals have no diffuse. Specular and diffuse share the available energy according to Fresnel. This physical correctness is what makes PBR "physically based."

## Implications for Rust Framework

### Adopt: Hammersley Sampling

The radical inverse function translates directly to WGSL. Implement it as a utility function in your shader library. For IBL, ambient occlusion, area lights, and any Monte Carlo integration, Hammersley will provide better results than pseudo-random with the same sample count.

### Adopt: Importance Sampling Patterns

The cosine-weighted hemisphere for diffuse and GGX-weighted for specular are standard techniques. Document the math clearly — future developers will thank you when they need to debug convergence issues.

### Consider: Adaptive vs. Pre-filtered

For an engine targeting desktop and web, you have more memory budget than a 64k demo. Pre-filtered environment maps (storing convolved mip levels) are faster and simpler. But the adaptive approach shown here is valuable for dynamic environments or procedural skies where pre-filtering isn't possible.

### Avoid: Three Separate Textures

The sides/top/bottom split is a workaround for the fake cubemap projection artifacts. If you're using real cubemaps (or a proper equirectangular-to-cubemap conversion), you don't need this. Modern GPUs handle cubemap sampling natively with no seam artifacts.

### Modify: Sample Counts

64 specular samples is a lot for every pixel, every frame. Consider:
- **Temporal accumulation**: Compute 8 samples per frame, accumulate over 8 frames
- **Spatial reuse**: Compute at half-resolution, upscale with bilateral filtering
- **Importance maps**: Only run expensive sampling on pixels that need it (detected via roughness, Fresnel)

### Document: Energy Conservation Math

The kD calculation, the Fresnel application, the PDF normalization — these are subtle and easy to get wrong. Include comments explaining the physical meaning and the math. Link to reference papers (Epic's PBR course notes, Heitz's GGX paper, etc.).

## Related Documents

For comprehensive coverage of the PBR and lighting systems, see:

- **[../rendering/overview.md](../rendering/overview.md)** — PBR system architecture and mental model
- **[../rendering/lighting.md](../rendering/lighting.md)** — Light types, shadows, IBL overview
- **[../rendering/shaders.md](../rendering/shaders.md)** — HLSL patterns, BRDF functions
- **[pbr-pipeline.md](pbr-pipeline.md)** — G-Buffer generation and deferred lighting
- **[ltc-area-lighting.md](ltc-area-lighting.md)** — LTC area light implementation (alternative to Monte Carlo)

For importance sampling theory and implementation:

- **Pharr, Jakob, Humphreys**: *Physically Based Rendering: From Theory to Implementation*, Chapter 13 (Monte Carlo Integration)
- **Heitz 2018**: "Sampling the GGX Distribution of Visible Normals" (improved GGX sampling)
- **Karis 2013**: "Real Shading in Unreal Engine 4" (split-sum approximation, BRDF LUT)

## Source References

| File | Purpose | Key Lines |
|------|---------|-----------|
| `deferred-fake-cubemap.hlsl` | Complete IBL shader | 1-230 |
| ├─ `radicalInverse_VdC()` | Van der Corput sequence | 94-101 |
| ├─ `DeCube()` | 3D to 2D projection | 103-111 |
| ├─ `fresnelSchlick()` | Fresnel approximation | 89-92 |
| ├─ `GeometrySmith()` | Smith GGX geometry | 124-132 |
| ├─ `D_ggx()` | GGX normal distribution | 139-145 |
| ├─ Diffuse pass | Cosine hemisphere sampling | 176-186 |
| └─ Specular pass | GGX importance sampling | 193-226 |

**Extracted shader path**:
```
demoscene/apex-public/Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl
```

**Shader metadata**:
- GUID: `168625FA5DABA54CC9795DAE67349F4E`
- Render technique: Deferred Fake Cubemap
- Target layer: Lighting Layer
- Texture inputs: G-Buffer (t0, t1), Depth (t7), Environment (t2, t3, t4)
