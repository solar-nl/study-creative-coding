# Color Systems in Creative Coding Frameworks

> Comprehensive analysis of color representation, manipulation, and theory across creative coding frameworks.

## Key Insight

> **Color systems' core idea:** RGB is for displays, HSV for picking, LAB/OkLab for perceptual uniformity, and Kubelka-Munk (Mixbox) for paint-like mixing - choose the space that matches your operation.

## Overview

Color is fundamental to creative coding. Frameworks differ significantly in:
- **Which color spaces** they support (RGB, HSV, LAB, OkLab, etc.)
- **How colors are stored** internally (floats, integers, packed bits)
- **API ergonomics** (type-safe vs mode-based, constructors vs functions)
- **Gamma handling** (linear vs sRGB workflows)
- **Color theory utilities** (harmony, gradients, palettes)

This document analyzes these aspects across frameworks to inform the design of a Rust creative coding framework.

---

## Color Space Comparison Matrix

### Frameworks

| Framework | RGB | HSV/HSB | HSL | LAB | LCH | XYZ | LUV | OkLab | CMYK |
|-----------|:---:|:-------:|:---:|:---:|:---:|:---:|:---:|:-----:|:----:|
| **nannou** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | - | - | - |
| **openrndr** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | - | - |
| **p5.js** | ✓ | ✓ | ✓ | - | - | - | - | - | - |
| **Processing** | ✓ | ✓ | - | - | - | - | - | - | - |
| **tixl** | ✓ | - | - | - | ✓ | - | - | ✓ | - |
| **DrawBot** | ✓ | - | - | - | - | - | - | - | ✓ |

### Libraries

| Library | RGB | HSV/HSB | HSL | LAB | LCH | XYZ | LUV | OkLab | CMYK |
|---------|:---:|:-------:|:---:|:---:|:---:|:---:|:---:|:-----:|:----:|
| **wgpu** | ✓ | - | - | - | - | - | - | - | - |
| **three.js** | ✓ | - | ✓ | - | - | ✓ | - | - | - |
| **orx** | ✓ | ✓ | ✓ | - | - | - | - | - | - |
| **toxiclibs** | ✓ | ✓ | - | ✓ | - | - | - | - | ✓ |
| **mixbox** | ✓ | - | - | - | - | - | - | - | - |

**Key observations:**
- **openrndr** has the most comprehensive color space support (16+ models)
- **nannou** leverages the Rust `palette` crate for extensive support
- **tixl** uniquely implements **OkLab** (modern perceptual model) in GPU shaders
- **DrawBot** and **toxiclibs** have **CMYK** support—rare in creative coding, essential for print
- **mixbox** (library) provides pigment-based mixing, not color spaces
- Web libraries (three.js) focus on RGB/HSL basics

---

## Internal Representations

How frameworks and libraries store color values internally:

### Frameworks

| Framework | Storage Type | Range | Notes |
|-----------|--------------|-------|-------|
| **nannou** | `palette` crate types | 0.0-1.0 (f32) | Type-safe, generic over scalar |
| **openrndr** | `data class ColorRGBa` | 0.0-1.0 (Double) | Kotlin data classes per space |
| **p5.js** | `levels` array | 0-255 (internal 0-1) | Normalized internally, 8-bit output |
| **Processing** | `int` (32-bit ARGB) | 0-255 packed | Bit-shifted components |
| **tixl** | `Vector4` / `float4` | 0.0-1.0 (float) | RGBA in shaders |
| **DrawBot** | NSColor / CGColor | 0.0-1.0 | macOS native, RGB + CMYK parallel APIs |

### Libraries

| Library | Storage Type | Range | Notes |
|---------|--------------|-------|-------|
| **wgpu** | `Color { r, g, b, a }` | 0.0-1.0 (f64) | Simple struct, GPU-focused |
| **three.js** | `Color { r, g, b }` | 0.0-1.0 (Number) | No alpha in Color class |
| **toxiclibs** | `TColor` (float fields) | 0.0-1.0 (float) | Implicit RGB/HSV/CMYK access |
| **mixbox** | `[u8; 3]` / `vec3` | 0-255 or 0.0-1.0 | Language-dependent |

### Code Examples

```rust
// nannou (Rust) - Type-safe color spaces
use nannou::prelude::*;
let c1: Srgb<f32> = srgb(1.0, 0.5, 0.25);
let c2: Hsv = hsv(0.08, 1.0, 0.9);
let c3: LinSrgb = c1.into_linear(); // Explicit conversion
```

```java
// Processing (Java) - 32-bit packed integer
colorMode(RGB, 255);
int c = color(255, 128, 64);  // Returns 0xFFFF8040
int r = (c >> 16) & 0xFF;     // Extract red
```

```javascript
// p5.js - Normalized array with 8-bit output
let c = color(255, 128, 64);
c._array  // [1.0, 0.502, 0.251, 1.0] (normalized)
c.levels  // [255, 128, 64, 255] (8-bit)
```

```kotlin
// openrndr (Kotlin) - Data class per color space
val rgb = ColorRGBa(1.0, 0.5, 0.25)
val hsv: ColorHSVa = rgb.toHSVa()
val lab: ColorLABa = rgb.toLABa()
```

```python
# DrawBot (Python) - Dual RGB/CMYK system for print
fill(1, 0, 0, 0.5)           # RGB: red at 50% opacity
cmykFill(0, 1, 1, 0)         # CMYK: same red, print-ready

stroke(0, 0, 1)              # RGB blue stroke
cmykStroke(1, 1, 0, 0)       # CMYK blue stroke

# Color spaces: sRGB, adobeRGB, genericGray
fill(0.5, 0.5, 0.5, colorSpace="adobeRGB")
```

---

## Color Space Conversions

### RGB ↔ HSV Algorithm

The HSV (Hue, Saturation, Value) conversion is fundamental. Here's how toxiclibs implements it:

```java
// toxiclibs TColor.java - HSV to RGB
public static float[] hsvToRGB(float h, float s, float v, float[] rgb) {
    if (s == 0.0f) {
        rgb[0] = rgb[1] = rgb[2] = v;  // Achromatic (gray)
    } else {
        h /= (60.0f / 360.0f);  // Sector 0-5
        int i = (int) h;
        float f = h - i;        // Fractional part
        float p = v * (1 - s);
        float q = v * (1 - s * f);
        float t = v * (1 - s * (1 - f));

        switch (i) {
            case 0: rgb[0] = v; rgb[1] = t; rgb[2] = p; break;
            case 1: rgb[0] = q; rgb[1] = v; rgb[2] = p; break;
            case 2: rgb[0] = p; rgb[1] = v; rgb[2] = t; break;
            case 3: rgb[0] = p; rgb[1] = q; rgb[2] = v; break;
            case 4: rgb[0] = t; rgb[1] = p; rgb[2] = v; break;
            default: rgb[0] = v; rgb[1] = p; rgb[2] = q; break;
        }
    }
    return rgb;
}
```

### Reference White Points

For perceptual color spaces (LAB, XYZ), the reference white matters. openrndr supports multiple illuminants:

```kotlin
// openrndr ColorXYZa.kt
object ColorXYZa {
    val SO2_D65  // CIE 1931 2° Standard Observer, D65 illuminant
    val SO10_D65 // CIE 1963 10° Standard Observer, D65
    // Also: A, C, F2, TL4, UL3000, D50, D55, D60, D75
}
```

---

## Perceptual Color Models

### Why Perceptual Models Matter

RGB and HSV are **not perceptually uniform** - equal numeric changes don't produce equal visual changes. Perceptual models like LAB, LCH, and OkLab address this:

| Model | Perceptually Uniform | Use Case |
|-------|---------------------|----------|
| RGB | No | Display, GPU |
| HSV/HSB | No (hue is uneven) | Color picking |
| HSL | No | CSS, web design |
| LAB | Yes (approximate) | Color science, printing |
| LCH | Yes (cylindrical LAB) | Intuitive perceptual adjustments |
| OkLab | Yes (modern, improved) | Modern graphics, gradients |
| LUV | Yes | TV broadcast |

### OkLab (tixl implementation)

OkLab is a modern perceptual color space designed by Björn Ottosson (2020). tixl implements it in HLSL:

```hlsl
// tixl color-functions.hlsl - OkLab matrices
static const float3x3 invB = {
    0.4121656120, 0.2118591070, 0.0883097947,
    0.5362752080, 0.6807189584, 0.2818474174,
    0.0514575653, 0.1074065790, 0.6302613616
};

inline float3 RgbToOkLab(float3 c) {
    float3 lms = mul(invB, c);
    return mul(invA, sign(lms) * pow(abs(lms), 0.333333));
}
```

### LCH (Lightness, Chroma, Hue)

LCH is the cylindrical form of LAB, making hue manipulation intuitive:

```hlsl
// tixl - RGB to LCH via OkLab
inline float3 RgbToLCh(float3 col) {
    col = mul(col, invB);
    col = mul(sign(col) * pow(abs(col), 0.333), invA);

    float3 polar;
    polar.x = col.x;                                    // L: Lightness
    polar.y = sqrt(col.y * col.y + col.z * col.z);     // C: Chroma
    polar.z = atan2(col.z, col.y) / (2 * PI) + 0.5;    // H: Hue (normalized)
    return polar;
}
```

### openrndr's Comprehensive Support

```kotlin
// openrndr - Multiple perceptual spaces
val rgb = ColorRGBa(1.0, 0.5, 0.25)

// Convert to perceptual spaces
val lab: ColorLABa = rgb.toLABa()      // L: 0-100, a/b: unbounded
val lch: ColorLCHABa = rgb.toLCHABa()  // Cylindrical LAB
val luv: ColorLUVa = rgb.toLUVa()      // CIE LUV
val xyz: ColorXYZa = rgb.toXYZa()      // Tristimulus

// Perceptual color manipulation
val shifted = lch.shiftHue(30.0)       // Rotate hue 30°
val desaturated = lch.withChroma(0.5)  // Reduce chroma
```

---

## Color Theory & Harmony

### toxiclibs Color Theory Strategies

toxiclibs provides the most comprehensive color theory implementation through a strategy pattern:

```java
// toxiclibs - Harmony generation strategies
ColorTheoryRegistry.COMPLEMENTARY      // Opposite on wheel
ColorTheoryRegistry.SPLIT_COMPLEMENTARY // Two colors adjacent to complement
ColorTheoryRegistry.TRIADIC            // Three equidistant colors
ColorTheoryRegistry.TETRADIC           // Four colors (rectangle)
ColorTheoryRegistry.ANALOGOUS          // Adjacent colors
ColorTheoryRegistry.MONOCHROME         // Single hue, varying lightness
```

### RYB Color Wheel

toxiclibs uses a **Red-Yellow-Blue** wheel (traditional artist's wheel) rather than RGB:

```java
// toxiclibs TColor.java - RYB wheel mapping (24 points)
protected static final Vec2D[] RYB_WHEEL = new Vec2D[] {
    new Vec2D(0, 0),      // Red
    new Vec2D(15, 8),     // Red-orange
    new Vec2D(30, 17),    // Orange
    new Vec2D(45, 26),    // Yellow-orange
    new Vec2D(60, 34),    // Yellow
    // ... 24 points mapping RYB to RGB hue
    new Vec2D(360, 0)     // Back to red
};
```

This produces more intuitive complementary colors for artists (red↔green, blue↔orange, yellow↔purple).

### Generating Harmonious Palettes

```java
// toxiclibs - Create a complementary palette
TColor baseColor = TColor.newHSV(0.0f, 0.8f, 0.9f);  // Red
ColorList palette = ColorTheoryRegistry.COMPLEMENTARY.createListFromColor(baseColor);
// Returns: [red, cyan]

// Triadic palette
ColorList triadic = ColorTheoryRegistry.TRIADIC.createListFromColor(baseColor);
// Returns: [red, green, blue]
```

---

## Linear vs Gamma (sRGB)

### The Problem

Displays use **gamma-corrected sRGB**, but math operations (blending, lighting) should happen in **linear** space. Mixing these causes incorrect results.

### Framework Approaches

| Framework | Approach |
|-----------|----------|
| **nannou** | Explicit `Srgb` vs `LinSrgb` types |
| **three.js** | `ColorManagement` system with working space |
| **openrndr** | `Linearity` enum on `ColorRGBa` |
| **p5.js** | No distinction (assumes sRGB) |
| **Processing** | No distinction (assumes sRGB) |

### nannou's Type-Safe Approach

```rust
// nannou - Distinct types prevent mixing
use nannou::color::{Srgb, LinSrgb};

let srgb: Srgb<f32> = srgb(0.5, 0.5, 0.5);     // Display-ready
let linear: LinSrgb<f32> = srgb.into_linear();  // Math-ready

// Can't accidentally mix - compile error:
// let wrong = srgb + linear;  // Error: mismatched types
```

### three.js ColorManagement

```javascript
// three.js - Centralized color management
THREE.ColorManagement.enabled = true;
THREE.ColorManagement.workingColorSpace = THREE.LinearSRGBColorSpace;

// Automatic conversion from sRGB textures to linear working space
// Automatic conversion from linear to sRGB on output
```

### openrndr's Linearity Property

```kotlin
// openrndr - Runtime linearity tracking
data class ColorRGBa(
    val r: Double,
    val g: Double,
    val b: Double,
    val alpha: Double = 1.0,
    val linearity: Linearity = Linearity.LINEAR
)

enum class Linearity {
    LINEAR,  // Linear color space
    SRGB     // Gamma-corrected sRGB
}
```

---

## Blending & Mixing

### Color Interpolation

Most frameworks support linear interpolation (lerp) between colors:

```kotlin
// openrndr - Color mixing
val a = ColorRGBa.RED
val b = ColorRGBa.BLUE
val mixed = a.mix(b, 0.5)  // 50% blend
```

```rust
// nannou (via palette crate)
use nannou::color::Mix;
let mixed = red.mix(&blue, 0.5);
```

### The RGB Mixing Problem

Standard RGB interpolation produces **muddy, desaturated results** when mixing complementary colors:

| Colors | RGB Result | Expected (Paint) |
|--------|------------|------------------|
| Blue + Yellow | Gray/Brown | Green |
| Red + Blue | Muddy Purple | Vibrant Purple |
| Red + Green | Brown | Brown (correct) |

This happens because RGB is an **additive** color model (light), while artists expect **subtractive** behavior (pigments).

### Mixbox: Pigment-Based Mixing

[Mixbox](https://github.com/scrtwpns/mixbox) solves this using **Kubelka-Munk theory** - a physical model of how light interacts with pigments.

**How it works:**
1. Convert RGB to a pigment "latent space" (via LUT texture)
2. Mix in pigment space (simulating paint behavior)
3. Convert back to RGB

```rust
// Rust - Pigment-based mixing
let blue = [0, 33, 133];
let yellow = [252, 211, 0];
let t = 0.5;

let [r, g, b] = mixbox::lerp(&blue, &yellow, t);
// Result: Green! (not gray)
```

```glsl
// GLSL shader - requires LUT texture
uniform sampler2D mixbox_lut;
#include "mixbox.glsl"

vec3 mixed = mixbox_lerp(blue, yellow, 0.5);  // Natural green
```

**Available pigments** (with calibrated RGB values):

| Pigment | RGB |
|---------|-----|
| Cadmium Yellow | 254, 236, 0 |
| Ultramarine Blue | 25, 0, 89 |
| Cadmium Red | 255, 39, 2 |
| Phthalo Green | 0, 60, 50 |
| Burnt Sienna | 123, 72, 0 |
| Cobalt Blue | 0, 33, 133 |
| Phthalo Blue | 13, 27, 68 |

**Platform support:** Rust, C/C++, Python, JavaScript, GLSL, HLSL, Metal, Unity, Godot

### Blend Modes

Blend modes define how colors combine. Common modes:

| Mode | Formula | Use Case |
|------|---------|----------|
| Normal | `src` | Default |
| Multiply | `src * dst` | Shadows, darkening |
| Screen | `1 - (1-src)(1-dst)` | Highlights, lightening |
| Overlay | Combine multiply/screen | Contrast |
| Add | `src + dst` | Glow, fire |

Most frameworks handle blend modes at the GPU/compositor level rather than in color classes.

---

## API Design Patterns

### Pattern 1: Mode-Based (Processing/p5.js)

Global state determines interpretation:

```java
// Processing
colorMode(HSB, 360, 100, 100);
fill(0, 100, 100);    // Interpreted as HSB
colorMode(RGB, 255);
fill(255, 0, 0);      // Now interpreted as RGB
```

**Pros:** Simple, familiar to beginners
**Cons:** Global state, easy to forget current mode

### Pattern 2: Type-Safe (nannou)

Distinct types for each color space:

```rust
// nannou
let rgb: Srgb = srgb(1.0, 0.0, 0.0);
let hsv: Hsv = hsv(0.0, 1.0, 1.0);
// Compiler enforces correct usage
```

**Pros:** No runtime errors, self-documenting
**Cons:** More verbose, learning curve

### Pattern 3: Data Class Per Space (openrndr)

Separate classes with conversion methods:

```kotlin
// openrndr
val rgb = ColorRGBa(1.0, 0.0, 0.0)
val hsv = rgb.toHSVa()
val lab = rgb.toLABa()
```

**Pros:** Clear conversions, IDE autocomplete
**Cons:** Many classes to learn

### Pattern 4: Unified Class (toxiclibs/three.js)

Single class with multiple access patterns:

```java
// toxiclibs TColor - access any representation
TColor c = TColor.newHSV(0.0f, 1.0f, 1.0f);
float r = c.red();      // RGB access
float h = c.hue();      // HSV access
float cyan = c.cyan();  // CMYK access
```

**Pros:** Flexible, one type to learn
**Cons:** Memory overhead, implicit conversions

### Pattern 5: Parallel Color Systems (DrawBot)

Separate functions for different color models, allowing explicit choice:

```python
# DrawBot - RGB and CMYK as parallel function families
fill(1, 0, 0)             # RGB red
cmykFill(0, 1, 1, 0)      # CMYK red (for print)

linearGradient(...)       # RGB gradient
cmykLinearGradient(...)   # CMYK gradient (for print)

shadow(...)               # RGB shadow
cmykShadow(...)           # CMYK shadow
```

**Pros:** Explicit print/screen intent, no accidental color space mixing
**Cons:** API surface area doubles, must remember to use correct family

### Constructor Patterns

```javascript
// three.js - Multiple constructor formats
new THREE.Color(0xff0000);           // Hex integer
new THREE.Color("rgb(255, 0, 0)");   // CSS string
new THREE.Color("red");              // X11 color name
new THREE.Color(1, 0, 0);            // RGB components
```

```kotlin
// openrndr - Factory methods
ColorRGBa.fromHex(0xFF0000)
ColorRGBa.fromHex("#ff0000")
ColorRGBa(1.0, 0.0, 0.0)
```

---

## Code Examples: Side-by-Side

### Creating a Red Color

```java
// Processing
color c = color(255, 0, 0);
```

```javascript
// p5.js
let c = color(255, 0, 0);
```

```javascript
// three.js
const c = new THREE.Color(0xff0000);
```

```kotlin
// openrndr
val c = ColorRGBa(1.0, 0.0, 0.0)
```

```rust
// nannou
let c = rgb(1.0, 0.0, 0.0);
```

### HSV Color with Hue Rotation

```java
// Processing
colorMode(HSB, 360, 100, 100);
color c = color(hue + 30, 100, 100);
```

```kotlin
// openrndr
val c = baseColor.toHSVa().shiftHue(30.0).toRGBa()
```

```rust
// nannou
let c = hsv(base_hue + 0.083, 1.0, 1.0);  // 30°/360° = 0.083
```

### Perceptual Color Adjustment

```kotlin
// openrndr - Adjust in LAB space
val adjusted = color.toLABa()
    .copy(l = 75.0)        // Set lightness to 75
    .toRGBa()
```

```hlsl
// tixl (HLSL) - Adjust in OkLab space
float3 lab = RgbToOkLab(color);
lab.x = 0.75;  // Set lightness
float3 result = OklabToRgb(lab);
```

---

## Recommendations for Rust Framework

Based on this analysis, recommendations for a new Rust creative coding framework:

### 1. Use the `palette` Crate

nannou demonstrates this well. Benefits:
- Type-safe color spaces (Srgb, Hsv, Lab, etc.)
- Automatic conversions via traits
- Proper linear/gamma handling
- Well-maintained, comprehensive

### 2. Provide Ergonomic Wrappers

Raw `palette` types can be verbose. Add helper functions:

```rust
// Recommended API
pub fn rgb(r: f32, g: f32, b: f32) -> Srgb<f32>;
pub fn hsv(h: f32, s: f32, v: f32) -> Hsv;
pub fn hex(value: u32) -> Srgb<u8>;
```

### 3. Support Perceptual Color Spaces

Include LAB, LCH, or OkLab for:
- Perceptually uniform gradients
- Intuitive lightness/chroma adjustments
- Better color theory operations

### 4. Consider OkLab for GPU

OkLab is simpler than LAB and designed for GPU implementation. Include shader functions.

### 5. Implement Color Theory Utilities

Take inspiration from toxiclibs:

```rust
pub trait ColorHarmony {
    fn complementary(&self) -> Self;
    fn triadic(&self) -> [Self; 3];
    fn analogous(&self, count: usize, spread: f32) -> Vec<Self>;
    fn split_complementary(&self) -> [Self; 2];
}
```

### 6. Consider Pigment-Based Mixing

For paint-like applications, integrate or learn from [Mixbox](https://github.com/scrtwpns/mixbox):

```rust
// Add as optional dependency
mixbox = "2.0.0"

// Use for natural color gradients
let natural_mix = mixbox::lerp(&color1, &color2, t);
```

Kubelka-Munk mixing is essential for:
- Digital painting tools
- Gradient generation that "feels right"
- Any application targeting artists familiar with physical media

### 7. Handle Linearity Explicitly

Make the distinction clear:

```rust
// Clear naming
pub fn srgb(r: f32, g: f32, b: f32) -> Srgb<f32>;       // Display
pub fn linear_rgb(r: f32, g: f32, b: f32) -> LinSrgb<f32>; // Math

// Or require explicit conversion
let linear = display_color.into_linear();
```

### 8. Flexible Input Parsing

Support multiple formats like three.js:

```rust
impl From<u32> for Color { }           // 0xFF0000
impl From<&str> for Color { }          // "#ff0000", "red"
impl From<(f32, f32, f32)> for Color { } // (1.0, 0.0, 0.0)
```

---

## Key Takeaways

1. **openrndr** has the most comprehensive color system - study it for API design
2. **toxiclibs** has the best color theory - port its strategies to Rust
3. **nannou/palette** shows idiomatic Rust color handling
4. **OkLab** is the modern choice for perceptual color - implement in shaders
5. **Mixbox** enables natural pigment mixing - essential for paint-like applications
6. **DrawBot** demonstrates print-focused color (CMYK) with parallel API pattern
7. **Type safety vs ergonomics** is the key tradeoff - provide both layers
8. **Linear workflow** is essential for correct rendering - make it explicit

---

## References

- [palette crate](https://crates.io/crates/palette) - Rust color library
- [Mixbox](https://github.com/scrtwpns/mixbox) - Pigment-based color mixing (Kubelka-Munk)
- [OkLab by Björn Ottosson](https://bottosson.github.io/posts/oklab/) - Modern perceptual color space
- [toxiclibs color](http://toxiclibs.org/docs/colorutils/) - Color theory reference
- [openrndr color](https://openrndr.org/) - Kotlin color implementation
- [CSS Color Level 4](https://www.w3.org/TR/css-color-4/) - Web color standards
