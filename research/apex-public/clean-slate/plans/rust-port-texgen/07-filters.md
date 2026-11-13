# Filter Operators

Filter operators apply convolution or other multi-sample operations to input textures. They typically involve neighborhood sampling.

## Filter Overview

| Operator | Passes | Description |
|----------|--------|-------------|
| **Blur** | 2-6 | Separable Gaussian blur |
| **DirBlur** | 1 | Directional motion blur |
| **Normalmap** | 1 | Height-to-normal (Sobel) |
| **Turbulence** | 1 | UV distortion |
| **Glass** | 1 | Refraction normal |

---

## Blur (Separable Gaussian)

Gaussian blur implemented as separable horizontal + vertical passes for efficiency.

### Algorithm

A 2D Gaussian kernel is separable into 1D kernels:
- Pass 0-2: Horizontal blur (increasing radius)
- Pass 3-5: Vertical blur (increasing radius)

Each pass accumulates samples weighted by Gaussian distribution.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | radius | 0-1 | Blur radius (scaled by texture size) |
| 1 | sigma | 0-1 | Gaussian sigma |

### WGSL Implementation

```wgsl
// blur.wgsl

// 1D Gaussian weight
fn gaussian(x: f32, sigma: f32) -> f32 {
    return exp(-(x * x) / (2.0 * sigma * sigma));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pass = pass_index();

    let radius_norm = param(0);
    let sigma = max(param(1) * 10.0, 0.1);

    // Calculate pixel radius (scale by texture size)
    let pixel_radius = i32(radius_norm * f32(max(dims.x, dims.y)) * 0.1);

    // Direction: X for passes 0-2, Y for passes 3-5
    let horizontal = pass < 3u;
    let dir = select(vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), horizontal);

    // Pixel size in UV space
    let pixel_size = 1.0 / vec2<f32>(dims);

    // Sample and accumulate
    var color = vec4<f32>(0.0);
    var weight_sum = 0.0;

    for (var i = -pixel_radius; i <= pixel_radius; i++) {
        let offset = dir * f32(i) * pixel_size;
        let sample_uv = uv + offset;

        let w = gaussian(f32(i), sigma);
        color += textureSampleLevel(input_texture, linear_sampler, sample_uv, 0.0) * w;
        weight_sum += w;
    }

    let result = color / weight_sum;
    textureStore(output, gid.xy, result);
}
```

### Rust Multi-Pass Handling

```rust
impl TexgenEvaluator {
    fn execute_blur(
        &mut self,
        op: &TexgenOperator,
        encoder: &mut wgpu::CommandEncoder,
        input: TextureHandle,
        mut result: TextureHandle,
        mut backbuffer: TextureHandle,
    ) {
        // 6 passes: 3 horizontal + 3 vertical
        for pass in 0..6 {
            if pass > 0 {
                std::mem::swap(&mut result, &mut backbuffer);
            }

            let source = if pass == 0 { input } else { backbuffer };

            // Update uniforms with pass index
            let uniforms = TexgenUniforms::new(&op.params, pass, op.seed);
            self.queue.write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(&uniforms));

            // Create bind group and dispatch
            // ...
        }
    }
}
```

---

## DirBlur (Directional Blur)

Motion blur along a specified direction.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | angle | 0-360° | Blur direction |
| 1 | length | 0-1 | Blur length |
| 2 | samples | 0-32 | Number of samples |

### WGSL Implementation

```wgsl
// dirblur.wgsl

const TAU: f32 = 6.28318530718;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let angle = param(0) * TAU;
    let length = param(1) * 0.2;  // Max 20% of texture size
    let samples = max(u32(param(2) * 32.0), 1u);

    // Direction vector
    let dir = vec2<f32>(cos(angle), sin(angle)) * length;

    // Sample along direction
    var color = vec4<f32>(0.0);
    for (var i = 0u; i < samples; i++) {
        let t = f32(i) / f32(samples - 1u) - 0.5;  // -0.5 to 0.5
        let sample_uv = uv + dir * t;
        color += textureSampleLevel(input_texture, linear_sampler, sample_uv, 0.0);
    }

    let result = color / f32(samples);
    textureStore(output, gid.xy, result);
}
```

---

## Normalmap (Sobel Height-to-Normal)

Converts a heightmap to tangent-space normal map using Sobel operator.

### Algorithm

The Sobel operator computes gradient by convolving with 3×3 kernels:

```
Sobel X:     Sobel Y:
-1  0  1    -1 -2 -1
-2  0  2     0  0  0
-1  0  1     1  2  1
```

Gradient vector → normal: `normalize(vec3(-gx, -gy, 1/strength))`

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | strength | 0-10 | Normal intensity (0 = flat) |
| 1 | mode | 0/1 | 0 = Sobel, 1 = simple diff |

### WGSL Implementation

```wgsl
// normalmap.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pixel = 1.0 / vec2<f32>(dims);

    let strength = max(param(0) * 10.0, 0.001);
    let use_sobel = param(1) < 0.5;

    // Sample 3×3 neighborhood (height = grayscale luminance)
    let tl = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>(-1.0, -1.0), 0.0).r;
    let tc = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>( 0.0, -1.0), 0.0).r;
    let tr = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>( 1.0, -1.0), 0.0).r;
    let ml = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>(-1.0,  0.0), 0.0).r;
    let mr = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>( 1.0,  0.0), 0.0).r;
    let bl = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>(-1.0,  1.0), 0.0).r;
    let bc = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>( 0.0,  1.0), 0.0).r;
    let br = textureSampleLevel(input_texture, linear_sampler, uv + pixel * vec2<f32>( 1.0,  1.0), 0.0).r;

    var gx: f32;
    var gy: f32;

    if (use_sobel) {
        // Sobel kernels
        gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
        gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    } else {
        // Simple central difference
        let center = textureSampleLevel(input_texture, linear_sampler, uv, 0.0).r;
        gx = mr - ml;
        gy = bc - tc;
    }

    // Scale gradient by strength
    gx *= strength;
    gy *= strength;

    // Construct normal (tangent space: XY = gradient, Z = up)
    let normal = normalize(vec3<f32>(-gx, -gy, 1.0));

    // Encode normal from [-1,1] to [0,1]
    let encoded = normal * 0.5 + 0.5;

    textureStore(output, gid.xy, vec4<f32>(encoded, 1.0));
}
```

---

## Turbulence

Distorts UV coordinates using the input texture as a displacement map, then samples a second iteration.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | distortion | 0-1 | Displacement strength |
| 1 | iterations | 1-4 | Displacement iterations |

### WGSL Implementation

```wgsl
// turbulence.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    var uv = gid_to_uv(gid, dims);

    let distortion = param(0) * 0.5;
    let iterations = max(u32(param(1) * 4.0), 1u);

    // Apply iterative displacement
    for (var i = 0u; i < iterations; i++) {
        let sample = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

        // Use RG channels as displacement (centered at 0.5)
        let offset = (sample.rg - 0.5) * distortion;
        uv = uv + offset;
    }

    // Final sample at distorted UV
    let result = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);
    textureStore(output, gid.xy, result);
}
```

---

## Glass (Refraction Normal)

Generates a normal map suitable for glass/water refraction effects.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | bevel | 0-1 | Edge bevel amount |
| 1 | depth | 0-1 | Refraction depth |

### WGSL Implementation

```wgsl
// glass.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pixel = 1.0 / vec2<f32>(dims);

    let bevel = param(0) * 0.1;
    let depth = param(1);

    // Sample alpha for edge detection
    let center = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);
    let left = textureSampleLevel(input_texture, linear_sampler, uv - vec2<f32>(pixel.x, 0.0), 0.0);
    let right = textureSampleLevel(input_texture, linear_sampler, uv + vec2<f32>(pixel.x, 0.0), 0.0);
    let up = textureSampleLevel(input_texture, linear_sampler, uv - vec2<f32>(0.0, pixel.y), 0.0);
    let down = textureSampleLevel(input_texture, linear_sampler, uv + vec2<f32>(0.0, pixel.y), 0.0);

    // Edge gradient
    let gx = (right.a - left.a) * bevel;
    let gy = (down.a - up.a) * bevel;

    // Normal from edge gradient + depth
    var normal = normalize(vec3<f32>(-gx, -gy, depth));

    // Only apply where there's alpha (edge detection)
    let edge_factor = saturate(abs(gx) + abs(gy));
    normal = mix(vec3<f32>(0.0, 0.0, 1.0), normal, edge_factor);

    // Encode to [0,1]
    let encoded = normal * 0.5 + 0.5;

    textureStore(output, gid.xy, vec4<f32>(encoded, center.a));
}
```

---

## Performance Considerations

### Blur Optimization

Separable blur is O(n) per axis instead of O(n²) for full kernel:
- 11×11 kernel: 121 samples → 22 samples (5.5× faster)
- 21×21 kernel: 441 samples → 42 samples (10× faster)

For large radii, consider:
1. **Downscale** → blur at lower resolution → upscale
2. **Multiple passes** with smaller kernels (Gaussian pyramid)
3. **Compute shader shared memory** for neighborhood caching

### Normalmap

Single-pass with 9 texture samples. Consider mipmap sampling for larger-scale normals.

### Cache-Friendly Access

Organize workgroups to maximize texture cache hits:
```wgsl
@compute @workgroup_size(8, 8)  // 64 threads in 8×8 tile
```

Threads within a workgroup access adjacent pixels, hitting cache lines efficiently.

---

## Integration with PBR Pipeline

Filter outputs integrate with materials:

| TexGen Output | PBR Usage |
|---------------|-----------|
| Blur(noise) | Soft clouds, ambient occlusion |
| Normalmap(cells) | Surface detail normals |
| Turbulence(gradient) | Distorted patterns |
| Glass(shape) | Glass/water refraction |

Example: Brushed metal workflow
```
Noise → Loop (stretch X) → Rotozoom → Combine →
    ├─→ Normalmap → Material Slot 1 (normal+roughness)
    └─→ Scale → Material Slot 0 (albedo+metalness)
```

---

## Related Documents

- [04-generators.md](04-generators.md) - Input sources
- [05-transforms.md](05-transforms.md) - UV transforms
- [06-color-blend.md](06-color-blend.md) - Color operations
