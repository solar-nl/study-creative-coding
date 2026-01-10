# Code Trace: Modulation System

## Overview

V2 (ViruZ II) is a legendary demoscene software synthesizer by Farbrausch, designed for extreme size optimization while maintaining professional sound quality. The modulation system is central to its expressive capability, allowing LFOs, envelopes, and MIDI controllers to dynamically modify synthesis parameters.

**Key Design Philosophy**: V2 processes modulation at **frame rate** (approximately 344 frames/sec at 44.1kHz), not sample rate. This provides a good balance between expressiveness and CPU efficiency - parameters change smoothly enough to sound continuous, but calculations happen 344x less frequently than sample-rate processing.

**Frame Size**: 128 samples at 44.1kHz (configurable via `fcframebase`)

## Data Structures

### Modulation Routing Entry (`V2Mod`)

```cpp
// synth_core.cpp:2555-2560
struct V2Mod
{
  sU8 source;   // source: vel/ctl1-7/aenv/env2/lfo1/lfo2/note
  sU8 val;      // 0=-1 .. 64=0 .. 128=1 (modulation depth/polarity)
  sU8 dest;     // destination (index into V2Sound parameter array)
};
```

Only **3 bytes** per modulation routing - extreme size efficiency for demos.

### Patch Definition (`V2Sound`)

```cpp
// synth_core.cpp:2562-2569
struct V2Sound
{
  sU8 voice[sizeof(syVV2) / sizeof(sF32)];  // Voice parameters as bytes
  sU8 chan[sizeof(syVChan) / sizeof(sF32)]; // Channel parameters as bytes
  sU8 maxpoly;                               // Maximum polyphony
  sU8 modnum;                                // Number of modulation routings
  V2Mod modmatrix[1];                        // Variable-length array (modnum entries)
};
```

The patch contains up to **255 modulation slots** (limited by `sU8 modnum`).

### Modulation Sources (from `sounddef.h:61-76`)

```cpp
const char *v2sources[] = {
  "Velocity",     // 0: Note velocity (0-127)
  "Modulation",   // 1: MIDI CC1 (Mod wheel)
  "Breath",       // 2: MIDI CC2
  "Ctl #3",       // 3-6: MIDI CC3-6
  "Ctl #4",
  "Ctl #5",
  "Ctl #6",
  "Volume",       // 7: MIDI CC7 (Volume)
  "Amp EG",       // 8: Amplitude envelope output
  "EG 2",         // 9: Modulation envelope output
  "LFO 1",        // 10: LFO 1 output
  "LFO 2",        // 11: LFO 2 output
  "Note",         // 12: MIDI note number (keyboard tracking)
};
```

## Envelope Generators (ADSR)

### Parameter Structure (`syVEnv`)

```cpp
// synth_core.cpp:911-919
struct syVEnv
{
  sF32 ar;  // attack rate
  sF32 dr;  // decay rate
  sF32 sl;  // sustain level
  sF32 sr;  // sustain rate (decay during sustain phase)
  sF32 rr;  // release rate
  sF32 vol; // volume/amplitude scaling
};
```

### State Machine (`V2Env`)

```cpp
// synth_core.cpp:921-1028
struct V2Env
{
  enum State { OFF, RELEASE, ATTACK, DECAY, SUSTAIN };

  sF32 out;     // Current output value (0-128 * gain)
  State state;  // Current envelope stage
  sF32 val;     // Internal value (0.0-128.0)
  sF32 atd;     // Attack delta (added each frame)
  sF32 dcf;     // Decay factor (multiplied each frame)
  sF32 sul;     // Sustain level threshold
  sF32 suf;     // Sustain factor (for sustain slope)
  sF32 ref;     // Release factor (multiplied each frame)
  sF32 gain;    // Output scaling
};
```

### Envelope Tick (Per-Frame Processing)

```cpp
// synth_core.cpp:969-1027
void tick(bool gate)
{
  // Gate transitions
  if (state <= RELEASE && gate)   state = ATTACK;   // Note on
  else if (state >= ATTACK && !gate) state = RELEASE; // Note off

  switch (state)
  {
  case OFF:
    val = 0.0f;
    break;

  case ATTACK:
    val += atd;                    // Linear attack
    if (val >= 128.0f) {
      val = 128.0f;
      state = DECAY;
    }
    break;

  case DECAY:
    val *= dcf;                    // Exponential decay
    if (val <= sul) {
      val = sul;
      state = SUSTAIN;
    }
    break;

  case SUSTAIN:
    val *= suf;                    // Sustain can also decay
    if (val > 128.0f) val = 128.0f;
    break;

  case RELEASE:
    val *= ref;                    // Exponential release
    break;
  }

  // Avoid denormals (fclowest = 2^-13)
  if (val <= fclowest) {
    val = 0.0f;
    state = OFF;
  }

  out = val * gain;  // Scale to modulation range
}
```

**Key Insight**: Attack is linear (additive), while decay/sustain/release are exponential (multiplicative). This produces natural-sounding envelopes.

### Parameter Conversion

```cpp
// synth_core.cpp:950-966
void set(const syVEnv *para)
{
  // Attack: 2^7 to 2^-4 (128 to 0.03, ~10 seconds at 344 frames/sec)
  atd = powf(2.0f, para->ar * fcattackmul + fcattackadd);

  // Decay: Exponential factor derived from frequency calculation
  dcf = 1.0f - calcfreq2(1.0f - para->dr / 128.0f);

  // Sustain level: Direct mapping
  sul = para->sl;

  // Sustain factor: Allows sustain to decay or grow
  suf = powf(2.0f, fcsusmul * (para->sr - 64.0f));

  // Release: Same as decay
  ref = 1.0f - calcfreq2(1.0f - para->rr / 128.0f);

  gain = para->vol / 128.0f;
}
```

## LFOs (Low Frequency Oscillators)

### Parameter Structure (`syVLFO`)

```cpp
// synth_core.cpp:1201-1210
struct syVLFO
{
  sF32 mode;    // 0=saw, 1=tri, 2=pulse, 3=sin, 4=s&h
  sF32 sync;    // 0=free, 1=key sync
  sF32 egmode;  // 0=continuous, 1=one-shot (envelope mode)
  sF32 rate;    // rate (0Hz..~43Hz)
  sF32 phase;   // start phase shift
  sF32 pol;     // polarity: +, -, +/-
  sF32 amp;     // amplification (0..1)
};
```

### Working State (`V2LFO`)

```cpp
// synth_core.cpp:1212-1328
struct V2LFO
{
  enum Mode { SAW, TRI, PULSE, SIN, S_H };

  sF32 out;       // Current output value
  sInt mode;      // Waveform mode
  bool sync;      // Key sync enabled
  bool eg;        // Envelope/one-shot mode
  sInt freq;      // Frequency (counter increment per frame)
  sU32 cntr;      // Phase counter (32-bit wrapping)
  sU32 cphase;    // Sync phase (reset value on note-on)
  sF32 gain;      // Output gain
  sF32 dc;        // DC offset (for polarity modes)
  sU32 nseed;     // Random seed for S&H
  sU32 last;      // Previous counter for S&H edge detection
};
```

### LFO Waveform Generation

```cpp
// synth_core.cpp:1281-1327
void tick()
{
  sF32 v;
  sU32 x;

  switch (mode & 7)
  {
  case SAW:
    // Counter directly maps to 0..1 output
    v = utof23(cntr);  // Convert 32-bit to 0..1 float
    break;

  case TRI:
    // XOR trick for triangle: fold at midpoint
    x = (cntr << 1) ^ (sS32(cntr) >> 31);
    v = utof23(x);
    break;

  case PULSE:
    // High bit determines 0 or 1
    x = sS32(cntr) >> 31;  // All 0s or all 1s
    v = utof23(x);
    break;

  case SIN:
    // Convert phase to sine
    v = utof23(cntr);
    v = fastsinrc(v * fc2pi) * 0.5f + 0.5f;  // Map to 0..1
    break;

  case S_H:
    // Sample & Hold: new random on each cycle
    if (cntr < last)           // Counter wrapped
      nseed = urandom(&nseed); // Generate new random
    last = cntr;
    v = utof23(nseed);
    break;
  }

  out = v * gain + dc;   // Apply gain and polarity DC offset

  cntr += freq;          // Advance phase
  if (cntr < (sU32)freq && eg)  // In one-shot mode, clamp at wrap
    cntr = ~0u;
}
```

### Polarity Modes

```cpp
// synth_core.cpp:1249-1268
switch ((sInt)para->pol)
{
case 0: // Unipolar positive (+)
  gain = para->amp;
  dc = 0.0f;
  break;

case 1: // Unipolar negative (-)
  gain = -para->amp;
  dc = 0.0f;
  break;

case 2: // Bipolar (+/-)
  gain = para->amp;
  dc = -0.5f * para->amp;  // Center around zero
  break;
}
```

## Modulation Matrix

### Source Value Retrieval

```cpp
// synth_core.cpp:3053-3086
sF32 getmodsource(const V2Voice *voice, sInt chan, sInt source) const
{
  sF32 in = 0.0f;

  switch (source)
  {
  case 0:  // Velocity
    in = voice->velo;  // 0-127
    break;

  case 1: case 2: case 3: case 4: case 5: case 6: case 7:  // MIDI Controllers
    in = chans[chan].ctl[source-1];  // 0-127
    break;

  case 8: case 9:  // Envelope outputs
    in = voice->env[source-8].out;   // 0-128 scaled
    break;

  case 10: case 11:  // LFO outputs
    in = voice->lfo[source-10].out;  // Varies by polarity
    break;

  default:  // Note number (keyboard tracking)
    in = 2.0f * (voice->note - 48.0f);  // Centered at C3
    break;
  }

  return in;
}
```

### Per-Voice Modulation Application

```cpp
// synth_core.cpp:3088-3119
void storeV2Values(sInt vind)
{
  sInt chan = chanmap[vind];
  if (chan < 0) return;

  const V2Sound *patch = getpatch(chans[chan].pgm);

  // Voice parameters as float array
  syVV2 *vpara = &voicesv[vind];
  sF32 *vparaf = (sF32 *)vpara;
  V2Voice *voice = &voicesw[vind];

  // Copy base parameter values (convert bytes to floats)
  for (sInt i=0; i < COUNTOF(patch->voice); i++)
    vparaf[i] = (sF32)patch->voice[i];

  // Apply modulation matrix
  for (sInt i=0; i < patch->modnum; i++)
  {
    const V2Mod *mod = &patch->modmatrix[i];

    // Skip if destination is channel parameter (not voice)
    if (mod->dest >= COUNTOF(patch->voice))
      continue;

    // Scale factor: -1 to +1 from 0-128 byte
    sF32 scale = (mod->val - 64.0f) / 64.0f;

    // Apply: base + (scale * source), clamped to 0-128
    vparaf[mod->dest] = clamp(
      vparaf[mod->dest] + scale * getmodsource(voice, chan, mod->source),
      0.0f, 128.0f
    );
  }

  // Apply modulated parameters to voice DSP
  voice->set(vpara);
}
```

### Per-Channel Modulation Application

```cpp
// synth_core.cpp:3121-3151
void storeChanValues(sInt chan)
{
  const V2Sound *patch = getpatch(chans[chan].pgm);

  syVChan *cpara = &chansv[chan];
  sF32 *cparaf = (sF32 *)cpara;
  V2Chan *cwork = &chansw[chan];
  V2Voice *voice = &voicesw[voicemap[chan]];  // Use first voice for modulation

  // Copy base channel parameters
  for (sInt i=0; i < COUNTOF(patch->chan); i++)
    cparaf[i] = (sF32)patch->chan[i];

  // Apply modulation matrix (channel destinations only)
  for (sInt i=0; i < patch->modnum; i++)
  {
    const V2Mod *mod = &patch->modmatrix[i];

    // Calculate channel-relative destination index
    sInt dest = mod->dest - COUNTOF(patch->voice);
    if (dest < 0 || dest >= COUNTOF(patch->chan))
      continue;

    sF32 scale = (mod->val - 64.0f) / 64.0f;
    cparaf[dest] = clamp(
      cparaf[dest] + scale * getmodsource(voice, chan, mod->source),
      0.0f, 128.0f
    );
  }

  cwork->set(cpara);
}
```

## Main Processing Loop (Tick)

```cpp
// synth_core.cpp:3153-3192
void tick()
{
  // Process all active voices
  for (sInt i=0; i < POLY; i++)
  {
    if (chanmap[i] < 0) continue;  // Voice inactive

    storeV2Values(i);    // Apply modulation matrix to voice params
    voicesw[i].tick();   // Tick envelopes and LFOs

    // Voice termination: EG1 (amp envelope) finished
    if (voicesw[i].env[0].state == V2Env::OFF)
      chanmap[i] = -1;   // Mark voice as free
  }

  // Process all channels
  for (sInt i=0; i < CHANS; i++)
    storeChanValues(i);  // Apply modulation to channel params

  ronanCBTick(&ronan);   // Speech synthesis tick

  tickd = instance.SRcFrameSize;  // Reset sample counter
  renderFrame();         // Render audio for this frame
}
```

## Voice Parameter Application

```cpp
// synth_core.cpp:1665-1676
void tick()  // V2Voice::tick()
{
  // Tick all envelopes
  for (sInt i=0; i < syVV2::NENV; i++)
    env[i].tick(gate);

  // Tick all LFOs
  for (sInt i=0; i < syVV2::NLFO; i++)
    lfo[i].tick();

  // Volume ramping: smoothly interpolate to new envelope value
  volramp = (env[0].out / 128.0f - curvol) * inst->SRfciframe;
}
```

**Volume Ramping**: Critical for preventing clicks. Instead of jumping to the new amplitude envelope value, V2 linearly interpolates across the frame.

## Parameter Application Flow

```
Every Frame (128 samples at 44.1kHz):
┌─────────────────────────────────────────────────────────────┐
│ 1. storeV2Values() - For each active voice:                 │
│    ├─ Copy base patch parameters (byte -> float)            │
│    ├─ Apply modulation matrix (source * scale + base)       │
│    └─ voice->set(vpara) - Update DSP parameters             │
│                                                              │
│ 2. voicesw[i].tick() - Per voice:                           │
│    ├─ env[0].tick(gate) - Amp envelope                      │
│    ├─ env[1].tick(gate) - Mod envelope                      │
│    ├─ lfo[0].tick()     - LFO 1                             │
│    ├─ lfo[1].tick()     - LFO 2                             │
│    └─ Calculate volramp (smoothing)                         │
│                                                              │
│ 3. storeChanValues() - For each channel:                    │
│    ├─ Copy base channel parameters                          │
│    ├─ Apply modulation matrix (channel destinations)        │
│    └─ cwork->set(cpara) - Update channel DSP                │
│                                                              │
│ 4. renderFrame() - Audio generation                         │
│    └─ Parameters already set; render uses fixed values      │
└─────────────────────────────────────────────────────────────┘
```

## Key Insights for Rust Implementation

### 1. Frame-Rate vs Sample-Rate Processing

V2 demonstrates that modulation at frame rate (344Hz) is sufficient for musical expressiveness:

```rust
// Rust approach: Separate control and audio rate
pub struct ModulationContext {
    frame_size: usize,
    sample_rate: f32,
    control_rate: f32,  // sample_rate / frame_size
}

impl ModulationContext {
    pub fn tick(&mut self, sources: &ModSources, matrix: &ModMatrix, params: &mut Params) {
        // Apply modulation once per frame
        matrix.apply(sources, params);
    }
}
```

### 2. Trait-Based Modulation Sources

```rust
pub trait ModulationSource {
    fn value(&self) -> f32;
}

pub struct Envelope {
    state: EnvelopeState,
    value: f32,
    // ... attack/decay/sustain/release parameters
}

impl ModulationSource for Envelope {
    fn value(&self) -> f32 { self.value * self.gain }
}

pub struct Lfo {
    phase: u32,
    freq: u32,
    mode: LfoMode,
    // ...
}

impl ModulationSource for Lfo {
    fn value(&self) -> f32 { /* waveform generation */ }
}
```

### 3. Modulation Matrix as Sum of Contributions

```rust
pub struct ModRoute {
    source: ModSourceId,
    destination: ParamId,
    amount: f32,  // -1.0 to 1.0
}

pub struct ModMatrix {
    routes: SmallVec<[ModRoute; 32]>,  // Most patches use fewer than 32
}

impl ModMatrix {
    pub fn apply(&self, sources: &impl ModSourceBank, params: &mut impl ParamBank) {
        // Reset to base values first
        params.reset_to_base();

        // Sum all modulation contributions
        for route in &self.routes {
            let source_val = sources.get(route.source);
            let current = params.get(route.destination);
            let modulated = (current + route.amount * source_val).clamp(0.0, 1.0);
            params.set(route.destination, modulated);
        }
    }
}
```

### 4. Volume Ramping Pattern

```rust
pub struct VoiceAmplitude {
    current: f32,
    target: f32,
    ramp: f32,  // (target - current) / frame_size
}

impl VoiceAmplitude {
    pub fn prepare_frame(&mut self, envelope_out: f32, frame_size: usize) {
        self.target = envelope_out;
        self.ramp = (self.target - self.current) / frame_size as f32;
    }

    pub fn next_sample(&mut self) -> f32 {
        let out = self.current;
        self.current += self.ramp;
        out
    }
}
```

### 5. Efficient Envelope State Machine

```rust
#[derive(Clone, Copy, PartialEq)]
pub enum EnvelopeState {
    Off,
    Attack,
    Decay,
    Sustain,
    Release,
}

pub struct Envelope {
    state: EnvelopeState,
    value: f32,
    attack_delta: f32,
    decay_factor: f32,
    sustain_level: f32,
    sustain_factor: f32,
    release_factor: f32,
}

impl Envelope {
    pub fn tick(&mut self, gate: bool) {
        // Gate transitions
        match (self.state, gate) {
            (EnvelopeState::Off | EnvelopeState::Release, true) => {
                self.state = EnvelopeState::Attack;
            }
            (EnvelopeState::Attack | EnvelopeState::Decay | EnvelopeState::Sustain, false) => {
                self.state = EnvelopeState::Release;
            }
            _ => {}
        }

        // State processing
        match self.state {
            EnvelopeState::Off => self.value = 0.0,
            EnvelopeState::Attack => {
                self.value += self.attack_delta;
                if self.value >= 1.0 {
                    self.value = 1.0;
                    self.state = EnvelopeState::Decay;
                }
            }
            EnvelopeState::Decay => {
                self.value *= self.decay_factor;
                if self.value <= self.sustain_level {
                    self.value = self.sustain_level;
                    self.state = EnvelopeState::Sustain;
                }
            }
            EnvelopeState::Sustain => {
                self.value *= self.sustain_factor;
                self.value = self.value.min(1.0);
            }
            EnvelopeState::Release => {
                self.value *= self.release_factor;
                if self.value < 1e-6 {
                    self.value = 0.0;
                    self.state = EnvelopeState::Off;
                }
            }
        }
    }
}
```

### 6. LFO with Multiple Waveforms

```rust
pub enum LfoMode {
    Saw,
    Triangle,
    Pulse,
    Sine,
    SampleAndHold,
}

impl Lfo {
    pub fn tick(&mut self) -> f32 {
        let raw = match self.mode {
            LfoMode::Saw => self.phase as f32 / u32::MAX as f32,
            LfoMode::Triangle => {
                let x = (self.phase << 1) ^ ((self.phase as i32 >> 31) as u32);
                x as f32 / u32::MAX as f32
            }
            LfoMode::Pulse => if self.phase >= 0x80000000 { 1.0 } else { 0.0 },
            LfoMode::Sine => {
                let t = self.phase as f32 / u32::MAX as f32;
                (t * std::f32::consts::TAU).sin() * 0.5 + 0.5
            }
            LfoMode::SampleAndHold => {
                if self.phase < self.last_phase {
                    self.held_value = self.rng.gen();
                }
                self.last_phase = self.phase;
                self.held_value
            }
        };

        self.phase = self.phase.wrapping_add(self.freq);
        raw * self.gain + self.dc_offset
    }
}
```

## Summary

V2's modulation system achieves musical expressiveness through:

1. **Frame-rate processing** (~344Hz) for modulation sources
2. **Simple 3-byte modulation routing** (source, amount, destination)
3. **Additive modulation** (base + sum of mod contributions)
4. **Linear interpolation** (volume ramping) to prevent clicks
5. **Efficient state machines** for envelopes
6. **Integer phase accumulators** for LFOs (wrapping arithmetic)

The architecture separates concerns cleanly:
- **Patch data**: Static parameter values + modulation routing
- **Voice state**: Dynamic DSP state + modulation source outputs
- **Processing**: Frame tick (update modulators) -> Apply matrix -> Render audio

This design is highly amenable to Rust's ownership model - modulation sources can be borrowed immutably while parameters are borrowed mutably during matrix application.
