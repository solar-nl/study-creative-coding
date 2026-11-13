# Tixl Shared HLSL Library

Every graphics system eventually accumulates a bag of functions it needs everywhere: noise to break up uniformity, quaternion math to orient particles, PBR equations to shade surfaces. In tixl, that accumulation lives in `Resources/shared/` — twelve HLSL files that any operator shader can include. Understanding this library reveals both the rendering capabilities and the design priorities of the system.

The shared library is organized around a deliberate division of concerns. Math that belongs together stays together: quaternion operations are isolated from hash functions, PBR rendering is split from its supporting BRDF formulas, and color science has its own file. This is not academic tidiness. It serves a practical purpose: shader compilation in DirectX 11 is expensive. Keeping files small means an operator that only needs hashes does not compile noise math, quaternion code, or PBR equations it will never use.

Think of these files like a C standard library, but purpose-built for real-time creative coding. You include what you need, nothing more. The flip side is that there is no automatic dependency resolution — if `pbr-render.hlsl` uses `point-light.hlsl`, the operator's shader must `#include` both.

The twelve files break into four conceptual clusters: data structures (point, point-legacy, point-light, SpriteDef), mathematics (quat-functions, bias-functions, hash-functions, noise-functions), color science (color-functions, blend-functions), and rendering (pbr, pbr-render).

## Include Dependency Graph

```
pbr-render.hlsl
    └── (requires) pbr.hlsl
            └── (constants) Fdielectric, PI, Epsilon

color-functions.hlsl
    └── (standalone)

blend-functions.hlsl
    └── (standalone)

bias-functions.hlsl
    └── (standalone)

hash-functions.hlsl
    └── (standalone)

noise-functions.hlsl
    └── (standalone)

quat-functions.hlsl (full version)
    └── (standalone)

point-legacy.hlsl (legacy version of quat + point)
    └── (duplicate of quat functions + LegacyPoint struct)

point.hlsl
    └── (standalone)

point-light.hlsl
    └── (standalone)

SpriteDef.hlsl
    └── (standalone)
```

The only true dependency is `pbr-render.hlsl → pbr.hlsl`. The rest are independently includable, though operators using the particle/point systems must include both `point.hlsl` and `quat-functions.hlsl` to have the full picture. The legacy variant `point-legacy.hlsl` is a single-file package that includes the older quaternion functions inline — a historical consolidation for shaders that predate the refactoring.

Operators reference these files with include paths relative to the tixl resource root:

```hlsl
// Typical shader preamble in an operator-specific HLSL file
#include "shared/point.hlsl"
#include "shared/quat-functions.hlsl"
#include "shared/noise-functions.hlsl"
```

The resource compilation system resolves these paths from the application's known resource directories. Shader sources in `Operators/Lib/Resources/` and the root `Resources/shared/` are on the search path.

---

## 1. `point.hlsl` — Core Data Structures

**Path:** `Operators/Lib/Assets/shaders/shared/point.hlsl`

This file is the canonical definition of tixl's three primary particle/point data types. It uses a header guard (`#ifndef __POINT__`) so it can be safely included multiple times.

The three structs share the same memory layout concept: 16 bytes of position data, 16 bytes of rotation quaternion, 16 bytes of color, and 16 bytes of additional attributes. This 64-byte stride aligns well with GPU cache lines and simplifies compute shader indexing.

```hlsl
struct LegacyPoint {
    float3 Position;
    float  W;           // historically: radius
    float4 Rotation;
    float4 Color;
    float3 Stretch;     // historically: velocity
    float  Selected;    // historically: birth time
};

struct Point {
    float3 Position;
    float  FX1;         // general-purpose float (e.g. scale scalar)
    float4 Rotation;
    float4 Color;
    float3 Scale;       // non-uniform XYZ scale
    float  FX2;         // general-purpose float
};

struct Particle {
    float3 Position;
    float  Radius;
    float4 Rotation;
    float4 Color;
    float3 Velocity;
    float  BirthTime;
};
```

The comment in `point.hlsl` explains the semantic aliasing: `LegacyPoint` reused W, Stretch, and Selected for different purposes depending on context (particles vs. display points). `Point` formalizes this into `FX1` and `FX2` as explicitly general-purpose fields, while pulling `Scale` out to be non-uniform. `Particle` makes the physics semantics explicit with `Velocity` and `BirthTime`.

The file also defines useful constants and macros:

```hlsl
#define QUATERNION_IDENTITY float4(0, 0, 0, 1)

#ifndef PI
#define PI 3.14159265359f
#endif

#ifndef TAU
#define TAU (3.14159265359f / 180)   // Note: this is π/180, i.e. degrees-to-radians
#endif

const static float NAN = sqrt(-1);   // GPU NaN sentinel for "uninitialized"

#ifndef mod
#define mod(x, y) ((x) - (y) * floor((x) / (y)))  // GLSL-compatible modulo
#endif
```

Note that `TAU` is defined as `π/180` (a degree-to-radian conversion factor) rather than the more common `2π`. This is unusual — TAU conventionally means `2π` in mathematics. In practice this definition is used inside the quaternion functions for degree-based angle conversions.

The `NAN` sentinel is a deliberate design choice. Particle systems use NaN positions to mark dead particles, and the GPU rasterizer discards NaN primitives silently. This avoids the overhead of a separate "alive" flag and branch.

---

## 2. `point-legacy.hlsl` — Legacy Point with Inline Quaternion Math

**Path:** `Resources/shared/point-legacy.hlsl`

This is an older monolithic file predating the split into `point.hlsl` and `quat-functions.hlsl`. It defines `LegacyPoint` and inlines a subset of quaternion operations directly. Newer operator shaders should prefer `point.hlsl` + `quat-functions.hlsl`.

The struct definition here uses lowercase field names (`position`, `rotation`, `velocity`, `extra`) compared to the title-case names in `point.hlsl`. This reflects a naming convention evolution.

```hlsl
struct LegacyPoint {
    float3 position;
    float  w;
    float4 rotation;
    float4 color;
    float3 velocity;
    float  extra;
};
```

The file includes the same `QUATERNION_IDENTITY`, `PI`, `mod`, and `NAN` definitions, and a subset of quaternion functions (`q_separate_v`, `q_encode_v`, `qMul`, `qRotateVec3`).

**Function signatures:**

| Function | Signature | Purpose |
|---|---|---|
| `q_separate_v` | `float q_separate_v(float4 q, out float4 normalized)` | Separate scale (length-1) from quaternion, returns scale-1 |
| `q_encode_v` | `float4 q_encode_v(float4 q, float v)` | Encode a scalar into quaternion magnitude |
| `qMul` | `float4 qMul(float4 q1, float4 q2)` | Quaternion multiplication |
| `qRotateVec3` | `float3 qRotateVec3(float3 v, float4 q)` | Rotate a 3D vector by a quaternion |

---

## 3. `quat-functions.hlsl` — Complete Quaternion Math

**Path:** `Operators/Lib/Assets/shaders/shared/quat-functions.hlsl`

This is the full quaternion library. Quaternions in tixl are stored as `float4(x, y, z, w)` — the XYZW convention. The identity quaternion is `(0, 0, 0, 1)`.

The mental model for quaternions: they represent 3D rotations as a 4D unit vector. Composing rotations is quaternion multiplication. Rotating a vector is the "sandwich product" — a conjugation. Interpolating rotations uses SLERP (spherical linear interpolation), which moves along the great circle between two orientations rather than linearly interpolating components.

### Function Reference

| Function | Signature | Notes |
|---|---|---|
| `q_separate_v` | `float q_separate_v(float4 q, out float4 normalized)` | Returns length-1, writes normalized quat. Used to store a scalar in quaternion magnitude |
| `q_encode_v` | `float4 q_encode_v(float4 q, float v)` | Encodes scalar v into quat magnitude: `q * (v + 1)` |
| `qMul` | `float4 qMul(float4 q1, float4 q2)` | Hamilton product of two quaternions |
| `qRotateVec3` | `float3 qRotateVec3(float3 v, float4 q)` | Rotate v by q. Uses the fast method from molecular-matters.com: `v + q.w*t + cross(q.xyz, t)` where `t = 2*cross(q.xyz, v)` |
| `qConjugate` | `float4 qConjugate(float4 q)` | Returns `(-x, -y, -z, w)` — inverse of unit quaternion |
| `qInverse` | `float4 qInverse(float4 q)` | `conjugate / dot(q, q)` — general inverse for non-unit quaternions |
| `qFromAngleAxis` | `float4 qFromAngleAxis(float angle, float3 axis)` | Construct from angle (radians) and axis |
| `qFromVectors` | `float4 qFromVectors(float3 v1, float3 v2)` | Rotation that takes v1 to v2; handles antiparallel case |
| `qLookAt` | `float4 qLookAt(float3 forward, float3 up)` | Rotation from a look-at matrix |
| `qSlerp` | `float4 qSlerp(float4 a, float4 b, float t)` | Spherical interpolation; degrades to LERP for small angles |
| `qFromEuler` | `float4 qFromEuler(float yaw, float pitch, float roll)` | Euler to quaternion (ZYX convention) |
| `qToMatrix` | `float4x4 qToMatrix(float4 quat)` | Quaternion to column-major 4x4 matrix |
| `quaternion_to_tmatrix` | `float4x4 quaternion_to_tmatrix(float4 quat)` | Quaternion to transposed (row-major) 4x4 matrix |
| `qFromMatrix3` | `float4 qFromMatrix3(float3x3 m)` | 3x3 rotation matrix to quaternion (fast, less numerically stable) |
| `qFromMatrix3Precise` | `float4 qFromMatrix3Precise(float3x3 m)` | 3x3 to quaternion (Shepperd's method, numerically stable) |

### Key Implementation Details

`qRotateVec3` uses the optimized formula from the Molecular Matters blog:

```hlsl
inline float3 qRotateVec3(float3 v, float4 q)
{
    float3 t = 2 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}
```

This avoids the full sandwich product `q * float4(v,0) * q_conjugate`, reducing cross and dot products. It is mathematically equivalent for unit quaternions.

`qFromVectors` handles the degenerate antiparallel case where `dot(v1, v2) ≈ -1` by finding an orthogonal axis and constructing a 180-degree rotation:

```hlsl
float4 qFromVectors(float3 v1, float3 v2)
{
    float d = dot(v1, v2);
    if (d < -0.999999) {
        // find orthogonal to v1, construct 180° rotation
        float3 tmp = cross(right, v1);
        if (length(tmp) < 0.000001) tmp = cross(up, v1);
        return qFromAngleAxis(PI, normalize(tmp));
    } else if (d > 0.999999) {
        return QUATERNION_IDENTITY;
    } else {
        float4 q;
        q.xyz = cross(v1, v2);
        q.w = 1 + d;
        return normalize(q);
    }
}
```

---

## 4. `point-light.hlsl` — Light Data Structure

**Path:** `Operators/Lib/Assets/shaders/shared/point-light.hlsl`

A minimal struct defining a point light source. This is the data structure passed from the C# side through a structured buffer to PBR shaders.

```hlsl
struct PointLight {
    float3 position;   // world-space position
    float  intensity;  // light intensity (linear)
    float4 color;      // RGBA color
    float  range;      // falloff reference distance
    float  decay;      // exponent for distance falloff
    float2 __padding;  // alignment padding
};
```

The total struct size is `3*4 + 4 + 4*4 + 4 + 4 + 2*4 = 48 bytes`. The falloff model used in `pbr-render.hlsl` is:

```hlsl
float intensity = Lights[i].intensity / (pow(dist / Lights[i].range, Lights[i].decay) + 1);
```

This is an analytic falloff where `range` is the distance at which intensity is halved (when `decay = 1`), and `decay` controls the steepness. Higher decay values create more localized point lights. At `decay = 2` this approximates inverse-square falloff.

---

## 5. `SpriteDef.hlsl` — Sprite Definition

**Path:** `Operators/Lib/Assets/shaders/shared/SpriteDef.hlsl`

Defines the data structure for a single sprite entry in a sprite batch buffer. Sprites in tixl combine 2D billboard rendering with character/glyph information for ASCII and text effects.

```hlsl
struct SpriteDef {
    float2 Size;            // world-space billboard size
    float4 Color;           // RGBA tint
    float2 UvMin;           // UV bottom-left in atlas
    float2 UvMax;           // UV top-right in atlas
    float2 Pivot;           // local pivot offset
    uint   CharIndex;       // index in the character set
    uint   CharIndexInLine; // horizontal position in a text line
    uint   LineIndex;       // vertical line index
    uint   Extra;           // spare field
};
```

Total struct size: `2*4 + 4*4 + 2*4 + 2*4 + 2*4 + 4*4 = 64 bytes`. The UV fields map into a texture atlas, while `CharIndex`, `CharIndexInLine`, and `LineIndex` support both random sprite drawing and structured text rendering.

---

## 6. `color-functions.hlsl` — OkLab and OkLCh Conversions

**Path:** `Operators/Lib/Assets/shaders/shared/color-functions.hlsl`

This file implements the OkLab perceptual color space, designed by Björn Ottosson in 2020. OkLab is a successor to CIELAB that fixes the hue linearity problems of its predecessor. The key property: unit steps in OkLab (L, a, b) space correspond to unit steps in perceived color difference.

The math involves two matrix multiplications and a cube root (in one direction) or cube power (in the other):

```
RGB → LMS (linear transform via invB matrix)
LMS → LMS^(1/3) (cube root, component-wise)
LMS^(1/3) → OkLab (linear transform via invA matrix)
```

The four static constant matrices are computed from first principles in Ottosson's derivation:

```hlsl
static const float3x3 fwdA = {1.0, 1.0, 1.0,
                       0.3963377774, -0.1055613458, -0.0894841775,
                       0.2158037573, -0.0638541728, -1.2914855480};

static const float3x3 fwdB = {4.0767245293, -1.2681437731, -0.0041119885,
                       -3.3072168827, 2.6093323231, -0.7034763098,
                       0.2307590544, -0.3411344290,  1.7068625689};

static const float3x3 invB = {0.4121656120, 0.2118591070, 0.0883097947,
                       0.5362752080, 0.6807189584, 0.2818474174,
                       0.0514575653, 0.1074065790, 0.6302613616};

static const float3x3 invA = {0.2104542553, 1.9779984951, 0.0259040371,
                       0.7936177850, -2.4285922050, 0.7827717662,
                       -0.0040720468, 0.4505937099, -0.8086757660};
```

`invB` and `invA` are the RGB→OkLab direction; `fwdA` and `fwdB` are the OkLab→RGB direction.

### Function Reference

| Function | Signature | Description |
|---|---|---|
| `RgbToOkLab` | `float3 RgbToOkLab(float3 c)` | Linear RGB to OkLab |
| `OklabToRgb` | `float3 OklabToRgb(float3 c)` | OkLab to linear RGB |
| `RgbToLCh` | `float3 RgbToLCh(float3 col)` | Linear RGB to OkLCh polar form |
| `LChToRgb` | `float3 LChToRgb(float3 polar)` | OkLCh polar form to linear RGB |

### Detailed Implementation

`RgbToOkLab` performs the two-step transform with sign-preserving cube root to handle out-of-gamut colors:

```hlsl
inline float3 RgbToOkLab(float3 c) {
    float3 lms = mul(invB, c);
    return mul(invA, (sign(lms) * pow(abs(lms), 0.3333333333333)));
}
```

`OklabToRgb` reverses this: cube the LMS^(1/3) values to recover LMS, then apply the forward RGB matrix:

```hlsl
inline float3 OklabToRgb(float3 c) {
    float3 lms = mul(fwdA, c);
    return mul(fwdB, (lms * lms * lms));
}
```

`RgbToLCh` converts to OkLab as an intermediate, then converts the (a, b) Cartesian opponent pair to polar (chroma, hue):

```hlsl
inline float3 RgbToLCh(float3 col) {
    col = mul(col, invB);
    col = mul((sign(col) * pow(abs(col), 0.3333333333333)), invA);

    float3 polar = 0;
    polar.x = col.x;                                        // L = lightness
    polar.y = sqrt(col.y * col.y + col.z * col.z);          // C = chroma magnitude
    polar.z = atan2(col.z, col.y) / (2 * 3.141592) + 0.5;  // H = hue, normalized [0, 1]
    return polar;
}
```

Hue is normalized to [0, 1] by dividing the atan2 result (range [-π, π]) by 2π and offsetting by 0.5. This means 0.0 and 1.0 represent the same hue (red), 0.25 is yellow-green, 0.5 is cyan/blue-green, 0.75 is blue-purple.

`LChToRgb` reverses by converting polar back to Cartesian OkLab, then to RGB:

```hlsl
inline float3 LChToRgb(float3 polar) {
    float3 col = 0;
    col.x = polar.x;
    polar.z = (polar.z - 0.5) * 2 * 3.141592;  // denormalize hue back to radians
    col.y = polar.y * cos(polar.z);              // a = C * cos(H)
    col.z = polar.y * sin(polar.z);              // b = C * sin(H)
    float3 lms = mul(col, fwdA);
    return mul((lms * lms * lms), fwdB);
}
```

Note the unconventional matrix multiplication order: `mul(col, fwdA)` (row vector × matrix) versus `mul(fwdA, col)` (matrix × column vector). HLSL `mul(v, M)` is a row vector times a matrix, equivalent to `M^T * col_vector`. This works correctly because the fwdA/fwdB matrices were constructed with this convention in mind — but it is worth being aware of when porting to wgpu or GLSL where conventions differ.

---

## 7. `blend-functions.hlsl` — Layer Blending Modes

**Path:** `Operators/Lib/Assets/shaders/shared/blend-functions.hlsl`

Implements Photoshop/DaVinci Resolve-style layer blending in a single function that switches on an integer blend mode index. The function uses premultiplied alpha for compositing.

```hlsl
float4 BlendColors(float4 tA, float4 tB, int blendMode)
```

`tA` is the base/background layer, `tB` is the top/blend layer. The alpha composite formula is:

```hlsl
float a = tA.a + tB.a - tA.a * tB.a;  // alpha "screen" — both layers fully opaque → alpha 1
```

### Blend Mode Reference

| Mode Integer | Name | Formula |
|---|---|---|
| 0 | Normal | `(1 - tB.a) * tA.rgb + tB.a * tB.rgb` |
| 1 | Screen | `1 - (1 - tA.rgb) * (1 - tB.rgb * tB.a)` |
| 2 | Multiply | `lerp(tA.rgb, tA.rgb * tB.rgb, tB.a)` |
| 3 | Overlay | Per-channel: `< 0.5` → `2 * A * B`, `>= 0.5` → `1 - 2*(1-A)*(1-B)`, blended by alpha |
| 4 | Difference | `abs(tA.rgb - tB.rgb) * tB.a + tB.rgb * (1 - tB.a)` |
| 5 | Use A | `tA.rgb` |
| 6 | Use B | `tB.rgb` |
| 7 | Color Dodge | `tA.rgb / (1.0001 - saturate(tB.rgb))` |
| 8 | Linear Dodge (Add) | `tA.rgb + tB.rgb` |
| 9 | Alpha Multiply | `a = tA.a * tB.a` (alpha only, RGB unchanged) |

The Color Dodge formula uses `1.0001` rather than `1.0` in the denominator to avoid division by zero when the blend color is fully white. Linear Dodge is the same as the additive blend used in particle rendering.

The `Blend` image operator (`image/use/Blend.cs`) exposes these modes plus orthogonal alpha blending modes. The integer values in the C# `RgbBlendModes` enum correspond directly to these switch cases, so there is no translation layer between the operator parameter and the shader.

---

## 8. `bias-functions.hlsl` — Distribution Shaping

**Path:** `Operators/Lib/Assets/shaders/shared/bias-functions.hlsl`

Provides functions for non-linearly remapping values in [0, 1]. The primary use case is controlling how a value animates — making a slider feel exponential or logarithmic rather than linear, or creating easing curves for animation.

### The Core Bias Function

The `GetBias` function implements the classical Schlick bias formula:

```hlsl
inline float GetBias(float bias, float x) {
    return x / ((1 / bias - 2) * (1 - x) + 1);
}
```

When `bias = 0.5`, this is the identity. When `bias < 0.5` values are pushed toward 0; when `bias > 0.5` values are pushed toward 1. This is the same bias function as in Ken Perlin's classic graphics toolbox.

### Function Reference

| Function | Signature | Behavior |
|---|---|---|
| `GetBias(float bias, float x)` | Scalar in, scalar out | Schlick bias: S-shaped curve adjustable around midpoint |
| `GetSchlickBias(float g, float x)` | Gain + input | Two-segment bias (different behavior below/above 0.5) |
| `ApplyGainAndBias(float value, float2 gainBias)` | Value + (gain, bias) | Combined gain then bias (or reversed, depending on gain) |
| `GetBias(float bias, float4 x)` | Float4 overload | Same as scalar version, SIMD-friendly |
| `GetSchlickBias(float4 x, float gain)` | Float4 overload | Same, float4 version |
| `ApplyGainAndBias(float4 v4, float2 gainBias)` | Float4 overload | Float4 version with clamping guards |
| `ApplyBiasAndGain(float x, float s, float t)` | x, shape, threshold | arxiv 2020 generalization (see note) |
| `ApplyBiasAndGain(float4 x, float s, float t)` | Float4 overload | Float4 version |

`ApplyGainAndBias` has a deliberate ordering: when `gain < 0.5`, it applies bias first then gain; when `gain >= 0.5`, it applies gain first then bias. The comment in the source explains that the simpler ordering caused neutral-looking behavior for `gain = 0.5` with any bias value — counterintuitive to users who expect bias alone to have effect regardless of gain.

The `ApplyBiasAndGain` pair (note the reversed word order from `ApplyGainAndBias`) is a different algorithm based on a 2020 arxiv paper. It remaps `s` from a `[0, 1]` input range to an internal `[0, 200]` range:

```hlsl
float ApplyBiasAndGain(float x, float s, float t) {
    float eps = 0.0001;
    float r = 200;
    s *= 2;
    s = s < 1 ? (pow(r, 1 - s)) : 1 / pow(r, s - 1);
    return x < t
        ? ((t * x) / (x + s * (t - x) + eps))
        : (((1 - t) * (x - 1)) / (1 - x - s * (t - x) + eps) + 1);
}
```

The threshold `t` splits the curve into two Möbius transform segments (rational functions), giving more flexibility than a single bias curve.

---

## 9. `hash-functions.hlsl` — Deterministic Pseudo-Random Numbers

**Path:** `Operators/Lib/Assets/shaders/shared/hash-functions.hlsl`

Provides a full matrix of hash functions with varying input/output dimensionalities. All functions are pure (no global state), deterministic, and GPU-friendly (no branches, no memory reads beyond the input).

The naming convention is `hashXY` where X is the output dimension and Y is the input dimension. For example, `hash23` takes a `float3` and returns a `float2`.

### Float Hash Functions (Iq's family)

These are based on Inigo Quilez's hash functions, which use fractional multiplication with a small constant to create chaos from structured input:

| Function | Signature | Description |
|---|---|---|
| `hash11` | `float hash11(float p)` | 1→1: float to float |
| `hash12` | `float hash12(float2 p)` | 2→1: float2 to float |
| `hash13` | `float hash13(float3 p3)` | 3→1: float3 to float |
| `hash21` | `float2 hash21(float p)` | 1→2: float to float2 |
| `hash22` | `float2 hash22(float2 p)` | 2→2: float2 to float2 |
| `hash23` | `float2 hash23(float3 p3)` | 3→2: float3 to float2 |
| `hash31` | `float3 hash31(float p)` | 1→3: float to float3 |
| `hash32` | `float3 hash32(float2 p)` | 2→3: float2 to float3 |
| `hash33` | `float3 hash33(float3 p3)` | 3→3: float3 to float3 |
| `hash41` | `float4 hash41(float p)` | 1→4: float to float4 |
| `hash42` | `float4 hash42(float2 p)` | 2→4: float2 to float4 |
| `hash43` | `float4 hash43(float3 p)` | 3→4: float3 to float4 |
| `hash44` | `float4 hash44(float4 p4)` | 4→4: float4 to float4 |

All outputs are in `[0, 1]`. The 2D and 3D input versions combine their components through dot products to produce the final scrambled value. For example `hash12`:

```hlsl
float hash12(float2 p) {
    float3 p3 = frac(float3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}
```

### Integer Hash Functions

| Function | Signature | Description |
|---|---|---|
| `hash33u` | `float3 hash33u(uint3 x)` | 3D integer to float3, Iq 2017 GLIBC-based |
| `hash41u` | `float4 hash41u(uint x)` | Integer to float4, prime-based |
| `hash11u` | `float hash11u(uint x)` | Integer to float |
| `pcg` | `uint pcg(in uint v)` | PCG hash, excellent statistical quality |
| `xxhash` | `uint xxhash(in uint p)` | xxHash-32 for high-quality non-crypto hashing |

The `pcg` function implements the PCG (Permuted Congruential Generator) hash, which has excellent statistical properties for Monte Carlo methods. It is suitable for sampling-heavy applications like pathtracing or particle simulation.

`xxhash` implements a simplified xxHash-32, trading some quality for simplicity compared to the full xxHash specification.

Private constants used internally:

```hlsl
#define _PRIME0 13331U
#define _PRIME1 1345777U
#define _PRIME2 98777177U
```

---

## 10. `noise-functions.hlsl` — Simplex and Gradient Noise

**Path:** `Operators/Lib/Assets/shaders/shared/noise-functions.hlsl`

Implements 3D coherent noise functions from Ian McEwan/Ashima Arts (MIT licensed from the webgl-noise project). This file provides the building blocks for all procedural texture generation in tixl.

### Function Reference

| Function | Signature | Type |
|---|---|---|
| `cnoise` | `float cnoise(float3 P)` | 3D classic (Perlin) gradient noise, range ~[-1, 1] |
| `pnoise` | `float pnoise(float3 P, float3 rep)` | Tileable Perlin noise with period `rep` |
| `snoise` | `float snoise(float3 v)` | 3D simplex noise, range ~[-1, 1] |
| `snoiseVec3` | `float3 snoiseVec3(float3 p)` | 3D vector of three independent simplex noises |
| `curlNoise` | `float3 curlNoise(float3 p)` | Curl (divergence-free) noise field from `snoiseVec3` |

Support functions (not for direct use):

| Function | Signature | Purpose |
|---|---|---|
| `mod289(float3)` | `float3 mod289(float3 x)` | Mod 289 for gradient table wrapping |
| `mod289(float4)` | `float4 mod289(float4 x)` | Float4 overload |
| `permute` | `float4 permute(float4 x)` | Gradient permutation polynomial |
| `taylorInvSqrt` | `float4 taylorInvSqrt(float4 r)` | Fast inverse sqrt approximation |
| `fade` | `float3 fade(float3 t)` | Quintic smoothing for Perlin noise |

### Simplex vs. Classic Noise

Classic (Perlin) noise `cnoise` uses a lattice of gradient vectors and trilinear interpolation with the quintic `fade` function: `6t^5 - 15t^4 + 10t^3`. This produces smooth derivatives and is tileable with `pnoise`.

Simplex noise `snoise` uses a simplex lattice (tetrahedra in 3D, triangles in 2D) rather than a cube lattice. This reduces the number of gradient lookups from 8 (cube corners) to 4 (tetrahedron corners), giving a roughly 2x speedup in 3D. The output has fewer directional artifacts and is slightly different in character — commonly described as "smoother" in appearance.

### Curl Noise

Curl noise is particularly useful for particle simulation. A curl (rotational) field is divergence-free — particles following it neither accumulate nor disperse, they flow like an incompressible fluid. The implementation finite-differences `snoiseVec3` in all three axes:

```hlsl
float3 curlNoise(float3 p) {
    const float e = .001;
    float3 dx = float3(e, 0.0, 0.0);
    float3 dy = float3(0.0, e, 0.0);
    float3 dz = float3(0.0, 0.0, e);

    float3 p_x0 = snoiseVec3(p - dx);
    float3 p_x1 = snoiseVec3(p + dx);
    // ... (y and z directions) ...

    float x = p_y1.z - p_y0.z - p_z1.y + p_z0.y;
    float y = p_z1.x - p_z0.x - p_x1.z + p_x0.z;
    float z = p_x1.y - p_x0.y - p_y1.x + p_y0.x;

    return normalize(float3(x, y, z) * (1.0 / (2.0 * e)));
}
```

This is the discrete cross-product of the gradient of the 3D noise, which gives a solenoidal (divergence-free) vector field. The step size `e = 0.001` provides a good balance between accuracy and noise amplification.

---

## 11. `pbr.hlsl` — PBR BRDF Functions and Structures

**Path:** `Operators/Lib/Assets/shaders/shared/pbr.hlsl`

Implements the Cook-Torrance microfacet specular BRDF plus supporting structures, adapted from Michal Siejak's reference implementation (based on Epic Games' SIGGRAPH 2013 course notes). This is the physically-based shading foundation.

```hlsl
// Constants
#define PI 3.141592
#define Epsilon 0.00001
#define Fdielectric 0.04  // typical dielectric F0 (fresnel at normal incidence)
```

### Data Structures

```hlsl
struct PbrVertex {
    float3 Position;
    float3 Normal;
    float3 Tangent;
    float3 Bitangent;
    float2 TexCoord;
    float2 TexCoord2;
    float  Selected;
    float3 __padding;
};

// Global fragment-level state, shared between pbr.hlsl and pbr-render.hlsl
struct FragmentMaterial {
    float  Roughness;
    float  Metalness;
    float  Occlusion;
    float  cosLo;          // cos(angle between N and V)
    float3 worldPosition;
    float4 albedo;
    float2 uv;
    float3 N;              // world-space normal
    float  fog;
    float3 Lo;             // outgoing (view) direction
};

static FragmentMaterial frag;  // the global fragment state
```

The `frag` global acts as an implicit communication channel between a shader's main function and `ComputePbr()` — the caller populates `frag` before calling the function. This avoids a long parameter list but creates an implicit dependency on global state.

### BRDF Function Reference

| Function | Signature | Description |
|---|---|---|
| `ndfGGX` | `float ndfGGX(float cosLh, float roughness)` | GGX normal distribution function (Trowbridge-Reitz). Returns specular lobe probability density at half-vector angle |
| `gaSchlickG1` | `float gaSchlickG1(float cosTheta, float k)` | Single-sided Schlick-GGX visibility term |
| `gaSchlickGGX` | `float gaSchlickGGX(float cosLi, float cosLo, float roughness)` | Smith-method combined geometry attenuation |
| `fresnelSchlick` | `float3 fresnelSchlick(float3 F0, float cosTheta)` | Schlick Fresnel approximation |
| `querySpecularTextureLevels` | `uint querySpecularTextureLevels(Texture2D specular)` | Returns mip count of specular IBL cubemap |

The GGX NDF formula:

```hlsl
float ndfGGX(float cosLh, float roughness) {
    float alpha = roughness * roughness;    // Disney reparametrization
    float alphaSq = alpha * alpha;
    float denom = (cosLh * cosLh) * (alphaSq - 1.0) + 1.0;
    return alphaSq / (PI * denom * denom);
}
```

Disney's roughness remapping squares the artist-facing roughness before passing it to the microfacet distribution. This makes the middle of the roughness range look perceptually "half rough" rather than having most variation at the smooth end.

Schlick-GGX geometry with Epic's roughness remapping for analytic lights:

```hlsl
float gaSchlickGGX(float cosLi, float cosLo, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;   // Epic's remapping for analytic lights
    return gaSchlickG1(cosLi, k) * gaSchlickG1(cosLo, k);
}
```

---

## 12. `pbr-render.hlsl` — Full PBR Lighting Evaluation

**Path:** `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl`

This file provides `ComputePbr()`, the main PBR lighting function that combines direct lighting from the `PointLight` array with IBL (Image Based Lighting) from a pre-filtered specular cubemap.

`ComputePbr()` assumes several globally available resources are bound by the calling shader — it cannot function as a standalone include without these bindings:

| Required Resource | Type | Description |
|---|---|---|
| `Lights` | `StructuredBuffer<PointLight>` | Array of point lights |
| `ActiveLightCount` | `int` (cbuffer) | Active lights count |
| `PrefilteredSpecular` | `Texture2D` (used as cubemap-like) | Pre-filtered specular environment |
| `BRDFLookup` | `Texture2D` | Split-sum BRDF LUT for IBL specular |
| `EmissiveColorMap` | `Texture2D` | Emissive texture |
| `WrappedSampler` | `SamplerState` | Wrapping sampler for IBL and emissive |
| `ClampedSampler` | `SamplerState` | Clamped sampler for BRDF LUT |
| `BaseColor` | `float4` (cbuffer) | Global base color multiplier |
| `Color` | `float4` (cbuffer) | Additional color tint |
| `Specular` | `float` (cbuffer) | Specular intensity scalar |
| `EmissiveColor` | `float4` (cbuffer) | Emissive color multiplier |
| `FogColor` | `float4` (cbuffer) | Fog color (alpha controls fog strength) |
| `frag` | `FragmentMaterial` (global) | Fragment state (from pbr.hlsl) |

### Direct Lighting Loop

```hlsl
float3 directLighting = 0.0;
for (uint i = 0; i < (uint)ActiveLightCount; ++i) {
    float3 Lvec = Lights[i].position - frag.worldPosition;
    float dist = length(Lvec);
    float3 L = Lvec / max(dist, 1e-4);

    float intensity = Lights[i].intensity /
                      (pow(dist / Lights[i].range, Lights[i].decay) + 1);
    float3 Lradiance = Lights[i].color.rgb * intensity;

    float NdotV = saturate(dot(N, V));
    float NdotL = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float NdotH = saturate(dot(N, H));

    float3 F = fresnelSchlick(F0, saturate(dot(H, V)));
    float D = ndfGGX(NdotH, frag.Roughness);
    float G = gaSchlickGGX(NdotL, NdotV, frag.Roughness);

    float3 kd = lerp(1.0 - F, 0.0, frag.Metalness);   // dielectric fraction
    float3 diffuseBRDF = kd * frag.albedo.rgb;
    float3 specularBRDF = ((F * D * G) /
                           max(Epsilon, 4.0 * NdotL * NdotV)) * Specular;

    directLighting += (diffuseBRDF + specularBRDF) * Lradiance * NdotL;
}
```

The `kd` (diffuse weight) computation uses energy conservation: `lerp(1 - F, 0, metalness)`. For metals, all diffuse energy goes to specular reflection; for dielectrics, the reflected portion (F) is subtracted from the diffuse.

### IBL (Ambient) Lighting

```hlsl
// IBL uses PrefilteredSpecular at two mip levels:
// - Near-zero roughness mip for irradiance (rough diffuse approximation)
// - Roughness-scaled mip for specular reflections

float3 irradiance = PrefilteredSpecular.SampleLevel(
    WrappedSampler, N, 0.6 * levels).rgb;          // diffuse: heavily blurred

float3 specularIrradiance = PrefilteredSpecular.SampleLevel(
    WrappedSampler, Lr, frag.Roughness * levels).rgb;  // specular: roughness-driven mip

float2 specularBRDF = BRDFLookup.SampleLevel(
    ClampedSampler, float2(frag.cosLo, frag.Roughness), 0).rg;  // split-sum

float3 specularIBL = (F0 * specularBRDF.x + specularBRDF.y) * specularIrradiance;
float3 diffuseIBL = kd * frag.albedo.rgb * irradiance;

ambientLighting = (diffuseIBL + specularIBL) * frag.Occlusion;
```

The split-sum approximation (from Brian Karis's Epic course notes) pre-integrates the IBL specular integral into two terms: the BRDF response (`specularBRDF.x`, `specularBRDF.y`) looked up from a 2D LUT indexed by view angle and roughness, and the specular irradiance from the pre-filtered cubemap.

The PBR pipeline deviates from a standard split-sum setup by using a single `Texture2D` `PrefilteredSpecular` as both the irradiance map (via a specific mip level at `0.6 * levels`) and the pre-filtered specular map (via roughness-scaled mip). In a standard IBL pipeline these are typically separate textures. This is a simplification that trades accuracy for resource economy.

### Output Composition

```hlsl
float4 litColor = float4(directLighting + ambientLighting, 1.0) * BaseColor * Color;

litColor += float4(EmissiveColorMap.Sample(WrappedSampler, frag.uv).rgb
                   * EmissiveColor.rgb, 0);  // add emissive, no alpha change
litColor.rgb = lerp(litColor.rgb, FogColor.rgb, frag.fog * FogColor.a);  // fog blend
litColor.a *= frag.albedo.a;  // apply material transparency

return litColor;
```

---

## Categorized Function Index

### Quaternion Operations (quat-functions.hlsl)

| Category | Functions |
|---|---|
| Construction | `qFromAngleAxis`, `qFromVectors`, `qFromEuler`, `qLookAt`, `qFromMatrix3`, `qFromMatrix3Precise` |
| Operations | `qMul`, `qConjugate`, `qInverse` |
| Application | `qRotateVec3` |
| Interpolation | `qSlerp` |
| Conversion | `qToMatrix`, `quaternion_to_tmatrix` |
| Value encoding | `q_separate_v`, `q_encode_v` |

### Hash Functions (hash-functions.hlsl)

| Category | Functions |
|---|---|
| Float → Float | `hash11`, `hash12`, `hash13` |
| Float → Float2 | `hash21`, `hash22`, `hash23` |
| Float → Float3 | `hash31`, `hash32`, `hash33` |
| Float → Float4 | `hash41`, `hash42`, `hash43`, `hash44` |
| Integer hashes | `hash33u`, `hash41u`, `hash11u`, `pcg`, `xxhash` |

### Noise Functions (noise-functions.hlsl)

| Category | Functions |
|---|---|
| Gradient noise | `cnoise` (classic Perlin), `pnoise` (tileable) |
| Simplex noise | `snoise` |
| Vector noise | `snoiseVec3` |
| Divergence-free | `curlNoise` |
| Support | `mod289`, `permute`, `taylorInvSqrt`, `fade` |

### Color Functions (color-functions.hlsl)

| Category | Functions |
|---|---|
| OkLab conversions | `RgbToOkLab`, `OklabToRgb` |
| OkLCh conversions | `RgbToLCh`, `LChToRgb` |
| Constants | `fwdA`, `fwdB`, `invA`, `invB` (matrices) |

### Blend Functions (blend-functions.hlsl)

| Category | Functions |
|---|---|
| Layer compositing | `BlendColors(float4 tA, float4 tB, int blendMode)` |
| Supported modes | Normal, Screen, Multiply, Overlay, Difference, UseA, UseB, ColorDodge, LinearDodge, AlphaMultiply |

### Bias/Distribution (bias-functions.hlsl)

| Category | Functions |
|---|---|
| Scalar bias | `GetBias`, `GetSchlickBias`, `ApplyGainAndBias` |
| Float4 bias | `GetBias(float4)`, `GetSchlickBias(float4)`, `ApplyGainAndBias(float4)` |
| Alternative shaping | `ApplyBiasAndGain(float)`, `ApplyBiasAndGain(float4)` |

### PBR Rendering (pbr.hlsl + pbr-render.hlsl)

| Category | Functions |
|---|---|
| Microfacet distribution | `ndfGGX` |
| Geometric attenuation | `gaSchlickG1`, `gaSchlickGGX` |
| Fresnel | `fresnelSchlick` |
| IBL support | `querySpecularTextureLevels` |
| Full evaluation | `ComputePbr()` (in pbr-render.hlsl) |

---

## Design Observations for a Rust/wgpu Port

Porting this library to wgpu reveals several interesting translation challenges.

The `frag` global in `pbr.hlsl` is idiomatic in HLSL but requires explicit plumbing in WGSL or GLSL. The natural Rust equivalent is a struct passed through function parameters rather than module-level mutable state. This forces a cleaner API at the cost of verbosity.

The matrix multiplication convention (`mul(col_vector, matrix)` versus `mul(matrix, col_vector)`) differs from GLSL and WGSL. In WGSL, matrix multiplication is `matrix * vector`. When porting `RgbToLCh` and `LChToRgb`, verify the matrix operand order carefully — a transposed matrix applied in the wrong order produces incorrect results silently.

The `NAN` sentinel via `sqrt(-1)` is portable to WGSL (`f32(f32::NAN)` in Rust). The GPU discard behavior for NaN-position vertices is guaranteed by the WGSL spec and confirmed in practice on all major GPU vendors.

The hash functions are trivially portable. The simplex noise functions require a careful read of GLSL→HLSL→WGSL translation, especially the `frac`/`floor` idioms and the component-wise operations on vector types.

---

Source files analyzed:
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/pbr.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/pbr-render.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point-light.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl`
- `visual-programming/tixl/Resources/shared/point-legacy.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/SpriteDef.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/noise-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/hash-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/color-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/blend-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/bias-functions.hlsl`
- `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/quat-functions.hlsl`
