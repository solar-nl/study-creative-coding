# Image-Based Lighting: Monte Carlo Implementation Guide

You're building a deferred renderer that needs ambient reflections from an environment (sky, surrounding geometry) without placing explicit light sources everywhere. IBL solves this by sampling an environment texture in many directions and evaluating the physically-based BRDF for each sample.

This document describes a Monte Carlo approach that requires zero pre-computation and works with any dynamically changing environment source. The trade-off: higher per-frame cost compared to pre-filtered techniques, but complete flexibility in environment content and update frequency.

The key insight: instead of sampling the environment uniformly (which would require thousands of samples to converge), you sample more heavily in directions where the BRDF is strongest. For diffuse surfaces, that means more samples near the normal. For specular surfaces, it means sampling around the reflection vector with spread controlled by roughness. This importance sampling reduces the sample count from thousands to ~100 while maintaining visual smoothness.

## Why IBL Exists

Consider a metallic sphere in an empty room. Area lights provide direct illumination where light rays hit the surface. But what about the parts of the sphere facing away from the lights? In the real world, those surfaces still receive light bounced from the walls, ceiling, and floor. IBL approximates this indirect illumination by treating the entire environment as a light source.

For metals, IBL provides colored reflections of the surroundings. For dielectrics (non-metals), it provides subtle ambient fill that prevents surfaces from going completely black in shadowed regions. The technique handles both contributions through the same sampling infrastructure, just with different BRDF weights.

## Pipeline Integration

IBL runs as a full-screen pass in the Lighting Layer of your deferred renderer. It reads the G-Buffer and accumulates lighting contributions using additive blending.

**Render pass configuration:**
- Color attachment: Main render target with `load_op: Load` (preserve existing lighting)
- Blend: `src_factor: One, dst_factor: One, op: Add` (additive accumulation)
- Depth attachment: Read-only (for position reconstruction), no depth write
- Bind groups: Camera uniforms, G-Buffer textures (albedo+metalness, normal+roughness), depth buffer, environment texture(s)

**G-Buffer layout (assumed):**
- RT0 (SV_TARGET1): `Albedo.RGB + Metalness.A`
- RT1 (SV_TARGET2): `Normal.RGB + Roughness.A`
- Depth buffer: Standard depth attachment

The shader reconstructs world-space position from depth and UV coordinates using inverse view and projection matrices. This saves bandwidth compared to storing position in the G-Buffer.

## Two-Phase Sampling Strategy

IBL splits lighting into two phases: diffuse irradiance and specular reflections. Each uses a different sampling pattern optimized for its BRDF.

### Phase 1: Diffuse Irradiance (32 samples)

Diffuse lighting is omnidirectional and smooth. We sample the environment across the hemisphere above the surface, weighted by the cosine of the angle from the normal. This matches the Lambert BRDF, which falls off as `cos(theta)`.

**Algorithm:**
1. Build a tangent-space basis aligned with the surface normal
2. Generate 32 sample directions using Hammersley low-discrepancy sequence
3. Transform samples from tangent space to world space
4. Sample environment at high mip level (blurred, e.g. mip 8)
5. Weight by `kD = (1 - Fresnel) × (1 - metallic)` for energy conservation
6. Accumulate: `diffuse += envSample * kD * albedo / PI / numSamples`

Why mip 8? Diffuse irradiance represents the average lighting from all directions, so sharp texture detail doesn't matter. Sampling a blurred mip level reduces aliasing and improves cache coherence.

**Tangent frame construction:**
```wgsl
// Avoid degeneracy when N points straight up
let up_vec = select(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 0.0, 1.0), abs(N.z) < 0.999);
let tangent_x = normalize(cross(N, up_vec));
let tangent_y = normalize(cross(tangent_x, N));
let tangent_frame = mat3x3f(tangent_x, tangent_y, N);
```

This creates an orthonormal basis where N is the Z-axis, allowing us to generate samples in "hemisphere space" and transform them to world space.

**Cosine-weighted hemisphere sampling:**
```wgsl
for (var i = 0u; i < 32u; i++) {
    let uv = radical_inverse_vdc(i);
    let phi = uv * TWO_PI;
    let cos_theta = 1.0 - f32(i) / 32.0;
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);

    // Sample direction in tangent space
    let sample_dir = vec3f(
        cos(phi) * sin_theta,
        sin(phi) * sin_theta,
        cos_theta
    );

    // Transform to world space
    let world_dir = tangent_frame * sample_dir;

    // Sample environment at high mip (blurred)
    let env_sample = textureSampleLevel(env_texture, env_sampler,
                                       de_cube(world_dir), 8.0).rgb;

    diffuse_light += env_sample * kD * albedo / PI / 32.0;
}
```

Why `cos_theta = 1.0 - i/32`? This distributes samples with cosine weighting — more samples near the pole (theta = 0) and fewer near the horizon (theta = 90°). The Lambert BRDF has a `cos(theta)` term, and by sampling with this distribution, we bake that term into the probability density, simplifying the math.

### Phase 2: Specular Reflections (64 samples)

Specular reflections concentrate around the mirror reflection vector, with spread determined by surface roughness. We use GGX importance sampling to generate half-vectors distributed according to the GGX normal distribution function.

**Algorithm:**
1. Use the same tangent frame as diffuse
2. Generate 64 half-vectors using GGX importance sampling
3. Compute reflection directions: `L = 2 × dot(V, H) × H - V`
4. Select mip level based on GGX PDF and sample solid angle
5. Sample environment at computed mip level
6. Evaluate Cook-Torrance BRDF (Fresnel × Geometry × NDF)
7. Accumulate: `specular += envSample * fresnel * G * VoH / (NoH * NoV) / numSamples`

**GGX importance sampling:**
```wgsl
for (var i = 0u; i < 64u; i++) {
    let xi = radical_inverse_vdc(i);

    // GGX importance sampling angles
    let phi = PI * f32(i) / 32.0;
    let roughness4 = roughness * roughness * roughness * roughness;
    let cos_theta = sqrt((1.0 - xi) / (1.0 + (roughness4 - 1.0) * xi));
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);

    // Half-vector in tangent space
    let H_tangent = vec3f(
        sin_theta * cos(phi),
        sin_theta * sin(phi),
        cos_theta
    );

    // Transform to world space
    let H = tangent_frame * H_tangent;

    // Reflection direction
    let L = 2.0 * dot(V, H) * H - V;

    let NoL = max(dot(N, L), 0.0);
    let NoH = max(dot(N, H), 0.0);
    let VoH = max(dot(V, H), 0.0);

    // Compute mip level from PDF
    let pdf = d_ggx(roughness, NoH) * NoH / (4.0 * VoH);
    let omega_s = 1.0 / (64.0 * pdf);
    let omega_p = 4.0 * PI / (6.0 * env_width * env_height);
    var mip_level = max(0.5 * log2(omega_s / omega_p), 0.0);

    if (roughness == 0.0) {
        mip_level = 0.0;  // Perfect mirror
    }

    // Sample environment
    let env_sample = textureSampleLevel(env_texture, env_sampler,
                                       de_cube(L), mip_level).rgb;

    // Evaluate BRDF
    let G = geometry_smith(N, V, L, roughness);
    let F = fresnel_schlick(VoH, F0);

    if (NoL > 0.0) {
        specular_light += env_sample * F * G * VoH / (NoH * NoV) / 64.0;
    }
}
```

The formula `cos_theta = sqrt((1 - xi) / (1 + (roughness^4 - 1) * xi))` inverts the GGX cumulative distribution function. Given a uniform random variable `xi` in [0,1], it produces angles distributed according to GGX. When roughness = 0, this simplifies to `cos_theta = 1`, meaning all samples point directly along the normal (perfect mirror).

**Adaptive mip level selection:**

The mip calculation balances the solid angle of the sample against the solid angle of a texel:
- `omega_s = 1 / (numSamples × PDF)` — solid angle covered by this sample
- `omega_p = 4π / (6 × width × height)` — solid angle of one texel in a cubemap
- `mip = 0.5 × log2(omega_s / omega_p)` — mip level where sample and texel sizes match

High PDF (concentrated samples on smooth surfaces) produces low mip (sharp reflections). Low PDF (spread samples on rough surfaces) produces high mip (blurred reflections). This approximates pre-filtered environment maps without requiring pre-computation.

## BRDF Utility Functions

These functions implement the Cook-Torrance microfacet BRDF used in PBR rendering.

### Van der Corput Radical Inverse

The foundation of the Hammersley sequence. Reverses the binary representation of an integer to create a low-discrepancy sequence.

```wgsl
fn radical_inverse_vdc(bits_in: u32) -> f32 {
    var bits = bits_in;
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return f32(bits) * 2.3283064365386963e-10;  // / 0x100000000
}
```

Why bit reversal? It distributes samples evenly across [0,1] with minimal clumping. The first sample, the first two samples, the first four samples, etc., are all well-distributed. This is the "low-discrepancy" property that makes Hammersley superior to random sampling.

### Fresnel-Schlick Approximation

Describes how much light reflects versus refracts at a surface, varying with viewing angle.

```wgsl
fn fresnel_schlick(cos_theta: f32, F0: vec3f) -> vec3f {
    return F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);
}
```

At glancing angles (cos_theta → 0), all materials become highly reflective (Fresnel → 1). At normal incidence (cos_theta = 1), materials reflect according to their F0 value. Dielectrics have F0 ≈ 0.04. Metals use their albedo color as F0.

### GGX Normal Distribution Function

Defines how microfacet normals are distributed around the macro normal. GGX has a characteristic "long tail" that produces bright edges on rough metals.

```wgsl
fn d_ggx(roughness: f32, NoH: f32) -> f32 {
    let alpha = roughness;
    let a2 = alpha * alpha;
    let cos2 = NoH * NoH;
    let denominator = cos2 * (a2 - 1.0) + 1.0;
    return (1.0 / PI) * (alpha / denominator) * (alpha / denominator);
}
```

The denominator reaches its minimum when NoH = 1 (half-vector aligned with normal), producing the peak of the distribution. As NoH decreases, the probability density falls off according to the roughness parameter.

### Smith-GGX Geometry Term

Models microfacet self-shadowing and masking. Rough surfaces have tall microfacets that can block light or occlude the view.

```wgsl
fn geometry_schlick_ggx(NdotV: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

fn geometry_smith(N: vec3f, V: vec3f, L: vec3f, roughness: f32) -> f32 {
    let NdotV = max(dot(N, V), 0.0);
    let NdotL = max(dot(N, L), 0.0);
    let ggx_v = geometry_schlick_ggx(NdotV, roughness);
    let ggx_l = geometry_schlick_ggx(NdotL, roughness);
    return ggx_v * ggx_l;
}
```

The Smith model assumes shadowing and masking are statistically independent, so the combined term is the product of individual terms for the view and light directions.

## Environment Source Options

The environment can come from various sources, trading quality for memory and flexibility.

### Option 1: Single 2D Texture (Fake Cubemap)

The cheapest option. Use a `DeCube()` function to project 3D directions onto a 2D texture by selecting the dominant axis.

```wgsl
fn de_cube(direction: vec3f) -> vec2f {
    let abs_dir = abs(direction);
    let max_axis = max(max(abs_dir.x, abs_dir.y), abs_dir.z);

    var uv = direction.zy;
    if (max_axis == abs_dir.y) { uv = direction.xz; }
    if (max_axis == abs_dir.z) { uv = direction.xy; }

    return 0.5 * (uv / max_axis + 1.0);
}
```

This maps any 3D direction to [0,1]² by projecting onto the cube face where the direction has its largest component. It has seam artifacts at face boundaries, but these average out during the multi-sample integration.

**Rust setup:**
```rust
// Create environment texture with mipmaps
let env_texture = device.create_texture(&wgpu::TextureDescriptor {
    size: wgpu::Extent3d {
        width: 256,
        height: 256,
        depth_or_array_layers: 1,
    },
    mip_level_count: 9,  // log2(256) + 1
    format: wgpu::TextureFormat::Rgba8Unorm,
    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
    ..Default::default()
});
```

### Option 2: Three 2D Textures (Sides, Top, Bottom)

Reduces artifacts from the fake cubemap projection by using separate textures for the vertical axis.

```wgsl
fn sample_environment(direction: vec3f, mip_level: f32) -> vec3f {
    let abs_dir = abs(direction);
    let max_axis = max(max(abs_dir.x, abs_dir.y), abs_dir.z);

    if (max_axis == abs_dir.y) {
        if (direction.y > 0.0) {
            return textureSampleLevel(env_top, env_sampler,
                                     de_cube(direction), mip_level).rgb;
        } else {
            return textureSampleLevel(env_bottom, env_sampler,
                                     de_cube(direction), mip_level).rgb;
        }
    } else {
        return textureSampleLevel(env_sides, env_sampler,
                                 de_cube(direction), mip_level).rgb;
    }
}
```

This allows different sky versus ground lighting and eliminates the worst seam artifacts at the horizon.

**Rust enum:**
```rust
pub enum EnvironmentSource {
    /// Single 2D texture unwrapped via DeCube
    Texture(wgpu::TextureView),

    /// Three textures: sides, top, bottom
    SplitTexture {
        sides: wgpu::TextureView,
        top: wgpu::TextureView,
        bottom: wgpu::TextureView,
    },

    /// Procedural gradient (generates a texture internally)
    Gradient {
        sky: [f32; 3],
        ground: [f32; 3],
    },
}
```

### Option 3: Procedural Gradient

For simple environments, generate a small texture on the CPU that interpolates between sky and ground colors based on the Y component of the direction.

```rust
fn generate_gradient_environment(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    sky_color: [f32; 3],
    ground_color: [f32; 3],
) -> wgpu::Texture {
    let size = 64;
    let mut data = Vec::with_capacity(size * size * 4);

    for y in 0..size {
        for x in 0..size {
            // Map to direction (rough approximation)
            let dy = (y as f32 / size as f32) * 2.0 - 1.0;
            let t = (dy + 1.0) * 0.5;  // 0 = bottom, 1 = top

            let color = [
                (ground_color[0] * (1.0 - t) + sky_color[0] * t * 255.0) as u8,
                (ground_color[1] * (1.0 - t) + sky_color[1] * t * 255.0) as u8,
                (ground_color[2] * (1.0 - t) + sky_color[2] * t * 255.0) as u8,
                255u8,
            ];
            data.extend_from_slice(&color);
        }
    }

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        size: wgpu::Extent3d {
            width: size as u32,
            height: size as u32,
            depth_or_array_layers: 1,
        },
        mip_level_count: 7,  // log2(64) + 1
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        ..Default::default()
    });

    queue.write_texture(
        texture.as_image_copy(),
        &data,
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(size * 4),
            rows_per_image: None,
        },
        wgpu::Extent3d {
            width: size as u32,
            height: size as u32,
            depth_or_array_layers: 1,
        },
    );

    texture
}
```

The mipmap chain handles the blurring needed for diffuse irradiance and rough specular.

## Energy Conservation and Material Properties

IBL must respect energy conservation: the total outgoing light cannot exceed incoming light. The key is properly splitting energy between diffuse and specular based on Fresnel and metalness.

**F0 calculation (base reflectivity):**
```wgsl
let F0 = mix(vec3f(0.04), albedo.rgb, metallic);
```

Non-metals (metallic = 0) have F0 = 0.04, a typical value for dielectrics. Metals (metallic = 1) use their albedo color as F0 because metals have colored reflectance.

**Fresnel for energy splitting:**
```wgsl
// Approximate average Fresnel over the hemisphere
let H = normalize(V + N);
let F = fresnel_schlick(max(dot(H, V), 0.0), F0);
```

Using `H = normalize(V + N)` approximates the half-vector for the hemisphere. This isn't the exact half-vector for each sample (which is computed per-sample in the specular phase), but provides a reasonable average Fresnel factor for splitting energy.

**kD derivation (diffuse weight):**
```wgsl
let kD = (1.0 - F) * (1.0 - metallic);
```

Energy that reflects specularly (governed by Fresnel F) can't also contribute to diffuse. So diffuse gets `(1 - F)` of the remaining energy. Additionally, metals have no diffuse component at all, so we multiply by `(1 - metallic)`.

**Material behavior:**
- **Dielectrics** (metallic = 0): Both diffuse and specular. At grazing angles, F → 1, so kD → 0 (surface becomes all specular)
- **Metals** (metallic = 1): The `(1 - metallic)` factor zeros out kD. No diffuse component, only specular reflections

## Complete WGSL Shader Example

Putting it all together:

```wgsl
// Bind group 0: Camera uniforms
struct CameraUniforms {
    view_matrix: mat4x4f,
    projection_matrix: mat4x4f,
    inverse_view_matrix: mat4x4f,
    inverse_projection_matrix: mat4x4f,
    camera_position: vec3f,
}
@group(0) @binding(0) var<uniform> camera: CameraUniforms;

// Bind group 1: G-Buffer textures
@group(1) @binding(0) var albedo_metalness_texture: texture_2d<f32>;
@group(1) @binding(1) var normal_roughness_texture: texture_2d<f32>;
@group(1) @binding(2) var depth_texture: texture_depth_2d;

// Bind group 2: Environment
@group(2) @binding(0) var env_texture: texture_2d<f32>;
@group(2) @binding(1) var env_sampler: sampler;

const PI: f32 = 3.14159265359;
const TWO_PI: f32 = 6.28318530718;

// Position reconstruction from depth
fn get_world_position(depth: f32, uv: vec2f) -> vec3f {
    let ndc = vec4f(uv * 2.0 - 1.0, depth, 1.0);
    let view_pos = camera.inverse_projection_matrix * ndc;
    let world_pos = camera.inverse_view_matrix * vec4f(view_pos.xyz / view_pos.w, 1.0);
    return world_pos.xyz / world_pos.w;
}

// Van der Corput radical inverse for Hammersley sequence
fn radical_inverse_vdc(bits_in: u32) -> f32 {
    var bits = bits_in;
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return f32(bits) * 2.3283064365386963e-10;
}

// Fake cubemap projection
fn de_cube(direction: vec3f) -> vec2f {
    let abs_dir = abs(direction);
    let max_axis = max(max(abs_dir.x, abs_dir.y), abs_dir.z);

    var uv = direction.zy;
    if (max_axis == abs_dir.y) { uv = direction.xz; }
    if (max_axis == abs_dir.z) { uv = direction.xy; }

    return 0.5 * (uv / max_axis + 1.0);
}

// Fresnel-Schlick approximation
fn fresnel_schlick(cos_theta: f32, F0: vec3f) -> vec3f {
    return F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);
}

// GGX normal distribution
fn d_ggx(roughness: f32, NoH: f32) -> f32 {
    let alpha = roughness;
    let a2 = alpha * alpha;
    let cos2 = NoH * NoH;
    let denom = cos2 * (a2 - 1.0) + 1.0;
    return (1.0 / PI) * (alpha / denom) * (alpha / denom);
}

// Schlick-GGX geometry term (single direction)
fn geometry_schlick_ggx(NdotV: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Smith geometry term (combined view + light)
fn geometry_smith(N: vec3f, V: vec3f, L: vec3f, roughness: f32) -> f32 {
    let NdotV = max(dot(N, V), 0.0);
    let NdotL = max(dot(N, L), 0.0);
    let ggx_v = geometry_schlick_ggx(NdotV, roughness);
    let ggx_l = geometry_schlick_ggx(NdotL, roughness);
    return ggx_v * ggx_l;
}

@fragment
fn fs_main(@builtin(position) frag_coord: vec4f) -> @location(0) vec4f {
    let pixel_coord = vec2i(frag_coord.xy);

    // Load G-Buffer
    let albedo_metalness = textureLoad(albedo_metalness_texture, pixel_coord, 0);
    let normal_roughness = textureLoad(normal_roughness_texture, pixel_coord, 0);
    let depth = textureLoad(depth_texture, pixel_coord, 0);

    let albedo = albedo_metalness.rgb;
    let metallic = albedo_metalness.a;
    let N = normalize(normal_roughness.xyz);
    let roughness = normal_roughness.a;

    // Reconstruct view vector
    let uv = frag_coord.xy / vec2f(textureDimensions(albedo_metalness_texture));
    let world_pos = get_world_position(depth, uv);
    let V = normalize(camera.camera_position - world_pos);

    // Fresnel at normal incidence
    let F0 = mix(vec3f(0.04), albedo, metallic);

    // Average Fresnel for energy splitting
    let H_avg = normalize(V + N);
    let F_avg = fresnel_schlick(max(dot(H_avg, V), 0.0), F0);

    // Energy for diffuse
    let kD = (1.0 - F_avg) * (1.0 - metallic);

    // Build tangent frame
    let up_vec = select(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 0.0, 1.0), abs(N.z) < 0.999);
    let tangent_x = normalize(cross(N, up_vec));
    let tangent_y = normalize(cross(tangent_x, N));
    let tangent_frame = mat3x3f(tangent_x, tangent_y, N);

    var light = vec3f(0.0);

    // ========================================================================
    // Phase 1: Diffuse Irradiance (32 samples)
    // ========================================================================
    for (var i = 0u; i < 32u; i++) {
        let uv_sample = radical_inverse_vdc(i);
        let phi = uv_sample * TWO_PI;
        let cos_theta = 1.0 - f32(i) / 32.0;
        let sin_theta = sqrt(1.0 - cos_theta * cos_theta);

        // Sample direction in tangent space
        let sample_dir = vec3f(
            cos(phi) * sin_theta,
            sin(phi) * sin_theta,
            cos_theta
        );

        // Transform to world space
        let world_dir = tangent_frame * sample_dir;

        // Sample environment at high mip (blurred for diffuse)
        let env_sample = textureSampleLevel(env_texture, env_sampler,
                                           de_cube(world_dir), 8.0).rgb;

        light += env_sample * kD * albedo / PI / 32.0;
    }

    // ========================================================================
    // Phase 2: Specular Reflections (64 samples)
    // ========================================================================
    let env_dims = textureDimensions(env_texture);
    let env_width = f32(env_dims.x);
    let env_height = f32(env_dims.y);

    let NoV = clamp(dot(N, V), 0.0, 1.0) + 0.0001;

    for (var i = 0u; i < 64u; i++) {
        let xi = radical_inverse_vdc(i);

        // GGX importance sampling angles
        let phi = PI * f32(i) / 32.0;
        let roughness4 = roughness * roughness * roughness * roughness;
        let cos_theta = sqrt((1.0 - xi) / (1.0 + (roughness4 - 1.0) * xi));
        let sin_theta = sqrt(1.0 - cos_theta * cos_theta);

        // Half-vector in tangent space
        let H_tangent = vec3f(
            sin_theta * cos(phi),
            sin_theta * sin(phi),
            cos_theta
        );

        // Transform to world space
        let H = tangent_frame * H_tangent;

        // Reflection direction
        let L = 2.0 * dot(V, H) * H - V;

        let NoL = clamp(dot(N, L), 0.0, 1.0);
        let NoH = clamp(dot(N, H), 0.0, 1.0);
        let VoH = clamp(dot(V, H), 0.0, 1.0);

        // Compute mip level from PDF
        let pdf = d_ggx(roughness, NoH) * NoH / (4.0 * VoH);
        let omega_s = 1.0 / (64.0 * pdf);
        let omega_p = 4.0 * PI / (6.0 * env_width * env_height);
        var mip_level = max(0.5 * log2(omega_s / omega_p), 0.0);

        if (roughness == 0.0) {
            mip_level = 0.0;
        }

        // Sample environment
        let env_sample = textureSampleLevel(env_texture, env_sampler,
                                           de_cube(L), mip_level).rgb;

        // Evaluate BRDF
        let G = geometry_smith(N, V, L, roughness);
        let F = fresnel_schlick(VoH, F0);

        if (NoL > 0.0) {
            light += env_sample * F * G * VoH / (NoH * NoV) / 64.0;
        }
    }

    return vec4f(light, 1.0);
}
```

## Rust Pipeline Setup

```rust
use wgpu::*;

pub struct IblPass {
    pipeline: RenderPipeline,
    bind_group_layout: BindGroupLayout,
}

impl IblPass {
    pub fn new(device: &Device, output_format: TextureFormat) -> Self {
        let bind_group_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("IBL Environment Layout"),
            entries: &[
                // Environment texture
                BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                // Environment sampler
                BindGroupLayoutEntry {
                    binding: 1,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Sampler(SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("IBL Shader"),
            source: ShaderSource::Wgsl(include_str!("ibl.wgsl").into()),
        });

        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("IBL Pipeline Layout"),
            bind_group_layouts: &[
                &camera_bind_group_layout,    // @group(0)
                &gbuffer_bind_group_layout,   // @group(1)
                &bind_group_layout,           // @group(2)
            ],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("IBL Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: &shader,
                entry_point: "vs_main",  // Fullscreen triangle vertex shader
                buffers: &[],
            },
            fragment: Some(FragmentState {
                module: &shader,
                entry_point: "fs_main",
                targets: &[Some(ColorTargetState {
                    format: output_format,
                    blend: Some(BlendState {
                        color: BlendComponent {
                            src_factor: BlendFactor::One,
                            dst_factor: BlendFactor::One,
                            operation: BlendOperation::Add,
                        },
                        alpha: BlendComponent {
                            src_factor: BlendFactor::One,
                            dst_factor: BlendFactor::One,
                            operation: BlendOperation::Add,
                        },
                    }),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            primitive: PrimitiveState::default(),
            depth_stencil: Some(DepthStencilState {
                format: TextureFormat::Depth32Float,
                depth_write_enabled: false,  // Read-only depth
                depth_compare: CompareFunction::Always,
                stencil: StencilState::default(),
                bias: DepthBiasState::default(),
            }),
            multisample: MultisampleState::default(),
            multiview: None,
        });

        Self {
            pipeline,
            bind_group_layout,
        }
    }

    pub fn render(
        &self,
        encoder: &mut CommandEncoder,
        output_view: &TextureView,
        depth_view: &TextureView,
        camera_bind_group: &BindGroup,
        gbuffer_bind_group: &BindGroup,
        environment_bind_group: &BindGroup,
    ) {
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("IBL Pass"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: output_view,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Load,  // Preserve existing lighting
                    store: StoreOp::Store,
                },
            })],
            depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
                view: depth_view,
                depth_ops: Some(Operations {
                    load: LoadOp::Load,
                    store: StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            timestamp_writes: None,
            occlusion_query_set: None,
        });

        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, camera_bind_group, &[]);
        pass.set_bind_group(1, gbuffer_bind_group, &[]);
        pass.set_bind_group(2, environment_bind_group, &[]);
        pass.draw(0..3, 0..1);  // Fullscreen triangle
    }
}
```

## Performance Considerations

**Sample count trade-off:** The current implementation uses 96 total samples (32 diffuse + 64 specular) per pixel. At 1080p, that's 199 million shader invocations per frame. On modern GPUs this is acceptable, but consider these optimizations:

**Temporal accumulation:** Compute 8 samples per frame and accumulate over 12 frames. Requires motion vectors to reproject previous frames and detect disocclusion.

**Spatial reuse:** Compute IBL at half resolution (540p) and upscale with bilateral filtering. Use the full-resolution depth and normal buffers to preserve edges.

**Importance thresholding:** Skip IBL entirely for rough dielectrics where the contribution is minimal. Test `roughness > 0.8 && metallic < 0.1` and early-exit.

**Bandwidth:** Each sample performs one environment texture fetch. With mipmaps and linear filtering, cache coherency is good. The Hammersley sequence provides better cache behavior than random sampling because nearby samples in the sequence access nearby texture coordinates.

**Divergence:** All pixels execute the same number of samples, so there's minimal thread divergence. The only branch is the roughness == 0 mip override, which compiles to a select.

## Future Directions

These techniques can replace or augment the Monte Carlo approach when pre-computation is acceptable.

### Pre-filtered Environment Maps

Instead of sampling the environment 96 times per pixel, pre-convolve the environment into a mip chain where each level corresponds to a specific roughness value. Runtime becomes a single texture lookup.

**Build process:**
1. For each mip level M corresponding to roughness R
2. For each texel in that mip
3. Sample the environment in many directions using GGX importance sampling for roughness R
4. Store the averaged result

This moves the 96-sample cost to a one-time pre-process. Works well for static environments or when you can afford to update occasionally.

### Spherical Harmonics (SH9) for Diffuse

Project the environment into 9 spherical harmonic coefficients (27 floats total: 3 bands × RGB). At runtime, diffuse irradiance becomes 9 dot products instead of 32 samples.

**SH projection:**
```rust
fn project_to_sh9(environment: &[Vec3; SAMPLE_COUNT]) -> [Vec3; 9] {
    let mut coeffs = [Vec3::ZERO; 9];
    for (direction, color) in environment {
        let sh_basis = evaluate_sh_basis(direction);
        for i in 0..9 {
            coeffs[i] += color * sh_basis[i];
        }
    }
    coeffs
}
```

The runtime shader just sums: `irradiance = sum(sh_coeffs[i] * sh_basis[i])` for i in 0..9.

### Split-Sum Approximation with BRDF LUT

The industry-standard approach from Unreal Engine 4. Separates the BRDF integral into two parts:
1. Pre-filtered environment map (roughness-dependent convolution)
2. BRDF integration LUT (2D texture indexed by `(NdotV, roughness)`)

Runtime: one environment sample + one LUT sample. The LUT is environment-independent — compute once, embed as `include_bytes!`.

### Real Cubemaps

The `DeCube()` 2D unwrapping has seam artifacts at face boundaries. True cubemap textures (`TextureViewDimension::Cube` in wgpu) eliminate this. Requires 6 faces instead of 1-3 textures, but modern GPUs handle cubemap sampling natively with seamless filtering across faces.

```rust
let cubemap = device.create_texture(&TextureDescriptor {
    size: Extent3d {
        width: 512,
        height: 512,
        depth_or_array_layers: 6,  // 6 faces
    },
    mip_level_count: 10,
    format: TextureFormat::Rgba16Float,
    dimension: TextureDimension::D2,
    usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
    view_formats: &[],
});

let view = cubemap.create_view(&TextureViewDescriptor {
    dimension: Some(TextureViewDimension::Cube),
    ..Default::default()
});
```

In WGSL, use `textureSampleLevel(env_cubemap, sampler, direction, mip)` directly — no `de_cube()` needed.

## Reference Implementation

This guide is based on Phoenix/apEx's Monte Carlo IBL implementation from the Clean Slate demo:

**Source files:**
- `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/annotated/materials/deferred-fake-cubemap.hlsl` (329 lines)
- `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/materials/deferred-fake-cubemap.hlsl` (231 lines, original)

**Study notes:**
- `notes/per-demoscene/apex-public/code-traces/reflections-ibl.md` — Detailed trace of the algorithm
- `notes/per-demoscene/apex-public/rendering/reflections.md` — Context within the full reflection system

**Research foundation:**
- Karis 2013: "Real Shading in Unreal Engine 4" (SIGGRAPH) — GGX importance sampling, split-sum approximation
- Heitz 2018: "Sampling the GGX Distribution of Visible Normals" — Improved GGX sampling (not used here, but relevant)
- Pharr, Jakob, Humphreys: *Physically Based Rendering* — Monte Carlo integration theory

## Summary

IBL adds ambient lighting from the environment through two-phase importance sampling. Diffuse uses 32 cosine-weighted hemisphere samples. Specular uses 64 GGX-weighted samples with adaptive mip selection. Energy conservation ensures the diffuse and specular contributions sum to the available light, respecting metalness and Fresnel.

The Monte Carlo approach requires zero pre-computation and works with any environment source. It trades per-frame cost for complete flexibility. For static environments, consider the future directions (pre-filtered maps, SH9, split-sum) which move the cost to pre-processing.

The implementation integrates into a deferred renderer as a full-screen pass with additive blending, reading G-Buffer properties and accumulating onto existing lighting. Position reconstruction from depth avoids storing world-space positions in the G-Buffer, saving 12 bytes per pixel.
