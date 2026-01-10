# Modulation: Bringing Static Parameters to Life

A synthesizer patch with fixed parameters sounds mechanical and lifeless. The filter cutoff stays frozen at one frequency. The oscillator pitch never wavers. Every note rings out with identical character, like a player piano hitting keys with robotic precision. Real instruments breathe, wobble, and evolve over time because the performer continuously adjusts how they play. Modulation gives synthesized sound that same organic movement.

Think of modulation as a puppeteer controlling a marionette. The puppet itself represents your synthesizer voice with all its parameters: the filter cutoff, oscillator pitch, amplifier volume, and dozens of other settings. Without the puppeteer, the puppet just hangs there, frozen in whatever pose you left it. The puppeteer's hands are the modulation sources: envelopes that sweep parameters during each note, LFOs that create rhythmic wobbles, velocity that responds to how hard you play. The crossbar of strings connecting those hands to the puppet's joints is the modulation matrix, routing each source to one or more destinations. The length of each string determines the modulation amount, how far that source pulls that parameter away from its static value.

This puppeteer analogy captures something essential about V2's modulation architecture. Multiple hands can pull the same joint: the filter cutoff might respond to both an envelope sweep and an LFO wobble simultaneously, their influences summing together. The puppeteer's reaction time matters: modulation updates happen at a slower "frame rate" than the audio itself, creating a subtle temporal relationship between control signals and sound output. And the puppet's movements must remain smooth even when the puppeteer makes sudden gestures, requiring careful interpolation to prevent audible discontinuities.

V2 solves these challenges with a two-tier timing system. Modulation sources update once per frame, approximately 344 times per second at the standard 44.1kHz sample rate. Audio generation runs at the full sample rate, 44,100 times per second, but interpolates modulated values smoothly across each frame. This design reflects a fundamental tension in real-time synthesis: computing modulation sources costs CPU cycles, so you want to update them as infrequently as possible without introducing audible artifacts. The 128-sample frame size strikes a pragmatic balance, keeping modulation smooth while leaving enough cycles for the computationally expensive audio generation.

## Envelope Generators: Shaping Sound Over Time

The most essential modulation source is the envelope generator, which creates time-varying contours that shape how a sound evolves from the moment you press a key until long after you release it. In our puppeteer analogy, the envelope is a hand that makes deliberate, scripted gestures: reaching upward during attack, settling back during decay, holding steady through sustain, then dropping away on release. Unlike the LFO's rhythmic oscillations, the envelope follows a one-way trajectory triggered by each note event. V2 implements a five-stage envelope: attack, decay, sustain, sustain-time, and release. The attack phase ramps the envelope up from zero to maximum. Decay then brings it down to the sustain level. The sustain phase holds at that level, with an optional slope that can rise or fall over time. Finally, release brings the envelope back to zero when you lift your finger from the key.

The envelope operates as a state machine driven by the gate signal. When you press a key, the gate goes high and the envelope jumps to attack state regardless of its current position. When you release, the gate goes low and the envelope transitions to release state, decaying from wherever it happens to be at that moment.

Here is how V2 defines the envelope's internal state and parameters:

```cpp
struct V2Env
{
  enum State { OFF, RELEASE, ATTACK, DECAY, SUSTAIN };

  sF32 out;   // final output value
  State state;
  sF32 val;   // raw output (0.0-128.0)
  sF32 atd;   // attack delta (added per frame)
  sF32 dcf;   // decay factor (multiplied per frame)
  sF32 sul;   // sustain level
  sF32 suf;   // sustain factor
  sF32 ref;   // release factor
  sF32 gain;  // output gain
};
```

The attack phase uses additive ramping while all other phases use multiplicative decay. This asymmetry reflects psychoacoustic reality: we perceive the onset of a sound linearly but its decay logarithmically. A linear attack feels natural, but a linear decay sounds artificial because our ears expect exponential falloff.

The tick function advances the envelope by one frame. Notice how the state transitions cascade: attack leads to decay which leads to sustain, while release can occur from any state when the gate drops.

```cpp
void tick(bool gate)
{
  // gate transitions override current state
  if (state <= RELEASE && gate)
    state = ATTACK;
  else if (state >= ATTACK && !gate)
    state = RELEASE;

  switch (state)
  {
  case ATTACK:
    val += atd;
    if (val >= 128.0f) { val = 128.0f; state = DECAY; }
    break;

  case DECAY:
    val *= dcf;
    if (val <= sul) { val = sul; state = SUSTAIN; }
    break;

  case SUSTAIN:
    val *= suf;
    if (val > 128.0f) val = 128.0f;
    break;

  case RELEASE:
    val *= ref;
    break;
  }

  // prevent denormals from accumulating
  if (val <= fclowest) { val = 0.0f; state = OFF; }

  out = val * gain;
}
```

The decay and release factors are derived from user-facing parameter values through a frequency calculation that maps the 0-127 MIDI range to perceptually useful time constants. Setting decay to zero produces instant transitions (relying on volume ramping to smooth the discontinuity), while maximum values yield decay times measured in seconds.

## LFOs: Rhythmic Modulation

Low Frequency Oscillators provide periodic modulation, the wobbles and pulses that add vibrato, tremolo, and rhythmic movement to sounds. V2's LFOs generate five waveforms: sawtooth, triangle, pulse, sine, and sample-and-hold noise. Each LFO can sync to note events, run in one-shot envelope mode, and output in positive-only, negative-only, or bipolar polarity.

The LFO structure reveals its dual nature as both an oscillator and a modulation source:

```cpp
struct V2LFO
{
  enum Mode { SAW, TRI, PULSE, SIN, S_H };

  sF32 out;       // current output value
  sInt mode;      // waveform selection
  bool sync;      // reset phase on note-on
  bool eg;        // one-shot envelope mode
  sInt freq;      // phase increment per frame
  sU32 cntr;      // current phase (32-bit for precision)
  sU32 cphase;    // phase offset for sync
  sF32 gain;      // output scaling
  sF32 dc;        // DC offset for polarity modes
  sU32 nseed;     // random seed for S&H
  sU32 last;      // previous counter for S&H detection
};
```

The 32-bit phase counter provides extremely fine frequency resolution without floating-point rounding errors accumulating over time. Each tick adds the frequency increment to the counter, and waveform generation derives from the current counter value. Returning to our puppeteer analogy, the LFO is a hand that moves in predictable patterns, cycling through its waveform shape with metronomic regularity.

The waveform generation exploits bit manipulation for efficiency. Triangle waves XOR the phase with its sign bit to create the fold-back. Pulse waves simply test the sign bit. The sample-and-hold mode detects counter wraparound by comparing against the previous value, generating new random values only at the waveform's fundamental frequency.

```cpp
void tick()
{
  sF32 v;
  sU32 x;

  switch (mode)
  {
  case SAW:
    v = utof23(cntr);  // direct phase-to-output mapping
    break;

  case TRI:
    x = (cntr << 1) ^ (sS32(cntr) >> 31);  // XOR with sign creates fold
    v = utof23(x);
    break;

  case PULSE:
    x = sS32(cntr) >> 31;  // sign bit becomes output
    v = utof23(x);
    break;

  case SIN:
    v = utof23(cntr);
    v = fastsinrc(v * fc2pi) * 0.5f + 0.5f;  // normalized 0-1
    break;

  case S_H:
    if (cntr < last)           // wraparound detection
      nseed = urandom(&nseed); // new random value
    last = cntr;
    v = utof23(nseed);
    break;
  }

  out = v * gain + dc;
  cntr += freq;

  if (cntr < (sU32)freq && eg)  // one-shot mode: clamp at wrap
    cntr = ~0u;
}
```

The polarity modes transform the 0-1 raw output into the desired range. Positive mode outputs 0 to amplitude. Negative mode outputs -amplitude to 0. Bipolar mode centers around zero, outputting -amplitude/2 to +amplitude/2. This flexibility lets the same LFO waveform serve different musical purposes: positive-only for filter sweeps that should stay above a baseline, bipolar for vibrato that should oscillate around the center pitch.

## The Modulation Matrix: Connecting Hands to Joints

The modulation matrix is the crossbar of strings that connects modulation sources to destinations. V2 allocates up to 255 routing slots per patch, each specifying a source, an amount, and a destination parameter. When computing a voice's parameters, the synth starts with the static patch values, then iterates through all modulation routings and applies the scaled source outputs additively.

Each routing entry occupies just three bytes, a remarkably compact representation:

```cpp
struct V2Mod
{
  sU8 source;  // 0=velocity, 1-7=controllers, 8-9=EG, 10-11=LFO, 12=note
  sU8 val;     // amount: 0=-100%, 64=0%, 128=+100%
  sU8 dest;    // parameter index into voice or channel arrays
};
```

The thirteen modulation sources cover the essential inputs. Velocity responds to how hard you play each note. Seven MIDI controller inputs accept external modulation. The two envelope generators and two LFOs provide internal time-varying signals. Note number lets you create keyboard tracking, making parameters respond to which key you press.

The source-fetching logic maps source indices to actual values:

```cpp
sF32 getmodsource(const V2Voice *voice, sInt chan, sInt source) const
{
  switch (source)
  {
  case 0:  // velocity
    return voice->velo;

  case 1: case 2: case 3: case 4: case 5: case 6: case 7:  // controllers
    return chans[chan].ctl[source-1];

  case 8: case 9:  // envelope outputs
    return voice->env[source-8].out;

  case 10: case 11:  // LFO outputs
    return voice->lfo[source-10].out;

  default:  // note number (keyboard tracking)
    return 2.0f * (voice->note - 48.0f);
  }
}
```

The modulation application happens in `storeV2Values`, called once per frame for each active voice. The function copies static parameter values into working storage, then applies all modulation routings before setting up the voice for rendering:

```cpp
void storeV2Values(sInt vind)
{
  const V2Sound *patch = getpatch(chans[chanmap[vind]].pgm);
  syVV2 *vpara = &voicesv[vind];
  sF32 *vparaf = (sF32 *)vpara;
  V2Voice *voice = &voicesw[vind];

  // start with static patch values
  for (sInt i=0; i < COUNTOF(patch->voice); i++)
    vparaf[i] = (sF32)patch->voice[i];

  // apply modulation matrix
  for (sInt i=0; i < patch->modnum; i++)
  {
    const V2Mod *mod = &patch->modmatrix[i];
    if (mod->dest >= COUNTOF(patch->voice))
      continue;

    sF32 scale = (mod->val - 64.0f) / 64.0f;  // -1 to +1 range
    vparaf[mod->dest] = clamp(
      vparaf[mod->dest] + scale * getmodsource(voice, chan, mod->source),
      0.0f, 128.0f
    );
  }

  voice->set(vpara);
}
```

The amount value uses an offset encoding: 64 means zero modulation, values below 64 produce negative scaling, and values above 64 produce positive scaling. This lets the same source either increase or decrease a destination parameter. The final result is clamped to the valid parameter range, preventing modulation from pushing values into undefined territory.

Multiple routings to the same destination simply accumulate. If you route both an LFO and an envelope to filter cutoff, their effects sum together. The puppeteer's multiple hands all pull on the same joint, their individual contributions combining into the final position.

## Frame-Rate Modulation and Volume Ramping

V2 updates modulation at frame rate, not sample rate. At 44.1kHz with 128-sample frames, this works out to roughly 344 modulation updates per second. The puppeteer's hands move at this slower frame rate, but the puppet's joints must move smoothly between positions to avoid audible stepping artifacts.

The frame size calculation adapts to different sample rates:

```cpp
static const sF32 fcframebase = 128.0f;  // base frame size in samples
static const sF32 fcsrbase = 44100.0f;   // base sample rate

void calcNewSampleRate(sInt samplerate)
{
  sF32 sr = (sF32)samplerate;
  SRcFrameSize = (sInt)(fcframebase * sr / fcsrbase + 0.5f);
  SRfciframe = 1.0f / (sF32)SRcFrameSize;
}
```

Volume ramping solves the most audible discontinuity problem. The voice amplitude, driven by envelope generator 1, must not jump between frames because sudden amplitude changes create clicks. The solution is linear interpolation: compute where the volume should be at frame end, calculate the per-sample ramp slope, then apply that slope during rendering.

The voice tick function computes the ramping slope:

```cpp
void tick()
{
  for (sInt i=0; i < syVV2::NENV; i++)
    env[i].tick(gate);

  for (sInt i=0; i < syVV2::NLFO; i++)
    lfo[i].tick();

  // compute per-sample volume ramp
  volramp = (env[0].out / 128.0f - curvol) * inst->SRfciframe;
}
```

During rendering, the volume interpolates smoothly across every sample:

```cpp
sF32 cv = curvol;
for (sInt i=0; i < nsamples; i++)
{
  sF32 out = voice[i] * cv;
  cv += volramp;

  dest[i].l += lvol * out;
  dest[i].r += rvol * out;
}
curvol = cv;
```

This linear ramping bridges the gap between frame-rate modulation updates and sample-rate audio output. The envelope might jump from sustain to release when you lift a key, but the volume slides smoothly from its current value toward zero rather than dropping instantaneously. The puppeteer's hand moves at frame rate, but the joint glides smoothly between positions.

## Design Insights for Rust Implementation

V2's modulation architecture offers several patterns worth preserving in a modern Rust synthesizer. The frame-rate/sample-rate split remains relevant: modulation at control rate reduces computation while volume ramping maintains audio quality. The modulation matrix's three-byte routing entries achieve remarkable expressiveness in minimal space, valuable for memory-constrained contexts.

The puppeteer model suggests a trait-based abstraction:

```rust
trait ModulationSource {
    fn tick(&mut self);
    fn output(&self) -> f32;
}

trait ModulationDestination {
    fn apply_modulation(&mut self, amount: f32, value: f32);
}
```

The modulation matrix becomes a routing table that connects sources to destinations, evaluated once per frame before audio rendering begins. Rust's ownership model naturally enforces the separation between parameter storage and modulation application that V2 achieves through careful pointer discipline.

Volume ramping generalizes to any parameter that changes discontinuously at frame boundaries. A `RampedParameter` type could encapsulate the current value, target value, and per-sample delta, automatically interpolating during audio callbacks. This transforms the manual ramping in V2 into a reusable abstraction.

The five-state envelope maps cleanly to a Rust enum with associated data. Pattern matching replaces the switch statement, and the state transitions become explicit edge cases. The multiplicative decay constants might benefit from Rust's const evaluation, computing the exponential curves at compile time rather than during `set()`.

---

*See also: [Oscillator Algorithms](./oscillators.md) for the audio generators these modulation signals control, [Voice Architecture](./voice.md) for how envelopes and LFOs fit into the per-voice processing pipeline, and [Filter Implementation](./filters.md) for a common modulation destination. For broader context on control-rate vs. audio-rate processing patterns, see the [Architecture Overview](./README.md).*
