# Phoenix Spline Waveform Modifiers

The most elegant animation systems separate motion from modulation. Phoenix's spline system does exactly this: keyframes define a base trajectory through interpolation, and then waveforms add oscillation on top. A camera can follow a smooth Bezier path while simultaneously pulsing with a sine wave. A light can fade linearly while flickering with square wave noise. The base spline carries the intentional motion, the waveform adds the texture.

This architecture keeps animations modular and composable. Instead of manually keyframing every oscillation cycle—an impossibility for high-frequency effects like vibration—you define the gross motion once and let the waveform generator handle the repetitive detail. The result is complex, organic movement from simple authoring gestures. A single boolean flag switches between additive and multiplicative modes, letting the same waveform create entirely different effects.

Phoenix implements five distinct waveform types: sine, square, triangle, sawtooth, and noise. Each serves a specific aesthetic purpose, from the smooth breathing of sine waves to the chaotic organic variation of filtered noise. Understanding when to use each waveform—and how they're implemented under the hood—is key to mastering Phoenix's animation system.

## The Problem: Expressive Motion Without Keyframe Hell

Imagine you need a spaceship to vibrate during engine thrust. You could keyframe the position at 60Hz for the entire thrust sequence, manually offsetting each frame by a small random amount. For a 10-second thruster burn, that's 600 keyframes to author, store, and process. Any change to the base trajectory requires re-authoring all 600 keyframes. The data explodes, the workflow becomes unmaintainable, and the final 4KB executable is now 50KB just for one effect.

Or you could define two keyframes—engine start and engine end—with linear interpolation between them, then add a noise waveform with 20Hz frequency. The base motion is clean and editable, the vibration is automatic and procedural, and the final data footprint is 32 bytes: two keyframes plus five waveform parameters. When you need to adjust the trajectory, you move two keyframes. When you need more vibration, you increase the amplitude. The concerns are separated, the workflow is sane, and the executable stays small.

This separation of concerns appears throughout demoscene engines because it solves the size-versus-expressiveness trade-off that defines the art form. Waveforms are the "texture" layer of animation: high-frequency detail that would be prohibitively expensive to keyframe but trivially cheap to generate procedurally.

## Waveform Architecture Overview

Every Phoenix spline can optionally have a waveform modifier active. After the spline calculates its base value through interpolation (constant, linear, cubic, or Bezier), the `PostProcess()` method applies the waveform transformation. The base value is never lost—it's modified in-place by adding or multiplying the waveform output.

The waveform system is controlled by five parameters stored directly in the `CphxSpline` class:

```cpp
// phxSpline.h:93-99
SPLINEWAVEFORM Waveform;              // Which waveform type (0-5)
D3DXFLOAT16 WaveformAmplitude;        // Magnitude of oscillation
D3DXFLOAT16 WaveformFrequency;        // Cycles per unit time
bool MultiplicativeWaveform;          // Add vs multiply mode
unsigned char RandSeed;               // For noise reproducibility
bool NoiseCalculated;                 // Lazy init flag for noise
float NoiseMap[WAVEFORMSPLINENOISEBUFFERSIZE]; // Pre-computed noise buffer (8192 floats)
```

The `D3DXFLOAT16` type is a 16-bit half-precision float, saving 4 bytes per parameter compared to full `float`—critical for 4KB demos where every byte matters. Amplitude and frequency don't need 32-bit precision; the visual difference is imperceptible, and the memory savings add up across hundreds of animated parameters.

The `RandSeed` is a single byte that seeds the random number generator for noise waveforms. This ensures reproducibility: the same seed always generates the same noise pattern, which is essential for synchronizing effects across multiple runs and for deterministic playback of recorded demos. It also enables authoring—artists can tweak the seed value to browse different noise patterns until they find one that feels right.

The `NoiseMap` array is an interesting size/quality trade-off. At 8192 samples × 4 bytes per float = 32KB, it's one of the largest allocations in the spline system. This buffer is shared across all splines via a static allocation, so the memory cost is paid once regardless of how many splines use noise waveforms. The large buffer size allows smooth, high-quality noise without audible aliasing artifacts, and it's only populated on-demand via lazy initialization.

## Phase Calculation: Mapping Time to Cycles

All waveforms begin with the same phase calculation:

```cpp
// phxSpline.cpp:155
float ph = t * WaveformFrequency;
```

This maps the current timeline time `t` (typically ranging 0.0 to 1.0 across the demo or scene duration) to a phase position within the waveform cycle. If `WaveformFrequency` is 5, then `ph` ranges from 0.0 to 5.0 as `t` goes from 0.0 to 1.0—meaning the waveform completes five full cycles over the timeline.

The phase `ph` is then used differently by each waveform type:

- **Sine and square**: `ph * pi * 2.0` converts phase to radians for `sin()`
- **Triangle**: `fmod(ph, 1)` extracts the fractional cycle position
- **Sawtooth**: `fmod(ph, 2.0)` uses a two-unit cycle to create symmetric ramps
- **Noise**: `ph * WAVEFORMSPLINENOISEBUFFERSIZE` indexes into the noise buffer

This consistent phase calculation keeps the waveform implementations orthogonal—changing frequency doesn't require understanding each waveform's internal math, it just scales time uniformly.

## WAVEFORM_NONE: The Fast Path

```cpp
// phxSpline.cpp:150-151
if (Waveform == WAVEFORM_NONE)
  return;
```

This is the most common waveform "type"—no waveform at all. Most splines in a typical demo don't use waveforms; they're simple keyframed animations for camera paths, object positions, and fade effects. The early return here is critical for performance: it skips all waveform computation with a single branch, avoiding `sin()` calls, floating-point modulo operations, and noise buffer lookups.

In a 4KB demo with 200+ active splines per frame, this fast path matters. The branch predictor will correctly predict "no waveform" for most splines most of the time, making this check nearly free. It's an example of optimizing for the common case: make the simple thing fast, even if it means the complex cases (actual waveforms) pay a small overhead cost for the initial check.

## WAVEFORM_SIN: Smooth Organic Oscillation

```cpp
// phxSpline.cpp:163-166
#ifdef SPLINE_WAVEFORM_SIN
case WAVEFORM_SIN:
  wf = s; // where s = sin(ph * pi * 2.0f)
  break;
#endif
```

The sine wave is the foundational waveform, producing smooth oscillation between -1.0 and +1.0. Its value at any phase is computed as:

```
wf = sin(ph × 2π)
```

After amplitude scaling (`wf *= WaveformAmplitude`), the result is added to or multiplied with the base spline value.

**Visual Characteristics:**

```
  1.0 ┤    ╭───╮       ╭───╮       ╭───╮
      │   ╱     ╲     ╱     ╲     ╱     ╲
  0.0 ┤──╯       ╰───╯       ╰───╯       ╰──
      │           ╲ ╱         ╲ ╱         ╲
 -1.0 ┤            ╰           ╰
      └─────────────────────────────────────
      0         0.5         1.0         1.5
                    Phase (cycles)
```

The sine wave has no sharp edges, no discontinuities, and no sudden changes in derivative—it's infinitely smooth. This makes it ideal for organic, natural-feeling motion that draws no attention to itself.

**Common Use Cases:**

- **Breathing effects**: Lights pulsing gently, objects scaling in and out, opacity fading rhythmically
- **Floating motion**: Objects bobbing up and down as if suspended in water or drifting in zero gravity
- **Camera shake**: Low-frequency sine waves on camera position for subtle, nauseating drift
- **Audio-reactive pulsing**: Amplitude-modulated sine waves synchronized to beat detection

The smoothness of sine waves makes them psychologically "invisible"—viewers perceive the motion but don't consciously register it as a repeating pattern. This is why sine waves dominate UI animation and motion graphics: they feel natural because they mimic the harmonic motion found throughout physics (pendulums, springs, waves).

**Performance Note:** The `sin()` call is the most expensive part of the waveform computation, typically 20-40 CPU cycles on x86. Phoenix computes `s = sin(ph * pi * 2.0f)` once and reuses it for both sine and square waveforms (if both are compiled in), amortizing the cost. Modern x87 FPUs have dedicated `FSIN` instructions, but they're not the fastest operations. In performance-critical contexts, you'd pre-compute a lookup table—but for demos where you're already computing shaders and geometry every frame, a few `sin()` calls are negligible.

## WAVEFORM_SQUARE: Binary On/Off Switching

```cpp
// phxSpline.cpp:169-174
#ifdef SPLINE_WAVEFORM_SQUARE
case WAVEFORM_SQUARE:
  if (s == 0)
    wf = 1.0;
  else
    wf = s / fabs(s);
  break;
#endif
```

The square wave is derived from the sine wave by extracting its sign. The formula `s / fabs(s)` returns -1.0 for negative values and +1.0 for positive values, producing a hard binary oscillation:

```
wf = sign(sin(ph × 2π))
```

The special case `if (s == 0)` handles the exact zero-crossing points where `sin()` returns 0.0, arbitrarily setting the output to 1.0. This avoids a division-by-zero and ensures the waveform has a defined value at every phase.

**Visual Characteristics:**

```
  1.0 ┤─────────╮           ╭─────────╮
      │         │           │         │
  0.0 ┤         │           │         │
      │         │           │         │
 -1.0 ┤         ╰───────────╯         ╰────
      └─────────────────────────────────────
      0       0.25      0.5       0.75   1.0
                    Phase (cycles)
```

The square wave has instantaneous transitions—it jumps from -1.0 to +1.0 with no intermediate values. This creates harsh, mechanical motion that feels digital and alien. The derivative is undefined at the transitions (mathematically infinite), which makes the motion feel "snappy" or "strobing."

**Common Use Cases:**

- **Strobing effects**: Lights flashing on and off, visibility toggling, laser pulse patterns
- **Mechanical movement**: Robot joints snapping between positions, digital readouts flickering
- **Threshold-based effects**: Switching between two discrete states based on timeline position
- **Glitch aesthetics**: Creating the jagged, unstable look of corrupted video or failing hardware

Square waves are also useful for **gating** other effects. For example, a square wave on a light's brightness makes it flash on and off. If you multiply a sine wave by a square wave, you get "gated oscillation"—smooth pulsing that turns on and off abruptly. This layering of waveforms (via multiplicative mode) enables surprisingly complex rhythms from simple building blocks.

**Performance Note:** The `fabs()` and division are fast on modern CPUs, and the branch for `s == 0` is nearly always mispredicted (zero-crossings are rare), but the cost is negligible—maybe 5 cycles total. The `sin()` call dominates the cost, so square waves are essentially free once you've computed sine.

## WAVEFORM_TRIANGLE: Linear Ramps

```cpp
// phxSpline.cpp:186-188
#ifdef SPLINE_WAVEFORM_TRIANGLE
case WAVEFORM_TRIANGLE:
  wf = (fmodf(ph, 1) - 0.5f) * 2;
  break;
#endif
```

Despite the comment in the source saying "TRIANGLE," this implementation actually produces a sawtooth-like wave with a single linear ramp per cycle. Let's trace the math:

1. `fmodf(ph, 1)` extracts the fractional part of the phase, wrapping it into the range [0.0, 1.0)
2. `- 0.5f` shifts the range to [-0.5, 0.5)
3. `* 2` scales it to [-1.0, 1.0)

The result is a linear ramp that starts at -1.0 and increases to +1.0 over one cycle, then instantly resets to -1.0 and repeats:

**Visual Characteristics:**

```
  1.0 ┤       ╱│       ╱│       ╱│       ╱
      │      ╱ │      ╱ │      ╱ │      ╱
  0.0 ┤     ╱  │     ╱  │     ╱  │     ╱
      │    ╱   │    ╱   │    ╱   │    ╱
 -1.0 ┤───╱    │───╱    │───╱    │───╱
      └─────────────────────────────────────
      0       0.5       1.0       1.5
                    Phase (cycles)
```

Wait—this isn't a triangle wave. A triangle wave should ramp up and then ramp back down symmetrically. This is a **sawtooth wave**, despite the enum name. The sharp reset at the end of each cycle creates a discontinuity, giving it a "scanning" or "resetting" quality.

**Common Use Cases:**

- **Scanning effects**: Radar sweeps, oscilloscope traces, progress bars that reset
- **Ramping parameters**: Gradually increasing values that snap back to the start (e.g., winding up for a jump)
- **Repeating counters**: Visual elements that accumulate and reset, like ammunition reloading indicators

The linear nature of the ramp makes it feel mechanical and predictable. Unlike sine waves, which accelerate and decelerate smoothly, triangle/sawtooth waves maintain constant velocity. This is useful when you want steady, uniform motion without easing.

**Performance Note:** `fmodf()` is typically 10-15 cycles on x86, making this one of the fastest waveforms to compute. The subtract and multiply are 1 cycle each. This makes triangle waves ideal for high-frequency modulation where `sin()` costs would add up.

## WAVEFORM_SAWTOOTH: True Triangle Wave

```cpp
// phxSpline.cpp:177-183
#ifdef SPLINE_WAVEFORM_SAWTOOTH
case WAVEFORM_SAWTOOTH:
{
  float f = fmodf(ph, 2.0f);
  f = (f > 1.0f) ? 2 - f : f;
  wf = (f - 0.5f) * 2;
  break;
}
#endif
```

The "sawtooth" case actually produces a true triangle wave—ramping up and then ramping down symmetrically. The naming mismatch between triangle and sawtooth is likely a historical artifact from refactoring or copy-paste errors during development. Let's trace the corrected math:

1. `fmodf(ph, 2.0f)` wraps phase into [0.0, 2.0)
2. `(f > 1.0f) ? 2 - f : f` mirrors the second half: if `f` is between 1.0 and 2.0, it reflects it back down
3. `(f - 0.5f) * 2` scales the result to [-1.0, 1.0]

This creates a symmetric up-and-down ramp:

**Visual Characteristics:**

```
  1.0 ┤    ╱╲      ╱╲      ╱╲      ╱╲
      │   ╱  ╲    ╱  ╲    ╱  ╲    ╱  ╲
  0.0 ┤  ╱    ╲  ╱    ╲  ╱    ╲  ╱    ╲
      │ ╱      ╲╱      ╲╱      ╲╱      ╲
 -1.0 ┤╱
      └─────────────────────────────────────
      0       0.5       1.0       1.5
                    Phase (cycles)
```

This is a proper triangle wave—it ramps up linearly from -1.0 to +1.0 over half a cycle, then ramps down linearly back to -1.0 over the second half. The slope changes sign at the peaks, creating a "corner" where the derivative flips.

**Common Use Cases:**

- **Oscillating motion**: Back-and-forth movement like a pendulum (but with constant velocity instead of acceleration)
- **Breathing with linearity**: Similar to sine waves but with a more mechanical, metronomic feel
- **LFO modulation**: Low-frequency oscillators in audio-reactive effects that need symmetric rise/fall
- **Zipper-like animations**: Visual elements that expand and contract at a steady rate

The triangle wave sits between sine and square in terms of smoothness. It has continuous values (unlike square) but has discontinuous derivatives at the peaks (unlike sine). This gives it a "purposeful" quality—it feels like something actively moving back and forth rather than naturally oscillating.

**Performance Note:** The `fmodf()` with 2.0 as the divisor is slightly cheaper than arbitrary divisors (compilers can optimize power-of-two divisions). The conditional branch `(f > 1.0f) ? 2 - f : f` is highly predictable—it's 50/50 over time, which modern branch predictors handle well. Total cost is about the same as the triangle case (~15-20 cycles).

## WAVEFORM_NOISE: Organic Chaos

Noise is the most complex waveform, requiring lazy initialization, random number generation, and multi-pass filtering. It produces smooth, random variation that feels organic and unpredictable—the opposite of the mathematically perfect oscillations of sine, square, and triangle waves.

### Lazy Initialization and Reproducibility

```cpp
// phxSpline.cpp:193-213
if (!NoiseCalculated)
{
  srand(RandSeed);
  for (int x = 0; x < WAVEFORMSPLINENOISEBUFFERSIZE; x++)
    map[x] = rand() / (float)RAND_MAX;
  int sampleWidth = WAVEFORMSPLINENOISEBUFFERSIZE / max(1, WaveformFrequency);

  for (int z = 0; z < 3; z++)
  {
    for (int x = 0; x < WAVEFORMSPLINENOISEBUFFERSIZE; x++)
    {
      float val = 0;
      for (int y = 0; y < sampleWidth; y++)
        val += map[(x + y) % WAVEFORMSPLINENOISEBUFFERSIZE];
      NoiseMap[x] = val / (float)sampleWidth;
    }
    for (int x = 0; x < WAVEFORMSPLINENOISEBUFFERSIZE; x++)
      map[x] = NoiseMap[x];
  }
  NoiseCalculated = true;
}
```

Noise generation is deferred until the first time the waveform is evaluated. This is classic lazy initialization: avoid paying the cost until you actually need the result. If a spline is never rendered (e.g., it's in a disabled scene or behind a conditional flag), its noise buffer is never allocated or computed.

The `RandSeed` provides reproducibility. Seeding the C standard library's `rand()` function with the same seed guarantees the same sequence of random numbers, which means the same noise pattern every time the demo runs. This is essential for demoscene productions where timing is synchronized to music—you can't have different random values on each playback or the choreography falls apart.

The initial loop fills a temporary `map` buffer with 8192 random values in [0.0, 1.0]. These values are pure white noise—completely uncorrelated, harsh, and aliased. White noise would sound like static; visually, it would look like flickering pixels. This raw noise needs smoothing.

### Three-Pass Box Blur Filter

The three nested loops implement a three-pass box blur filter, progressively smoothing the noise:

```cpp
int sampleWidth = WAVEFORMSPLINENOISEBUFFERSIZE / max(1, WaveformFrequency);

for (int z = 0; z < 3; z++)  // 3 passes
{
  for (int x = 0; x < WAVEFORMSPLINENOISEBUFFERSIZE; x++)  // For each sample
  {
    float val = 0;
    for (int y = 0; y < sampleWidth; y++)  // Average over sampleWidth neighbors
      val += map[(x + y) % WAVEFORMSPLINENOISEBUFFERSIZE];
    NoiseMap[x] = val / (float)sampleWidth;
  }
  // Copy result back to map for next pass
  for (int x = 0; x < WAVEFORMSPLINENOISEBUFFERSIZE; x++)
    map[x] = NoiseMap[x];
}
```

**First pass:** Each output sample is the average of `sampleWidth` consecutive input samples. This is a box blur—a simple low-pass filter that removes high-frequency noise. The `sampleWidth` is inversely proportional to `WaveformFrequency`: higher frequency means smaller sample width, less smoothing, and more detail in the noise.

**Second and third passes:** The filtered result is copied back to `map`, then filtered again. Applying a box blur three times approximates a Gaussian blur—the result has smoother gradients and fewer sharp transitions. This turns harsh white noise into smooth, rolling hills of variation.

The `% WAVEFORMSPLINENOISEBUFFERSIZE` modulo operation wraps the buffer, treating it as circular. This ensures the noise pattern loops seamlessly—no discontinuity when `t` wraps from 1.0 back to 0.0 for looping splines.

**Why not Perlin or simplex noise?** Those algorithms produce higher-quality, band-limited noise with better visual characteristics. The answer is code size. Perlin noise requires gradient tables, interpolation math, and multi-octave summation. That's hundreds of bytes of code. The three-pass box blur is ~50 bytes of machine code and leverages the C standard library's `rand()`, which is already linked in. For 4KB demos, this trade-off is worth it—the noise looks "good enough" for motion blur, camera shake, and organic variation.

### Sampling the Noise Buffer

```cpp
// phxSpline.cpp:215-217
float tn = fmod(t * WAVEFORMSPLINENOISEBUFFERSIZE, 1);
int tp = (int)(t * WAVEFORMSPLINENOISEBUFFERSIZE);
wf = (NoiseMap[tp] + (NoiseMap[(tp + 1) % WAVEFORMSPLINENOISEBUFFERSIZE] - NoiseMap[tp]) * tn) * 2 - 1;
```

Once the noise buffer is initialized, sampling is straightforward:

1. **Map timeline time to buffer index**: `t * WAVEFORMSPLINENOISEBUFFERSIZE` scales `t` from [0.0, 1.0] to [0, 8192]
2. **Extract integer and fractional parts**: `tp` is the integer index, `tn` is the fractional remainder for interpolation
3. **Linear interpolation**: `NoiseMap[tp] + (NoiseMap[tp+1] - NoiseMap[tp]) * tn` blends between adjacent samples
4. **Remap to [-1.0, 1.0]**: `* 2 - 1` converts from [0.0, 1.0] to waveform range

The linear interpolation is critical. Without it, you'd get stepping artifacts as the noise snaps from one discrete value to the next. With interpolation, the noise transitions smoothly, maintaining the band-limited quality from the blur filter.

**Visual Characteristics:**

```
  1.0 ┤   ╭─╮ ╭╮    ╭─╮   ╭╮  ╭──╮
      │  ╱   ╰╯ ╰╮ ╱   ╰╮╭╯ ╰─╯   ╰╮
  0.0 ┤─╯        ╰─      ╰╯         ╰─╮╭─
      │                                ╰╯
 -1.0 ┤
      └─────────────────────────────────────
      0       0.25      0.5       0.75   1.0
                    Phase (cycles)
```

Unlike the mathematical perfection of sine, square, and triangle waves, noise has no repeating pattern (beyond the buffer loop point). It's continuous but unpredictable—every sample is a surprise. This makes it ideal for breaking up the mechanical regularity of other waveforms and injecting organic life into motion.

**Common Use Cases:**

- **Camera shake**: Low-frequency noise on camera position/rotation for handheld or impact effects
- **Organic motion**: Objects that drift, float, or sway without following a predictable pattern
- **Texture animation**: Noise-driven UV offsets for water, fire, or atmospheric effects
- **Breakup of symmetry**: Adding noise to otherwise perfect geometric patterns to make them feel natural

**Performance Note:** The noise waveform is the most expensive:
- **Initialization**: ~100,000 cycles (8192 samples × 3 passes × sampleWidth iterations)
- **Per-frame sampling**: ~10 cycles (one modulo, one multiply, one add for interpolation)

The initialization cost is paid only once per spline, amortized across the entire demo. The per-frame cost is negligible. The 32KB memory footprint for the `NoiseMap` buffer is the real cost—but since it's a static allocation shared across all splines, it's a one-time penalty regardless of how many noise waveforms you use.

## Amplitude Scaling and Application Modes

After computing the raw waveform value `wf` (which ranges from -1.0 to +1.0 for all waveform types), the system applies amplitude scaling and then combines it with the base spline value:

```cpp
// phxSpline.cpp:223-228
wf *= WaveformAmplitude;

if (MultiplicativeWaveform)
  Value[0] *= wf;
else
  Value[0] += wf;
```

### Amplitude Scaling

`WaveformAmplitude` controls the magnitude of the oscillation. For additive mode, it's the direct offset applied to the base value. For multiplicative mode, it's the modulation depth. A few examples:

- **Amplitude = 0.1, additive**: Base value of 5.0 oscillates between 4.9 and 5.1 (± 0.1)
- **Amplitude = 2.0, additive**: Base value of 5.0 oscillates between 3.0 and 7.0 (± 2.0)
- **Amplitude = 0.5, multiplicative**: Base value is modulated by 0.5× to 0.5×, effectively multiplying by [-0.5, 0.5]

The amplitude is stored as a `D3DXFLOAT16` (half-precision float), limiting its range to approximately ±65,504 with reduced precision. For waveform amplitudes, this is more than sufficient—visual motion rarely needs amplitude values beyond ±100, and the precision loss at typical scales (0.1 to 10.0) is imperceptible.

### Additive Mode: Oscillation Around Base Value

```cpp
Value[0] += wf;
```

Additive mode adds the scaled waveform to the base spline value. This creates oscillation **around** the base trajectory. If the spline is a linear fade from 0.0 to 10.0, and you add a sine wave with amplitude 1.0, the result is a fade from 0.0 to 10.0 with ±1.0 oscillation superimposed.

Think of additive mode as **vibration** or **texture** on top of the base motion. The base spline defines the gross trajectory, the waveform adds fine-grained detail. This is the most common mode for:

- **Position offsets**: Camera shake, character wobble, object vibration
- **Color variation**: Flickering lights, pulsing emissives, rainbow cycling
- **Parameter modulation**: Scaling factor, rotation angle, any numeric parameter

Additive mode preserves the overall "trend" of the base spline. A spline that goes from 0 to 100 still ends at 100, just with a wavy path to get there.

### Multiplicative Mode: Amplitude Modulation

```cpp
Value[0] *= wf;
```

Multiplicative mode multiplies the base spline value by the scaled waveform. This creates **amplitude modulation**—the base value's magnitude is modulated by the waveform. If the waveform oscillates between 0.0 and 1.0, the base value is scaled between 0% and 100% of its original magnitude.

Multiplicative mode is less intuitive but extremely powerful. Consider a sine wave with amplitude 0.5 in multiplicative mode:
- `wf` ranges from -1.0 to +1.0
- `wf *= 0.5` scales it to -0.5 to +0.5
- `Value[0] *= wf` multiplies the base by -0.5 to +0.5

Wait—that inverts the sign! If the base value is positive, multiplying by a negative waveform makes it negative. This can produce unexpected results. In practice, multiplicative mode is often used with waveforms that stay positive (e.g., square wave with amplitude offset to avoid negative values, or sine with a DC offset applied manually).

**Common use cases for multiplicative mode:**

- **Gating effects**: A square wave multiplied against a sine wave creates "gated oscillation"—the sine wave turns on and off abruptly
- **Envelope modulation**: Applying a triangle or noise waveform to an intensity value to create "breathing" that scales proportionally with the base intensity
- **Frequency modulation**: Modulating the frequency parameter of another waveform to create complex rhythms (though Phoenix doesn't support this directly—you'd need to do it manually in tool code)

Multiplicative mode is the audio engineer's "ring modulation"—multiplying two signals to produce sum and difference frequencies. In the demoscene, it's used for layering effects and creating complex, non-linear interactions between animation curves.

### Choosing Between Additive and Multiplicative

**Use additive mode when:**
- You want to add detail without changing the overall range or trend of the base spline
- You're offsetting position, rotation, or other spatial parameters
- You want vibration, shake, or texture

**Use multiplicative mode when:**
- You want the waveform effect to scale proportionally with the base value
- You're modulating intensity, brightness, or other magnitude-based parameters
- You want gating, pulsing, or rhythmic on/off effects

In practice, additive mode is used 90% of the time. Multiplicative mode is a specialized tool for specific effects where scaling proportionally matters.

## Waveform Comparison Table

| Waveform | Formula | Range | Smoothness | Derivative | CPU Cost | Use Cases |
|----------|---------|-------|------------|------------|----------|-----------|
| **None** | `Value` | N/A | N/A | N/A | 0 cycles | Default; most splines |
| **Sine** | `sin(ph × 2π)` | [-1, 1] | Infinitely smooth | Continuous everywhere | ~30 cycles | Breathing, floating, organic motion |
| **Square** | `sign(sin(ph × 2π))` | {-1, 1} | Discontinuous | Undefined at transitions | ~35 cycles | Strobing, on/off, glitch effects |
| **Triangle** | `fmod(ph, 1) × 2 - 1` | [-1, 1] | Continuous | Piecewise constant (with reset) | ~15 cycles | Scanning, ramping, linear rise |
| **Sawtooth** | `mirror(fmod(ph, 2))` | [-1, 1] | Continuous | Piecewise constant | ~20 cycles | Symmetric oscillation, LFO |
| **Noise** | Filtered random | [-1, 1] | Smooth (interpolated) | Continuous | ~10 cycles/sample + 100K init | Organic variation, shake, chaos |

## Performance Characteristics Deep Dive

### Memory Footprint

Per-spline waveform data:
- `SPLINEWAVEFORM Waveform` — 4 bytes (enum, compiler pads to int)
- `D3DXFLOAT16 WaveformAmplitude` — 2 bytes
- `D3DXFLOAT16 WaveformFrequency` — 2 bytes
- `bool MultiplicativeWaveform` — 1 byte
- `unsigned char RandSeed` — 1 byte
- `bool NoiseCalculated` — 1 byte
- Padding — 1 byte (struct alignment)
- **Total: 12 bytes per spline**

Shared static data:
- `float map[8192]` — 32KB (temporary during noise init)
- `float NoiseMap[8192]` per spline — 32KB per spline using noise

The per-spline overhead is tiny—12 bytes is negligible even with hundreds of splines. The noise buffer is the real cost, but it's only allocated for splines that actually use noise waveforms. Most splines don't, so the typical memory overhead is just the 12-byte parameter block.

### CPU Cost Breakdown

Measured on a hypothetical modern x86 CPU with rough cycle estimates:

| Operation | Cycles | Notes |
|-----------|--------|-------|
| `if (Waveform == WAVEFORM_NONE)` | ~1 | Branch predictor wins for most splines |
| `float ph = t * WaveformFrequency` | ~3 | One multiply, pipeline stall unlikely |
| `sin(ph * pi * 2.0f)` | ~25 | x87 `FSIN` instruction |
| `fabs(s)` | ~2 | Bitmask operation in practice |
| `s / fabs(s)` | ~5 | FP divide, but reciprocal throughput is good |
| `fmodf(ph, 1)` | ~12 | Software emulation or `FPREM` |
| `fmodf(ph, 2.0f)` | ~12 | Same as above |
| `NoiseMap[tp]` | ~3 | L1 cache hit assumed |
| Interpolation math | ~5 | Multiply, add, add—pipelined |
| `wf *= WaveformAmplitude` | ~3 | One multiply |
| `Value[0] += wf` or `Value[0] *= wf` | ~3 | One add or multiply |

**Total per-frame cost:**
- **None**: 1 cycle (early return)
- **Sine**: ~40 cycles
- **Square**: ~45 cycles (includes `sin()`)
- **Triangle**: ~25 cycles
- **Sawtooth**: ~30 cycles
- **Noise**: ~30 cycles (assumes buffer is cached)

These are ballpark figures—actual performance depends on CPU microarchitecture, compiler optimizations, and whether the instruction cache is hot. The key insight is that waveform computation is **cheap** compared to the rest of a frame's workload. A typical 4KB demo spends 90% of its CPU time in the GPU command buffer submission, scene traversal, and shader execution. Waveform computation is noise in the profiler.

### Optimization Opportunities

Phoenix's implementation is already well-optimized for code size, but if you were porting this to a modern Rust framework with performance as a priority, consider:

1. **SIMD vectorization**: Compute 4 or 8 waveforms in parallel using SSE/AVX or NEON intrinsics. Modern CPUs can compute 4× `sin()` calls in the time it takes to do one scalar.

2. **Lookup tables for sin()**: Pre-compute a 1024-entry sine table and use linear interpolation. This trades 4KB of read-only data for ~10× faster sine computation. For demos with hundreds of sine-driven animations, this pays off.

3. **Separate hot path for common cases**: If 90% of your splines use sine or none, special-case those in a tight inner loop to maximize instruction cache efficiency and branch prediction.

4. **Lazy frequency scaling**: Instead of `ph = t * WaveformFrequency` every frame, cache `ph` and increment it by `delta_t * WaveformFrequency`. This trades one multiply for one add, which is faster and has better numerical stability.

5. **Noise buffer streaming**: Instead of 8192 samples, use a smaller buffer (e.g., 512 samples) and generate noise on-demand with a faster algorithm like `xorshift128`. This saves memory at the cost of slightly less smooth noise.

But remember: Phoenix is a **4KB demo engine**. Every byte of code counts. The current implementation is a masterclass in balancing quality, performance, and size. The code footprint for all five waveforms is under 200 bytes of x86 machine code. That's the real optimization.

## Waveform Layering and Composition

Phoenix only supports one waveform per spline, but you can layer effects by creating multiple splines and compositing them:

**Additive layering**: Create two splines with the same keyframes but different waveforms. In your scene graph, sum their outputs. For example:
- Spline A: Camera X position, sine wave at 2Hz, amplitude 0.5
- Spline B: Camera X position (same base), noise at 20Hz, amplitude 0.1
- Final X = Spline A + Spline B

This gives you low-frequency sine drift (the "sway") plus high-frequency noise (the "shake"). The result feels organic because it has motion at multiple time scales.

**Multiplicative layering**: Use one spline's output as the amplitude parameter for another (if your engine supports dynamic parameter binding). For example:
- Spline A: Light intensity, triangle wave at 1Hz (the base pulsing)
- Spline B: Amplitude modulator, noise at 5Hz (randomizes the pulse depth)
- Final intensity = Base × Spline A × Spline B

This creates pulsing that varies in strength—organic and unpredictable.

Phoenix doesn't expose these composition patterns directly, but demo tools that sit on top of Phoenix (like the APEXDEMOTOOL editor referenced in other files) often implement them via node graphs or expression evaluators.

## Implications for a Rust Creative Coding Framework

### API Design Lessons

1. **Separate base motion from modulation**: Waveforms are a separate concern from interpolation. Don't bake oscillation into the interpolation logic—keep it as a post-process modifier. This keeps the API composable and the implementation modular.

2. **Provide both additive and multiplicative modes**: They serve different use cases. Additive is intuitive for positions and offsets, multiplicative is essential for gating and proportional scaling.

3. **Support reproducible randomness**: The `RandSeed` parameter is critical for demos and interactive art where repeatability matters. In Rust, this would be a `u32` or `u64` seed passed to a PRNG like `rand_pcg` or `rand_xoshiro`.

4. **Lazy initialization for expensive resources**: Don't generate the noise buffer until it's needed. In Rust, use `Option<Vec<f32>>` or `once_cell::sync::Lazy` for the noise buffer—initialize on first access.

5. **Use half-precision floats where appropriate**: Modern GPUs have excellent `f16` support, and for animation parameters, the precision loss is imperceptible. Rust's `half` crate provides `f16` types that compile to efficient SIMD operations on ARM (neon) and x86 (F16C).

### Rust Implementation Sketch

```rust
pub enum Waveform {
    None,
    Sin,
    Square,
    Triangle,
    Sawtooth,
    Noise { seed: u32 },
}

pub struct WaveformModifier {
    pub waveform: Waveform,
    pub amplitude: half::f16,
    pub frequency: half::f16,
    pub multiplicative: bool,
    noise_buffer: once_cell::sync::OnceCell<Vec<f32>>,
}

impl WaveformModifier {
    pub fn apply(&self, base_value: f32, time: f32) -> f32 {
        let phase = time * self.frequency.to_f32();

        let wf = match self.waveform {
            Waveform::None => return base_value,
            Waveform::Sin => (phase * std::f32::consts::TAU).sin(),
            Waveform::Square => (phase * std::f32::consts::TAU).sin().signum(),
            Waveform::Triangle => (phase.fract() - 0.5) * 2.0,
            Waveform::Sawtooth => {
                let f = phase % 2.0;
                let f = if f > 1.0 { 2.0 - f } else { f };
                (f - 0.5) * 2.0
            }
            Waveform::Noise { seed } => {
                let buffer = self.noise_buffer.get_or_init(|| {
                    generate_noise_buffer(*seed, self.frequency.to_f32())
                });
                sample_noise(buffer, time)
            }
        };

        let scaled = wf * self.amplitude.to_f32();

        if self.multiplicative {
            base_value * scaled
        } else {
            base_value + scaled
        }
    }
}
```

This design mirrors Phoenix's structure but uses Rust idioms:
- **Enums with associated data**: `Waveform::Noise { seed }` attaches the seed to the variant
- **`OnceCell` for lazy initialization**: Thread-safe, one-time initialization without locks
- **`half::f16` for amplitude/frequency**: Saves memory, compiles to fast SIMD
- **Pattern matching instead of switch**: Exhaustiveness checking at compile time

### Performance Considerations in Rust

Rust's zero-cost abstractions mean this code compiles to roughly the same machine code as Phoenix's C++, but with additional safety:

- **No undefined behavior**: The C++ code uses `fmodf()` and division without checking for edge cases. Rust's `%` operator is well-defined for all finite floats.
- **No buffer overruns**: Indexing `NoiseMap` in C++ trusts that `tp < WAVEFORMSPLINENOISEBUFFERSIZE`. Rust's bounds checking catches errors at runtime (or can be elided when the compiler proves safety).
- **Thread-safe lazy init**: `OnceCell` is safe to use from multiple threads, unlike the C++ static `map` which would race under concurrent access.

The Rust version would be **as fast or faster** due to LLVM optimizations and modern CPU features that weren't available when Phoenix was written (circa 2010-2015 based on DirectX 10 usage).

### Extended Waveform Types to Consider

If designing a modern framework, consider adding:

- **Perlin/Simplex noise**: Higher-quality noise for natural phenomena (clouds, terrain, fire)
- **Custom waveforms via callbacks**: Let users pass `Fn(f32) -> f32` closures for arbitrary waveforms
- **Multi-octave noise**: Layered noise at different frequencies (fractal Brownian motion) for richer textures
- **Easing functions as waveforms**: Treat ease-in/ease-out curves as one-shot waveforms that can loop

But remember: Phoenix's five waveforms cover 95% of use cases. Don't over-engineer. The beauty of demoscene design is solving 95% of problems with 5% of the code.

## Edge Cases and Gotchas

### Zero Frequency

What happens if `WaveformFrequency` is 0.0?

```cpp
float ph = t * WaveformFrequency;  // ph = t * 0.0 = 0.0 always
```

Phase is always zero, so the waveform output is constant—the value at phase 0.0:
- **Sine**: `sin(0) = 0.0`
- **Square**: `sign(sin(0)) = 1.0` (due to the `if (s == 0)` special case)
- **Triangle**: `(fmod(0, 1) - 0.5) * 2 = -1.0`
- **Sawtooth**: `((0 % 2.0) - 0.5) * 2 = -1.0`
- **Noise**: Samples the first buffer entry, which is a random value

Zero frequency effectively "freezes" the waveform at its starting value. This isn't useful intentionally, but it doesn't crash or produce NaNs—it just degenerates to a constant offset or multiplier.

### Very High Frequency

If `WaveformFrequency` is extremely large (e.g., 10,000), the phase advances rapidly, potentially causing aliasing:
- **Sine/Square**: Aliasing creates audible tones if driving audio, visual "strobing" if driving brightness
- **Triangle/Sawtooth**: High-frequency linear ramps become imperceptible—the average value dominates
- **Noise**: The sample width becomes tiny (`8192 / 10000 ≈ 0.8`), so the box blur barely smooths anything, and the noise becomes almost white again

Phoenix doesn't clamp or warn about high frequencies. If you set frequency to 1000, you get 1000 cycles per unit time. Whether that looks good is your problem. This is the demoscene philosophy: trust the artist, don't hand-hold.

### Noise Buffer Overflow

The noise sampling code uses modulo to wrap the buffer index:

```cpp
NoiseMap[(tp + 1) % WAVEFORMSPLINENOISEBUFFERSIZE]
```

This ensures no out-of-bounds access. Even if `t` is negative or greater than 1.0 (which can happen with looping splines or extended timelines), the modulo wraps it safely. However, negative `t` values produce negative indices before the modulo, which in C++ is implementation-defined behavior for `%`. In practice, on two's-complement machines (all modern hardware), it works correctly.

In Rust, `%` for negative values is well-defined: `-5 % 8192 = -5`, which would then cause a panic on array indexing. You'd need `rem_euclid()` for true mathematical modulo.

### Amplitude Overflow

`WaveformAmplitude` is a `D3DXFLOAT16`, which has a maximum value around 65,504. If you set amplitude to 100,000, it overflows to infinity. The subsequent multiplication `wf *= WaveformAmplitude` produces infinity or NaN, which propagates through the rest of the scene.

Phoenix doesn't clamp or validate amplitude. Again, this is the demoscene ethos: if you set insane values, you get insane results. The tool (APEXDEMOTOOL) might clamp inputs in the UI, but the runtime engine doesn't.

## Conclusion: Waveforms as Compositional Building Blocks

Phoenix's waveform system is a lesson in economy of design. Five waveform types, three trigonometric functions, and one filtered noise generator cover the vast majority of animation needs in a 4KB demo. The system is:

- **Composable**: Base splines define gross motion, waveforms add detail
- **Predictable**: Reproducible randomness via seeds, deterministic math
- **Efficient**: Lazy initialization, cheap per-frame cost, minimal memory overhead
- **Expressive**: Additive and multiplicative modes enable vastly different effects from the same waveforms

The elegance lies not in what's included, but in what's omitted. No custom waveforms, no envelope generators, no multi-band filters—just five proven patterns that demo artists have used for decades. This is the demoscene aesthetic: solve the 80/20 problem perfectly, then move on.

For a Rust creative coding framework, the lessons are clear:
1. **Separate base animation from modulation** — Keep interpolation and waveforms orthogonal
2. **Provide a small, complete set of waveforms** — Cover the most common patterns, don't build a synthesizer
3. **Support both additive and multiplicative modes** — They're mathematically trivial but compositionally powerful
4. **Enable reproducible randomness** — Seeded noise is essential for interactive art and synchronized demos
5. **Optimize for the common case** — Fast-path `WAVEFORM_NONE`, lazy-init expensive resources

Waveforms turn keyframes into living, breathing motion. They're the difference between a rigid, mechanical animation and one that feels organic, intentional, and alive. Master them, and you master the demoscene's secret weapon for expressive motion under impossible size constraints.

---

**File References:**
- Waveform enum: `demoscene/apex-public/apEx/Phoenix/phxSpline.h:39-47`
- Waveform parameters: `demoscene/apex-public/apEx/Phoenix/phxSpline.h:93-99`
- PostProcess implementation: `demoscene/apex-public/apEx/Phoenix/phxSpline.cpp:143-230`
- Phase calculation: `demoscene/apex-public/apEx/Phoenix/phxSpline.cpp:155`
- Noise generation: `demoscene/apex-public/apEx/Phoenix/phxSpline.cpp:193-218`
- Amplitude and mode application: `demoscene/apex-public/apEx/Phoenix/phxSpline.cpp:223-228`
