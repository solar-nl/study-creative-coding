# V2 Synthesizer Study

> Farbrausch's production synthesizer powering legendary demos and .kkrieger

---

## Why Study V2?

The V2 represents a decade of demoscene audio expertise compressed into production-quality code. It powered:

- **fr-041: debris** — The legendary 177KB demo with orchestral audio
- **.kkrieger** — A complete FPS game in 96KB with dynamic soundtrack
- **fr-038: theta** — Complex multi-channel compositions in minimal space

Unlike academic synthesizers or bloated DAW plugins, V2 was designed under extreme constraints: every byte counted, every CPU cycle mattered, yet it still delivered expressive, professional-quality sound.

### Relevance to Creative Coding

V2 solves problems that creative coding frameworks often handle poorly:

| Challenge | V2's Solution | Framework Relevance |
|-----------|---------------|---------------------|
| Real-time audio generation | Lock-free voice pool, frame-based processing | Audio-reactive visuals need sample-accurate sync |
| Expressive modulation | 255-slot mod matrix with per-sample resolution | Parameter animation systems can learn from this |
| Multi-platform distribution | Three-tier architecture (core/API/plugin) | Clean separation enables cross-platform audio |
| CPU efficiency | Dual implementation (asm + C++ reference) | SIMD patterns transfer to modern Rust |

---

## Key Insights

1. **Voice Pool Architecture** — 64 simultaneous voices with per-voice state isolation. Voice stealing uses LRU when polyphony exceeds limit.

2. **Modulation Matrix** — Up to 255 routing slots per patch connecting sources (envelopes, LFOs, MIDI) to destinations (filter cutoff, oscillator pitch, etc.).

3. **Frame-Based Processing** — Audio rendered in 128-sample chunks. Modulation updates per-frame (~344Hz), audio runs at sample rate (44.1kHz+).

4. **Three-Tier Separation** — Assembly core for speed, C API for portability, plugin wrappers for host integration.

5. **Real-Time Safety** — No memory allocation in the audio thread. Denormal prevention throughout. Circular buffer streaming with thread synchronization.

6. **Audio-Visual Sync** — Sample-position tracking enables precise synchronization with demo timelines.

---

## Documentation Structure

```
v2/
├── README.md                    # This file
├── architecture.md              # System layers and data flow
├── synthesis-engine/
│   ├── voice-architecture.md    # 64-voice polyphony system
│   ├── oscillators.md           # 7 waveform modes
│   ├── filters.md               # State-variable and Moog filters
│   └── modulation.md            # ADSR, LFO, mod matrix
├── effects/
│   └── signal-chain.md          # Distortion, delay, reverb, compression
├── integration/
│   ├── audio-io.md              # DirectSound threading
│   ├── midi-handling.md         # Note/CC processing
│   └── plugin-interfaces.md     # VST, Buzz, Winamp
├── patterns/
│   └── audio-dsp-patterns.md    # Rust translation patterns
└── code-traces/
    ├── note-to-sound.md         # MIDI note → audio output trace
    └── modulation-update.md     # LFO → parameter update trace
```

---

## Quick Reference

### Core Files

| File | Lines | Purpose |
|------|-------|---------|
| `v2/synth.asm` | 5,932 | x86 assembly core (optimized) |
| `v2/synth_core.cpp` | 3,352 | C++ reference (readable) |
| `v2/synth.h` | ~200 | Public API |
| `v2/libv2.h` | ~100 | C-callable interface |
| `v2/sounddef.h` | 371 | Patch/parameter definitions |

### Entry Points

```c
// Initialize synthesizer with patch bank
void synthInit(void *synth, const void *patchmap, int samplerate);

// Render audio frames
void synthRender(void *synth, void *buf, int samples, void *buf2, int add);

// Process MIDI events
void synthProcessMIDI(void *synth, const void *ptr);

// VU metering
void synthGetMainVU(void *synth, float *left, float *right);
```

---

## Related Documents

- [Werkkzeug4 Study](../werkkzeug4/) — V2 was integrated into demo productions via Werkkzeug
- [Node Graph Patterns](../patterns/node-graph-patterns.md) — Operator patterns from the same codebase
- [Audio Synthesis Theme](../../../themes/systems/audio-synthesis.md) — Cross-framework comparison (planned)

---

## External Resources

- [Pouet: Farbrausch](https://www.pouet.net/groups.php?which=322) — Production archive
- [ryg's blog](https://fgiesen.wordpress.com/) — Technical posts from V2's author
- [V2 source on GitHub](https://github.com/farbrausch/fr_public/tree/master/v2) — Original release
