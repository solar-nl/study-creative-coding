# Spline Evaluation Code Trace

Understanding how animation splines work often feels like encountering magic. You store a few keyframes, pass a time value, and somehow get smooth interpolated results. But the real challenge in compact demo environments is doing this efficiently while maintaining quality.

Phoenix's spline system solves a specific size-code tradeoff: how do you implement smooth interpolation with minimal binary footprint while supporting looping animations? The solution involves careful key lookup, cubic interpolation via Catmull-Rom, and optional waveform modulation—all in under 200 lines of carefully optimized code.

This trace follows a single evaluation call through the complete pipeline, revealing how Phoenix transforms compressed keyframe data into smooth animated values. You'll see the key search algorithm, the mathematics of Catmull-Rom interpolation, and the clever goto-based pattern that saves bytes in the final binary.

## The Problem: Smooth Animation from Discrete Keys

Before diving into code, consider what we're solving. An animator places keyframes at specific times—maybe at t=0.0, t=0.25, t=0.5, and t=1.0. But the engine needs values at arbitrary times like t=0.327 or t=0.891. Linear interpolation creates obvious kinks. Cubic interpolation requires knowing not just the neighboring keys, but the keys before and after those neighbors to compute smooth tangents.

The challenge intensifies in demos where:
- Animations must loop seamlessly
- Binary size is critical (every byte counts)
- Keyframes use half-precision floats to save space
- Multiple spline types (scalar, quaternion) share infrastructure

Phoenix's approach: gather four keys around the query time, compute fractional position between the middle two, apply Catmull-Rom interpolation, then optionally add procedural waveforms. The result? Smooth curves from compact data.

## Setup: A Five-Key Spline

Let's trace a concrete scenario. Our spline has:

- 5 keyframes at t = 0.0, 0.2, 0.4, 0.6, 0.8
- Values: 0.0, 1.0, 0.5, 0.8, 0.2 (stored as D3DXFLOAT16)
- Interpolation mode: INTERPOLATION_CUBIC
- Loop: true (animation wraps around)
- No waveform modulation (for simplicity)

We're evaluating at **t = 0.45**, which falls between keys at t=0.4 and t=0.6.

## Entry Point: CphxSpline::CalculateValue(0.45)

The evaluation begins in `phxSpline.cpp:33`:

```cpp
void CphxSpline::CalculateValue( float t )
```

The method signature is deceptively simple—take a time value, populate the `Value[4]` array with results. The complexity hides in how it handles edge cases, key lookup, and interpolation dispatch.

## Early Exit: Handle Degenerate Cases

The first checks handle splines that don't need interpolation. From `phxSpline.cpp:36-51`:

```cpp
if ( !KeyCount )
  return;
```

If there are no keys at all, bail immediately. The `Value` array remains uninitialized, but this should never happen with valid spline data.

Next, single-key splines or boundary conditions:

```cpp
if ( KeyCount == 1 || ( !Loop && t <= Keys[ 0 ]->GetTime() ) )
{
  Keys[ 0 ]->GetValue( Value );
  POSTPROCESS;
  return;
}
```

This handles two scenarios:
1. **Single key**: Use its value regardless of time
2. **Before first key** (non-looping): Clamp to first key

The `POSTPROCESS` macro at `phxSpline.cpp:31` expands to `goto postproc`—a size optimization that lets multiple code paths share the waveform processing logic at the end without function call overhead.

Similarly for the end boundary:

```cpp
if ( !Loop && t >= Keys[ KeyCount - 1 ]->GetTime() )
{
  Keys[ KeyCount - 1 ]->GetValue( Value );
  POSTPROCESS;
  return;
}
```

In our case (t=0.45, Loop=true, KeyCount=5), none of these early exits trigger. We proceed to interpolation.

## Key Search: Find the Surrounding Interval

Now we need to locate which keys surround t=0.45. The algorithm at `phxSpline.cpp:55-57`:

```cpp
int pos = -1;
while ( pos < KeyCount - 1 && Keys[ ( pos + 1 ) % KeyCount ]->GetTime() <= t ) pos++;
pos += KeyCount - 1;
```

This loop increments `pos` until `Keys[pos+1]->GetTime()` exceeds our target time. Let's trace through iterations:

**Iteration 1**: pos=-1, checking Keys[0]->GetTime() = 0.0 <= 0.45? Yes, pos becomes 0
**Iteration 2**: pos=0, checking Keys[1]->GetTime() = 0.2 <= 0.45? Yes, pos becomes 1
**Iteration 3**: pos=1, checking Keys[2]->GetTime() = 0.4 <= 0.45? Yes, pos becomes 2
**Iteration 4**: pos=2, checking Keys[3]->GetTime() = 0.6 <= 0.45? No, stop

After the loop: pos=2. Then `pos += KeyCount - 1` gives pos = 2 + 4 = 6.

Why add KeyCount-1? It offsets the position so the subsequent modulo arithmetic correctly wraps around when gathering the four-key window. This becomes clear in the next step.

## Gathering Four Keys

Cubic interpolation requires four keys: one before, the two bracketing our time, and one after. The gathering happens at `phxSpline.cpp:59-60`:

```cpp
CphxSplineKey *NeededKeys[ 4 ];
for ( int x = 0; x < 4; x++ )
  NeededKeys[ x ] = Keys[ ( pos + x ) % KeyCount ];
```

With pos=6 and KeyCount=5, the modulo operation wraps:

- **NeededKeys[0]** = Keys[(6+0) % 5] = Keys[1] at t=0.2, value=1.0
- **NeededKeys[1]** = Keys[(6+1) % 5] = Keys[2] at t=0.4, value=0.5
- **NeededKeys[2]** = Keys[(6+2) % 5] = Keys[3] at t=0.6, value=0.8
- **NeededKeys[3]** = Keys[(6+3) % 5] = Keys[4] at t=0.8, value=0.2

Our target time t=0.45 falls between NeededKeys[1] (t=0.4) and NeededKeys[2] (t=0.6), with flanking keys providing tangent information.

## Computing Fractional Position

We need to know where t=0.45 sits between the middle two keys as a 0-1 fraction. The calculation at `phxSpline.cpp:64-71`:

```cpp
float distkeys;
distkeys = NeededKeys[ 2 ]->GetTime() - NeededKeys[ 1 ]->GetTime();
if ( Loop ) distkeys = 1 + distkeys - (int)( 1 + distkeys );
```

For our case:
- distkeys = 0.6 - 0.4 = 0.2
- Loop adjustment: distkeys = 1 + 0.2 - (int)(1.2) = 1.2 - 1 = 0.2

The loop adjustment handles wraparound. If NeededKeys[1] were at t=0.9 and NeededKeys[2] at t=0.1 (wrapping past 1.0), the difference would be negative. Adding 1 and taking the fractional part gives the correct distance.

Next, compute the fractional position:

```cpp
float partialt = t - NeededKeys[ 1 ]->GetTime() + 1;
partialt = ( partialt - (int)( partialt ) ) / distkeys;
```

The +1 and fractional extraction handle wrapping:
- partialt = 0.45 - 0.4 + 1 = 1.05
- partialt = (1.05 - 1) / 0.2 = 0.05 / 0.2 = 0.25

So t=0.45 is exactly 25% of the way from key2 (t=0.4) to key3 (t=0.6). This normalized value drives interpolation.

## Interpolation Dispatch

Now we select the interpolation method based on the spline's mode. From `phxSpline.cpp:73-95`:

```cpp
switch ( Interpolation )
{
#ifdef SPLINE_INTERPOLATION_CONSTANT
  case INTERPOLATION_CONSTANT:
    NeededKeys[ 1 ]->GetValue( Value );
    break;
#endif
#if defined SPLINE_INTERPOLATION_LINEAR || defined SPLINE_INTERPOLATION_SLERP
  case INTERPOLATION_LINEAR:
    Lerp( NeededKeys[ 1 ], NeededKeys[ 2 ], partialt );
    break;
#endif
#if defined SPLINE_INTERPOLATION_CUBIC || defined SPLINE_INTERPOLATION_SQUAD
  case INTERPOLATION_CUBIC:
    QuadraticInterpolation( NeededKeys[ 0 ], NeededKeys[ 1 ], NeededKeys[ 2 ], NeededKeys[ 3 ], partialt );
    break;
#endif
```

The `#ifdef` guards allow Phoenix to compile out unused interpolation modes—critical for size-coding. If a demo only uses cubic splines, the constant and linear cases vanish from the binary.

Our spline uses INTERPOLATION_CUBIC, so we call `QuadraticInterpolation()` with all four keys and partialt=0.25.

## Cubic Interpolation: CphxSpline_float16::QuadraticInterpolation()

The method at `phxSpline.cpp:110-114` is remarkably concise:

```cpp
void CphxSpline_float16::QuadraticInterpolation( CphxSplineKey *a, CphxSplineKey *b, CphxSplineKey *c, CphxSplineKey *d, float t )
{
  Value[ 0 ] = catmullrom( a->Value[ 0 ], b->Value[ 0 ], c->Value[ 0 ], d->Value[ 0 ], t );
}
```

It delegates to `catmullrom()` with the four key values and our fractional t. Note that `CphxSplineKey::Value` is a `D3DXFLOAT16[4]` array—half-precision floats converted to full precision by the D3DX library during access.

## Catmull-Rom Formula: The Mathematics of Smoothness

The heart of the smoothness lives in `phxMath.cpp:19-25`:

```cpp
float catmullrom( float a, float b, float c, float d, float t )
{
  float P = ( d - c ) - ( a - b );
  float Q = ( a - b ) - P;
  float R = c - a;
  return ( P*t*t*t ) + ( Q*t*t ) + ( R*t ) + b;
}
```

This is the Catmull-Rom cubic polynomial. Let's understand what each coefficient represents.

Think of this as constructing a cubic curve that passes through points b and c, using points a and d to determine the tangent directions. The standard Catmull-Rom formula is:

```
f(t) = 0.5 * [
  t³(-a + 3b - 3c + d) +
  t²(2a - 5b + 4c - d) +
  t(-a + c) +
  2b
]
```

Phoenix's version is algebraically equivalent but optimized for minimal operations:

- **P = (d - c) - (a - b)**: The "acceleration" term. This controls how the curve's slope changes.
- **Q = (a - b) - P**: The "velocity adjustment" term, derived from P to minimize operations.
- **R = c - a**: The "velocity" term. This is half the tangent at point b (the tangent goes from a to c).
- **b**: The starting value at t=0.

The polynomial evaluates as: P·t³ + Q·t² + R·t + b

Let's compute with our values:
- a = NeededKeys[0]->Value[0] = 1.0
- b = NeededKeys[1]->Value[0] = 0.5
- c = NeededKeys[2]->Value[0] = 0.8
- d = NeededKeys[3]->Value[0] = 0.2
- t = 0.25

Computing coefficients:
- P = (0.2 - 0.8) - (1.0 - 0.5) = -0.6 - 0.5 = -1.1
- Q = (1.0 - 0.5) - (-1.1) = 0.5 + 1.1 = 1.6
- R = 0.8 - 1.0 = -0.2

Evaluating the polynomial:
- t³ term: -1.1 × (0.25)³ = -1.1 × 0.015625 = -0.0171875
- t² term: 1.6 × (0.25)² = 1.6 × 0.0625 = 0.1
- t term: -0.2 × 0.25 = -0.05
- constant: 0.5

Result: -0.0171875 + 0.1 - 0.05 + 0.5 = **0.5328125**

So at t=0.45, the spline evaluates to approximately 0.533. This gets written to `Value[0]`.

## The Catmull-Rom Insight

Why does this formula create smooth curves? The key is that the tangent at each point is determined by its neighbors. At point b, the tangent points from a to c. At point c, the tangent points from b to d. This ensures C¹ continuity—not just the values match, but the slopes match too.

Imagine driving on a road. With linear interpolation, you'd hit sharp corners—zero turning radius, infinite lateral G-forces. With Catmull-Rom, the road curves smoothly because the direction change is continuous. The four-point window gives you "look-ahead and look-behind" to blend smoothly through each segment.

## PostProcess: Waveform Modulation (Optional)

After interpolation completes, we hit the postprocess section at `phxSpline.cpp:97-100`:

```cpp
postproc:;
#if defined SPLINE_WAVEFORM_SIN || defined SPLINE_WAVEFORM_SQUARE || defined SPLINE_WAVEFORM_TRIANGLE || defined SPLINE_WAVEFORM_SAWTOOTH || defined SPLINE_WAVEFORM_NOISE
  PostProcess( t );
#endif
```

The `postproc:` label is the target of those earlier `POSTPROCESS` goto statements. This pattern—using goto to merge code paths—saves bytes compared to function calls or repeated code.

If waveforms are enabled (compile-time flag), `PostProcess()` can add procedural modulation. From `phxSpline.cpp:143-229`, it supports:

- **WAVEFORM_SIN**: Sine wave overlay
- **WAVEFORM_SQUARE**: Square wave (hard transitions)
- **WAVEFORM_TRIANGLE**: Triangle wave (linear ramps)
- **WAVEFORM_SAWTOOTH**: Sawtooth wave (asymmetric ramps)
- **WAVEFORM_NOISE**: Smoothed random noise

The waveform calculation:

```cpp
float wf = 0;
float ph = t * WaveformFrequency;
// ... generate wf based on waveform type ...
wf *= WaveformAmplitude;

if ( MultiplicativeWaveform )
  Value[ 0 ] *= wf;
else
  Value[ 0 ] += wf;
```

This lets animators create complex effects by combining smooth spline curves with procedural oscillation. Think of a camera that follows a smooth path but jitters slightly (additive noise), or a light that pulses (multiplicative sine).

In our example, Waveform is WAVEFORM_NONE, so PostProcess returns immediately. Our interpolated value 0.533 remains unchanged.

## Return: The Final Value

After PostProcess completes, execution returns to the caller. The `Value[0]` member now contains 0.5328125, ready to be read via `GetVector()` or direct access.

For multi-component splines (like vec3 or quaternion), this process repeats for each component or uses specialized methods (SQUAD for quaternions, for instance).

## Key Design Patterns

Several patterns emerge from this implementation:

**1. Compile-Time Feature Selection**

The liberal use of `#ifdef` guards lets Phoenix include only the features each demo needs:

```cpp
#ifdef SPLINE_INTERPOLATION_CUBIC
  case INTERPOLATION_CUBIC:
    QuadraticInterpolation(...);
#endif
```

A demo using only linear interpolation compiles out all cubic code, saving kilobytes.

**2. Goto for Size Optimization**

The `POSTPROCESS` macro demonstrates a controversial but effective technique:

```cpp
#define POSTPROCESS goto postproc
```

This saves bytes compared to:
- Function calls (push/pop overhead)
- Duplicating postprocess logic in each early exit
- Complex flag-based conditionals

In size-coding, readability sometimes yields to binary compactness.

**3. Virtual Method Dispatch for Polymorphism**

The base class defines virtual `QuadraticInterpolation()`, letting scalar and quaternion splines share the same lookup logic:

```cpp
class CphxSpline {
  virtual void QuadraticInterpolation(...) {};
};

class CphxSpline_float16 : public CphxSpline {
  virtual void QuadraticInterpolation(...) { /* Catmull-Rom */ }
};

class CphxSpline_Quaternion16 : public CphxSpline {
  virtual void QuadraticInterpolation(...) { /* SQUAD */ }
};
```

The dispatcher in `CalculateValue()` doesn't care about spline type—polymorphism handles it.

**4. Half-Precision Storage**

Keys store values as `D3DXFLOAT16`—16-bit half-precision floats. This halves memory usage for keyframe data. The D3DX library transparently converts to float during access:

```cpp
D3DXFLOAT16 Value[ 4 ];
float v = Value[0]; // implicit conversion
```

For demos with hundreds of animated parameters, this is a significant space saving.

## Edge Case: Loop Wraparound

Our example didn't trigger wraparound, but consider evaluating at t=0.95 with our five keys. The search would find pos at the last key. Gathering four keys:

- NeededKeys[0] = Keys[(pos+0) % 5] = Keys[3] (t=0.6)
- NeededKeys[1] = Keys[(pos+1) % 5] = Keys[4] (t=0.8)
- NeededKeys[2] = Keys[(pos+2) % 5] = Keys[0] (t=0.0, wraps!)
- NeededKeys[3] = Keys[(pos+3) % 5] = Keys[1] (t=0.2)

Now distkeys calculation becomes critical:

```cpp
distkeys = NeededKeys[2]->GetTime() - NeededKeys[1]->GetTime();
// distkeys = 0.0 - 0.8 = -0.8 (negative!)
if ( Loop ) distkeys = 1 + distkeys - (int)(1 + distkeys);
// distkeys = 1 + (-0.8) - (int)(0.2) = 0.2 - 0 = 0.2
```

The fractional part extraction correctly interprets the wrapped interval. This same logic works for partialt:

```cpp
partialt = t - NeededKeys[1]->GetTime() + 1;
// partialt = 0.95 - 0.8 + 1 = 1.15
partialt = ( partialt - (int)(partialt) ) / distkeys;
// partialt = (1.15 - 1) / 0.2 = 0.15 / 0.2 = 0.75
```

So t=0.95 is 75% of the way from the last key (t=0.8) to the first key (t=0.0, wrapped). The Catmull-Rom interpolation then produces a smooth curve that seamlessly loops.

## Gotchas and Surprises

**Modulo with Negative Numbers**

The `pos += KeyCount - 1` adjustment ensures pos is positive before modulo operations. In C++, negative modulo behavior is implementation-defined pre-C++11 (and even in C++11, `-1 % 5` gives `-1`, not `4`). The offset guarantees positive inputs.

**Fractional Extraction Pattern**

The `1 + value - (int)(1 + value)` pattern appears twice. This is a portable way to get the fractional part of a value that might be negative:

```cpp
float frac = 1 + x - (int)(1 + x);
```

For x=-0.3: `frac = 1 + (-0.3) - 0 = 0.7` (correct)
For x=0.2: `frac = 1 + 0.2 - 1 = 0.2` (correct)

Standard `fmod()` or `modf()` could work, but this is fewer operations and doesn't require math library functions.

**Goto Considered... Essential?**

Modern C++ style guides discourage goto, but size-coding has different priorities. The `POSTPROCESS` macro saves approximately 10-15 bytes per early exit compared to function calls. In a 64KB demo, those bytes matter.

**Why "Quadratic" for Cubic?**

The method name `QuadraticInterpolation()` is misleading—it performs cubic interpolation (degree 3 polynomial). Likely a naming artifact from early development. The comment at `phxMath.cpp:19` confirms it's Catmull-Rom, which is definitionally cubic.

## Implications for Framework Design

Phoenix's spline system offers several lessons for a Rust creative coding framework:

**1. Conditional Compilation for Size**

Rust's feature flags enable similar selective compilation:

```rust
#[cfg(feature = "spline-cubic")]
fn cubic_interpolate(&self, keys: &[Key; 4], t: f32) -> f32 {
  catmullrom(keys[0].value, keys[1].value, keys[2].value, keys[3].value, t)
}
```

Users can opt into only the spline features they need.

**2. Trait-Based Polymorphism**

Rather than virtual methods, traits provide zero-cost abstraction:

```rust
trait Interpolate {
  fn interpolate(&self, keys: &[Key; 4], t: f32) -> Self;
}

impl Interpolate for f32 {
  fn interpolate(&self, keys: &[Key; 4], t: f32) -> f32 {
    catmullrom(keys[0].value, keys[1].value, keys[2].value, keys[3].value, t)
  }
}

impl Interpolate for Quat {
  fn interpolate(&self, keys: &[Key; 4], t: f32) -> Quat {
    squad(keys[0].value, keys[1].value, keys[2].value, keys[3].value, t)
  }
}
```

The compiler monomorphizes for each type, eliminating runtime dispatch overhead.

**3. Half-Precision Types**

Rust's `half` crate provides `f16` types. For memory-constrained scenarios:

```rust
use half::f16;

struct Key {
  time: u8,
  value: f16,
}
```

But default to `f32` unless size is critical—the ergonomics win usually outweighs the space savings.

**4. Iterator-Based Key Search**

Rust's iterator combinators can replace the manual loop:

```rust
let pos = keys.iter()
  .position(|k| k.time > t)
  .map(|i| i.saturating_sub(1))
  .unwrap_or(keys.len() - 1);
```

Though for size-coding, a manual loop might compile smaller.

**5. Avoid Goto Equivalents**

Rust doesn't have goto (except `break 'label` for loop control). Refactor postprocess as a method call:

```rust
fn calculate_value(&mut self, t: f32) {
  if self.keys.is_empty() {
    return;
  }

  // ... early exits call self.postprocess(t) before returning ...

  // ... interpolation ...

  self.postprocess(t);
}

fn postprocess(&mut self, t: f32) {
  if self.waveform != Waveform::None {
    // apply waveform
  }
}
```

The function call overhead is negligible on modern CPUs, and link-time optimization can inline it.

## Cross-References

For related animation and interpolation topics, see:

- **Code Trace: Spline Compression** (coming soon) — How Phoenix packs keyframe data into minimal bytes
- **Quaternion Interpolation (SQUAD)** — Smooth rotation interpolation using spherical quadrangle interpolation
- **Procedural Waveforms** — Details on the noise generation and waveform synthesis in PostProcess

For comparative analysis:

- **notes/themes/animation-systems.md** — How other frameworks handle splines and keyframe interpolation
- **notes/per-framework/nannou/api-design.md** — Rust approaches to animation and easing functions

## References

- **Source**: `demoscene/apex-public/apEx/Phoenix/phxSpline.h` (interface)
- **Source**: `demoscene/apex-public/apEx/Phoenix/phxSpline.cpp` (implementation)
- **Source**: `demoscene/apex-public/apEx/Phoenix/phxMath.cpp` (Catmull-Rom formula)
- **Catmull-Rom Splines**: [Wikipedia](https://en.wikipedia.org/wiki/Centripetal_Catmull%E2%80%93Rom_spline) — Mathematical background
- **D3DX Half-Precision**: DirectX SDK documentation on D3DXFLOAT16
