# Voice Architecture in V2

## The Orchestra on a Budget

Imagine conducting an orchestra of sixty-four musicians. Each performer holds their instrument ready, capable of playing any part you assign. When a melody arrives, you point to a violinist who begins playing. Another phrase comes, and you signal a cellist. The music swells as more musicians join, each maintaining their own position on stage, their own dynamics, their own interpretation of the notes you hand them. But here lies the constraint: you have exactly sixty-four musicians, no more. When the sixty-fifth part arrives and every seat is occupied, someone must stop mid-phrase to take up the new melody. The question becomes: who do you silence?

This scenario captures the fundamental challenge of polyphonic synthesis. A software synthesizer receives a stream of MIDI notes, each demanding its own oscillators, filters, and envelopes. Unlike a real orchestra, the synthesizer cannot simply hire more musicians when the music grows complex. Hardware constraints impose a ceiling. The V2 synthesizer from Farbrausch sets this ceiling at sixty-four simultaneous voices, a number chosen through careful balancing of expressiveness against the CPU budgets typical of demoscene productions in the early 2000s.

The polyphony problem extends beyond mere counting. Each voice consumes both memory and processing power. More voices mean richer harmonies and longer release tails, allowing notes to fade naturally rather than cutting off abruptly. Fewer voices mean leaner resource usage and predictable performance. V2's sixty-four-voice architecture represents a sweet spot: enough musicians to handle complex arrangements including sustained pads, arpeggiators, and layered sounds, while remaining efficient enough for real-time synthesis without dropouts.

## Why Sixty-Four Voices?

Why sixty-four musicians and not thirty-two or one hundred twenty-eight? The choice reflects three competing concerns. First, musical expressiveness demands sufficient polyphony. A simple piano chord uses four to six notes. Add a bass line, a lead melody, and percussion, and the count rises quickly. When notes have long release times, the sustaining tails overlap with new attacks, compounding the voice count. Professional synthesizers of the era offered between 32 and 128 voices; V2's sixty-four slots place it comfortably in this range.

Second, memory consumption scales linearly with polyphony. Each voice maintains its own state: three oscillators with phase accumulators, two multi-mode filters with internal buffers, two envelope generators, two low-frequency oscillators, and a distortion stage with DC filtering. This state occupies roughly 400 bytes per voice. Multiply by sixty-four and the voice pool consumes about 25 kilobytes, significant when the entire demo executable must fit in 64KB.

Third, CPU cost per frame scales with active voices. Every audio frame, typically 128 samples at 44.1kHz, requires updating modulators and rendering audio for each active voice. The frame-rate processing amortizes control calculations, but the audio rendering remains proportional to voice count.

## Each Voice: A Musician's Complete Setup

Picture a single musician in the orchestra. They have sheet music describing the passage to play, an instrument with specific tonal characteristics, and a position on stage determining where the audience hears them. The V2Voice structure mirrors this organization exactly. Each voice maintains everything needed to generate a complete monophonic sound, from raw waveform generation through filtering to spatial placement in the stereo field.

The voice state structure reveals this comprehensive design. Every voice contains three oscillators that generate raw harmonic content, two filters that shape the frequency spectrum, two envelope generators that control amplitude and modulation over time, and two LFOs that provide cyclic modulation. (For deep coverage of how these modulators shape sound, see [Modulation System](modulation.md).)

```cpp
struct V2Voice
{
  sInt note;        // MIDI note number being played
  sF32 velo;        // Note velocity (0-127 range)
  bool gate;        // True while key is held, false after release

  sF32 curvol;      // Current volume (smoothed)
  sF32 volramp;     // Volume change per sample for smooth transitions
  sF32 lvol, rvol;  // Left and right panning gains

  V2Osc osc[3];     // Three oscillators
  V2Flt vcf[2];     // Two voltage-controlled filters
  V2Env env[2];     // Two envelope generators
  V2LFO lfo[2];     // Two low-frequency oscillators
  V2Dist dist;      // Distortion stage
  V2DCFilter dcf;   // DC offset removal
};
```

The component counts match classic subtractive synthesizer architecture. Three oscillators allow for thick layered sounds: one might provide the fundamental, another an octave above for brightness, a third slightly detuned for chorusing effects. Two filters enable complex spectral shaping, whether in series for steep cutoff slopes or in parallel for morphing between different timbres.

## The Musician Roster: Voice Pool Management

The orchestra's roster determines which musician plays each part. In V2, two parallel arrays manage this assignment. The `chanmap` array tracks which MIDI channel owns each voice, using -1 to indicate an unassigned voice waiting in the wings. The `allocpos` array records when each voice received its current assignment, enabling fair selection when the roster fills.

```cpp
struct V2Synth
{
  static const sInt POLY = 64;    // Maximum simultaneous voices
  static const sInt CHANS = 16;   // MIDI channels

  sU32 curalloc;                  // Monotonic allocation counter
  sInt chanmap[POLY];             // Voice -> channel mapping (-1 = free)
  sU32 allocpos[POLY];            // Allocation timestamp per voice
  V2Voice voicesw[POLY];          // The 64 voice instances
};
```

The `curalloc` counter increments monotonically with each voice assignment, serving as a logical timestamp. When two voices compete for reassignment, the one with the smaller allocation timestamp has been playing longer.

## Conducting the Entrance: Voice Allocation

When a Note On message arrives, the conductor must decide which musician takes the part. The allocation algorithm follows a strict priority order, favoring musical naturalness over mechanical fairness. The goal is to steal voices in the least audible way possible.

The first choice is always a completely free voice. If any musician sits idle in the roster, assign them immediately. When no free voices exist, the algorithm searches for a voice in its release phase. These voices have already received Note Off messages; their gates are closed, and they are simply fading out. Interrupting a fading note causes less audible disruption than cutting off an actively held note.

Only as a last resort does the allocator steal an actively gated voice. Here too, it selects the oldest, reasoning that the ear has already absorbed that note's contribution to the texture.

```cpp
// Step 1: Try to find a completely free voice
sInt usevoice = -1;
for (sInt i=0; i < POLY; i++)
{
  if (chanmap[i] < 0) { usevoice = i; break; }
}

// Step 2: If full, find the oldest voice with gate off (in release)
if (usevoice < 0)
{
  sU32 oldest = curalloc;
  for (sInt i=0; i < POLY; i++)
  {
    if (!voicesw[i].gate && allocpos[i] < oldest)
    { oldest = allocpos[i]; usevoice = i; }
  }
}

// Step 3: Still nothing? Take the oldest active voice (voice stealing)
if (usevoice < 0)
{
  sU32 oldest = curalloc;
  for (sInt i=0; i < POLY; i++)
  {
    if (allocpos[i] < oldest) { oldest = allocpos[i]; usevoice = i; }
  }
}
```

## Joining the Performance: Note On Handling

When a voice receives its assignment, it must prepare to play. The `noteOn` method handles this transition, resetting state as appropriate for the patch's synchronization settings. Some patches want phase-locked oscillators that start from a predictable point; others prefer the slight variation of unsynchronized phases.

The method stores the MIDI note number and velocity, then sets the gate to true, signaling the envelope generators to begin their attack phase. Depending on the keysync setting, oscillator phase accumulators may reset to zero, filter states may clear, or the voice may simply continue from wherever it was.

```cpp
void noteOn(sInt note, sInt vel)
{
  this->note = note;
  velo = (sF32)vel;
  gate = true;

  // Reset envelope generators to attack phase
  for (sInt i=0; i < 2; i++)
    env[i].state = V2Env::ATTACK;

  // Keysync determines how much state resets
  switch (keysync)
  {
  case SYNC_FULL:   // Reset everything
    for (sInt i=0; i < 2; i++) env[i].val = 0.0f;
    curvol = 0.0f;
    // fall-through
  case SYNC_OSC:    // Reset oscillator phases
    for (sInt i=0; i < 3; i++) osc[i].cnt = 0;
    // fall-through
  case SYNC_NONE:
  default:
    break;
  }

  for (sInt i=0; i < 3; i++) osc[i].chgPitch();
  for (sInt i=0; i < 2; i++) lfo[i].keyOn();
}
```

The fall-through behavior creates a hierarchy of reset levels. SYNC_FULL resets everything including envelopes and filters. SYNC_OSC resets just oscillator phases but preserves other state. SYNC_NONE performs minimal reset, allowing legato-style playing where filter resonance carries over between notes.

## Leaving the Stage: Note Off and Voice Release

When the conductor signals a musician to stop, they do not simply cut off mid-phrase. Instead, they transition to a release phase, allowing their sound to fade naturally. In V2, Note Off simply sets the gate to false. The envelope generators detect this state change and transition from their current phase to the release phase. The noteOff method remains simple because the complexity lives in the envelope generators themselves.

A voice in release continues consuming resources until its amplitude envelope reaches the OFF state. The main tick loop checks for this condition and reclaims the voice only when the sound has truly ended.

## Stage Positioning: Voice Routing and Panning

Each musician occupies a position on the stage, determining where the audience perceives their sound. V2 implements this spatial placement through equal-power panning, a technique that maintains consistent perceived loudness as sounds move between left and right speakers.

Simple linear panning would create a volume dip in the center. A note panned to the middle would play at half volume in each speaker, summing to less perceived loudness than a note panned fully left or right. Equal-power panning uses square root scaling to compensate.

```cpp
// In V2Voice::set()
sF32 p = para->panning / 128.0f;  // Normalize to 0.0-1.0 range
lvol = sqrtf(1.0f - p);           // Left gain
rvol = sqrtf(p);                  // Right gain
// Note: lvol^2 + rvol^2 = 1 (constant power)
```

As the panning parameter sweeps from left to right, the sound moves smoothly across the stereo field without the volume fluctuations that would occur with linear crossfading.

## Per-Voice Processing: The Individual Performance

Each voice renders its audio independently before mixing into the channel buffer. This per-voice processing chain mirrors the signal flow of a hardware synthesizer: oscillators generate raw waveforms, filters shape the spectrum, distortion adds harmonics, and DC filtering removes any accumulated offset.

The render method orchestrates this signal flow. First, it clears the working buffer to silence. Then each oscillator adds its output into the buffer. The filter chain processes the combined oscillator output. Distortion and DC filtering complete the tonal shaping. Finally, the amplitude envelope and panning transform the mono voice signal into a stereo contribution to the channel.

The volume ramping prevents clicks during level changes. Rather than jumping to the new envelope value, the code interpolates linearly across the frame. At 128 samples per frame, this creates smooth transitions imperceptible to the ear.

## Global vs Per-Voice: Division of Labor

Not all processing happens per-voice. Some effects make more sense at the channel level, processing the combined output of multiple voices together. This division mirrors how a real mixing console works: each musician's microphone might have individual EQ, but the reverb applies to the entire section.

Per-voice processing includes oscillators, filters, basic distortion, and panning. These operations define the individual timbre and placement of each note. Channel-level processing includes compression, bass boost, chorus/flanger, and sends to global reverb and delay. Global effects include the reverb and delay themselves, plus the master compressor and EQ.

This hierarchy exists for both musical and computational reasons. Global reverb would be prohibitively expensive to duplicate across sixty-four voices. But beyond efficiency, shared reverb creates a sense of space: all voices exist in the same acoustic environment, contributing to a cohesive mix.

## Rust Translation Considerations

The V2 voice architecture translates naturally to Rust with some idiomatic adjustments. The voice pool becomes a fixed-size array owned by the synthesizer, with allocation status tracked through an enum rather than magic -1 values.

```rust
struct Voice {
    note: u8,
    velocity: f32,
    gate: bool,
    current_volume: f32,
    volume_ramp: f32,
    left_gain: f32,
    right_gain: f32,
    oscillators: [Oscillator; 3],
    filters: [Filter; 2],
    envelopes: [Envelope; 2],
    lfos: [Lfo; 2],
    distortion: Distortion,
    dc_filter: DcFilter,
}

struct VoicePool {
    voices: [Voice; 64],
    allocation: [Option<VoiceAllocation>; 64],
    allocation_counter: u64,
}

struct VoiceAllocation {
    channel: usize,
    timestamp: u64,
}
```

The `Option<VoiceAllocation>` replaces the -1 sentinel value, making the free/allocated distinction type-safe. Voice stealing logic benefits from Rust's iterator methods, with filter, min_by_key, and map operations providing expressive code that can potentially be optimized with SIMD for the inner loops.

---

**See also:**
- [V2 Architecture](../architecture.md) - Three-tier system overview
- [Modulation System](modulation.md) - Envelopes and LFOs in depth
- [Note to Sound Trace](../code-traces/note-to-sound.md) - Complete signal flow walkthrough
- [V2 Overview](../README.md) - Introduction and key insights
