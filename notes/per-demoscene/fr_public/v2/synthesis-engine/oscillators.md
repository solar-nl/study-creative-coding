# Oscillators in V2: The Raw Materials of Sound

## The Sound Painter's Brushes

Every painter begins with brushes. A broad flat brush lays down sweeping backgrounds. A fine-tipped round brush traces delicate details. A textured bristle brush creates organic, unpredictable strokes. The choice of brush fundamentally shapes what appears on the canvas, not through color alone, but through the very character of each mark.

The V2 synthesizer treats its oscillators exactly like an artist's brushes. Each oscillator paints a particular stroke onto the sonic canvas. A sawtooth oscillator sweeps boldly across the frequency spectrum, rich with harmonics. A sine oscillator traces pure, clean curves with mathematical precision. A noise oscillator splatters random texture across the entire bandwidth. The synthesizer gives you three brushes to work with simultaneously, each capable of seven distinct stroke styles. How you combine them determines whether your sound sings with crystalline clarity or growls with aggressive complexity.

The problem oscillators solve is fundamental: where does sound come from? Before filtering, before modulation, before effects, something must vibrate. In the physical world, a violin string oscillates when bowed. A clarinet reed pulses when air passes over it. A drum membrane shakes when struck. Each vibrating body produces a characteristic pattern of pressure waves that our ears interpret as timbre. The oscillator is the digital equivalent of these vibrating bodies, generating the raw waveform patterns that all subsequent processing shapes and sculpts.

Why does V2 provide three oscillators per voice rather than one or ten? The choice reflects decades of synthesizer design wisdom. A single oscillator produces thin, static tones. Two oscillators enable detuning for chorus effects and octave layering for richness. Three oscillators hit a sweet spot: enough for complex timbres including a fundamental, an octave doubling, and a detuned chorusing layer, without excessive CPU cost or patch complexity. Classic hardware synthesizers from the Minimoog to the Prophet-5 established this three-oscillator template, and V2 follows their lead.

The real sophistication lies not in the oscillator count but in how they interact. Each oscillator can either add its output to the mix or multiply it against what came before. This multiplication mode, called ring modulation, creates the sonic equivalent of a moire pattern where two grids overlap to produce interference fringes. The result contains frequencies present in neither original signal, generating metallic, bell-like, or alien textures impossible through simple mixing.

## Seven Stroke Styles

The `mode` parameter selects which waveform an oscillator generates. Each mode produces fundamentally different harmonic content, analogous to how a calligraphy brush, a house-painting brush, and an airbrush create entirely different marks despite all applying paint to canvas.

Mode 0 silences the oscillator entirely, useful when a patch needs only one or two sound sources. Mode 1 generates the generalized triangle-sawtooth wave, V2's most versatile brush. Mode 2 produces pulse waves with variable width. Mode 3 generates pure sine waves. Mode 4 outputs filtered noise. Mode 5 enables FM synthesis where the oscillator's pitch bends according to the current buffer contents. Modes 6 and 7 tap into auxiliary buses, allowing voices to incorporate external signals.

The triangle-sawtooth mode deserves special attention as V2's workhorse waveform. Rather than offering separate triangle and sawtooth oscillators, V2 combines them into a single continuously variable shape controlled by the `color` parameter. When color sits at the midpoint, the oscillator produces a symmetric triangle wave. Pushing color toward one extreme morphs the shape into a pure sawtooth ramping upward. Pushing the other direction produces a sawtooth ramping downward. This continuous morphing provides more timbral range than discrete waveform selection would allow.

The following enumeration shows how V2 labels its oscillator modes internally.

```cpp
enum Mode
{
  OSC_OFF     = 0,  // Silent
  OSC_TRI_SAW = 1,  // Variable triangle-sawtooth
  OSC_PULSE   = 2,  // Pulse wave with variable duty cycle
  OSC_SIN     = 3,  // Pure sine
  OSC_NOISE   = 4,  // Filtered noise
  OSC_FM_SIN  = 5,  // FM synthesis (carrier is sine)
  OSC_AUXA    = 6,  // Aux bus A input
  OSC_AUXB    = 7,  // Aux bus B input
};
```

The render dispatcher examines the mode and calls the appropriate specialized routine. Each waveform type requires different mathematics, so separating them into distinct functions enables optimization without tangled conditional logic.

```cpp
void render(sF32 *dest, sInt nsamples)
{
  switch (mode & 7)
  {
  case OSC_OFF:     break;
  case OSC_TRI_SAW: renderTriSaw(dest, nsamples); break;
  case OSC_PULSE:   renderPulse(dest, nsamples); break;
  case OSC_SIN:     renderSin(dest, nsamples); break;
  case OSC_NOISE:   renderNoise(dest, nsamples); break;
  case OSC_FM_SIN:  renderFMSin(dest, nsamples); break;
  case OSC_AUXA:    renderAux(dest, inst->auxabuf, nsamples); break;
  case OSC_AUXB:    renderAux(dest, inst->auxbbuf, nsamples); break;
  }
}
```

## Brushes Working Together

A painter rarely uses a single brush for an entire painting. Backgrounds get broad strokes, details get fine lines, and textures emerge from combining multiple brush techniques on the same area. V2's three oscillators work similarly, each contributing to the final sound through either addition or multiplication.

The default combination mode simply adds each oscillator's output to an accumulating buffer. The first oscillator writes its waveform. The second oscillator adds its waveform on top. The third adds its contribution. The resulting signal contains all the harmonic content from all three sources superimposed.

Ring modulation provides the alternative combination mode. When an oscillator has ring mode enabled, it multiplies its output against the buffer rather than adding to it. This multiplication creates sum and difference frequencies. If oscillator one generates a 440Hz tone and oscillator two (in ring mode) generates a 100Hz tone, the result contains 540Hz (sum) and 340Hz (difference) but neither original frequency. The sonic character becomes inharmonic, metallic, and complex.

The output method encapsulates this simple but powerful switching logic.

```cpp
inline void output(sF32 *dest, sF32 x)
{
  if (ring)
    *dest *= x;  // Ring modulation: multiply
  else
    *dest += x;  // Normal: accumulate
}
```

## From Note to Frequency

When a MIDI note arrives, the oscillator must translate the abstract note number into a concrete frequency. MIDI note 60 represents middle C at 261.63Hz. Note 72 represents the C one octave higher at 523.25Hz. Note 48 represents the C one octave lower at 130.81Hz. Each semitone step multiplies frequency by the twelfth-root-of-two, approximately 1.0595.

V2 performs this conversion using an exponential formula. The base frequency constant encodes middle C's frequency scaled for the sample rate and the 32-bit phase accumulator range. The exponent adjusts by the number of semitones away from middle C, plus any transpose and detune offsets from the patch parameters.

The `chgPitch` method calculates the phase increment that the oscillator will add to its counter each sample.

```cpp
void chgPitch()
{
  // Calculate phase increment for 32-bit counter
  // freq = basefrq * 2^((pitch + note - 60) / 12)
  freq = (sInt)(inst->SRfcobasefrq * pow(2.0f, (pitch + note - 60.0f) / 12.0f));
}
```

The constants establishing the base frequency appear in the V2Instance initialization. The oscillator base frequency constant of 261.6255653Hz corresponds precisely to middle C in twelve-tone equal temperament. Multiplying by 2^31 and dividing by the sample rate yields the phase increment that would complete one full cycle at middle C's frequency.

```cpp
static const sF32 fcoscbase = 261.6255653f;  // Middle C frequency in Hz
static const sF32 fc32bit = 2147483648.0f;   // 2^31 for full phase range

// In calcNewSampleRate:
SRfcobasefrq = (fcoscbase * fc32bit) / sr;
```

## The Phase Accumulator: Painting Without Drift

Imagine a brush that moves across the canvas at a perfectly steady rate, returning to its starting position exactly on time, cycle after cycle, without ever drifting early or late. The phase accumulator provides this drift-free periodicity through the elegant mathematics of integer overflow.

The oscillator maintains a 32-bit unsigned counter. Each sample, it adds the frequency increment to this counter. When the counter exceeds its maximum value, it wraps around to zero automatically. This wrapping is not a bug but the core mechanism. The counter sweeps from 0 to 4,294,967,295 and back to 0, tracing out exactly one waveform cycle in the process.

The frequency increment determines how many steps the counter takes per sample. A larger increment means faster cycling and higher pitch. Because integer addition and overflow are exact operations, no rounding errors accumulate. The oscillator stays perfectly in tune indefinitely.

## The Aliasing Problem

A naive approach to oscillator generation would simply sample the mathematical waveform at each instant. The problem is that sawtooth, pulse, and triangle waves contain infinite harmonics extending far above human hearing. When the sample rate cannot represent these high frequencies, they fold back into the audible range as aliasing artifacts, creating harsh distortion that worsens at higher pitches.

V2 addresses this through analytical integration. Rather than asking "what is the waveform value at time t?", V2 asks "what is the average waveform value between time t and time t+h?" where h is one sample period. This averaging smooths out the sharp transitions that cause aliasing.

For the triangle-sawtooth wave, computing this average requires tracking which waveform segments fall within each sample interval. The waveform rises linearly, then falls. A sample interval might fall entirely within the rising phase, entirely within the falling phase, or straddle the transition. V2's state machine tracks these cases.

```cpp
enum OSMTransitionCode    // Encodes which waveform regions the interval spans
{
  OSMTC_DOWN = 0,         // Purely in falling phase
  OSMTC_UP_DOWN = 2,      // Rising then falling
  OSMTC_UP = 3,           // Purely in rising phase
  OSMTC_DOWN_UP_DOWN = 4, // Falling, rising, falling (wraps around)
  OSMTC_DOWN_UP = 5,      // Falling then rising (wraps around)
  OSMTC_UP_DOWN_UP = 7    // Rising, falling, rising (wraps around)
};
```

The common cases require only the average of a linear function, which equals the midpoint value. Transition cases integrate separate segments. The complete rendering handles all six cases.

```cpp
void renderTriSaw(sF32 *dest, sInt nsamples)
{
  sF32 f = utof23(freq);       // Frequency as fraction of sample rate
  sF32 rcpf = 1.0f / f;        // Reciprocal for transition cases
  sF32 col = utof23(brpt);     // Break point (shape control)

  sF32 c1 = gain / col;        // Scaled integration constant for rising
  sF32 c2 = -gain / (1.0f - col);  // For falling

  sU32 state = osm_init();

  for (sInt i=0; i < nsamples; i++)
  {
    sF32 p = utof23(cnt) - col;
    sF32 y = 0.0f;

    switch (osm_tick(state))
    {
    case OSMTC_UP:    // Simple: average of linear rising ramp
      y = c1 * (p + p - f);
      break;
    case OSMTC_DOWN:  // Simple: average of linear falling ramp
      y = c2 * (p + p - f);
      break;
    case OSMTC_UP_DOWN:  // Transition: integrate both segments
      y = rcpf * (c2 * sqr(p) - c1 * sqr(p-f));
      break;
    // ... additional transition cases
    }
    output(dest + i, y + gain);
  }
}
```

## Sine and Noise: Special Cases

The sine wave requires no anti-aliasing because it contains only a single frequency component. V2 exploits this purity by using a direct computation with a fast polynomial approximation of sine. A quarter-wave symmetry optimization reduces the calculation to the range where the approximation achieves highest accuracy.

```cpp
void renderSin(sF32 *dest, sInt nsamples)
{
  for (sInt i=0; i < nsamples; i++)
  {
    sU32 phase = cnt + 0x40000000;  // Add pi/2 to get cosine->sine
    cnt += freq;

    // Exploit symmetry: cos(x) = cos(-x)
    if (phase & 0x80000000)
      phase = ~phase;

    // Convert phase to float in [-pi/2, pi/2]
    sF32 t = bits2float((phase >> 8) | 0x3f800000);
    t = t * fcpi - fc1p5pi;

    output(dest + i, gain * fastsin(t));
  }
}
```

Noise requires the opposite treatment. Where sine has no harmonics to alias, noise has all frequencies equally represented. V2 generates white noise through a linear congruential random number generator, then passes it through a resonant filter controlled by the color parameter. This filtering shapes the noise spectrum from bright hiss to dark rumble (see [Filters](filters.md) for how V2 implements its filter stages).

## FM Synthesis: One Brush Guides Another

Frequency modulation synthesis represents V2's most exotic oscillator mode. The FM oscillator uses the current buffer contents to bend its pitch continuously. Whatever the previous oscillators produced becomes the modulation signal, enabling extraordinary flexibility: slow sine for vibrato, fast pulse for aggressive digital timbres, or filtered noise for evolving textures.

```cpp
void renderFMSin(sF32 *dest, sInt nsamples)
{
  for (sInt i=0; i < nsamples; i++)
  {
    sF32 mod = dest[i] * fcfmmax;           // Scale modulator
    sF32 t = (utof23(cnt) + mod) * fc2pi;   // Add modulation to phase
    cnt += freq;

    sF32 out = gain * fastsinrc(t);
    if (ring)
      dest[i] *= out;
    else
      dest[i] = out;  // Replace buffer with FM output
  }
}
```

The key line `dest[i] * fcfmmax` reads the current buffer value as the modulation depth. The `fcfmmax` constant of 2.0 scales this modulation to a reasonable range. The modulation directly offsets the phase before the sine calculation, creating the characteristic FM shimmer.

## Rust Translation: Idiomatic Oscillators

The V2 oscillator architecture translates naturally to Rust with enum-based waveform selection replacing integer mode codes. Each waveform variant can carry its specific state, keeping related data together.

```rust
enum OscillatorMode {
    Off,
    TriSaw { break_point: u32 },
    Pulse { duty_cycle: u32 },
    Sine,
    Noise { filter: LrcFilter, seed: u32 },
    FmSine,
    Aux(AuxBus),
}

struct Oscillator {
    mode: OscillatorMode,
    ring: bool,
    counter: u32,
    frequency: i32,
    gain: f32,
}
```

The phase accumulator benefits from Rust's `Wrapping<u32>` type, making the overflow behavior explicit rather than relying on implementation-defined wraparound. The inner rendering loops are candidates for SIMD optimization through `std::simd`.

---

**See also:**
- [Voice Architecture](voice-architecture.md) - How oscillators fit into the voice structure
- [Modulation System](modulation.md) - Envelopes and LFOs that control oscillator parameters
- [Note to Sound Trace](../code-traces/note-to-sound.md) - Complete signal flow from MIDI to audio
