# Mixbox

> Pigment-based color mixing library using Kubelka-Munk theory.

## Quick Facts

| Property | Value |
|----------|-------|
| **Type** | Color mixing library (not a framework) |
| **Repository** | [scrtwpns/mixbox](https://github.com/scrtwpns/mixbox) |
| **License** | CC BY-NC 4.0 (non-commercial), commercial licenses available |
| **Version** | 2.0.0 |
| **Languages** | Rust, C/C++, C#, Java, JavaScript, Python |
| **Shaders** | GLSL, HLSL, Metal |
| **Engines** | Unity, Godot, Blender |

## Philosophy & Purpose

Mixbox solves the fundamental problem with RGB color mixing:

| Colors | RGB Result | Mixbox Result |
|--------|------------|---------------|
| Blue + Yellow | Gray/Brown | **Green** |
| Red + Blue | Muddy Purple | **Vibrant Purple** |
| Cyan + Magenta | Gray | **Blue** |

Traditional RGB is **additive** (light mixing), but artists expect **subtractive** behavior (pigment mixing). Mixbox simulates real paint behavior using physics-based color theory.

**Target audience:** Digital painting tools, creative coding with natural color gradients, any application where artists expect paint-like color behavior.

## Core Concept: Kubelka-Munk Theory

Kubelka-Munk is a physical optics model that predicts how light interacts with pigmented layers:

```
RGB Input → Latent Pigment Space → Mix → RGB Output
              (via LUT texture)
```

The library uses a **lookup table (LUT)** texture to encode pigment behavior, making GPU implementation efficient.

## Key Entry Points

| File | Purpose |
|------|---------|
| `rust/src/lib.rs` | Rust implementation |
| `c/mixbox.h` | C/C++ header |
| `glsl/mixbox.glsl` | GLSL shader include |
| `hlsl/mixbox.hlsl` | HLSL shader include |
| `mixbox_lut.png` | Pigment LUT texture (required for shaders) |

## Available Pigments

| Pigment | RGB | Linear RGB |
|---------|-----|------------|
| Cadmium Yellow | 254, 236, 0 | 0.996, 0.925, 0.0 |
| Hansa Yellow | 252, 211, 0 | 0.988, 0.827, 0.0 |
| Cadmium Orange | 255, 105, 0 | 1.0, 0.412, 0.0 |
| Cadmium Red | 255, 39, 2 | 1.0, 0.153, 0.008 |
| Quinacridone Magenta | 128, 2, 46 | 0.502, 0.008, 0.180 |
| Cobalt Violet | 78, 0, 66 | 0.306, 0.0, 0.259 |
| Ultramarine Blue | 25, 0, 89 | 0.098, 0.0, 0.349 |
| Cobalt Blue | 0, 33, 133 | 0.0, 0.129, 0.522 |
| Phthalo Blue | 13, 27, 68 | 0.051, 0.106, 0.267 |
| Phthalo Green | 0, 60, 50 | 0.0, 0.235, 0.196 |
| Permanent Green | 7, 109, 22 | 0.027, 0.427, 0.086 |
| Sap Green | 107, 148, 4 | 0.420, 0.580, 0.016 |
| Burnt Sienna | 123, 72, 0 | 0.482, 0.282, 0.0 |

## Study Questions

- [x] What problem does Mixbox solve? → RGB mixing produces muddy colors
- [x] How does it work? → Kubelka-Munk theory via LUT texture
- [x] What platforms are supported? → Rust, C/C++, shaders (GLSL/HLSL/Metal)
- [ ] How does the latent space encoding work?
- [ ] What are the performance characteristics vs standard lerp?
- [ ] How to integrate with existing color pipelines?

## Comparison with Standard Mixing

| Aspect | RGB Lerp | Mixbox |
|--------|----------|--------|
| Speed | Fastest | Slightly slower (LUT lookup) |
| Results | Additive (light) | Subtractive (pigment) |
| Blue + Yellow | Gray | Green |
| GPU Support | Native | Requires LUT texture |
| Use Case | UI, technical | Artistic, painting |

## Production Usage

- **Rebelle 5 Pro** - Digital painting software (as "Rebelle Pigments")
- **Blender Flip Fluids** - Fluid simulation addon
