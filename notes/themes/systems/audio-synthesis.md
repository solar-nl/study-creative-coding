# Audio Synthesis: Cross-Framework Comparison

> Five creative coding frameworks, five approaches to the unforgiving constraints of real-time audio

---

## The Unique Challenge of Audio

Audio programming demands what most creative coding tasks do not: absolute punctuality. A graphics frame arriving 16 milliseconds late causes a brief stutter. An audio buffer arriving 16 milliseconds late produces an audible click that breaks immersion entirely. The audio hardware consumes samples at precisely 44,100 per second (or 48,000, depending on configuration), and it refuses to wait for your synthesizer to finish a complex calculation. Miss the deadline, and listeners hear silence or artifacts.

This constraint shapes every architectural decision in real-time audio systems. Memory allocation, which typically completes in microseconds, becomes dangerous because allocators may block waiting for operating system locks. File I/O, network requests, even logging to console can stall the audio thread long enough to cause dropouts. The audio callback must execute in bounded time, every time, with no exceptions.

Creative coding frameworks handle this challenge in fundamentally different ways. Some build audio synthesis into their core, optimizing every path for real-time safety. Others delegate to external libraries, providing clean integration points but leaving audio complexity to specialists. Still others embrace the browser's Web Audio API, trading low-level control for cross-platform compatibility. Understanding these approaches helps identify which patterns translate to a new Rust-based framework.

Think of audio processing as a factory assembly line producing samples at a fixed rate. The conveyor belt moves continuously whether workers have filled the boxes or not. Empty boxes reaching the end mean silence in the speakers. Each framework takes a different approach to staffing this assembly line, from employing dedicated specialists (V2's built-in polyphonic synth) to hiring contractors through established agencies (nannou's CPAL integration) to outsourcing to the browser's facilities (cables.gl's Web Audio operators).

This comparison examines five frameworks across five dimensions: how they talk to audio hardware, how they manage simultaneous voices, how they ensure real-time safety, how they handle parameter modulation, and how deeply audio integrates with the rest of the framework.

---

## Framework Overview

| Framework | Language | Audio Approach | Primary Use Case |
|-----------|----------|----------------|------------------|
| **V2** (fr_public) | C++/asm | Built-in 64-voice polyphonic synth | Demoscene, size-coded productions |
| **nannou** | Rust | CPAL + dasp ecosystem | Creative coding, installations |
| **OpenFrameworks** | C++ | ofSoundStream, addon-based | Multimedia art, prototyping |
| **Processing** | Java | Minim / Sound library | Education, sketching |
| **cables.gl** | JavaScript | Web Audio API integration | Web-based visuals, live performance |

---

## Audio Backend Abstraction

Every framework must eventually talk to the operating system's audio subsystem. The approaches range from direct platform calls to multi-layered abstractions.

### Platform-Specific vs. Cross-Platform

**V2** speaks directly to Windows DirectSound, accepting the platform lock in exchange for minimal abstraction overhead. The `soundsys.cpp` file implements a circular buffer dance with DirectSound, manually tracking play cursors and handling buffer wraparound. This directness enables precise latency control but limits portability.

**OpenFrameworks** abstracts through ofSoundStream, which internally delegates to RtAudio or platform-specific backends. The API exposes device enumeration and stream configuration while hiding platform differences.

| Aspect | V2 | nannou | OpenFrameworks | Processing | cables.gl |
|--------|-----|--------|----------------|------------|-----------|
| **Backend** | DirectSound (Windows) | CPAL | RtAudio / platform | JavaSound / PortAudio | Web Audio API |
| **Device control** | Single default | Full enumeration | Full enumeration | Limited | Browser-managed |
| **Latency control** | Explicit buffer sizing | Via CPAL config | Buffer size parameter | Abstracted | Browser-dependent |

### The Callback Model

All frameworks converge on a callback pattern: the audio system invokes your code when it needs samples. This inversion of control ensures the audio thread maintains priority.

**nannou** exemplifies the Rust approach with CPAL.

```rust
let stream = audio_host
    .new_output_stream(model)
    .render(|audio: &mut Audio, buffer: &mut Buffer| {
        for frame in buffer.frames_mut() {
            let sample = (2.0 * PI * audio.phase).sin() as f32;
            audio.phase += audio.hz / buffer.sample_rate() as f64;
            for channel in frame {
                *channel = sample * 0.5;
            }
        }
    })
    .build()
    .unwrap();
```

The callback receives a mutable buffer and must fill it before returning. This pattern appears universally, from V2's DSIOCALLBACK to OpenFrameworks' audioOut method to Web Audio's ScriptProcessorNode (deprecated) and AudioWorklet (modern).

**OpenFrameworks** uses a similar pattern through class inheritance.

```cpp
class ofApp : public ofBaseApp {
public:
    void audioOut(ofSoundBuffer& buffer) override {
        for (size_t i = 0; i < buffer.getNumFrames(); i++) {
            float sample = sin(phase) * volume;
            phase += frequency * TWO_PI / buffer.getSampleRate();
            buffer[i * 2] = sample;      // Left
            buffer[i * 2 + 1] = sample;  // Right
        }
    }
};
```

### Key Insight

Abstraction level correlates with intended use case. V2's direct approach suits demoscene productions where every byte matters. CPAL's cross-platform design fits Rust's portability goals. Web Audio's browser integration eliminates deployment friction for web artists.

---

## Voice Management

Polyphony presents a resource management challenge. Each simultaneous note requires its own oscillators, filters, and envelope generators. How frameworks handle voice allocation reveals their design priorities.

### Built-In vs. External

**V2** implements a complete 64-voice polyphonic synthesizer with sophisticated voice stealing. When all voices are active and a new note arrives, the allocator searches in priority order: free voices first, then voices in release phase (gate off), then the oldest active voice. This minimizes audible artifacts by preferring to steal notes that are already fading.

```cpp
// V2's voice allocation priority (simplified from synth_core.cpp)
sInt usevoice = -1;

// Priority 1: Find any free voice
for (sInt i = 0; i < POLY; i++) {
    if (chanmap[i] < 0) { usevoice = i; break; }
}

// Priority 2: Find oldest voice with gate off (in release)
if (usevoice < 0) {
    sU32 oldest = curalloc;
    for (sInt i = 0; i < POLY; i++) {
        if (!voicesw[i].gate && allocpos[i] < oldest) {
            oldest = allocpos[i]; usevoice = i;
        }
    }
}

// Priority 3: Steal oldest active voice
if (usevoice < 0) {
    sU32 oldest = curalloc;
    for (sInt i = 0; i < POLY; i++) {
        if (allocpos[i] < oldest) { oldest = allocpos[i]; usevoice = i; }
    }
}
```

**nannou** and **OpenFrameworks** leave voice management to the application. Neither provides built-in polyphony; developers implement their own voice pools or use external synthesizer libraries. This flexibility suits creative coding where audio needs vary widely.

**cables.gl** inherits Web Audio's voice model, where each note typically creates new AudioNodes that disconnect when finished. The browser handles garbage collection, simplifying code at the cost of less predictable resource usage.

| Framework | Voice Count | Allocation Strategy | Voice Stealing |
|-----------|-------------|---------------------|----------------|
| **V2** | 64 fixed | Priority-based LRU | Yes, sophisticated |
| **nannou** | User-defined | User-implemented | User-implemented |
| **OpenFrameworks** | User-defined | User-implemented | User-implemented |
| **Processing** | Library-dependent | Minim/Sound varies | Library-dependent |
| **cables.gl** | Browser-limited | Node creation | GC-based cleanup |

### Key Insight

Frameworks targeting specific audio use cases (V2 for demoscene music) build in voice management. General-purpose creative coding frameworks delegate to user code or external libraries, avoiding assumptions about polyphony needs.

---

## Real-Time Safety

The audio thread must never block. This constraint eliminates many common programming patterns from audio callbacks.

### Forbidden Operations

Memory allocation, file I/O, mutex acquisition, and system calls can all block for unbounded time. Real-time audio code must avoid these operations entirely within the callback.

**V2** achieves real-time safety through static allocation. The entire synthesizer state, including all 64 voices and their delay buffers, is allocated at initialization. The audio callback performs no allocations during operation.

```cpp
// V2 pre-allocates everything in V2Synth structure
struct V2Synth {
    V2Voice voicesw[POLY];              // 64 voices pre-allocated
    sF32 maindelbuf[2][32768];          // Delay lines pre-allocated
    sF32 chandelbuf[CHANS][2][2048];    // Per-channel delays
    // Total: approximately 2.5 MB, all static
};
```

**Rust** enforces different constraints through its type system. Types that might allocate (String, Vec without pre-reserved capacity) become obvious when you use them in audio code. Lock-free communication replaces mutex-protected regions.

```rust
use std::sync::atomic::{AtomicU64, Ordering};
use ringbuf::HeapRb;

// Lock-free position tracking
struct AudioPosition {
    samples_rendered: AtomicU64,
}

impl AudioPosition {
    fn advance(&self, count: u64) {
        self.samples_rendered.fetch_add(count, Ordering::Release);
    }
}

// Lock-free MIDI event delivery
fn audio_callback(synth: &mut Synth, midi: &mut Consumer<MidiEvent>, out: &mut [f32]) {
    while let Some(event) = midi.try_pop() {
        synth.process_midi(event);
    }
    synth.render(out);
}
```

| Framework | Thread Safety Approach | Communication Pattern |
|-----------|----------------------|----------------------|
| **V2** | Critical sections | Lock during access |
| **nannou** | Rust ownership | Lock-free ring buffers |
| **OpenFrameworks** | std::mutex available | User responsibility |
| **Processing** | Java synchronized | Callback isolation |
| **cables.gl** | Single-threaded (JS) | Event-driven |

### Key Insight

V2 achieves safety through discipline and static allocation. Rust achieves it through type system enforcement. JavaScript sidesteps the issue with single-threaded execution (though AudioWorklets introduce threading). A Rust framework should leverage the type system to surface real-time violations as compile-time errors where possible.

---

## Modulation Systems

Parameters rarely stay constant in music. Envelopes shape amplitude over time, LFOs add vibrato and tremolo, velocity affects timbre. How frameworks handle time-varying parameters affects both expressiveness and performance.

### Control Rate vs. Audio Rate

**V2** introduces a crucial optimization: frame-based processing. Rather than updating envelopes and LFOs for every sample (44,100 times per second), V2 updates them once per frame of 128 samples (roughly 344 times per second). This 128x reduction in control calculations frees CPU cycles for audio rendering.

Volume ramping prevents clicks from control-rate stepping. The envelope calculates a target volume, then the audio loop linearly interpolates across the frame.

```cpp
// Control-rate update (once per frame)
void Voice::tick() {
    for (int i = 0; i < 2; i++) env[i].tick(gate);
    for (int i = 0; i < 2; i++) lfo[i].tick();
    volramp = (env[0].out / 128.0f - curvol) * SRfciframe;
}

// Audio-rate render (per sample, with smooth ramping)
void Voice::render(StereoSample* dest, int nsamples) {
    float cv = curvol;
    for (int i = 0; i < nsamples; i++) {
        float out = voice[i] * cv;
        cv += volramp;
        dest[i].l += lvol * out;
        dest[i].r += rvol * out;
    }
    curvol = cv;
}
```

**Web Audio** provides built-in AudioParam objects with automation methods (setValueAtTime, linearRampToValueAtTime, exponentialRampToValueAtTime). The browser handles interpolation internally.

**cables.gl** wraps Web Audio's AudioParam system for operator ports.

```javascript
// cables.gl audio parameter handling
port.onChange = () => {
    const value = port.get();
    if (node.setValueAtTime) {
        node.setValueAtTime(value, audioCtx.currentTime);
    } else {
        node.value = value;
    }
};
```

| Framework | Modulation Model | Update Rate | Anti-Zipper |
|-----------|-----------------|-------------|-------------|
| **V2** | Frame-based tick/render | ~344 Hz | Linear ramping |
| **nannou** | User-implemented | User choice | User-implemented |
| **OpenFrameworks** | User-implemented | User choice | User-implemented |
| **Processing** | Library-dependent | Library-dependent | Library-dependent |
| **cables.gl** | AudioParam automation | Sample-accurate | Browser-handled |

### Modulation Routing

**V2** implements a modulation matrix where sources (envelopes, LFOs, velocity, MIDI controllers) connect to destinations (filter cutoff, oscillator pitch, amplitude) through configurable routings. Each routing specifies source, destination, and amount.

This pattern translates naturally to Rust traits.

```rust
trait ModSource {
    fn output(&self) -> f32;
}

impl ModSource for Envelope {
    fn output(&self) -> f32 { self.value * self.gain }
}

impl ModSource for Lfo {
    fn output(&self) -> f32 { self.value * self.gain + self.dc }
}

struct ModRouting {
    source: SourceId,
    dest: usize,
    amount: f32,
}

impl ModulationMatrix {
    fn apply(&self, sources: &Sources, params: &mut [f32]) {
        for r in &self.routings {
            params[r.dest] += sources.get(r.source) * r.amount;
        }
    }
}
```

### Key Insight

Frame-based processing with linear interpolation delivers an excellent cost/quality tradeoff. Control calculations at 344 Hz remain imperceptible while dramatically reducing CPU load. A Rust framework should adopt this pattern for any built-in modulation system.

---

## Integration Depth

How deeply audio integrates with the rest of the framework affects both capability and complexity.

### Built-In vs. Ecosystem

| Framework | Integration Model | Audio-Visual Sync | Learning Curve |
|-----------|------------------|-------------------|----------------|
| **V2** | Deeply integrated | Sample-accurate | High (specialized) |
| **nannou** | CPAL + dasp | App-level | Moderate |
| **OpenFrameworks** | Core + addons | Buffer-level | Moderate |
| **Processing** | External library | Frame-level | Low |
| **cables.gl** | Web Audio ops | Operator-based | Low-moderate |

**V2** tightly couples audio and demo timing through sample position tracking. The demo engine queries `dsGetCurSmp()` to know exactly which sample is playing, enabling frame-accurate visual synchronization with the music.

**nannou** separates concerns cleanly. The audio stream runs independently from the application model, with communication through Rust's standard concurrency primitives. This separation enables flexible architectures but requires explicit synchronization for audio-reactive visuals.

**cables.gl** integrates Web Audio through operators that fit naturally in its node-based editor. Audio nodes connect to visual operators, enabling audio-reactive patching without code.

### Key Insight

Deep integration suits specialized use cases (demoscene, music software). Ecosystem-based approaches suit general creative coding where audio needs vary. A Rust framework could offer both: core integration for common patterns, plus clean extension points for advanced audio work.

---

## Key Insights for Rust Framework

This cross-framework comparison suggests several design directions for a Rust-based creative coding framework.

### Adopt from V2

| Pattern | Why | Rust Adaptation |
|---------|-----|-----------------|
| Frame-based processing | 128x reduction in control calculations | Fixed-size buffers, slice API |
| Voice pool with Option | Type-safe allocation state | `[Option<VoiceAllocation>; 64]` |
| Static pre-allocation | Guaranteed real-time safety | Arena allocators, fixed pools |
| Modulation matrix | Flexible, data-driven routing | Trait-based sources, enum dispatch |

### Adopt from CPAL/dasp Ecosystem

| Pattern | Why | Implementation |
|---------|-----|----------------|
| Cross-platform abstraction | Rust's portability goals | Use CPAL directly |
| Sample type generics | Flexibility without runtime cost | dasp's sample traits |
| Lock-free communication | Type-safe real-time safety | ringbuf crate |

### Consider from Web Audio

| Pattern | Why | Adaptation |
|---------|-----|------------|
| Node graph composition | Visual programming friendly | Optional high-level API |
| Built-in automation curves | Smooth parameter changes | Envelope helpers |
| Analyzer nodes | Audio-reactive visuals | FFT integration |

### Avoid

| Anti-Pattern | Why |
|--------------|-----|
| Allocation in audio callback | Breaks real-time guarantees |
| Mutex-protected audio state | Risks priority inversion |
| Single-backend lock-in | Limits platform reach |
| No built-in helpers | Leaves common patterns to users |

---

## Summary

Audio synthesis in creative coding frameworks spans a spectrum from deeply integrated (V2's complete synthesizer) to ecosystem-delegated (nannou's CPAL approach) to platform-provided (cables.gl's Web Audio). Each approach reflects its context: V2 optimizes for demoscene constraints, nannou leverages Rust's safety guarantees, and Web Audio trades control for browser reach.

For a new Rust framework, the evidence suggests a layered approach:

1. **Core**: Use CPAL for cross-platform audio backend abstraction
2. **Helpers**: Provide frame-based processing utilities, voice pool primitives, and modulation helpers
3. **Integration**: Enable clean audio-visual synchronization without mandating it
4. **Safety**: Leverage Rust's type system to make real-time violations visible at compile time

One constraint unifies all approaches: the audio callback must complete in bounded time, every time. How frameworks achieve this varies, but the requirement remains universal.

---

## Related Documents

| Document | Topics Covered |
|----------|---------------|
| [V2 Audio I/O](../../per-demoscene/fr_public/v2/integration/audio-io.md) | DirectSound streaming, threading model |
| [V2 Voice Architecture](../../per-demoscene/fr_public/v2/synthesis-engine/voice-architecture.md) | Polyphony, voice stealing |
| [V2 Audio DSP Patterns](../../per-demoscene/fr_public/v2/patterns/audio-dsp-patterns.md) | Rust translations of V2 patterns |
| [Node Graph Systems](../core/node-graph-systems.md) | Visual programming comparison (includes cables.gl audio operators) |
| [Rust-Specific Idioms](../../../insights/rust-specific.md) | Ownership, traits, Arc patterns for lock-free audio |
| [nannou Architecture](../../per-framework/nannou/architecture.md) | CPAL integration, model-update-view pattern |
