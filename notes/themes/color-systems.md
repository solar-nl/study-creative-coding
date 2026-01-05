# Theme: Color Systems

> Cross-cutting analysis of how frameworks handle color.

## Concept Overview

Color handling includes:
- Color spaces (RGB, HSL, HSB, Lab, etc.)
- Color modes and interpretation
- Blending and compositing
- Gradients

## Framework Implementations

### Color Spaces Supported

| Framework | Spaces |
|-----------|--------|
| p5.js | RGB, HSB, HSL |
| Processing | RGB, HSB |
| three.js | RGB, HSL (Color class) |
| toxiclibs | RGB, HSV, CMYK, Lab, etc. (TColor) |
| openrndr | RGB, HSL, HSV, XYZ, Lab |
| nannou | sRGB, linear RGB, HSL, HSV |

### Color Mode Pattern

```javascript
// p5.js / Processing
colorMode(HSB, 360, 100, 100);
fill(0, 100, 100);  // Red in HSB
```

```rust
// nannou
draw.ellipse().color(hsla(0.0, 1.0, 0.5, 1.0));
```

## Key Questions

- Linear vs gamma-corrected color?
- How are color conversions handled?
- What blending modes are supported?
- How are gradients created?

## Recommendations for Rust Framework

1. **Type-safe color spaces** — Use Rust types to prevent mixing
2. **Conversion traits** — Easy conversion between spaces
3. **Linear workflow** — Internal linear, convert on input/output
4. **palette crate** — Consider using or learning from
