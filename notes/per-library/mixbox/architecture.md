# Mixbox - Architecture (Demystified)

## Overview

Mixbox is a **color mixing library** that simulates pigment-based color blending using Kubelka-Munk theory. This document explains exactly how it works, including the polynomial coefficients, the LUT structure, and why certain design choices were made.

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
│            Polynomial evaluation + residual                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## The 7-Dimensional Latent Space (Decoded)

Mixbox uses a 7-dimensional representation:

```
Latent = [c0, c1, c2, c3, residual_r, residual_g, residual_b]
```

| Index | Name | Meaning |
|-------|------|---------|
| 0 | `c0` | **Phthalo Blue** pigment concentration |
| 1 | `c1` | **Hansa Yellow** pigment concentration |
| 2 | `c2` | **Quinacridone Magenta** pigment concentration |
| 3 | `c3` | **Titanium White** = `1 - c0 - c1 - c2` |
| 4 | `residual_r` | Red channel correction |
| 5 | `residual_g` | Green channel correction |
| 6 | `residual_b` | Blue channel correction |

The residual captures colors that can't be represented by the pigment model (e.g., pure RGB green, black).

---

## The Polynomial (Fully Exposed)

The RGB reconstruction uses a **20-term 3rd-order polynomial** in 4 variables. These coefficients are the core of Mixbox:

```rust
fn eval_polynomial(c0: f32, c1: f32, c2: f32, c3: f32) -> [f32; 3] {
    // Precompute products
    let c00 = c0 * c0;  let c11 = c1 * c1;
    let c22 = c2 * c2;  let c33 = c3 * c3;
    let c01 = c0 * c1;  let c02 = c0 * c2;  let c12 = c1 * c2;

    let (mut r, mut g, mut b) = (0.0, 0.0, 0.0);

    // === CUBIC TERMS: Pure pigment colors ===
    // c0³: Phthalo Blue
    let w = c0 * c00;
    r += 0.07717053 * w;  g += 0.02826978 * w;  b += 0.24832992 * w;

    // c1³: Hansa Yellow
    let w = c1 * c11;
    r += 0.95912302 * w;  g += 0.80256528 * w;  b += 0.03561839 * w;

    // c2³: Quinacridone Magenta
    let w = c2 * c22;
    r += 0.74683774 * w;  g += 0.04868586 * w;  b += 0.00000000 * w;

    // c3³: Titanium White (≈ 1, 1, 1)
    let w = c3 * c33;
    r += 0.99518138 * w;  g += 0.99978149 * w;  b += 0.99704802 * w;

    // === INTERACTION TERMS: Non-linear mixing (Kubelka-Munk behavior) ===
    // Blue × Yellow interactions → GREEN emerges here!
    let w = c00 * c1; r += 0.04819146*w; g += 0.83363781*w; b += 0.32515377*w;
    let w = c01 * c1; r += -0.68146950*w; g += 1.46107803*w; b += 1.06980936*w;

    // Blue × Magenta
    let w = c00 * c2; r += 0.27058419*w; g += -0.15324870*w; b += 1.98735057*w;
    let w = c02 * c2; r += 0.80478189*w; g += 0.67093710*w; b += 0.18424500*w;

    // Blue × White
    let w = c00 * c3; r += -0.35031003*w; g += 1.37855826*w; b += 3.68865000*w;
    let w = c0 * c33; r += 1.05128046*w; g += 1.97815239*w; b += 2.82989073*w;

    // Yellow × Magenta → Orange/Red
    let w = c11 * c2; r += 3.21607125*w; g += 0.81270228*w; b += 1.03384539*w;
    let w = c1 * c22; r += 2.78893374*w; g += 0.41565549*w; b += -0.04487295*w;

    // Yellow × White
    let w = c11 * c3; r += 3.02162577*w; g += 2.55374103*w; b += 0.32766114*w;
    let w = c1 * c33; r += 2.95124691*w; g += 2.81201112*w; b += 1.17578442*w;

    // Magenta × White
    let w = c22 * c3; r += 2.82677043*w; g += 0.79933038*w; b += 1.81715262*w;
    let w = c2 * c33; r += 2.99691099*w; g += 1.22593053*w; b += 1.80653661*w;

    // Three-way interactions
    let w = c01 * c2; r += 1.87394106*w; g += 2.05027182*w; b += -0.29835996*w;
    let w = c01 * c3; r += 2.56609566*w; g += 7.03428198*w; b += 0.62575374*w;
    let w = c02 * c3; r += 4.08329484*w; g += -1.40408358*w; b += 2.14995522*w;
    let w = c12 * c3; r += 6.00078678*w; g += 2.55552042*w; b += 1.90739502*w;

    [r, g, b]
}
```

**Key insight**: The interaction terms encode subtractive mixing. Note how `c0 * c1` (blue × yellow) produces high green values — this is where "blue + yellow = green" comes from!

---

## Why the LUT Exists

### What the LUT Does

The LUT (`lut.dat`, 786KB) maps RGB → (c0, c1, c2) pigment concentrations. It's a 64×64×64 3D lookup table.

### Why Not Just Invert the Polynomial?

We attempted to create a LUT-free implementation using Newton-Raphson inversion. **It produces subtractive mixing, but with errors:**

| Colors | LUT-free Result | Mixbox (LUT) | Error |
|--------|-----------------|--------------|-------|
| Blue + Yellow | (39, 121, 89) | (41, 130, 57) | 43 |
| Red + Blue | (83, 49, 75) | (85, 47, 58) | 21 |
| Yellow + Magenta | (192, 92, 38) | (192, 93, 37) | **2** |

### The Problem: Multiple Valid Decompositions

The polynomial is **not injective** — many pigment combinations produce the same RGB color:

**Cobalt Blue RGB(0, 33, 133):**
| Source | c0 (blue) | c1 (yellow) | c2 (magenta) |
|--------|-----------|-------------|--------------|
| **Mixbox LUT** | 0.864 | **0.005** | 0.030 |
| Newton-Raphson | 0.763 | **0.234** | 0.000 |

Both reconstruct the color correctly! But Newton-Raphson adds yellow to blue, which produces wrong results when mixing with actual yellow.

### The LUT is Optimized for Mixing

The LUT encodes decompositions that are **optimized for mixing quality**, not just color reconstruction. This is learned/trained data that cannot be recovered from the polynomial alone.

---

## Colors Outside the Pigment Gamut

Some RGB colors can't be represented by the pigment model. The residual handles these:

| Color | Polynomial Predicts | Actual RGB | Residual |
|-------|---------------------|------------|----------|
| White | (0.995, 1.0, 0.997) | (1, 1, 1) | ~0 |
| Gray | (0.502, 0.502, 0.502) | (0.5, 0.5, 0.5) | ~0 |
| **Black** | (0.22, 0.22, 0.22) | (0, 0, 0) | **-0.22** |
| **Pure RGB Green** | (0.30, 0.63, 0.24) | (0, 1, 0) | **large** |

Black and saturated RGB colors require large residuals because they're outside the pigment gamut.

---

## LUT-Free Implementation Attempts

We tried several strategies to match Mixbox without the LUT:

### 1. Newton-Raphson Inversion
Finds *a* valid decomposition, but not the *optimal* one for mixing.

### 2. Multiple Starting Points
Tries 8+ initial guesses, picks lowest error. Helps slightly.

### 3. Semantic Prior
Penalizes "wrong" decompositions (e.g., yellow in blue colors). **Nails the decomposition but breaks mixing.**

### 4. Sparsity Regularization
Prefers sparse solutions (one dominant pigment). Partial success.

### Conclusion

The LUT contains information that **cannot be recovered algorithmically** from the polynomial. It encodes learned pigment physics optimized for mixing outcomes.

---

## What Would Enable LUT-Free Mixing

To match Mixbox without the LUT, you would need:

1. **Spectral Kubelka-Munk**: Actual K(λ) and S(λ) curves for each pigment
2. **Neural network trained on LUT samples**: Small MLP can approximate the mapping
3. **The same optimization procedure** used to create the original LUT

---

## Module Structure

```
mixbox/
├── rust/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs          # Rust implementation
│       └── lut.dat         # Embedded LUT (786KB)
├── c/
│   ├── mixbox.h            # C/C++ header
│   └── mixbox.c            # C implementation
├── glsl/
│   └── mixbox.glsl         # GLSL shader
├── hlsl/
│   └── mixbox.hlsl         # HLSL shader
├── metal/
│   └── mixbox.metal        # Metal shader
└── mixbox_lut.png          # LUT texture for GPU
```

---

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **LUT for RGB→pigments** | Polynomial inversion is ambiguous; LUT encodes optimal decomposition |
| **Polynomial for pigments→RGB** | 60 coefficients, fast to evaluate |
| **7D latent space** | 4 pigments + 3 residual channels covers full RGB gamut |
| **Residual channels** | Handle colors outside pigment gamut |
| **64³ LUT resolution** | Good tradeoff between size (786KB) and accuracy |

---

## Key Insight

> **The "magic" is not in the polynomial — it's in the LUT.**
>
> The polynomial coefficients are visible and encode Kubelka-Munk physics.
> The LUT encodes *which* decomposition to use for each color, optimized for mixing.
> This is learned data, not derivable from first principles.

---

## References

- [Mixbox Paper](https://scrtwpns.com/mixbox.pdf) - Sochorová & Jamriška
- [Kubelka-Munk Theory](https://en.wikipedia.org/wiki/Kubelka–Munk_theory)
- `compare_with_mixbox/` - Our LUT-free experiments
- `pigment_mixing_explained.rs` - Educational implementation
