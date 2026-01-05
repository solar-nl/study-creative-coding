# Mixbox - Architecture

## Overview

Mixbox is a **color mixing library** (not a framework) that provides a single core operation: pigment-based color interpolation.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Input Colors                             │
│                    (RGB1, RGB2, mix ratio t)                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Latent Space Conversion                       │
│            RGB → 7-dimensional pigment representation            │
│                      (via LUT lookup)                            │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Pigment Mixing                              │
│              Linear interpolation in latent space                │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    RGB Reconstruction                            │
│            Latent space → RGB output                             │
└─────────────────────────────────────────────────────────────────┘
```

## Core Algorithm

### The Latent Space

Mixbox converts RGB to a 7-dimensional latent representation:

```
Latent = [c0, c1, c2, c3, c4, c5, c6]
```

Where:
- `c0-c5` represent pigment concentrations
- `c6` represents a residual/white component

This latent space is derived from Kubelka-Munk theory, which models:
- Light absorption by pigments
- Light scattering within paint layers
- The resulting reflectance

### LUT-Based Conversion

Instead of computing Kubelka-Munk equations directly, Mixbox uses a precomputed **lookup table**:

```
mixbox_lut.png (512x512 or similar)
```

The LUT encodes the RGB→Latent and Latent→RGB mappings for efficient GPU evaluation.

### Mixing Operation

Once in latent space, mixing is simple linear interpolation:

```rust
latent_mixed = latent1 * (1 - t) + latent2 * t
```

The magic is in the latent space itself - linear mixing there produces subtractive (pigment-like) behavior in RGB space.

## Module Structure

```
mixbox/
├── rust/
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs          # Rust implementation
├── c/
│   ├── mixbox.h            # C/C++ header
│   └── mixbox.c            # C implementation
├── glsl/
│   └── mixbox.glsl         # GLSL shader
├── hlsl/
│   └── mixbox.hlsl         # HLSL shader
├── metal/
│   └── mixbox.metal        # Metal shader
├── python/
│   └── pymixbox/           # Python package
├── javascript/
│   └── mixbox.js           # JS implementation
├── java/
│   └── Mixbox.java         # Java implementation
├── csharp/
│   └── Mixbox.cs           # C# implementation
├── unity/                   # Unity package
├── godot/                   # Godot integration
└── mixbox_lut.png          # Precomputed LUT texture
```

## Key Components

### 1. LUT Texture (`mixbox_lut.png`)

The lookup table is the heart of Mixbox:

- **Format**: PNG image (typically 512x512)
- **Encoding**: RGB values encode latent space coefficients
- **Usage**: Bound as texture in GPU implementations

### 2. Latent Space Functions

```glsl
// GLSL example structure
vec3 mixbox_rgb_to_latent(vec3 rgb);   // RGB → 7D latent
vec3 mixbox_latent_to_rgb(vec3 latent); // 7D latent → RGB
```

### 3. Lerp Function

```rust
// Rust - main API
pub fn lerp(rgb1: &[u8; 3], rgb2: &[u8; 3], t: f32) -> [u8; 3]

// GLSL - main API
vec3 mixbox_lerp(vec3 rgb1, vec3 rgb2, float t)
```

## Kubelka-Munk Theory Background

The Kubelka-Munk model describes paint as having two properties:

1. **K (absorption coefficient)** - how much light the pigment absorbs
2. **S (scattering coefficient)** - how much light the pigment scatters

The reflectance R of a paint layer is:

```
R = 1 + K/S - sqrt((K/S)² + 2*K/S)
```

When mixing pigments:
- K and S values combine additively (weighted by concentration)
- This produces subtractive color behavior

Mixbox encodes these relationships in its LUT rather than computing them directly.

## Implementation Patterns

### CPU Implementation (Rust)

```rust
pub fn lerp(rgb1: &[u8; 3], rgb2: &[u8; 3], t: f32) -> [u8; 3] {
    // 1. Convert RGB to latent space (LUT lookup embedded in code)
    let latent1 = rgb_to_latent(rgb1);
    let latent2 = rgb_to_latent(rgb2);

    // 2. Linear interpolation in latent space
    let latent_mixed = lerp_latent(&latent1, &latent2, t);

    // 3. Convert back to RGB
    latent_to_rgb(&latent_mixed)
}
```

### GPU Implementation (GLSL)

```glsl
uniform sampler2D mixbox_lut;  // Must bind LUT texture

vec3 mixbox_lerp(vec3 rgb1, vec3 rgb2, float t) {
    // 1. Sample LUT to get latent representation
    vec3 latent1 = texture(mixbox_lut, rgb1.rg).rgb;  // Simplified
    vec3 latent2 = texture(mixbox_lut, rgb2.rg).rgb;

    // 2. Lerp in latent space
    vec3 latent_mixed = mix(latent1, latent2, t);

    // 3. Reconstruct RGB (also via LUT or polynomial)
    return latent_to_rgb(latent_mixed);
}
```

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **LUT-based** | Faster than computing K-M equations; GPU-friendly |
| **7D latent space** | Sufficient to model common pigments accurately |
| **Simple lerp API** | Drop-in replacement for standard color lerp |
| **Multiple languages** | Broad adoption; same algorithm everywhere |
| **PNG for LUT** | Universal format; easy to load |

## Patterns for Rust Framework Integration

1. **Optional dependency** - Not everyone needs pigment mixing

```toml
[dependencies]
mixbox = { version = "2.0.0", optional = true }

[features]
pigment-mixing = ["mixbox"]
```

2. **Trait-based integration**

```rust
pub trait PigmentMix {
    fn pigment_mix(&self, other: &Self, t: f32) -> Self;
}

impl PigmentMix for Srgb<u8> {
    fn pigment_mix(&self, other: &Self, t: f32) -> Self {
        let [r, g, b] = mixbox::lerp(
            &[self.red, self.green, self.blue],
            &[other.red, other.green, other.blue],
            t
        );
        Srgb::new(r, g, b)
    }
}
```

3. **Shader include** - Bundle `mixbox.glsl` with framework shaders

## Key Files to Study

| File | Purpose |
|------|---------|
| `rust/src/lib.rs` | Core Rust implementation |
| `glsl/mixbox.glsl` | GLSL shader implementation |
| `mixbox_lut.png` | The precomputed lookup table |
