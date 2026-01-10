# Building Your Own Mixbox-Style LUT

Based on the paper "Practical Pigment Mixing for Digital Painting" (Sochorová & Jamriška, 2021), here's the complete recipe for constructing your own pigment mixing LUT.

---

## Overview

The LUT construction is NOT a global optimization over mixing pairs (as we hypothesized). It's simpler:

```
For each RGB color:
    c = unmix(RGB)     ← Newton solver finds pigment concentrations
    store c[0:3]       ← c[4] is implicit (1 - c1 - c2 - c3)
```

The "magic" comes from:
1. **Spectral data** for real pigments (K and S curves)
2. **Surrogate pigment optimization** to fit within sRGB gamut
3. **Polynomial fitting** for fast runtime evaluation

---

## Required Data

### 1. Pigment Spectral Coefficients

For each pigment, you need K(λ) and S(λ) curves:
- **K(λ)**: Absorption coefficient per wavelength
- **S(λ)**: Scattering coefficient per wavelength
- **Wavelengths**: 380-750nm in 10nm steps (36 samples)

**Sources:**
- [Artist Paint Spectral Database (Berns 2016)](https://www.rit.edu/science/sites/rit.edu.science/files/2019-03/ArtistSpectralDatabase.pdf)
- [Okumura Thesis (2005)](https://repository.rit.edu/theses/4892/)
- Measure yourself with a spectrophotometer

**Mixbox uses:**
- PB15:4 (Phthalo Blue)
- PY73 (Hansa Yellow)
- PR122 (Quinacridone Magenta)
- PW6 (Titanium White)

### 2. Standard Colorimetric Data

- **CIE Standard Observer**: x̄(λ), ȳ(λ), z̄(λ) functions
- **D65 Illuminant**: Standard daylight spectrum
- **Saunderson Constants**: k₁ = 0.03, k₂ = 0.65 (from Berns database)

---

## The Kubelka-Munk Pipeline

### Step 1: Mix K and S (Equation 1)

```python
def mix_KS(concentrations, pigments):
    K_mix = np.zeros(36)  # 36 wavelengths
    S_mix = np.zeros(36)

    for i, (K, S) in enumerate(pigments):
        K_mix += concentrations[i] * K
        S_mix += concentrations[i] * S

    return K_mix, S_mix
```

### Step 2: K-M Reflectance (Equation 2)

```python
def km_reflectance(K, S):
    # For thick, opaque layer
    KS = K / S
    R = 1 + KS - np.sqrt(KS**2 + 2*KS)
    return R
```

### Step 3: Saunderson Correction (Equation 6)

```python
def saunderson(R, k1=0.03, k2=0.65):
    # Accounts for surface reflection
    R_prime = (1 - k1) * (1 - k2) * R / (1 - k2 * R)
    return R_prime
```

### Step 4: Spectrum to XYZ (Equations 3-5)

```python
def spectrum_to_XYZ(R_prime, D65, observer):
    X = np.trapz(observer.x * D65 * R_prime, dx=10)
    Y = np.trapz(observer.y * D65 * R_prime, dx=10)
    Z = np.trapz(observer.z * D65 * R_prime, dx=10)
    return X, Y, Z
```

### Step 5: XYZ to sRGB (Equation 7)

```python
def XYZ_to_sRGB(X, Y, Z, Y_D65):
    M = np.array([
        [+3.2406, -1.5372, -0.4986],
        [-0.9689, +1.8758, +0.0415],
        [+0.0557, -0.2040, +1.0570]
    ])
    RGB = M @ np.array([X, Y, Z]) / Y_D65
    return RGB
```

### Complete mix() Function

```python
def mix(concentrations, pigments, D65, observer, Y_D65):
    K, S = mix_KS(concentrations, pigments)
    R = km_reflectance(K, S)
    R_prime = saunderson(R)
    X, Y, Z = spectrum_to_XYZ(R_prime, D65, observer)
    RGB = XYZ_to_sRGB(X, Y, Z, Y_D65)
    return RGB
```

---

## The unmix() Function (Equation 9)

```python
from scipy.optimize import minimize

def unmix(target_RGB, pigments, D65, observer, Y_D65):
    def objective(c):
        c4 = 1 - c[0] - c[1] - c[2]
        if c4 < 0:
            return 1e10
        concentrations = [c[0], c[1], c[2], c4]
        predicted = mix(concentrations, pigments, D65, observer, Y_D65)
        return np.sum((predicted - target_RGB)**2)

    # Constraints: ci >= 0, sum = 1
    constraints = [
        {'type': 'ineq', 'fun': lambda c: c[0]},
        {'type': 'ineq', 'fun': lambda c: c[1]},
        {'type': 'ineq', 'fun': lambda c: c[2]},
        {'type': 'ineq', 'fun': lambda c: 1 - c[0] - c[1] - c[2]},
    ]

    result = minimize(
        objective,
        x0=[0.25, 0.25, 0.25],  # Initial guess
        method='L-BFGS-B',
        bounds=[(0, 1), (0, 1), (0, 1)]
    )

    c = result.x
    return [c[0], c[1], c[2], 1 - c[0] - c[1] - c[2]]
```

---

## Surrogate Pigments (Section 3.1)

Real pigments produce colors **outside sRGB gamut**. The paper optimizes modified "surrogate" pigments Q* that stay within gamut:

```python
def optimize_surrogates(P_star, alpha=1e5):
    """
    Minimize: E_push(Q) + α * E_pull(Q, P*)

    E_push: Penalize gamut boundary outside RGB cube
    E_pull: Keep surrogates perceptually close to originals
    """
    Q = P_star.copy()  # Start with original pigments

    while not gamut_fits_in_RGB(Q):
        # Optimize with current alpha
        Q = L_BFGS_B_optimize(Q, P_star, alpha)
        alpha /= 2

    return Q
```

---

## Building the LUT

### Step 1: Optimize Surrogate Pigments

```python
Q_star = optimize_surrogates(P_star)
```

### Step 2: Generate LUT

```python
def build_lut(pigments, resolution=64):
    lut = np.zeros((resolution, resolution, resolution, 3))

    for r in range(resolution):
        for g in range(resolution):
            for b in range(resolution):
                rgb = np.array([r, g, b]) / (resolution - 1)
                c = unmix(rgb, pigments, D65, observer, Y_D65)
                lut[r, g, b] = c[:3]  # Store c0, c1, c2 (c3 is implicit)

    return lut
```

### Step 3: Fit Polynomial (Optional, for Speed)

```python
def fit_polynomial(pigments, num_samples=100000):
    """
    Generate samples and fit 3rd-order polynomial.
    This replaces the expensive spectral integration at runtime.
    """
    X = []  # Input: concentrations
    Y = []  # Output: RGB

    for _ in range(num_samples):
        c = random_concentrations()  # Sum to 1
        rgb = mix(c, pigments, D65, observer, Y_D65)
        X.append([c[0], c[1], c[2], c[3]])
        Y.append(rgb)

    # Fit 20-term polynomial (see architecture.md for terms)
    coefficients = polynomial_regression(X, Y, degree=3)
    return coefficients
```

---

## File Sizes

| Component | Size |
|-----------|------|
| LUT (64³ × 3 × 8-bit) | 786 KB |
| LUT compressed (PNG) | ~350 KB |
| Polynomial (60 coefficients) | 240 bytes |

---

## Alternative: Using Mixbox's LUT as Training Data

If you can't get spectral data, you can:

1. **Sample Mixbox's LUT** exhaustively (64³ = 262,144 points)
2. **Train a neural network**: RGB → (c0, c1, c2)
3. **Use the same polynomial** for decoding

```python
def train_neural_unmix():
    X = []  # RGB inputs
    Y = []  # Concentration outputs

    for r in range(64):
        for g in range(64):
            for b in range(64):
                rgb = [r*4, g*4, b*4]
                latent = mixbox.rgb_to_latent(rgb)
                X.append(rgb)
                Y.append(latent[:3])

    # Train small MLP: 3 → 32 → 32 → 3
    model = MLP([3, 32, 32, 3])
    model.fit(X, Y)
    return model
```

---

## Summary

To build your own LUT:

1. **Get K(λ), S(λ) data** for 4 pigments (or use neural approximation)
2. **Implement full K-M pipeline**: mix() and unmix()
3. **Optimize surrogate pigments** to fit sRGB gamut
4. **Generate LUT**: unmix() for all 64³ RGB colors
5. **Fit polynomial** for fast runtime decoding
6. **Compress** as PNG for distribution

The paper shows this is straightforward—the complexity is in getting quality spectral data.

---

## Sources

- [Mixbox Paper (Sochorová & Jamriška, 2021)](https://dl.acm.org/doi/10.1145/3478513.3480549)
- [Artist Paint Spectral Database (Berns 2016)](https://www.rit.edu/science/sites/rit.edu.science/files/2019-03/ArtistSpectralDatabase.pdf)
- [Okumura Thesis](https://repository.rit.edu/theses/4892/)
- [Spectral Paint Curves with ML (Wander)](https://larswander.com/writing/spectral-paint-curves/)
