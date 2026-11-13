# Color and Blend Operators

Color operators modify pixel values (hue, saturation, contrast). Blend operators combine two textures using various blend modes.

## Operator Overview

### Color Operators (1 input)

| Operator | Description |
|----------|-------------|
| **Colorize** | Map grayscale to color gradient |
| **HSL** | Adjust hue, saturation, lightness |
| **Scale** | Remap value range |
| **Contrast** | Adjust contrast and brightness |
| **Invert** | Invert colors |
| **Curves** | RGB spline curves |
| **Smoothstep** | Threshold with soft edges |

### Blend Operators (2 inputs)

| Operator | Description |
|----------|-------------|
| **Combine** | 10 blend modes |
| **Mix** | Linear interpolation |
| **MixMap** | Per-pixel blend via mask |
| **ReplaceAlpha** | Replace alpha channel |

---

## Colorize

Maps grayscale input to a two-color gradient.

### Parameters

| Index | Name | Description |
|-------|------|-------------|
| 0-3 | color1 | Start color (RGBA) |
| 4-7 | color2 | End color (RGBA) |

### WGSL Implementation

```wgsl
// colorize.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    // Use luminance as interpolation factor
    let lum = input_color.r;

    // Decode colors
    let color1 = vec4<f32>(param(0), param(1), param(2), param(3));
    let color2 = vec4<f32>(param(4), param(5), param(6), param(7));

    // Interpolate between colors
    let result = mix(color1, color2, lum);

    textureStore(output, gid.xy, result);
}
```

---

## HSL Adjustment

Modify hue, saturation, and lightness in HSL color space.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | hue_shift | -1 to 1 | Hue rotation (0.5 = no change) |
| 1 | saturation | 0-2 | Saturation multiplier (0.5 = 1×) |
| 2 | lightness | 0-2 | Lightness multiplier (0.5 = 1×) |

### WGSL Implementation

```wgsl
// hsl.wgsl

// RGB ↔ HSL conversion
fn rgb_to_hsl(rgb: vec3<f32>) -> vec3<f32> {
    let max_c = max(max(rgb.r, rgb.g), rgb.b);
    let min_c = min(min(rgb.r, rgb.g), rgb.b);
    let delta = max_c - min_c;

    var h = 0.0;
    var s = 0.0;
    let l = (max_c + min_c) * 0.5;

    if (delta > 0.0001) {
        s = select(
            delta / (2.0 - max_c - min_c),
            delta / (max_c + min_c),
            l < 0.5
        );

        if (max_c == rgb.r) {
            h = (rgb.g - rgb.b) / delta + select(6.0, 0.0, rgb.g < rgb.b);
        } else if (max_c == rgb.g) {
            h = (rgb.b - rgb.r) / delta + 2.0;
        } else {
            h = (rgb.r - rgb.g) / delta + 4.0;
        }
        h /= 6.0;
    }

    return vec3<f32>(h, s, l);
}

fn hue_to_rgb(p: f32, q: f32, t: f32) -> f32 {
    var tt = t;
    if (tt < 0.0) { tt += 1.0; }
    if (tt > 1.0) { tt -= 1.0; }
    if (tt < 1.0/6.0) { return p + (q - p) * 6.0 * tt; }
    if (tt < 1.0/2.0) { return q; }
    if (tt < 2.0/3.0) { return p + (q - p) * (2.0/3.0 - tt) * 6.0; }
    return p;
}

fn hsl_to_rgb(hsl: vec3<f32>) -> vec3<f32> {
    if (hsl.y < 0.0001) {
        return vec3<f32>(hsl.z, hsl.z, hsl.z);
    }

    let q = select(
        hsl.z + hsl.y - hsl.z * hsl.y,
        hsl.z * (1.0 + hsl.y),
        hsl.z < 0.5
    );
    let p = 2.0 * hsl.z - q;

    return vec3<f32>(
        hue_to_rgb(p, q, hsl.x + 1.0/3.0),
        hue_to_rgb(p, q, hsl.x),
        hue_to_rgb(p, q, hsl.x - 1.0/3.0)
    );
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    // Decode adjustments
    let hue_shift = (param(0) - 0.5) * 2.0;  // -1 to 1
    let sat_mult = param(1) * 2.0;  // 0 to 2
    let light_mult = param(2) * 2.0;  // 0 to 2

    // Convert to HSL
    var hsl = rgb_to_hsl(input_color.rgb);

    // Apply adjustments
    hsl.x = fract(hsl.x + hue_shift);
    hsl.y = saturate(hsl.y * sat_mult);
    hsl.z = saturate(hsl.z * light_mult);

    // Convert back to RGB
    let rgb = hsl_to_rgb(hsl);

    textureStore(output, gid.xy, vec4<f32>(rgb, input_color.a));
}
```

---

## Scale (Remap Range)

Remaps input values from one range to another.

### Parameters

| Index | Name | Description |
|-------|------|-------------|
| 0-3 | min_rgba | Output minimum for each channel |
| 4-7 | max_rgba | Output maximum for each channel |

### WGSL Implementation

```wgsl
// scale.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    // Decode min/max for each channel
    let min_val = vec4<f32>(param(0), param(1), param(2), param(3));
    let max_val = vec4<f32>(param(4), param(5), param(6), param(7));

    // Remap: input [0,1] → output [min,max]
    let result = mix(min_val, max_val, input_color);

    textureStore(output, gid.xy, result);
}
```

---

## Contrast

Adjust contrast and brightness.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | contrast | 0-2 | Contrast multiplier (0.5 = 1×) |
| 1 | brightness | -1 to 1 | Brightness offset (0.5 = 0) |
| 2 | pivot | 0-1 | Contrast pivot point |

### WGSL Implementation

```wgsl
// contrast.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    let contrast = param(0) * 2.0;
    let brightness = (param(1) - 0.5) * 2.0;
    let pivot = param(2);

    // Apply contrast around pivot point
    var result = (input_color.rgb - pivot) * contrast + pivot;

    // Apply brightness
    result = result + brightness;

    textureStore(output, gid.xy, vec4<f32>(saturate(result), input_color.a));
}
```

---

## Invert

Simple color inversion.

### WGSL Implementation

```wgsl
// invert.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    // Invert RGB, preserve alpha
    let result = vec4<f32>(1.0 - input_color.rgb, input_color.a);

    textureStore(output, gid.xy, result);
}
```

---

## Smoothstep

Smooth threshold with configurable edges.

### Parameters

| Index | Name | Description |
|-------|------|-------------|
| 0 | edge0 | Lower threshold |
| 1 | edge1 | Upper threshold |

### WGSL Implementation

```wgsl
// smoothstep_op.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let input_color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    let edge0 = param(0);
    let edge1 = max(param(1), edge0 + 0.001);

    // Apply smoothstep to each channel
    let result = smoothstep(vec4<f32>(edge0), vec4<f32>(edge1), input_color);

    textureStore(output, gid.xy, result);
}
```

---

## Combine (Blend Modes)

The Combine operator supports 10 blend modes.

### Parameters

| Index | Name | Description |
|-------|------|-------------|
| 0 | mode | Blend mode (0-9) |

### Blend Mode Table

| Value | Mode | Formula |
|-------|------|---------|
| 0 | Add | `a + b` |
| 1 | Subtract | `a - b` |
| 2 | Multiply | `a * b` |
| 3 | Screen | `1 - (1-a)(1-b)` |
| 4 | Overlay | `2ab` if a<0.5, else `1-2(1-a)(1-b)` |
| 5 | Lighten | `max(a, b)` |
| 6 | Darken | `min(a, b)` |
| 7 | Difference | `abs(a - b)` |
| 8 | Exclusion | `a + b - 2ab` |
| 9 | Average | `(a + b) / 2` |

### WGSL Implementation

```wgsl
// combine.wgsl

// Blend mode functions
fn blend_add(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a + b;
}

fn blend_subtract(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a - b;
}

fn blend_multiply(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a * b;
}

fn blend_screen(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return 1.0 - (1.0 - a) * (1.0 - b);
}

fn blend_overlay_channel(a: f32, b: f32) -> f32 {
    return select(
        1.0 - 2.0 * (1.0 - a) * (1.0 - b),
        2.0 * a * b,
        a < 0.5
    );
}

fn blend_overlay(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        blend_overlay_channel(a.r, b.r),
        blend_overlay_channel(a.g, b.g),
        blend_overlay_channel(a.b, b.b)
    );
}

fn blend_lighten(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return max(a, b);
}

fn blend_darken(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return min(a, b);
}

fn blend_difference(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return abs(a - b);
}

fn blend_exclusion(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a + b - 2.0 * a * b;
}

fn blend_average(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return (a + b) * 0.5;
}

@group(0) @binding(0) var<uniform> u: TexgenUniforms;
@group(0) @binding(1) var input_a: texture_2d<f32>;
@group(0) @binding(2) var input_b: texture_2d<f32>;
@group(0) @binding(3) var linear_sampler: sampler;
@group(0) @binding(4) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let a = textureSampleLevel(input_a, linear_sampler, uv, 0.0);
    let b = textureSampleLevel(input_b, linear_sampler, uv, 0.0);

    let mode = u32(param(0) * 10.0);

    var result: vec3<f32>;
    switch (mode) {
        case 0u: { result = blend_add(a.rgb, b.rgb); }
        case 1u: { result = blend_subtract(a.rgb, b.rgb); }
        case 2u: { result = blend_multiply(a.rgb, b.rgb); }
        case 3u: { result = blend_screen(a.rgb, b.rgb); }
        case 4u: { result = blend_overlay(a.rgb, b.rgb); }
        case 5u: { result = blend_lighten(a.rgb, b.rgb); }
        case 6u: { result = blend_darken(a.rgb, b.rgb); }
        case 7u: { result = blend_difference(a.rgb, b.rgb); }
        case 8u: { result = blend_exclusion(a.rgb, b.rgb); }
        case 9u: { result = blend_average(a.rgb, b.rgb); }
        default: { result = a.rgb; }
    }

    // Use alpha from first input
    textureStore(output, gid.xy, vec4<f32>(saturate(result), a.a));
}
```

---

## Mix

Linear interpolation between two textures.

### Parameters

| Index | Name | Description |
|-------|------|-------------|
| 0 | factor | Blend factor (0 = input A, 1 = input B) |

### WGSL Implementation

```wgsl
// mix.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let a = textureSampleLevel(input_a, linear_sampler, uv, 0.0);
    let b = textureSampleLevel(input_b, linear_sampler, uv, 0.0);

    let factor = param(0);
    let result = mix(a, b, factor);

    textureStore(output, gid.xy, result);
}
```

---

## MixMap

Per-pixel blend using a mask texture as the blend factor.

### Inputs

- Input 0: Texture A
- Input 1: Texture B
- Input 2: Mask (uses red channel as blend factor)

### WGSL Implementation

```wgsl
// mixmap.wgsl

@group(0) @binding(0) var<uniform> u: TexgenUniforms;
@group(0) @binding(1) var input_a: texture_2d<f32>;
@group(0) @binding(2) var input_b: texture_2d<f32>;
@group(0) @binding(3) var mask: texture_2d<f32>;
@group(0) @binding(4) var linear_sampler: sampler;
@group(0) @binding(5) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let a = textureSampleLevel(input_a, linear_sampler, uv, 0.0);
    let b = textureSampleLevel(input_b, linear_sampler, uv, 0.0);
    let m = textureSampleLevel(mask, linear_sampler, uv, 0.0);

    let result = mix(a, b, m.r);

    textureStore(output, gid.xy, result);
}
```

---

## ReplaceAlpha

Replace alpha channel from another texture.

### Inputs

- Input 0: RGB source
- Input 1: Alpha source (uses red channel)

### WGSL Implementation

```wgsl
// replace_alpha.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let rgb_source = textureSampleLevel(input_a, linear_sampler, uv, 0.0);
    let alpha_source = textureSampleLevel(input_b, linear_sampler, uv, 0.0);

    let result = vec4<f32>(rgb_source.rgb, alpha_source.r);

    textureStore(output, gid.xy, result);
}
```

---

## Related Documents

- [04-generators.md](04-generators.md) - Pattern generators
- [05-transforms.md](05-transforms.md) - UV transforms
- [07-filters.md](07-filters.md) - Convolution filters
