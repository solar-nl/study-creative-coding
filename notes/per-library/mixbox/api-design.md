# Mixbox - API Design

> "The best API is one you don't have to think about." - Mixbox achieves this with a single function.

## Key Insight

> **Mixbox API's core idea:** Replace `lerp(color1, color2, t)` with `mixbox_lerp(color1, color2, t)` - same signature, physically accurate pigment mixing.

## Overview

Mixbox has an extremely simple API: **one function** that replaces standard color lerp.

```
mixbox_lerp(color1, color2, t) → mixed_color
```

This simplicity is intentional - it's a drop-in replacement for existing color interpolation.

## API by Language

### Rust

```rust
// Cargo.toml
// mixbox = "2.0.0"

use mixbox;

fn main() {
    let blue = [0, 33, 133];      // Cobalt Blue
    let yellow = [252, 211, 0];    // Hansa Yellow
    let t = 0.5;

    let [r, g, b] = mixbox::lerp(&blue, &yellow, t);
    // Result: Green (not gray!)
}
```

**Signature:**
```rust
pub fn lerp(rgb1: &[u8; 3], rgb2: &[u8; 3], t: f32) -> [u8; 3]
```

### C/C++

```c
#include "mixbox.h"

unsigned char r, g, b;
mixbox_lerp(
    r1, g1, b1,  // First color
    r2, g2, b2,  // Second color
    t,           // Mix ratio [0-1]
    &r, &g, &b   // Output
);
```

### JavaScript

```javascript
// Browser (CDN)
<script src="https://scrtwpns.com/mixbox.js"></script>

// Node.js
const mixbox = require("mixbox");

let rgb1 = "rgb(0, 33, 133)";   // or [0, 33, 133]
let rgb2 = "rgb(252, 211, 0)";
let t = 0.5;

let [r, g, b] = mixbox.lerp(rgb1, rgb2, t);
```

### Python

```python
import mixbox

rgb1 = (0, 33, 133)
rgb2 = (252, 211, 0)
t = 0.5

r, g, b = mixbox.lerp(rgb1, rgb2, t)
```

### GLSL

```glsl
uniform sampler2D mixbox_lut;  // REQUIRED: bind LUT texture
#include "mixbox.glsl"

void main() {
    vec3 color1 = vec3(0.0, 0.13, 0.52);  // Blue (normalized)
    vec3 color2 = vec3(0.99, 0.83, 0.0);  // Yellow
    float t = 0.5;

    vec3 mixed = mixbox_lerp(color1, color2, t);
    gl_FragColor = vec4(mixed, 1.0);
}
```

### HLSL

```hlsl
Texture2D mixbox_lut;  // REQUIRED: bind LUT texture
SamplerState mixbox_sampler;
#include "mixbox.hlsl"

float4 main(float2 uv : TEXCOORD) : SV_Target {
    float3 color1 = float3(0.0, 0.13, 0.52);
    float3 color2 = float3(0.99, 0.83, 0.0);

    float3 mixed = MixboxLerp(color1, color2, 0.5);
    return float4(mixed, 1.0);
}
```

### Metal

```metal
#include "mixbox.metal"

fragment float4 fragmentShader(
    texture2d<float> mixbox_lut [[texture(0)]],
    // ...
) {
    float3 color1 = float3(0.0, 0.13, 0.52);
    float3 color2 = float3(0.99, 0.83, 0.0);

    float3 mixed = mixbox_lerp(mixbox_lut, color1, color2, 0.5);
    return float4(mixed, 1.0);
}
```

## Input Formats

Different implementations accept different input formats:

| Language | Input Format | Range |
|----------|--------------|-------|
| Rust | `[u8; 3]` | 0-255 |
| C/C++ | `unsigned char` | 0-255 |
| JavaScript | `[r, g, b]` or CSS string | 0-255 |
| Python | `(r, g, b)` tuple | 0-255 |
| GLSL | `vec3` | 0.0-1.0 |
| HLSL | `float3` | 0.0-1.0 |
| Metal | `float3` | 0.0-1.0 |

## Advanced: Latent Space Access

For multi-color mixing, access the latent space directly:

### Rust

```rust
// Convert to latent space
let latent1 = mixbox::rgb_to_latent(&color1);
let latent2 = mixbox::rgb_to_latent(&color2);
let latent3 = mixbox::rgb_to_latent(&color3);

// Mix multiple colors in latent space
let mut mixed_latent = [0.0f32; 7];
for i in 0..7 {
    mixed_latent[i] = latent1[i] * 0.33
                    + latent2[i] * 0.33
                    + latent3[i] * 0.34;
}

// Convert back to RGB
let [r, g, b] = mixbox::latent_to_rgb(&mixed_latent);
```

### GLSL

```glsl
// Mix 4 colors with custom weights
vec3 mix4(vec3 c1, vec3 c2, vec3 c3, vec3 c4, vec4 weights) {
    // Get latent representations
    mixbox_latent l1 = mixbox_rgb_to_latent(c1);
    mixbox_latent l2 = mixbox_rgb_to_latent(c2);
    mixbox_latent l3 = mixbox_rgb_to_latent(c3);
    mixbox_latent l4 = mixbox_rgb_to_latent(c4);

    // Blend in latent space
    mixbox_latent mixed;
    // ... weighted average of latent values ...

    return mixbox_latent_to_rgb(mixed);
}
```

## Pigment Constants

Pre-defined pigment colors for consistent results:

```rust
// Rust
const CADMIUM_YELLOW: [u8; 3] = [254, 236, 0];
const ULTRAMARINE_BLUE: [u8; 3] = [25, 0, 89];
const CADMIUM_RED: [u8; 3] = [255, 39, 2];
const PHTHALO_GREEN: [u8; 3] = [0, 60, 50];
const COBALT_BLUE: [u8; 3] = [0, 33, 133];
// ... etc
```

```glsl
// GLSL (normalized)
#define MIXBOX_CADMIUM_YELLOW vec3(0.996, 0.925, 0.0)
#define MIXBOX_ULTRAMARINE_BLUE vec3(0.098, 0.0, 0.349)
// ... etc
```

## Comparison with Standard Lerp

```rust
// Standard RGB lerp (produces gray for blue+yellow)
fn rgb_lerp(c1: [u8; 3], c2: [u8; 3], t: f32) -> [u8; 3] {
    [
        ((c1[0] as f32) * (1.0 - t) + (c2[0] as f32) * t) as u8,
        ((c1[1] as f32) * (1.0 - t) + (c2[1] as f32) * t) as u8,
        ((c1[2] as f32) * (1.0 - t) + (c2[2] as f32) * t) as u8,
    ]
}

// Mixbox lerp (produces green for blue+yellow)
let mixed = mixbox::lerp(&blue, &yellow, 0.5);
```

## API Design Principles

1. **Minimal API** - One function for 90% of use cases
2. **Drop-in replacement** - Same signature as standard lerp
3. **No global state** - Pure functions
4. **Cross-platform consistency** - Same algorithm in all languages
5. **GPU-ready** - Shader implementations for real-time use

## Integration Patterns

### As Color Trait Extension

```rust
trait PigmentMix {
    fn pigment_lerp(&self, other: &Self, t: f32) -> Self;
}

impl PigmentMix for [u8; 3] {
    fn pigment_lerp(&self, other: &Self, t: f32) -> Self {
        mixbox::lerp(self, other, t)
    }
}
```

### In a Creative Coding Framework

```rust
// Gradient with pigment mixing
pub fn pigment_gradient(colors: &[[u8; 3]], steps: usize) -> Vec<[u8; 3]> {
    let mut result = Vec::new();
    for i in 0..steps {
        let t = i as f32 / (steps - 1) as f32;
        // Map t to color pair and local t
        let segment = (t * (colors.len() - 1) as f32) as usize;
        let local_t = t * (colors.len() - 1) as f32 - segment as f32;

        let c1 = colors[segment.min(colors.len() - 2)];
        let c2 = colors[(segment + 1).min(colors.len() - 1)];

        result.push(mixbox::lerp(&c1, &c2, local_t));
    }
    result
}
```

## Key Files

| File | Purpose |
|------|---------|
| `rust/src/lib.rs` | Rust API |
| `glsl/mixbox.glsl` | GLSL shader API |
| `hlsl/mixbox.hlsl` | HLSL shader API |
| `javascript/mixbox.js` | JavaScript API |
