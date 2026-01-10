# Reverse Engineering the Mixbox Model

## Executive Summary

We successfully reverse engineered the key aspects of Mixbox's pigment mixing algorithm. Our findings:

1. **The polynomial is fully transparent** - all 60 coefficients are exposed
2. **The LUT encodes optimized decompositions** - not just valid, but optimal for mixing
3. **White (c3) acts as a catalyst** - enables critical three-way interactions
4. **The optimization is global** - considers ALL pairwise mixing outcomes

---

## The Three Layers of Mixbox

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: THE POLYNOMIAL (Fully Transparent)                    │
│  - 20 terms, 60 coefficients                                    │
│  - Maps pigments → RGB                                          │
│  - Encodes Kubelka-Munk physics                                 │
└─────────────────────────────────────────────────────────────────┘
                              ↕
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2: THE LUT (The "Secret Sauce")                          │
│  - 64³ entries = 262,144 decompositions                         │
│  - Maps RGB → pigments                                          │
│  - Optimized for mixing, not just reconstruction                │
└─────────────────────────────────────────────────────────────────┘
                              ↕
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: THE OPTIMIZATION OBJECTIVE (Inferred)                 │
│  - Minimize complementary contamination                         │
│  - Preserve white component for interaction effects             │
│  - Global optimization over all color pairs                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Discovery 1: Complementary Contamination

The LUT systematically avoids putting complementary pigments together:

| Color Type | LUT c1 (yellow) | Newton-Raphson c1 |
|------------|-----------------|-------------------|
| Blue colors | 0.015 (avg) | 0.024 (avg) |
| Cobalt Blue | 0.005 | 0.075 |

**Why this matters**: When blue mixes with yellow, the c0×c1 interaction term produces green. If blue already contains yellow, less "new" yellow is added during mixing, reducing the interaction effect.

---

## Key Discovery 2: White as Catalyst

The three-way interaction term `c0 × c1 × c3` has coefficient **7.03** for the green channel!

| Blue Variant | c3 (white) | Mixed Green Output |
|--------------|------------|--------------------|
| LUT-like | 0.11 | 0.509 |
| No white | 0.00 | 0.371 |
| More white | 0.21 | 0.582 |

**Physical interpretation**: White pigment (titanium dioxide) is highly scattering. Light bounces around inside the paint film more, enabling more pigment interactions. The polynomial captures this physics.

---

## Key Discovery 3: Three-Way Interactions

The polynomial's most powerful terms for color mixing:

| Term | R Coeff | G Coeff | B Coeff | Effect |
|------|---------|---------|---------|--------|
| c0·c1·c3 | 2.57 | **7.03** | 0.63 | Blue×Yellow×White → GREEN |
| c1·c2·c3 | 6.00 | 2.56 | 1.91 | Yellow×Magenta×White → RED |
| c0·c2·c3 | 4.08 | -1.40 | 2.15 | Blue×Magenta×White → PURPLE |

These three-way interactions are the "magic" of subtractive mixing!

---

## Why LUT-Free Approaches Fail

### Attempt 1: Newton-Raphson Inversion
- **Problem**: Finds ANY valid decomposition, not the OPTIMAL one
- **Result**: c3 ≈ 0 for saturated colors, killing three-way interactions

### Attempt 2: Semantic Prior
- **Problem**: Penalizes wrong pigments but doesn't preserve c3
- **Result**: Better decomposition, worse mixing (error increased!)

### Attempt 3: Complementary Prior
- **Problem**: Minimizes contamination but still doesn't optimize c3
- **Result**: Similar decomposition to LUT, but c3 still wrong

### The Core Issue
All local optimization approaches fail because the optimal decomposition depends on **how the color will be mixed with other colors** — a global property.

---

## The Actual LUT Construction (From the Paper!)

After reading the paper, we discovered our hypothesis was **partially wrong**. The LUT is NOT a global optimization over mixing pairs. It's simpler:

```
For each RGB color:
    c = unmix(RGB)     ← Newton solver minimizes ||mix(c) - RGB||²
    store c[0:3]       ← c[4] is implicit (1 - c0 - c1 - c2)
```

**The "magic" comes from:**

1. **Spectral K-M mixing**: The mix() function uses real pigment spectral data
2. **Surrogate pigment optimization**: Real pigments exceed sRGB gamut, so they optimize modified "surrogate" pigments that stay within bounds
3. **The polynomial is FITTED**: Generated from thousands of spectral K-M evaluations

The complementary contamination we observed is an **emergent property** of the K-M physics, not an explicit optimization objective!

---

## Paths to LUT-Free Mixing

### Path 1: Build Your Own LUT (Now Possible!)

With the paper's recipe:
```
1. Get K(λ), S(λ) data for 4 pigments
2. Implement spectral K-M: mix() and unmix()
3. Optimize surrogate pigments to fit sRGB
4. Generate LUT: unmix() for all 64³ colors
5. Fit polynomial for fast decoding
```

See [building_your_own_lut.md](building_your_own_lut.md) for details.

### Path 2: Neural Network Distillation
```
Train: RGB → (c0, c1, c2)
Data: Sample all 262,144 LUT entries from Mixbox
Model: Small MLP (3 → 32 → 32 → 3)
Size: ~4KB weights vs 786KB LUT
```

### Path 3: Spectral Kubelka-Munk (Runtime)
```
For each pigment, store:
  K(λ) - absorption spectrum (380-780nm, 36 samples)
  S(λ) - scattering spectrum

Mix spectrally at runtime (slower but LUT-free):
  K_mix(λ) = Σ ci × Ki(λ)
  S_mix(λ) = Σ ci × Si(λ)
  R(λ) = 1 + K/S - sqrt((K/S)² + 2K/S)

Convert to RGB via CIE color matching + Saunderson correction
```

### Challenge: Getting Spectral Data

The K and S coefficients may be proprietary. Options:
- [Berns database](https://www.rit.edu/science/sites/rit.edu.science/files/2019-03/ArtistSpectralDatabase.pdf) (academic)
- Measure with spectrophotometer
- Fit from Mixbox samples (reverse engineer K/S from LUT)

---

## What the Paper Actually Contains

The Mixbox paper (Sochorová & Jamriška, SIGGRAPH 2021) describes:

1. **Pigment Selection**: Phthalo Blue, Hansa Yellow, Quinacridone Magenta, Titanium White
   - Chosen for wide gamut coverage (suggested by Briggs 2007)
   - Uses Golden Artist acrylics: PB15:4, PY73, PR122, PW6

2. **Spectral Data Source**: Artist Paint Spectral Database [Berns 2016]
   - K(λ) and S(λ) sampled at 380-750nm in 10nm increments
   - Saunderson constants: k₁ = 0.03, k₂ = 0.65

3. **Surrogate Pigment Optimization**: Key innovation!
   - Real pigments exceed sRGB gamut
   - Optimizes Q* to fit within RGB cube while staying close to P*
   - Uses Oklab for perceptual distance

4. **LUT Generation**: Simply unmix() for each RGB color
   - Newton solver with L-BFGS-B
   - 64³ resolution (not 256³)
   - Only 3 concentrations stored (4th is implicit)

5. **Polynomial Fitting**: Not explicitly described, but implied
   - Fitted to approximate the spectral mix() function
   - Enables fast runtime without spectral integration

---

## Conclusion

The Mixbox model is elegant in its design:
- **Simple forward pass**: Polynomial evaluation + residual
- **Complex inverse pass**: Globally optimized LUT

The "magic" is not in hiding information—the polynomial is fully exposed. The magic is in the **optimization that created the LUT**, which considers the global structure of color mixing rather than just local reconstruction accuracy.

To fully replicate Mixbox without the LUT, one would need either:
1. Access to the same ground truth data (spectral measurements)
2. A way to train on the existing LUT (neural network)
3. A spectral simulation with accurate pigment data

---

## Experimental Code

All experiments are in `compare_with_mixbox/`:

| File | Purpose |
|------|---------|
| `main.rs` | Basic comparison with mixbox |
| `analyze_lut.rs` | LUT structure analysis |
| `improved.rs` | Multi-start optimization |
| `semantic.rs` | Semantic prior approach |
| `reverse_engineer.rs` | Comprehensive reverse engineering |
| `complementary_prior.rs` | Complementary contamination approach |
| `global_analysis.rs` | Polynomial term analysis |

Run any experiment:
```bash
cargo run --bin reverse_engineer
cargo run --bin global_analysis
```
