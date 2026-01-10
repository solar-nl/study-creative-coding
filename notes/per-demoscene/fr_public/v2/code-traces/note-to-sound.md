# Code Trace: MIDI Note to Audio Output

## Overview

The V2 synthesizer implements a complete signal path from MIDI input to audio output through a carefully architected series of stages. When a MIDI Note On message arrives, the synthesizer allocates a voice from its 64-voice polyphony pool, initializes oscillators with the note frequency, and begins processing. Each audio frame (~128 samples at 44.1kHz), the voice renders oscillator waveforms, passes them through configurable filter chains, applies distortion and DC filtering, then mixes the result into a channel buffer. Channels accumulate multiple voices and apply their own effects (compression, boost, chorus/delay, distortion). Finally, all channels are summed with global reverb and delay effects before output.

The architecture uses a "parameter" struct (e.g., `syVOsc`) for patch data that gets converted each frame into "working" state (e.g., `V2Osc`) that holds both parameters and runtime state. This separation enables efficient modulation matrix processing where MIDI controllers, envelopes, and LFOs can dynamically modify any parameter.

## Stage 1: MIDI Input Processing

### Entry Point
- **Function**: `V2Synth::processMIDI()` (synth_core.cpp:2799-3004)
- **C API wrapper**: `synthProcessMIDI()` (synth_core.cpp:3290-3293)

### Data Structures
```cpp
// Channel state - holds program and controller values
struct V2ChanInfo {
  sU8 pgm;      // Current program/patch number (0-127)
  sU8 ctl[7];   // Controller values: mod, breath, ctl3-6, volume
};

// Synth-level tracking
struct V2Synth {
  sU32 mrstat;          // MIDI running status byte
  sU32 curalloc;        // Monotonic allocation counter for LRU
  sInt chanmap[64];     // voice -> channel mapping (-1 = free)
  sU32 allocpos[64];    // allocation timestamp per voice
  V2ChanInfo chans[16]; // per-channel state
};
```

### MIDI Message Parsing
The parser uses MIDI running status - once a status byte is received, subsequent data bytes are interpreted using that status until a new one arrives.

```cpp
void processMIDI(const sU8 *cmd) {
  while (*cmd != 0xfd) { // 0xfd = end of stream marker
    if (*cmd & 0x80)     // High bit set = status byte
      mrstat = *cmd++;

    sInt chan = mrstat & 0xf;
    switch ((mrstat >> 4) & 7) {
      case 1: // Note On (0x9n)
        // cmd[0] = note, cmd[1] = velocity
        // velocity == 0 is treated as Note Off
        break;
      case 0: // Note Off (0x8n)
        break;
      case 3: // Control Change (0xBn)
        // cmd[0] = controller number, cmd[1] = value
        break;
      case 4: // Program Change (0xCn)
        break;
      // ... other message types
    }
  }
}
```

### Rust Translation Notes
- Use an enum for MIDI message types with pattern matching
- Consider a streaming parser that yields `MidiEvent` values
- Running status could be internal parser state

```rust
enum MidiEvent {
    NoteOn { channel: u8, note: u8, velocity: u8 },
    NoteOff { channel: u8, note: u8, velocity: u8 },
    ControlChange { channel: u8, controller: u8, value: u8 },
    ProgramChange { channel: u8, program: u8 },
}
```

## Stage 2: Voice Allocation

### Location
- synth_core.cpp:2818-2898 (inside Note On handling)

### Data Structures
```cpp
// Core allocation state
sInt chanmap[POLY];    // Which channel owns each voice (-1 = free)
sU32 allocpos[POLY];   // When was each voice allocated (for LRU)
sU32 curalloc;         // Global allocation counter
sInt voicemap[CHANS];  // Last voice allocated to each channel
```

### Allocation Algorithm

The voice allocator follows a priority scheme:

1. **Check polyphony limit**: Get max polyphony from patch definition
2. **If under limit**: Find any free voice (`chanmap[i] < 0`)
3. **If at limit**: Search only voices on current channel
4. **Priority order**:
   - First: Free voices
   - Second: Oldest voice with gate off (in release phase)
   - Third: Oldest voice period (voice stealing)

```cpp
// Step 1: Try to find a free voice if under polyphony limit
sInt usevoice = -1;
if (!npoly || npoly < sound->maxpoly) {
  for (sInt i=0; i < POLY; i++) {
    if (chanmap[i] < 0) {  // Free voice found
      usevoice = i;
      break;
    }
  }
}

// Step 2: If no free voice, find oldest with gate off
if (usevoice < 0) {
  sU32 oldest = curalloc;
  for (sInt i=0; i < POLY; i++) {
    if ((chanmap[i] & chanmask) == chanfind &&
        !voicesw[i].gate &&
        allocpos[i] < oldest) {
      oldest = allocpos[i];
      usevoice = i;
    }
  }
}

// Step 3: Still nothing? Take oldest active voice (voice stealing)
if (usevoice < 0) {
  sU32 oldest = curalloc;
  for (sInt i=0; i < POLY; i++) {
    if ((chanmap[i] & chanmask) == chanfind &&
        allocpos[i] < oldest) {
      oldest = allocpos[i];
      usevoice = i;
    }
  }
}

// Step 4: Assign and trigger
chanmap[usevoice] = chan;
voicemap[chan] = usevoice;
allocpos[usevoice] = curalloc++;
storeV2Values(usevoice);  // Apply patch + modulation
voicesw[usevoice].noteOn(note, velocity);
```

### Rust Translation Notes
- Model as a pool allocator with `Option<ChannelId>` ownership
- Use `std::cmp::Ordering` for prioritized search
- Consider a `VoiceAllocator` trait for different strategies

```rust
struct VoicePool {
    voices: Vec<Voice>,
    allocation_counter: u64,
    allocations: Vec<Option<VoiceAllocation>>,
}

struct VoiceAllocation {
    channel: usize,
    timestamp: u64,
    gate: bool,
}
```

## Stage 3: Note-to-Frequency Conversion

### Location
- `V2Osc::chgPitch()` (synth_core.cpp:534-538)
- Called from `noteOn()` and `set()`

### Data Structures
```cpp
struct V2Osc {
  sInt freq;     // Phase increment per sample (32-bit fixed point)
  sF32 note;     // MIDI note number (with transpose)
  sF32 pitch;    // Fine pitch offset from patch
  V2Instance *inst;  // For sample rate constants
};
```

### Conversion Formula
The conversion uses standard 12-TET equal temperament with A4 = 440Hz implied through the base frequency constant.

```cpp
void chgPitch() {
  // Calculate phase increment for 32-bit counter
  // freq = basefrq * 2^((pitch + note - 60) / 12)
  freq = (sInt)(inst->SRfcobasefrq * pow(2.0f, (pitch + note - 60.0f) / 12.0f));

  // Also calculate noise filter frequency based on pitch
  nffrq = inst->SRfclinfreq * calcfreq((pitch + 64.0f) / 128.0f);
}

// In V2Instance initialization:
// SRfcobasefrq = (261.6255653 * 2^31) / samplerate
// This is middle C (C4) mapped to full 32-bit phase range
static const sF32 fcoscbase = 261.6255653f;  // Middle C frequency
SRfcobasefrq = (fcoscbase * fc32bit) / sr;
```

### Key Constants
- `fc32bit = 2147483648.0f` (2^31) - Full phase range
- `fcoscbase = 261.6255653f` - Middle C (MIDI note 60)
- Note 60 is the reference point (hence `note - 60` in formula)

### Rust Translation Notes
- Use const generics or associated constants for tuning systems
- Consider a `Pitch` type that wraps the frequency calculation
- Fixed-point phase accumulators map well to Rust's wrapping arithmetic

```rust
const MIDDLE_C_HZ: f32 = 261.6255653;
const PHASE_BITS: u32 = 32;

fn note_to_freq_increment(note: f32, sample_rate: f32) -> u32 {
    let base = (MIDDLE_C_HZ * (1u64 << PHASE_BITS) as f32) / sample_rate;
    (base * 2.0_f32.powf((note - 60.0) / 12.0)) as u32
}
```

## Stage 4: Oscillator Rendering

### Location
- `V2Osc::render()` (synth_core.cpp:554-569)
- Mode-specific: `renderTriSaw()`, `renderPulse()`, `renderSin()`, etc.

### Data Structures
```cpp
struct syVOsc {  // Patch parameters
  sF32 mode;     // Oscillator type (0-7)
  sF32 ring;     // Ring modulation enable
  sF32 pitch;    // Pitch offset
  sF32 detune;   // Fine detune
  sF32 color;    // Waveshape parameter (pulse width, tri-saw mix)
  sF32 gain;     // Output level
};

struct V2Osc {   // Working state
  sInt mode;     // OSC_OFF, OSC_TRI_SAW, OSC_PULSE, OSC_SIN, OSC_NOISE, OSC_FM_SIN, OSC_AUXA, OSC_AUXB
  bool ring;     // Ring mod mode (multiply instead of add)
  sU32 cnt;      // 32-bit phase accumulator
  sInt freq;     // Phase increment per sample
  sU32 brpt;     // Break point for tri/pulse (duty cycle)
  sF32 gain;     // Output gain
  // ... noise filter state, etc.
};
```

### Oscillator Modes

```cpp
enum Mode {
  OSC_OFF     = 0,  // No output
  OSC_TRI_SAW = 1,  // Variable triangle-sawtooth (color = shape)
  OSC_PULSE   = 2,  // Pulse wave (color = duty cycle)
  OSC_SIN     = 3,  // Pure sine
  OSC_NOISE   = 4,  // Filtered noise
  OSC_FM_SIN  = 5,  // FM sine (uses buffer as modulator)
  OSC_AUXA    = 6,  // Aux bus A input
  OSC_AUXB    = 7,  // Aux bus B input
};
```

### Anti-Aliasing: Band-Limited Waveforms

V2 uses an elegant anti-aliasing approach: instead of point-sampling, it computes the box-filtered (averaged) waveform value over each sample period. This effectively convolves with a box filter, attenuating high frequencies.

```cpp
// For tri/saw: instead of just sampling at time t, compute the
// average value over [t, t+h] where h = 1 sample period
void renderTriSaw(sF32 *dest, sInt nsamples) {
  sF32 f = utof23(freq);       // Frequency as fraction of sample rate
  sF32 rcpf = 1.0f / f;        // Reciprocal for anti-aliasing

  // State machine tracks transitions through waveform
  // Cases: pure up, pure down, up->down transition, down->up, etc.
  for (sInt i=0; i < nsamples; i++) {
    sF32 p = utof23(cnt) - col;  // Current phase position
    switch (osm_tick(state)) {
      case OSMTC_UP:   // Simple case: average of linear ramp
        y = c1 * (p + p - f);
        break;
      case OSMTC_DOWN:
        y = c2 * (p + p - f);
        break;
      case OSMTC_UP_DOWN:  // Transition: integrate both segments
        y = rcpf * (c2 * sqr(p) - c1 * sqr(p-f));
        break;
      // ... more transition cases
    }
    output(dest + i, y + gain);
  }
}
```

### Ring Modulation
The output method switches between additive mixing and ring modulation:

```cpp
inline void output(sF32 *dest, sF32 x) {
  if (ring)
    *dest *= x;  // Ring mod: multiply with existing buffer
  else
    *dest += x;  // Normal: add to buffer
}
```

### Rust Translation Notes
- Model oscillator modes as an enum with associated render methods
- Use a trait for common oscillator behavior
- Consider SIMD for the inner loops

```rust
trait Oscillator {
    fn render(&mut self, dest: &mut [f32], sample_rate: f32);
}

enum OscMode {
    Off,
    TriSaw { color: f32 },
    Pulse { duty: f32 },
    Sin,
    Noise { filter: NoiseFilter },
    FmSin,
    Aux(AuxBus),
}
```

## Stage 5: Filter Processing

### Location
- `V2Flt::render()` (synth_core.cpp:1097-1195)
- Filter coefficients: `V2Flt::set()` (synth_core.cpp:1071-1095)

### Data Structures
```cpp
struct syVFlt {  // Patch parameters
  sF32 mode;     // Filter type
  sF32 cutoff;   // Cutoff frequency (0-127)
  sF32 reso;     // Resonance (0-127)
};

struct V2Flt {   // Working state
  sInt mode;     // Filter mode enum
  sF32 cfreq;    // Calculated cutoff coefficient
  sF32 res;      // Calculated resonance
  V2LRC lrc;     // State variable filter state
  V2Moog moog;   // Moog ladder filter state
};

// LRC (State Variable) filter state
struct V2LRC {
  sF32 l, b;     // Low-pass and band-pass outputs (state)

  sF32 step_2x(sF32 in, sF32 freq, sF32 reso) {
    // 2x oversampled state variable filter
    l += freq * b - fcdcoffset;
    b += freq * (in - b*reso - l);
    l += freq * b;
    sF32 h = in - b*reso - l;  // High-pass output
    b += freq * h;
    return h;
  }
};
```

### Filter Modes

```cpp
enum Mode {
  BYPASS,   // Pass through unchanged
  LOW,      // State variable lowpass
  BAND,     // State variable bandpass
  HIGH,     // State variable highpass
  NOTCH,    // Low + High (rejects band)
  ALL,      // All-pass (phase shift only)
  MOOGL,    // Moog ladder lowpass (4-pole)
  MOOGH,    // Moog ladder highpass (input minus LP)
};
```

### Filter Routing Options
V2 supports three filter routing modes (set in the voice):

```cpp
enum FilterRouting {
  FLTR_SINGLE = 0,   // Only filter 1 is used
  FLTR_SERIAL,       // Filter 1 -> Filter 2
  FLTR_PARALLEL,     // Filter 1 and 2 mixed with balance control
};

// In V2Voice::render():
switch (fmode) {
  case FLTR_SINGLE:
    vcf[0].render(voice, voice, nsamples);
    break;
  case FLTR_SERIAL:
    vcf[0].render(voice, voice, nsamples);
    vcf[1].render(voice, voice, nsamples);
    break;
  case FLTR_PARALLEL:
    vcf[1].render(voice2, voice, nsamples);  // Copy to temp buffer
    vcf[0].render(voice, voice, nsamples);   // In-place filter 1
    for (sInt i=0; i < nsamples; i++)
      voice[i] = voice[i]*f1gain + voice2[i]*f2gain;  // Mix
    break;
}
```

### Moog Ladder Filter
The Moog filter uses a 4-pole ladder topology with nonlinear feedback:

```cpp
struct V2Moog {
  sF32 b[5];  // 4 filter stages + input history

  sF32 step(sF32 realin, sF32 f, sF32 p, sF32 q) {
    sF32 in = realin + fcdcoffset;
    in -= q * b[4];  // Feedback from output

    // 4 cascaded 1-pole lowpass stages
    sF32 t1, t2, t3, b4;
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

### Rust Translation Notes
- Model filter types as an enum with state inside variants
- Use associated types or generics for different filter topologies
- Consider a `Filter` trait for uniform interface

```rust
enum FilterType {
    Bypass,
    StateVariable(SVFilterState),
    Moog(MoogState),
}

struct SVFilterState {
    low: f32,
    band: f32,
}

impl Filter for SVFilterState {
    fn process(&mut self, input: f32, freq: f32, reso: f32) -> FilterOutputs { ... }
}
```

## Stage 6: Voice Rendering & Mixing

### Location
- `V2Voice::render()` (synth_core.cpp:1678-1736)
- `V2Voice::tick()` (synth_core.cpp:1665-1676) - envelope/LFO updates

### Data Structures
```cpp
struct V2Voice {
  sInt note;        // Current MIDI note
  sF32 velo;        // Note velocity
  bool gate;        // Gate on/off

  sF32 curvol;      // Current volume (for ramping)
  sF32 volramp;     // Volume change per sample
  sF32 xpose;       // Transpose amount
  sInt fmode;       // Filter routing mode
  sF32 lvol, rvol;  // Left/right pan gains

  V2Osc osc[3];     // 3 oscillators
  V2Flt vcf[2];     // 2 filters
  V2Env env[2];     // 2 envelopes (AmpEG + ModEG)
  V2LFO lfo[2];     // 2 LFOs
  V2Dist dist;      // Voice distortion
  V2DCFilter dcf;   // DC removal
};
```

### Per-Frame Processing (tick)

Each audio frame (~128 samples), envelopes and LFOs are updated:

```cpp
void tick() {
  // Update all envelopes with current gate state
  for (sInt i=0; i < NENV; i++)
    env[i].tick(gate);

  // Update all LFOs
  for (sInt i=0; i < NLFO; i++)
    lfo[i].tick();

  // Calculate volume ramp slope for smooth transitions
  volramp = (env[0].out / 128.0f - curvol) * inst->SRfciframe;
}
```

### Audio Rendering

```cpp
void render(StereoSample *dest, sInt nsamples) {
  sF32 *voice = inst->vcebuf;  // Working buffer
  memset(voice, 0, nsamples * sizeof(*voice));

  // 1. Render all oscillators (additive/ring mod)
  for (sInt i=0; i < NOSC; i++)
    osc[i].render(voice, nsamples);

  // 2. Apply filter chain (single/serial/parallel)
  switch (fmode) { /* ... see Stage 5 ... */ }

  // 3. Apply voice distortion
  dist.renderMono(voice, voice, nsamples);

  // 4. Remove DC offset
  dcf.renderMono(voice, voice, nsamples);

  // 5. Apply envelope & pan to stereo output
  sF32 cv = curvol;
  for (sInt i=0; i < nsamples; i++) {
    sF32 out = voice[i] * cv;
    cv += volramp;  // Smooth volume ramping

    dest[i].l += lvol * out + fcdcoffset;  // Pan left
    dest[i].r += rvol * out + fcdcoffset;  // Pan right
  }
  curvol = cv;
}
```

### Equal-Power Panning

```cpp
// In V2Voice::set()
sF32 p = para->panning / 128.0f;  // 0.0 to 1.0
lvol = sqrtf(1.0f - p);           // Left gain
rvol = sqrtf(p);                  // Right gain
// Note: lvol^2 + rvol^2 = 1 (constant power)
```

### Rust Translation Notes
- Model voice as struct with owned component state
- Use `&mut [StereoSample]` for output buffer
- Consider arena allocation for voice pools

```rust
struct Voice {
    note: u8,
    velocity: f32,
    gate: bool,
    oscillators: [Oscillator; 3],
    filters: [Filter; 2],
    envelopes: [Envelope; 2],
    lfos: [Lfo; 2],
    distortion: Distortion,
    dc_filter: DcFilter,
    pan: Panning,
    volume_ramp: VolumeRamp,
}

impl Voice {
    fn render(&mut self, dest: &mut [StereoSample]) { ... }
}
```

## Stage 7: Channel Processing & Final Mix

### Location
- `V2Chan::process()` (synth_core.cpp:2488-2526)
- `V2Synth::renderFrame()` (synth_core.cpp:3194-3268)

### Data Structures
```cpp
struct V2Chan {
  sF32 chgain;    // Channel volume
  sF32 a1gain;    // Aux1 send (reverb)
  sF32 a2gain;    // Aux2 send (delay)
  sF32 aasnd;     // Aux A send
  sF32 absnd;     // Aux B send
  sF32 aarcv;     // Aux A receive
  sF32 abrcv;     // Aux B receive

  V2DCFilter dcf1;   // Pre-effect DC filter
  V2Comp comp;       // Per-channel compressor
  V2Boost boost;     // Bass boost EQ
  V2Dist dist;       // Channel distortion
  V2DCFilter dcf2;   // Post-distortion DC filter
  V2ModDel chorus;   // Chorus/flanger effect
};

struct V2Synth {
  // Global effects
  V2Reverb reverb;
  V2ModDel delay;
  V2DCFilter dcf;
  V2Comp compr;     // Master compressor

  // Filter globals
  sF32 lcfreq;      // Low cut frequency
  sF32 hcfreq;      // High cut frequency
};
```

### Frame Rendering Flow

```cpp
void renderFrame() {
  sInt nsamples = instance.SRcFrameSize;

  // 1. Clear all buffers
  memset(instance.mixbuf, 0, ...);   // Main stereo mix
  memset(instance.aux1buf, 0, ...);  // Reverb send
  memset(instance.aux2buf, 0, ...);  // Delay send
  memset(instance.auxabuf, 0, ...);  // Aux A bus
  memset(instance.auxbbuf, 0, ...);  // Aux B bus

  // 2. Process each channel
  for (sInt chan=0; chan < CHANS; chan++) {
    // Skip channels with no active voices
    if (no_voices_on_channel(chan)) continue;

    // Clear channel buffer
    memset(instance.chanbuf, 0, ...);

    // Render all voices to channel buffer
    for (sInt voice=0; voice < POLY; voice++) {
      if (chanmap[voice] == chan)
        voicesw[voice].render(instance.chanbuf, nsamples);
    }

    // Channel effects chain
    chansw[chan].process(nsamples);
  }

  // 3. Global effects
  reverb.render(mixbuf, nsamples);        // Aux1 -> mix
  delay.renderAux2Main(mixbuf, nsamples); // Aux2 -> mix
  dcf.renderStereo(mixbuf, mixbuf, nsamples);

  // 4. Global EQ (low cut / high cut)
  for (sInt i=0; i < nsamples; i++) {
    for (sInt ch=0; ch < 2; ch++) {
      sF32 x = mix[i].ch[ch] - lcbuf[ch];
      lcbuf[ch] += lcf * x;  // High-pass

      if (hcf != 1.0f) {
        hcbuf[ch] += hcf * (x - hcbuf[ch]);
        x = hcbuf[ch];       // Low-pass
      }
      mix[i].ch[ch] = x;
    }
  }

  // 5. Master compressor
  compr.render(mix, nsamples);
}
```

### Channel Effects Chain

```cpp
void process(sInt nsamples) {
  StereoSample *chan = inst->chanbuf;

  // 1. Receive from aux buses
  accumulate(chan, inst->auxabuf, nsamples, aarcv);
  accumulate(chan, inst->auxbbuf, nsamples, abrcv);

  // 2. Channel effect chain
  dcf1.renderStereo(chan, chan, nsamples);   // DC filter
  comp.render(chan, nsamples);               // Compressor
  boost.render(chan, nsamples);              // Bass boost

  // 3. Dist/Chorus routing (configurable order)
  if (fxr == FXR_DIST_THEN_CHORUS) {
    dist.renderStereo(chan, chan, nsamples);
    dcf2.renderStereo(chan, chan, nsamples);
    chorus.renderChan(chan, nsamples);
  } else {
    chorus.renderChan(chan, nsamples);
    dist.renderStereo(chan, chan, nsamples);
    dcf2.renderStereo(chan, chan, nsamples);
  }

  // 4. Send to aux buses
  accumulateMonoMix(inst->aux1buf, chan, nsamples, a1gain);  // Reverb
  accumulateMonoMix(inst->aux2buf, chan, nsamples, a2gain);  // Delay
  accumulate(inst->auxabuf, chan, nsamples, aasnd);
  accumulate(inst->auxbbuf, chan, nsamples, absnd);

  // 5. Add to main mix
  accumulate(inst->mixbuf, chan, nsamples, chgain);
}
```

### Rust Translation Notes
- Model mixing as a graph of audio nodes
- Use a `MixBus` abstraction for accumulation
- Consider lock-free ring buffers for aux buses

```rust
struct MixerFrame {
    main_out: Vec<StereoSample>,
    aux_reverb: Vec<f32>,
    aux_delay: Vec<f32>,
    aux_a: Vec<StereoSample>,
    aux_b: Vec<StereoSample>,
}

struct ChannelStrip {
    dc_filter: DcFilter,
    compressor: Compressor,
    boost: BassBoost,
    distortion: Distortion,
    chorus: ModDelay,
    routing: EffectRouting,
    sends: AuxSends,
}
```

## Stage 8: Output Buffer

### Location
- `V2Synth::render()` (synth_core.cpp:2734-2797)
- C API: `synthRender()` (synth_core.cpp:3285-3288)

### API
```cpp
void __stdcall synthRender(void *pthis, void *buf, int smp, void *buf2, int add);
// buf = interleaved stereo buffer (if buf2 is null) or left channel
// buf2 = right channel (for split buffers) or null
// smp = number of samples
// add = 0: overwrite, 1: add to existing buffer
```

### Fragmented Rendering

The synth renders in fixed-size frames (~128 samples) but the caller may request arbitrary sizes. The render function handles this by tracking partially consumed frames:

```cpp
void render(sF32 *buf, sInt nsamples, sF32 *buf2, bool add) {
  sInt todo = nsamples;

  while (todo) {
    // Render a new frame if needed
    if (!tickd)
      tick();  // Processes MIDI, updates modulators, renders frame

    // Copy available samples to output
    const StereoSample *src = &instance.mixbuf[instance.SRcFrameSize - tickd];
    sInt nread = min(todo, tickd);

    if (!buf2) {  // Interleaved output
      if (!add)
        memcpy(buf, src, nread * sizeof(StereoSample));
      else
        for (sInt i=0; i < nread; i++) {
          buf[i*2+0] += src[i].l;
          buf[i*2+1] += src[i].r;
        }
      buf += 2*nread;
    } else {  // Split channels
      for (sInt i=0; i < nread; i++) {
        buf[i] = add ? buf[i] + src[i].l : src[i].l;
        buf2[i] = add ? buf2[i] + src[i].r : src[i].r;
      }
      buf += nread; buf2 += nread;
    }

    todo -= nread;
    tickd -= nread;
  }
}
```

### Rust Translation Notes
- Use slices for output buffers
- Consider `Iterator<Item = StereoSample>` for streaming
- Support both interleaved and planar formats via traits

```rust
trait AudioOutput {
    fn write_interleaved(&mut self, samples: &[StereoSample]);
    fn write_planar(&mut self, left: &[f32], right: &[f32]);
}

impl Synth {
    fn render(&mut self, output: &mut impl AudioOutput, nsamples: usize) { ... }
}
```

## Key Insights

### Architecture Patterns

1. **Parameter/Working State Separation**: Every component has two structs - `syV*` for patch parameters and `V2*` for runtime state. This enables efficient modulation where parameters are recalculated each frame.

2. **Frame-Based Processing**: Audio is processed in fixed-size frames (~128 samples). Modulators (envelopes, LFOs) update once per frame, not per sample. This trades accuracy for performance.

3. **Hierarchical Mixing**: Voice -> Channel -> Mix with aux buses. Each level has its own effect chain. Aux buses enable shared effects (reverb, delay) without duplicating state per voice.

4. **LRU Voice Stealing**: Polyphony management uses allocation timestamps to fairly steal voices. Preference given to voices in release phase.

5. **Band-Limited Oscillators**: Box-filtered waveforms with transition state machine. Elegant solution that's simpler than wavetable approaches.

### Rust-Specific Considerations

1. **Ownership**: Voices are owned by a pool, borrowed by channels during rendering. Consider `Arena<Voice>` with indices rather than references.

2. **Lifetimes**: The `V2Instance` pointer pattern (`inst: *V2Instance`) maps to Rust lifetime parameters or arena indices.

3. **Traits for Effects**: Each effect type (`Filter`, `Envelope`, `Oscillator`) could be a trait with common interface.

4. **SIMD Opportunities**: Inner loops (oscillator rendering, filter processing) are candidates for `std::simd` or `packed_simd`.

5. **Real-Time Safety**: Avoid allocations in render path. Use pre-allocated buffers. Consider `#[inline]` for hot paths.

### Memory Layout

```
V2Synth
  +-- V2Instance
  |     +-- Frame buffers (vcebuf, chanbuf, mixbuf, aux*)
  +-- V2Voice[64]
  |     +-- V2Osc[3]
  |     +-- V2Flt[2]
  |     +-- V2Env[2]
  |     +-- V2LFO[2]
  +-- V2Chan[16]
  |     +-- Per-channel effects
  +-- Global effects (reverb, delay, compressor)
  +-- Delay buffers (32KB main, 4KB per channel)
```

Total approximate size: ~2.5MB for a full V2Synth instance.

### Signal Flow Summary

```
MIDI Note On
     |
     v
Voice Allocation (LRU)
     |
     v
Note -> Frequency (12-TET)
     |
     v
+---> OSC 1 --+
|             |
+---> OSC 2 --+---> Voice Buffer (mono)
|             |
+---> OSC 3 --+
              |
              v
        Filter Chain (1-2 VCFs)
              |
              v
        Voice Distortion
              |
              v
        DC Filter
              |
              v
        Envelope * Pan --> Channel Buffer (stereo)
                              |
                              v
                    Channel Effects Chain
                    (Comp, Boost, Dist, Chorus)
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
         Main Mix       Aux1 (Verb)     Aux2 (Delay)
              |               |               |
              +-------<-------+-------<-------+
                              |
                              v
                     Global Effects
                     (Verb, Delay, EQ, Comp)
                              |
                              v
                       Audio Output
```
