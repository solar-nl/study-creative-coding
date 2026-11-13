# Pitfalls and Troubleshooting Guide

This document covers common problems, subtle bugs, and platform-specific issues you'll encounter when porting the Phoenix PBR pipeline to Rust + WGPU.

## Table of Contents

1. [Coordinate System Mismatches](#coordinate-system-mismatches)
2. [Matrix Layout Confusion](#matrix-layout-confusion)
3. [Depth Buffer Issues](#depth-buffer-issues)
4. [Texture Format Gotchas](#texture-format-gotchas)
5. [Shader Translation Traps](#shader-translation-traps)
6. [LTC Data Interpretation](#ltc-data-interpretation)
7. [Precision and Numerical Stability](#precision-and-numerical-stability)
8. [Performance Pitfalls](#performance-pitfalls)
9. [Platform-Specific Issues](#platform-specific-issues)
10. [Debugging Strategies](#debugging-strategies)

---

## Coordinate System Mismatches

### Problem: Upside-Down Rendering

**Symptom**: Scene renders upside-down or UV coordinates are flipped.

**Cause**: WGPU uses Vulkan's coordinate system:
- Clip space Y: **down is positive** (opposite of D3D11/OpenGL)
- Texture origin: **top-left** (same as D3D11)
- NDC depth: **[0, 1]** (same as D3D11)

**Solution**:

```rust
// Use glam's right-handed functions which account for this
let projection = glam::Mat4::perspective_rh(fov, aspect, near, far);

// If using a custom projection, flip Y:
projection.y_axis.y *= -1.0;
```

In shaders, when reconstructing world position:
```wgsl
// WRONG - assumes OpenGL convention
let ndc = vec2<f32>(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0);

// CORRECT - flip Y for WGPU
let ndc = vec2<f32>(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
```

### Problem: Shadow Map Coordinates Wrong

**Symptom**: Shadows appear in wrong locations or are mirrored.

**Solution**: When sampling shadow maps:
```wgsl
// Transform NDC to UV, then flip Y
let uv = shadow_ndc.xy * 0.5 + 0.5;
let shadow_uv = vec2<f32>(uv.x, 1.0 - uv.y);  // Flip Y!
```

---

## Matrix Layout Confusion

### Problem: Garbled Transforms

**Symptom**: Objects appear stretched, rotated wrong, or don't move correctly.

**Cause**: HLSL uses **row-major** matrices by default, WGSL uses **column-major**.

**Critical Difference**:
```
HLSL row-major:     WGSL column-major:
| a b c d |         | a e i m |
| e f g h |         | b f j n |
| i j k l |         | c g k o |
| m n o p |         | d h l p |
```

**Solution 1**: Transpose when uploading to GPU:
```rust
// In Rust, before writing to buffer
let matrix_for_gpu = cpu_matrix.transpose();
```

**Solution 2**: Use glam consistently (it's column-major like WGSL):
```rust
// glam is already column-major, no transpose needed
let view = Mat4::look_at_rh(eye, target, up);
queue.write_buffer(&buffer, 0, bytemuck::bytes_of(&view));
```

**Solution 3**: Reverse multiplication order in shaders:
```hlsl
// HLSL (row-major)
float4 result = mul(matrix, vector);
float4 result = mul(mul(proj, view), world);
```
```wgsl
// WGSL (column-major) - reverse order!
let result = matrix * vector;
let result = proj * view * world;
```

### Problem: Normal Matrix Wrong

**Symptom**: Lighting looks wrong after non-uniform scaling.

**Cause**: The normal matrix should be the inverse-transpose of the model matrix.

```rust
// WRONG - just using the model matrix
let normal_matrix = model_matrix;

// CORRECT
let normal_matrix = model_matrix.inverse().transpose();

// Or for uniform scale only (cheaper):
let normal_matrix = Mat3::from_mat4(model_matrix);
```

---

## Depth Buffer Issues

### Problem: Z-Fighting

**Symptom**: Flickering surfaces, especially at distance.

**Cause**: 32-bit float depth buffer has non-linear precision distribution.

**Solutions**:

1. **Reverse-Z projection** (recommended):
```rust
// Reverse-Z: near plane maps to 1.0, far to 0.0
fn perspective_reverse_z(fov: f32, aspect: f32, near: f32) -> Mat4 {
    let f = 1.0 / (fov * 0.5).tan();
    Mat4::from_cols(
        Vec4::new(f / aspect, 0.0, 0.0, 0.0),
        Vec4::new(0.0, f, 0.0, 0.0),
        Vec4::new(0.0, 0.0, 0.0, -1.0),
        Vec4::new(0.0, 0.0, near, 0.0),
    )
}
```

Update depth test:
```rust
depth_compare: wgpu::CompareFunction::Greater,  // Not Less!
```

Clear to 0.0 instead of 1.0:
```rust
load: wgpu::LoadOp::Clear(0.0),
```

2. **Logarithmic depth** (for extreme ranges):
```wgsl
// In vertex shader
let log_depth = log2(max(1e-6, clip_pos.w + 1.0)) * log_depth_scale;
out.position.z = log_depth * clip_pos.w;
```

### Problem: Can't Sample Depth Buffer

**Symptom**: Shader compilation error or black depth reads.

**Cause**: Depth texture needs correct usage flags and view.

```rust
// Texture must have TEXTURE_BINDING usage
usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,

// In WGSL, use texture_depth_2d, not texture_2d<f32>
@group(0) @binding(0) var depth: texture_depth_2d;

// Sampling returns f32, not vec4
let d = textureSample(depth, sampler, uv);  // Returns f32
```

---

## Texture Format Gotchas

### Problem: sRGB Conversion Double-Applied

**Symptom**: Overly bright or washed-out colors.

**Cause**: sRGB conversion happening twice (texture + shader) or not at all.

**Rules**:
- Albedo/diffuse textures: Use `Rgba8UnormSrgb` (hardware sRGB decode)
- Normal maps: Use `Rgba8Unorm` (linear data, no conversion)
- HDR data: Use `Rgba16Float` or `Rgba32Float`
- G-Buffer: Store linear values, apply gamma only at final output

```rust
// Albedo texture - sRGB encoded source
format: wgpu::TextureFormat::Rgba8UnormSrgb,

// Normal map - linear data
format: wgpu::TextureFormat::Rgba8Unorm,

// G-Buffer RT0 (albedo storage) - store linear
format: wgpu::TextureFormat::Rgba8Unorm,  // NOT Srgb!
```

### Problem: Texture Format Not Supported

**Symptom**: `Unsupported texture format` error on some platforms.

**Cause**: Not all formats are available on all backends.

**Safe formats** (universal support):
- `Rgba8Unorm`, `Rgba8UnormSrgb`
- `Bgra8Unorm`, `Bgra8UnormSrgb`
- `Rgba16Float`
- `Depth32Float`
- `Depth24PlusStencil8`

**Problematic formats**:
- `Rgba16Unorm` - Not on WebGPU
- `Rgb10a2Unorm` - Limited support
- `Depth32FloatStencil8` - Check `Features::DEPTH32FLOAT_STENCIL8`

```rust
// Check format support at runtime
if adapter.get_texture_format_features(format).allowed_usages.contains(usage) {
    // Safe to use
}
```

### Problem: BC/DXT Compression Not Available

**Symptom**: Compressed textures fail to load on Mac/mobile.

**Cause**: BC formats require `Features::TEXTURE_COMPRESSION_BC`.

**Solution**: Provide fallbacks or use universal compression:
```rust
let format = if device.features().contains(Features::TEXTURE_COMPRESSION_BC) {
    wgpu::TextureFormat::Bc7RgbaUnorm
} else if device.features().contains(Features::TEXTURE_COMPRESSION_ASTC) {
    wgpu::TextureFormat::Astc4x4RgbaUnorm  // iOS/Android
} else {
    wgpu::TextureFormat::Rgba8Unorm  // Fallback
};
```

---

## Shader Translation Traps

### Problem: `saturate()` Doesn't Exist

**Symptom**: WGSL compilation error.

**Reality**: `saturate()` IS in WGSL. But if you're seeing errors, check for:
```wgsl
// Make sure you're not calling it on integers
let x: f32 = saturate(some_float);     // OK
let y: i32 = saturate(some_int);        // ERROR - no integer version
```

### Problem: Integer Division Truncation

**Symptom**: Artifacts in effects using integer math.

```wgsl
// WRONG - integer division truncates
let half = screen_width / 2;  // If screen_width is u32

// CORRECT - use float division
let half = f32(screen_width) / 2.0;
```

### Problem: `select()` Argument Order

**Symptom**: Conditions work backwards.

```wgsl
// WGSL select() is NOT like HLSL ternary!
// select(false_value, true_value, condition)

// HLSL: condition ? a : b
// WGSL: select(b, a, condition)  // Note: b first!

let result = select(0.0, 1.0, x > 0.5);  // Returns 1.0 if x > 0.5
```

### Problem: No Implicit Type Conversion

**Symptom**: Type mismatch errors everywhere.

```wgsl
// WRONG - WGSL requires explicit casts
let x: f32 = 1;
let y = x + 2;

// CORRECT
let x: f32 = 1.0;
let y = x + 2.0;

// Or with explicit cast
let z = x + f32(some_integer);
```

### Problem: Swizzle Assignment Not Supported

**Symptom**: Can't assign to swizzled components.

```wgsl
// WRONG in WGSL
color.rgb = new_color;

// CORRECT - assign full vector
color = vec4<f32>(new_color, color.a);
```

---

## LTC Data Interpretation

### Problem: LTC Textures Look Wrong

**Symptom**: Area lights have incorrect falloff or Fresnel.

**Cause**: The original LTC data is stored as **half-precision floats** (16-bit), and the byte layout matters.

**Data Format**:
- `ltc_1.h`: 2048 bytes = 16×16 texels × 8 bytes/texel (R16G16B16A16_FLOAT)
- `ltc_2.h`: 512 bytes = 16×16 texels × 2 bytes/texel (R8G8_UNORM)

**Verification**:
```rust
// Matrix texture should be 16x16, 8 bytes per texel
assert_eq!(LTC_MATRIX_DATA.len(), 16 * 16 * 8);  // 2048

// Fresnel texture should be 16x16, 2 bytes per texel
assert_eq!(LTC_FRESNEL_DATA.len(), 16 * 16 * 2);  // 512
```

### Problem: LTC UV Coordinates Wrong

**Symptom**: Roughness/angle response is backwards or clamped.

**Correct UV mapping**:
```wgsl
// UV for LTC lookup
// X = roughness (0 = smooth, 1 = rough)
// Y = sqrt(1 - cos_theta) (linearizes the angular response)
let uv = vec2<f32>(roughness, sqrt(1.0 - max(dot(N, V), 0.0)));
```

**Common mistake** - using `acos` instead of `sqrt(1 - cos)`:
```wgsl
// WRONG - non-linear distribution
let uv_y = acos(n_dot_v) / PI;

// CORRECT - matches how the LTC table was generated
let uv_y = sqrt(1.0 - n_dot_v);
```

---

## Precision and Numerical Stability

### Problem: Black Specular Highlights

**Symptom**: Specular disappears at grazing angles or low roughness.

**Cause**: Division by near-zero in BRDF.

```wgsl
// WRONG - can divide by zero
let D = alpha2 / (PI * denom * denom);

// CORRECT - clamp denominator
let D = alpha2 / (PI * max(denom * denom, 1e-7));

// Also clamp roughness minimum
let roughness = max(material_roughness, 0.04);
```

### Problem: NaN Propagation

**Symptom**: Black pixels that spread or flicker.

**Cause**: `sqrt()` of negative, `acos()` outside [-1,1], `normalize()` of zero vector.

```wgsl
// Add safety clamps
let safe_dot = clamp(dot(a, b), -1.0, 1.0);
let angle = acos(safe_dot);

let safe_len = max(length(v), 1e-6);
let normalized = v / safe_len;

// Or use is_nan check
if is_nan(result) {
    result = 0.0;
}
```

### Problem: Fireflies in HDR

**Symptom**: Bright pixel artifacts, especially with area lights.

**Cause**: Extremely bright samples from specular highlights.

```wgsl
// Clamp maximum contribution
let max_intensity = 100.0;
let clamped_color = min(lit_color, vec3<f32>(max_intensity));

// Or use soft clamp
fn soft_clamp(x: f32, max_val: f32) -> f32 {
    return max_val * tanh(x / max_val);
}
```

---

## Performance Pitfalls

### Problem: Slow Uniform Updates

**Symptom**: Frame rate drops with many objects.

**Cause**: Creating new bind groups every frame.

**Solution**: Use dynamic uniform buffers:
```rust
// One bind group, multiple offsets
pass.set_bind_group(1, &object_bind_group, &[offset_for_object_i]);
```

### Problem: GPU Stalls

**Symptom**: Inconsistent frame times, stuttering.

**Cause**: Blocking on GPU results.

```rust
// WRONG - blocks CPU
let output = buffer.slice(..).get_mapped_range();

// CORRECT - use async mapping
buffer.slice(..).map_async(wgpu::MapMode::Read, |result| {
    // Handle result in callback
});
device.poll(wgpu::Maintain::Wait);  // Or Poll in game loop
```

### Problem: Too Many Draw Calls

**Symptom**: CPU-bound, low GPU utilization.

**Solution**: Batch draws with instancing:
```rust
// Instead of 1000 draw calls:
for object in objects {
    pass.draw_indexed(...);
}

// Use instancing:
pass.draw_indexed(0..mesh.indices, 0, 0..1000);
```

### Problem: Post-Processing Chain Slow

**Symptom**: Post-FX dominate frame time.

**Solutions**:
1. Process at half resolution, upscale at end
2. Combine passes (grain + vignette in one shader)
3. Use compute shaders for separable operations
4. Skip effects when camera is moving fast

---

## Platform-Specific Issues

### Problem: Different Results on Metal vs Vulkan

**Symptom**: Lighting looks different on Mac vs Windows.

**Causes**:
1. **Floating point precision**: Metal tends to flush denormals
2. **Texture filtering**: Subtle differences in bilinear interpolation
3. **Shader compilation**: Different optimizations

**Mitigations**:
```wgsl
// Avoid operations sensitive to precision
let safe_value = max(computed_value, 1e-6);

// Use explicit precision hints where available
// (WGSL doesn't have these yet, but avoid denormal-range values)
```

### Problem: WebGPU Feature Limitations

**Symptom**: Features work locally but fail in browser.

**Check before using**:
- `depth_clip_control` - Not in base WebGPU
- `texture_compression_bc` - Desktop only
- `float32_filterable` - Requires extension

```rust
// Query limits
let limits = device.limits();
let max_texture_size = limits.max_texture_dimension_2d;
let max_bind_groups = limits.max_bind_groups;
```

### Problem: Mobile GPU Tile Memory

**Symptom**: Performance cliff on mobile when G-Buffer is large.

**Cause**: Mobile GPUs have limited tile memory; large MRTs spill to main memory.

**Solutions**:
1. Use smaller G-Buffer formats (RGB10A2 instead of RGBA16F)
2. Consider forward rendering on mobile
3. Reduce G-Buffer to 2 RTs maximum

---

## Debugging Strategies

### Visual Debugging

Add debug visualization modes:
```wgsl
// In fragment shader
#ifdef DEBUG_NORMALS
    return vec4<f32>(N * 0.5 + 0.5, 1.0);
#endif

#ifdef DEBUG_DEPTH
    let linear_d = linearize_depth(depth);
    return vec4<f32>(vec3<f32>(linear_d / far_plane), 1.0);
#endif

#ifdef DEBUG_ROUGHNESS
    return vec4<f32>(vec3<f32>(roughness), 1.0);
#endif
```

### RenderDoc Integration

Capture with RenderDoc for:
- Viewing G-Buffer contents
- Inspecting draw call state
- Shader debugging

```rust
// Enable in wgpu
let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
    backends: wgpu::Backends::VULKAN,  // RenderDoc works best with Vulkan
    flags: wgpu::InstanceFlags::ALLOW_UNDERLYING_NONCOMPLIANT_ADAPTER,
    ..Default::default()
});
```

### Shader Validation

Use naga to validate shaders at build time:
```rust
// build.rs
use naga::front::wgsl;
use naga::valid::Validator;

fn validate_shader(source: &str) {
    let module = wgsl::parse_str(source).expect("WGSL parse error");
    let mut validator = Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    validator.validate(&module).expect("Validation error");
}
```

### Numerical Debugging

Insert debug outputs to track values:
```wgsl
// Temporarily output intermediate values
if debug_mode == 1u {
    return vec4<f32>(n_dot_v, roughness, metallic, 1.0);
}
if debug_mode == 2u {
    return vec4<f32>(diffuse, 1.0);
}
if debug_mode == 3u {
    return vec4<f32>(specular, 1.0);
}
```

---

## Buffer Alignment Nightmares

### Problem: Uniform Values Are Wrong/Garbage

**Symptom**: Some uniform values read correctly, others are garbage or zero.

**Cause**: WGSL has strict alignment requirements that don't match naive Rust struct layout.

**WGSL Alignment Rules**:
| Type | Alignment | Size |
|------|-----------|------|
| `f32` | 4 | 4 |
| `vec2<f32>` | 8 | 8 |
| `vec3<f32>` | **16** | 12 |
| `vec4<f32>` | 16 | 16 |
| `mat4x4<f32>` | 16 | 64 |

**The vec3 trap** - vec3 has 16-byte alignment but 12-byte size:

```rust
// WRONG - Rust packs tightly
#[repr(C)]
struct Bad {
    position: [f32; 3],  // offset 0, size 12
    scale: f32,          // offset 12 - WRONG! WGSL expects 16
}

// CORRECT - Use vec4 or explicit padding
#[repr(C)]
struct Good {
    position: [f32; 3],  // offset 0
    _pad0: f32,          // offset 12 - padding
    scale: f32,          // offset 16 - correct!
    _pad1: [f32; 3],     // pad to 16-byte boundary
}

// BETTER - Just use vec4 everywhere
#[repr(C)]
struct Better {
    position: [f32; 4],  // offset 0 (use .xyz in shader)
    scale: [f32; 4],     // offset 16 (use .x in shader)
}
```

### Problem: Array Stride Mismatch

**Symptom**: Only first array element reads correctly.

**Cause**: WGSL arrays have element stride rounded up to 16 bytes.

```rust
// WRONG - f32 array in Rust is tightly packed
struct Bad {
    values: [f32; 8],  // Rust: 4-byte stride, WGSL expects 16!
}

// CORRECT - pad each element
struct Good {
    values: [[f32; 4]; 8],  // Use vec4, access .x in shader
}

// Or for vec3 arrays:
struct AlsoGood {
    positions: [[f32; 4]; 8],  // NOT [f32; 3]! Use vec4.
}
```

### Problem: Dynamic Offset Alignment

**Symptom**: Validation error about dynamic offset alignment.

**Cause**: Dynamic uniform offsets must be multiples of `min_uniform_buffer_offset_alignment` (often 256 bytes).

```rust
// Query the requirement
let alignment = device.limits().min_uniform_buffer_offset_alignment as usize;

// Calculate padded size
let padded_size = (std::mem::size_of::<ObjectUniforms>() + alignment - 1) / alignment * alignment;

// Write at aligned offsets
let offset = object_index * padded_size;
queue.write_buffer(&buffer, offset as u64, bytemuck::bytes_of(&data));
```

### Debugging Alignment Issues

Use `bytemuck` with explicit size checks:

```rust
use std::mem::{size_of, align_of};

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct MyUniforms {
    // fields...
}

// Verify at compile time or startup
const _: () = assert!(size_of::<MyUniforms>() % 16 == 0, "Size must be multiple of 16");

// Print layout for debugging
println!("Size: {}, Align: {}", size_of::<MyUniforms>(), align_of::<MyUniforms>());
```

---

## Synchronization and Resource Lifetime

### Problem: Use-After-Free Crashes

**Symptom**: Random crashes, especially when resizing or recreating resources.

**Cause**: WGPU resources are reference-counted but command buffers capture references.

```rust
// DANGEROUS - texture might be dropped before commands execute
{
    let temp_texture = create_texture();
    encoder.copy_texture_to_texture(&temp_texture, &dest, size);
}  // temp_texture dropped here!
queue.submit([encoder.finish()]);  // Commands reference dropped texture!

// SAFE - ensure lifetime extends past submit
let temp_texture = create_texture();
encoder.copy_texture_to_texture(&temp_texture, &dest, size);
queue.submit([encoder.finish()]);
// temp_texture can be dropped now
```

### Problem: Stale Bind Groups After Resize

**Symptom**: Crash or wrong rendering after window resize.

**Cause**: Bind groups hold references to old textures.

```rust
// When resizing:
fn resize(&mut self, new_size: PhysicalSize<u32>) {
    self.surface.configure(&self.device, &self.config);

    // MUST recreate G-Buffer textures
    self.gbuffer = GBuffer::new(&self.device, new_size.width, new_size.height);

    // MUST recreate bind groups that reference G-Buffer
    self.lighting_bind_group = create_lighting_bind_group(
        &self.device,
        &self.gbuffer,  // New textures!
    );
}
```

### Problem: Read-After-Write Hazard

**Symptom**: Render uses stale data from previous frame.

**Cause**: Missing synchronization between passes.

```rust
// WGPU handles most synchronization automatically within a command buffer.
// But across submits, you may need explicit synchronization:

// Submit shadow pass
queue.submit([shadow_encoder.finish()]);

// If you need to READ the shadow map in CPU:
device.poll(wgpu::Maintain::Wait);  // Wait for GPU completion

// For GPU-to-GPU, automatic synchronization usually works,
// but ensure you're not creating the lighting command buffer
// before submitting the shadow commands.
```

---

## Quick Reference: Common Fixes

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Upside-down | Y-flip missing | Flip Y in UV or projection |
| Garbled geometry | Matrix layout | Transpose or reverse mul order |
| Black specular | Division by zero | Add epsilon to denominators |
| Wrong shadows | Coordinate flip | Flip Y in shadow UV |
| NaN pixels | sqrt/acos domain | Clamp inputs to valid range |
| Double-bright | sRGB double-conversion | Use correct texture formats |
| Flickering depth | Z-fighting | Use reverse-Z |
| Slow frames | Too many bind groups | Use dynamic offsets |

---

## Related Documents

- [hlsl-wgsl-guide.md](hlsl-wgsl-guide.md) - Syntax translation reference
- [wgpu-patterns.md](wgpu-patterns.md) - Correct API usage patterns
- [01-data-structures.md](../01-data-structures.md) - Buffer layout requirements
