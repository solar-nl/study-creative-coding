# Audio DSP Patterns: From V2 to Rust

> Six battle-tested audio patterns from demoscene C++ translated to idiomatic Rust

---

## The Translation Guide Analogy

Moving from V2's C++ patterns to idiomatic Rust resembles translating between spoken languages. The source language—V2's C++ with inline assembly—prizes compactness and raw performance. The target language—Rust with safe abstractions—values memory safety and explicit ownership. Neither approach is superior; each reflects its era's constraints and priorities. The translator's job: finding equivalent expressions that preserve intent while respecting the target language's idioms.

This document serves as a phrasebook for that translation. Each entry identifies a problem V2 solved, shows how V2's source language expressed the solution, then provides the equivalent Rust expression. The goal is not to transliterate C++ into Rust syntax. The goal is to capture the pattern's essence in Rust's native voice. A direct word-for-word translation sounds stilted in any language; an idiomatic translation flows naturally while preserving meaning.

The patterns collected here emerged from V2's constraints: sixty-four simultaneous voices, real-time audio deadlines, and the demoscene's obsession with fitting functionality into kilobytes. These constraints forced elegant solutions. Rust's different constraints, ownership, lifetimes, and safe concurrency, force different expressions of those solutions. The underlying wisdom transfers; the surface syntax transforms.

---

## Pattern 1: Voice Pool Management

**The problem:** A polyphonic synthesizer needs to manage a fixed number of voices without dynamic allocation. When all voices are active and a new note arrives, the system must decide which voice to steal. This decision should minimize audible artifacts by preferring voices that have already begun their release phase over those still actively sounding.

**V2's approach:** The [voice architecture](../synthesis-engine/voice-architecture.md) document details V2's solution. A fixed array of 64 voices pairs with a parallel allocation map. The map tracks which MIDI channel owns each voice (-1 for free), plus an allocation timestamp for LRU stealing. Voice allocation searches in priority order: free voices first, then released voices (gate off), then oldest active voices. The key insight is separating voice state from allocation metadata. The voice itself knows nothing about the pool; the pool knows everything about voice lifetimes.

**Rust translation:** Replace the magic -1 sentinel with `Option`, making the free/allocated distinction type-safe. The allocation logic translates naturally using iterator methods, expressing the priority search declaratively.

```rust
struct VoiceAllocation { channel: usize, timestamp: u64, gate: bool }

struct VoicePool {
    voices: [Voice; 64],
    allocations: [Option<VoiceAllocation>; 64],
    allocation_counter: u64,
}

impl VoicePool {
    fn allocate(&mut self, channel: usize) -> Option<usize> {
        // Priority 1: Free voice
        if let Some(idx) = self.allocations.iter().position(Option::is_none) {
            return Some(self.claim_voice(idx, channel));
        }
        // Priority 2: Released voice (oldest first)
        if let Some(idx) = self.allocations.iter().enumerate()
            .filter(|(_, a)| a.as_ref().map(|a| !a.gate).unwrap_or(false))
            .min_by_key(|(_, a)| a.as_ref().unwrap().timestamp)
            .map(|(i, _)| i) {
            return Some(self.claim_voice(idx, channel));
        }
        // Priority 3: Oldest active voice (voice stealing)
        self.allocations.iter().enumerate()
            .filter_map(|(i, a)| a.as_ref().map(|a| (i, a.timestamp)))
            .min_by_key(|(_, ts)| *ts)
            .map(|(i, _)| self.claim_voice(i, channel))
    }

    fn claim_voice(&mut self, idx: usize, channel: usize) -> usize {
        self.allocation_counter += 1;
        self.allocations[idx] = Some(VoiceAllocation {
            channel, timestamp: self.allocation_counter, gate: true,
        });
        self.voices[idx].reset();
        idx
    }
}
```

**Key insight:** Rust's `Option` eliminates sentinel value bugs while iterator chains express allocation priority in readable, declarative style.

---

## Pattern 2: Frame-Based Processing

**The problem:** Audio synthesis at sample rate (44,100 Hz) cannot afford per-sample calculations for slowly-changing values like envelope levels or filter coefficients. Control-rate calculations should happen less frequently without introducing audible stepping artifacts. The solution must also enable SIMD optimization of the inner audio loops.

**V2's approach:** The [architecture document](../architecture.md) explains V2's frame-based model. Processing divides into frames of 128 samples (approximately 2.9ms at 44.1kHz). Each frame begins with a "tick" that updates all modulators at control rate, then renders audio at sample rate. This 128x reduction in control calculations leaves CPU cycles for audio rendering. Volume ramping prevents clicks from control-rate stepping by interpolating between old and new envelope values across the frame.

**Rust translation:** Frame-based processing maps naturally to Rust's slice-oriented API. A buffer of samples becomes a mutable slice that processing functions fill. The frame size provides natural boundaries for both control updates and SIMD vectorization.

```rust
const FRAME_SIZE: usize = 128;

impl Voice {
    fn process_frame(&mut self, output: &mut [f32; FRAME_SIZE]) {
        // Control-rate update: happens once per frame
        self.tick();
        let target_vol = self.envelope.output() / 128.0;
        let ramp = (target_vol - self.current_vol) / FRAME_SIZE as f32;

        // Audio-rate render: per sample with smooth ramping
        let mut vol = self.current_vol;
        for sample in output.iter_mut() {
            *sample = self.render_sample() * vol;
            vol += ramp;
        }
        self.current_vol = vol;
    }
}
```

For SIMD optimization, Rust's `std::simd` provides portable vectorization. The frame size of 128 divides evenly by common SIMD widths (4, 8, 16), enabling efficient processing of the inner loop.

**Key insight:** Frame-based processing amortizes control calculations 128x while ramp interpolation eliminates clicks. The pattern generalizes to any parameter needing smooth transitions.

---

## Pattern 3: Modulation Graph

**The problem:** A synthesizer needs flexible routing between modulation sources (envelopes, LFOs, velocity) and destinations (filter cutoff, pitch, amplitude). Artists expect to route multiple sources to the same destination with different amounts, and the results should sum additively. The routing should be data-driven, not hardcoded.

**V2's approach:** The [modulation document](../synthesis-engine/modulation.md) covers V2's solution. Each routing occupies three bytes: source index, amount (with 64 as zero for bipolar modulation), and destination parameter index. During each frame, the system copies base parameter values from the patch, then iterates through all routings, adding scaled source outputs to destinations. The modulation sources are heterogeneous: velocity is fixed per note, envelopes evolve over time, LFOs cycle continuously, MIDI controllers arrive externally. A unified interface makes the routing code oblivious to source type.

**Rust translation:** Traits provide a unified interface for heterogeneous modulation sources. Each source implements a common trait, enabling polymorphic routing without dynamic dispatch in the hot path.

```rust
trait ModSource { fn output(&self) -> f32; }

impl ModSource for Envelope { fn output(&self) -> f32 { self.value * self.gain } }
impl ModSource for Lfo { fn output(&self) -> f32 { self.value * self.gain + self.dc } }
struct Velocity(f32);
impl ModSource for Velocity { fn output(&self) -> f32 { self.0 } }

struct ModRouting { source: SourceId, dest: usize, amount: f32 }

impl ModulationMatrix {
    fn apply(&self, sources: &Sources, params: &mut [f32]) {
        for r in &self.routings {
            params[r.dest] += sources.get(r.source) * r.amount;
        }
    }
}
```

**Key insight:** The trait-based approach provides compile-time polymorphism while keeping routing data compact. The sum-of-contributions model emerges naturally from iterating and accumulating.

---

## Pattern 4: Real-Time Safety

**The problem:** The audio thread must never block. Memory allocation can acquire locks. File I/O waits on disk. Even logging can contend for buffers. Any operation that might block risks audio dropout. Meanwhile, other threads need to send MIDI events and query playback position without corrupting shared state.

**V2's approach:** The [audio I/O document](../integration/audio-io.md) details V2's strategy. The core synthesis engine assumes single-threaded access and performs no allocation during rendering. The DirectSound layer provides explicit lock/unlock functions for cross-thread communication. Static allocation at initialization time eliminates runtime allocation in the audio path. Every buffer, every voice, every delay line exists before the first sample renders.

**Rust translation:** Rust's ownership system makes real-time constraints explicit. Types that might allocate or block simply cannot be passed to the audio callback. Lock-free communication replaces mutex-protected regions. The `ringbuf` crate provides wait-free MIDI event delivery.

```rust
use std::sync::atomic::{AtomicU64, Ordering};
use ringbuf::{HeapRb, Consumer};

struct AudioPosition { samples: AtomicU64 }
impl AudioPosition {
    fn advance(&self, n: u64) { self.samples.fetch_add(n, Ordering::Release); }
    fn current(&self) -> u64 { self.samples.load(Ordering::Acquire) }
}

fn audio_callback(synth: &mut Synth, midi: &mut Consumer<MidiEvent>, out: &mut [f32]) {
    // Drain MIDI events (non-blocking, wait-free)
    while let Some(event) = midi.try_pop() { synth.process_midi(event); }
    // Render audio (no allocation, no blocking)
    synth.render(out);
}
```

**Key insight:** Rust's type system enforces real-time constraints at compile time. Lock-free structures eliminate blocking that V2 avoided through discipline; Rust prevents it through design.

---

## Pattern 5: State Variable Filter

**The problem:** A synthesizer filter should produce multiple outputs (low-pass, band-pass, high-pass, notch) simultaneously from the same computation. This enables morphing between filter types without recalculating. The filter must remain stable at all cutoff frequencies and support modulation without zipper noise.

**V2's approach:** The [filters document](../synthesis-engine/filters.md) explains V2's state variable filter. Two integrators in feedback produce the classic topology. Internal state variables `l` (low) and `b` (band) generate all outputs through combination: low-pass directly, high-pass by subtraction, band-pass directly, notch by summing low and high. Running at 2x oversampling prevents instability at high frequencies. The resonance parameter controls feedback from the band-pass output, creating the characteristic squelch as it approaches self-oscillation.

**Rust translation:** The filter returns all outputs simultaneously, enabling the caller to select or blend without recomputing. This design separates computation from selection.

```rust
struct FilterOutput { low: f32, band: f32, high: f32 }
impl FilterOutput {
    fn notch(&self) -> f32 { self.low + self.high }
    fn select(&self, mode: FilterMode) -> f32 {
        match mode {
            FilterMode::LowPass => self.low,
            FilterMode::BandPass => self.band,
            FilterMode::HighPass => self.high,
            FilterMode::Notch => self.notch(),
        }
    }
}

struct StateVariableFilter { low: f32, band: f32 }
impl StateVariableFilter {
    fn process(&mut self, input: f32, cutoff: f32, reso: f32) -> FilterOutput {
        for _ in 0..2 {  // 2x oversampling for stability
            self.low += cutoff * self.band;
            let high = input - self.band * reso - self.low;
            self.band += cutoff * high;
        }
        FilterOutput {
            low: self.low, band: self.band,
            high: input - self.band * reso - self.low,
        }
    }
}
```

**Key insight:** Returning all filter outputs enables flexible routing and morphing. The struct bundles related values with methods to combine them.

---

## Pattern 6: Plugin Abstraction

**The problem:** A synthesizer should work across multiple host environments: standalone applications, VST plugins, tracker software, web audio. Each host has different callback signatures, buffer formats, and lifecycle expectations. The core synthesis code should remain ignorant of these differences.

**V2's approach:** The [architecture document](../architecture.md) describes V2's three-tier separation. The core synthesis lives in tier one, accepting opaque pointers and raw buffer arrays. The C API in tier two provides stable function signatures that any host can call. Plugin wrappers in tier three adapt host-specific conventions to the C API. This layering means adding a new host requires only writing a new wrapper. The synthesis code never changes.

**Rust translation:** Traits define the abstraction boundary between the synthesizer and its hosts. The synthesizer implements a core trait; adapters implement host-specific interfaces by delegating to the core.

```rust
trait AudioProcessor {
    fn process(&mut self, midi: &[MidiEvent], output: &mut [f32]);
    fn set_sample_rate(&mut self, rate: f32);
    fn reset(&mut self);
}

impl AudioProcessor for V2Synth {
    fn process(&mut self, midi: &[MidiEvent], output: &mut [f32]) {
        for event in midi { self.handle_midi(*event); }
        self.render(output);
    }
    fn set_sample_rate(&mut self, rate: f32) { self.recalculate_coefficients(rate); }
    fn reset(&mut self) { self.voices.reset_all(); self.effects.clear(); }
}

// CPAL adapter wraps the core for desktop audio
fn build_cpal_stream(proc: Arc<Mutex<impl AudioProcessor>>) -> cpal::Stream {
    device.build_output_stream(&config, move |data: &mut [f32], _| {
        proc.lock().unwrap().process(&[], data);
    }, |e| eprintln!("{}", e), None).unwrap()
}
```

**Key insight:** The trait boundary isolates host-specific concerns from synthesis logic. Adding new hosts requires only implementing adapters; the core remains untouched.

---

## Summary Table

| Pattern | Problem | V2 Solution | Rust Translation |
|---------|---------|-------------|------------------|
| Voice Pool | Fixed polyphony without allocation | Array + -1 sentinel map | `[Option<Allocation>; 64]` |
| Frame Processing | Control vs. sample rate | 128-sample frames, volume ramping | Slice API, `std::simd` |
| Modulation Graph | Flexible source/dest routing | 3-byte routings, sum contributions | `trait ModSource`, enum dispatch |
| Real-Time Safety | No blocking in audio thread | Static alloc, critical sections | Atomics, `ringbuf` crate |
| State Variable Filter | Multi-output from single topology | `l`/`b` state, mode selection | `FilterOutput` struct with methods |
| Plugin Abstraction | Multiple hosts, single core | C API + wrappers | `trait AudioProcessor` + adapters |

---

## Implementation Order

These patterns have dependencies. Implementing them in the wrong order creates rework.

1. **Start with frame-based processing.** The frame concept underlies everything else. Define frame size constants and slice-based APIs first.

2. **Add voice pool management.** With frames defined, implement the pool. Use `Option` for allocation state from the start.

3. **Implement modulation routing.** The trait-based sources integrate naturally once voices exist. Keep routing data compact.

4. **Add the state variable filter.** Filters are standalone DSP units. The multi-output struct pattern applies immediately.

5. **Establish real-time safety patterns.** Once the core works, add lock-free communication. The `ringbuf` crate drops in easily.

6. **Abstract for plugins last.** With a working core, the trait boundary becomes obvious. Host adapters follow naturally.

---

## Related Documents

| Source | Topics Covered |
|--------|---------------|
| [Voice Architecture](../synthesis-engine/voice-architecture.md) | Pool management, allocation priority |
| [Modulation System](../synthesis-engine/modulation.md) | Envelopes, LFOs, routing matrix |
| [Filters](../synthesis-engine/filters.md) | State variable, Moog ladder |
| [Audio I/O](../integration/audio-io.md) | Threading, lock-free communication |
| [V2 Architecture](../architecture.md) | Three-tier design, frame processing |
| [Rust-Specific Idioms](../../../../insights/rust-specific.md) | Ownership, traits, `Arc` patterns |
