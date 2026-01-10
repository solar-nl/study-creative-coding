# Filters in V2

## The Audio Sculptor's Workshop

Imagine a sculptor standing before a rough marble block. The stone contains every possible form within it, but only through careful removal of material does the artist reveal the figure inside. The sculptor's chisel determines not just what is removed but how the edges appear: smooth curves, sharp ridges, or the subtle undulations that give surfaces life. A master sculptor might work in passes, first roughing out the overall shape, then refining with progressively finer tools.

This is exactly what audio filters do to sound. An oscillator generates a rich waveform filled with harmonics at every frequency, like that block of uncarved marble. A sawtooth wave contains all harmonics in decreasing amplitude; a pulse wave contains odd and even harmonics in complex ratios. This spectral richness provides raw material, but raw material rarely sounds musical. The filter acts as the sculptor's chisel, removing frequencies to reveal the desired timbre within.

The cutoff frequency determines where the chisel cuts. Frequencies above the cutoff (for a low-pass filter) get removed, just as stone above a certain plane might be carved away. The resonance parameter controls how the chisel behaves at the cut point: a gentle slope that gradually attenuates frequencies, or an aggressive boost right at the cutoff that creates a pronounced ridge in the frequency response. High resonance settings produce that distinctive synth "squelch" as the filter emphasizes frequencies near the cutoff while suppressing everything beyond.

V2 extends this sculpting metaphor with its dual-filter architecture. Two filters per voice means two chisels available for shaping. The patch designer can route these filters in different configurations: a single filter for efficiency, serial routing for deep cuts requiring multiple passes, or parallel routing where two sculptors work simultaneously on different aspects of the sound. Serial routing provides steeper filter slopes and more dramatic timbral changes. Parallel routing enables morphing between different filter characters, blending a warm low-pass with a nasal band-pass for sounds that evolve as modulators sweep the balance.

## Why Filters Define Character

Without filtering, synthesizers would sound thin and characterless. Raw oscillator waveforms possess geometric precision, an artificial quality that rarely occurs in acoustic instruments. A plucked guitar string begins bright and harsh, then mellows as higher harmonics decay faster than the fundamental. A bowed violin exhibits complex spectral evolution as bow pressure and speed change. These natural instruments filter their own output through resonant bodies, room acoustics, and the physical properties of vibrating materials.

The filter becomes the synthesizer's equivalent of these natural shaping mechanisms. By sweeping cutoff frequency over time, typically driven by an envelope generator, the synthesizer recreates that fundamental acoustic behavior: bright attack that mellows into a rounder sustain. By boosting resonance, it approximates the formant peaks that give acoustic instruments their recognizable character.

## The State Variable Filter: A Versatile Chisel

V2's primary filter topology is the state variable filter, a design that produces multiple simultaneous outputs from a single set of state variables. Think of it as a sculptor's chisel ground to a special profile that can create different edge types depending on which face contacts the stone. From two internal state variables named `l` (low) and `b` (band), the filter derives low-pass, band-pass, high-pass, notch, and all-pass outputs.

The elegance of the state variable design lies in its mathematical foundation. Two integrators connected in a feedback loop naturally produce resonant behavior. The filter maintains two pieces of history: the low-pass output from the previous sample and the band-pass output. Each new input sample updates these states through a simple recurrence relation, and different combinations of the states yield different filter responses.

V2 implements this through the `V2LRC` structure, where the cryptic name hints at the electrical circuit analogy (inductor-resistor-capacitor).

```cpp
struct V2LRC
{
  sF32 l, b;  // Low-pass and band-pass state

  sF32 step_2x(sF32 in, sF32 freq, sF32 reso)
  {
    in += fcdcoffset;  // Bias to prevent denormals

    // First integration step
    l += freq * b - fcdcoffset;
    b += freq * (in - b*reso - l);

    // Second integration step (2x oversampling)
    l += freq * b;
    sF32 h = in - b*reso - l;
    b += freq * h;

    return h;  // High-pass output
  }
};
```

The method name `step_2x` reveals an important implementation detail: the filter runs at twice the audio sample rate internally. This oversampling prevents instability and aliasing that would otherwise occur at high cutoff frequencies. Each call to `step_2x` performs two complete filter iterations, halving the effective cutoff frequency coefficient to compensate.

The `reso` parameter controls feedback from the band-pass output into the input. Low values produce gentle filtering with gradual frequency rolloff. Values approaching 1.0 create sharp resonant peaks at the cutoff frequency. At maximum resonance, the filter enters self-oscillation, generating its own sine wave even with no input.

## Eight Filter Modes from Two Topologies

V2 offers eight distinct filter modes, though they derive from only two underlying algorithms: the state variable filter and the Moog ladder filter. The state variable filter provides six modes with gentle 12dB-per-octave slopes, while the Moog ladder contributes two modes with the steeper 24dB-per-octave characteristic. The filter mode enum reveals this organization.

```cpp
enum Mode
{
  BYPASS,   // Pass through unchanged
  LOW,      // State variable low-pass
  BAND,     // State variable band-pass
  HIGH,     // State variable high-pass
  NOTCH,    // State variable notch (rejects band)
  ALL,      // State variable all-pass
  MOOGL,    // Moog ladder low-pass
  MOOGH     // Moog ladder high-pass
};
```

The first six modes all use the state variable filter, selecting different combinations of the internal state to produce the output. Low-pass mode returns the `l` state directly, giving frequencies below cutoff. Band-pass returns the `b` state, passing only frequencies near cutoff. High-pass returns the calculated `h` value, which contains frequencies above cutoff. Notch mode sums low and high, creating a gap at the cutoff frequency. All-pass mode combines all three, passing all frequencies but with phase shifts.

The render method implements these modes through a switch statement that selects which output to use.

```cpp
void render(sF32 *dest, const sF32 *src, sInt nsamples, sInt step=1)
{
  switch (mode & 7)
  {
  case LOW:
    for (sInt i=0; i < nsamples; i++)
    {
      flt.step_2x(src[i*step], cfreq, res);
      dest[i*step] = flt.l;  // Output low-pass state
    }
    break;

  case BAND:
    for (sInt i=0; i < nsamples; i++)
    {
      flt.step_2x(src[i*step], cfreq, res);
      dest[i*step] = flt.b;  // Output band-pass state
    }
    break;

  case NOTCH:
    for (sInt i=0; i < nsamples; i++)
    {
      sF32 h = flt.step_2x(src[i*step], cfreq, res);
      dest[i*step] = flt.l + h;  // Low plus high = notch
    }
    break;
  // ... other cases
  }
}
```

The step parameter enables stereo processing by skipping samples, though V2 uses mono processing for voice-level filters.

## The Moog Ladder: A Four-Pole Classic

The state variable filter produces 12dB-per-octave slopes, gentle enough for many applications but sometimes insufficient for the dramatic timbral sweeps that define classic synthesizer sounds. The Moog ladder filter addresses this with a 24dB-per-octave slope, four times steeper in decibel terms. This design cascades four identical single-pole low-pass stages, each contributing 6dB of attenuation per octave.

The ladder topology creates its distinctive character through nonlinear feedback. Output from the fourth stage feeds back to the input, and this feedback path includes intentional saturation. When driven hard, the ladder filter produces harmonics that warm the sound rather than simply cutting frequencies.

```cpp
struct V2Moog
{
  sF32 b[5];  // Four filter stages plus input history

  sF32 step(sF32 realin, sF32 f, sF32 p, sF32 q)
  {
    sF32 in = realin + fcdcoffset;
    sF32 t1, t2, t3, b4;

    in -= q * b[4];  // Feedback from output

    // Four cascaded single-pole stages
    t1 = b[1]; b[1] = (in + b[0]) * p - b[1] * f;
    t2 = b[2]; b[2] = (t1 + b[1]) * p - b[2] * f;
    t3 = b[3]; b[3] = (t2 + b[2]) * p - b[3] * f;
               b4   = (t3 + b[3]) * p - b[4] * f;

    b4 -= b4*b4*b4 * (1.0f/6.0f);  // Soft clipping
    b[4] = b4 - fcdcoffset;
    b[0] = realin;

    return b4;
  }
};
```

The soft clipping expression `b4 - b4*b4*b4 / 6` approximates a hyperbolic tangent curve without the computational expense. This keeps output bounded while adding subtle harmonic distortion that contributes to the Moog sound.

V2's Moog implementation runs at 2x oversampling, calling `step` twice per audio sample. The MOOGH mode implements a high-pass variant by subtracting the low-pass output from the input, a technique that works because the sum of all frequency content equals the original signal.

## Two Filters, Three Routings

Each V2 voice contains two independent filter instances, and the patch defines how signal flows through them. The routing parameter selects among three configurations, each suited to different sound design goals.

Single-filter mode uses only the first filter, ignoring the second entirely. Serial mode passes audio through the first filter, then through the second. Parallel mode splits the signal, processes through both filters simultaneously, then mixes the results with adjustable balance.

The voice render method implements these routings with straightforward logic.

```cpp
switch (fmode)
{
case FLTR_SINGLE:
  vcf[0].render(voice, voice, nsamples);
  break;

case FLTR_SERIAL:
  vcf[0].render(voice, voice, nsamples);
  vcf[1].render(voice, voice, nsamples);
  break;

case FLTR_PARALLEL:
  vcf[1].render(voice2, voice, nsamples);  // Filter 2 to temp buffer
  vcf[0].render(voice, voice, nsamples);   // Filter 1 in-place
  for (sInt i=0; i < nsamples; i++)
    voice[i] = voice[i]*f1gain + voice2[i]*f2gain;  // Mix
  break;
}
```

Serial routing creates steeper effective slopes. Two 12dB low-pass filters in series produce 24dB overall, matching the Moog ladder's steepness but with different character. Serial low-pass followed by high-pass creates a band-pass with independently controllable edges. The sculpting analogy holds: a rough chisel removes bulk material, then a fine chisel refines the surface.

Parallel routing enables timbral morphing. Set one filter to low-pass and one to band-pass, then modulate the balance between them. The sound smoothly transitions from full and warm to nasal and focused. Two sculptors working simultaneously, their contributions blended into the final form.

## Modulation: The Animated Sculpture

Static filter settings produce static timbres. The real power emerges when modulation sources animate the filter parameters. Cutoff frequency and resonance serve as primary modulation destinations throughout the V2 modulation matrix. An envelope can sweep cutoff from low to high during attack, creating the classic synth punch. An LFO can wobble resonance for a rhythmic, liquid quality.

The V2 modulation system recalculates filter coefficients every audio frame (typically 128 samples). This frame-rate update balances accuracy against efficiency. Per-sample coefficient updates would create smoother modulation but consume substantial CPU. Frame-rate updates produce stepped modulation that, at audio rates, blends together imperceptibly.

The coefficient calculation in `V2Flt::set` converts MIDI-range parameters (0-127) to filter coefficients.

```cpp
void set(const syVFlt *para)
{
  mode = (sInt)para->mode;
  sF32 f = calcfreq(para->cutoff / 128.0f) * inst->SRfclinfreq;
  sF32 r = para->reso / 128.0f;

  if (mode < MOOGL)
  {
    res = 1.0f - r;  // Invert for state variable feedback
    cfreq = f;
  }
  else
  {
    // Moog coefficient calculation
    f *= 0.25f;
    sF32 t = 1.0f - f;
    moogp = f + 0.8f * f * t;
    moogf = 1.0f - moogp - moogp;
    moogq = 4.0f * r * (1.0f + 0.5f * t * (1.0f - t + 5.6f * t * t));
  }
}
```

The `calcfreq` function applies an exponential mapping, converting linear MIDI values to perceptually uniform frequency steps. This makes a cutoff change from 64 to 72 sound like the same interval as a change from 100 to 108, matching how human hearing perceives frequency. This perceptual mapping parallels how color spaces use non-linear transforms to achieve uniform visual steps (see [Color Systems](../../../../themes/color-systems.md) for the visual equivalent).

## Rust Translation Considerations

The filter architecture translates cleanly to Rust with some idiomatic adjustments. The two filter types become enum variants, each holding their own state.

```rust
enum FilterState {
    Bypass,
    StateVariable { mode: SVMode, state: SVState },
    Moog { mode: MoogMode, state: MoogState },
}

struct SVState { low: f32, band: f32 }

enum SVMode { LowPass, BandPass, HighPass, Notch, AllPass }
```

The filter routing logic maps directly to Rust pattern matching. SIMD optimization opportunities exist in the inner loops, particularly for parallel routing where two filters process independently.

---

**See also:**
- [Voice Architecture](voice-architecture.md) - How filters fit in the voice signal chain
- [Modulation System](modulation.md) - Envelope and LFO sources for filter control
- [Note to Sound Trace](../code-traces/note-to-sound.md) - Complete signal flow walkthrough
