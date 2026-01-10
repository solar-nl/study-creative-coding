# V2 Synthesizer Architecture

## The Recording Studio Model

Picture a professional recording studio. Musicians perform in a soundproofed tracking room while engineers watch through thick glass from the control room, adjusting faders and effects on a massive mixing console. The tracking room runs continuously during a session; you cannot stop the tape to reconfigure the microphones mid-take. Engineers communicate intentions through the glass, but the performers must interpret and execute without interruption. The console shapes the final output, routing signals through compressors and reverbs before they reach the master recorder.

The V2 synthesizer follows this same architectural division. Farbrausch designed V2 to generate professional-quality audio within the extreme size constraints of demoscene productions. Every architectural decision reflects two competing pressures: the audio thread cannot pause to think (like a live recording session), and the entire synthesizer must fit in kilobytes, not megabytes. The solution separates concerns into three distinct layers, each with its own responsibilities and timing requirements.

This architecture emerged from the practical realities of real-time audio. Modern computers can execute billions of instructions per second, yet audio demands sample delivery at precise 22-microsecond intervals (at 44.1kHz). Miss that deadline and the listener hears clicks, pops, or silence. The studio metaphor captures this constraint perfectly: the tape keeps rolling whether you are ready or not.

Understanding V2's three-tier architecture explains not just how the synthesizer works, but why software synthesizers are structured this way universally. The patterns you learn here apply to any real-time audio system, from simple tone generators to commercial DAW plugins.

For detailed walkthroughs of specific operations, see the [code traces](code-traces/) directory, particularly [note-to-sound.md](code-traces/note-to-sound.md) which follows a MIDI note through the entire pipeline.

## Why Three Tiers?

Real-time audio software faces a fundamental tension. Users want rich interfaces with immediate feedback. But audio generation cannot wait for UI redraws or disk access. These two worlds operate on incompatible timescales: human perception works in hundreds of milliseconds while audio demands sub-millisecond precision.

The three-tier solution isolates each concern. The core synthesis engine runs in the tracking room, generating audio samples as fast as the CPU allows. The C API creates the control room window, providing a stable interface through which external code can observe and direct the session. Plugin wrappers form different mixing consoles, adapting V2 to VST hosts, Buzz trackers, or Winamp visualization.

This separation yields several benefits. The core can be optimized ruthlessly without breaking external interfaces. Different hosts can integrate V2 without modifying synthesis code. Most critically, the audio thread never blocks waiting for UI or host operations. The tracking room keeps recording regardless of what happens in the control room.

## Tier 1: The Tracking Room (Core Synthesis)

The tracking room houses all the musicians and their instruments. In V2, this means the oscillators, filters, envelopes, and effects that actually generate sound. The core synthesis code lives in `synth_core.cpp`, a 3200-line implementation that handles everything from MIDI parsing to final audio output.

V2 allocates all memory statically at initialization. The entire synthesizer state fits in a single `V2Synth` structure that requires approximately 2.5 megabytes. This might seem excessive for a "size-coded" demoscene synth, but consider what it contains: 64 polyphonic voices, 16 MIDI channels, global reverb and delay with their delay lines, plus all the working buffers for a frame of audio.

The decision to avoid dynamic allocation during audio generation reflects a hard real-time constraint. Memory allocators may block waiting for operating system locks. Even a brief pause can cause audio dropouts. By pre-allocating everything, V2 guarantees the audio thread never waits.

The V2Synth structure organizes memory hierarchically. This example shows the major components:

```cpp
struct V2Synth
{
  static const sInt POLY = 64;    // Maximum simultaneous voices
  static const sInt CHANS = 16;   // MIDI channels

  const V2PatchMap *patchmap;     // Pointer to patch definitions
  sU32 mrstat;                    // MIDI running status
  sU32 curalloc;                  // Voice allocation counter

  V2ChanInfo chans[CHANS];        // Per-channel state
  V2Voice voicesw[POLY];          // Voice working state
  V2Chan chansw[CHANS];           // Channel working state

  V2Reverb reverb;                // Global reverb
  V2ModDel delay;                 // Global delay
  V2Comp compr;                   // Master compressor

  sF32 maindelbuf[2][32768];      // ~1.5MB for main delay
  sF32 chandelbuf[CHANS][2][2048]; // ~512KB for channel delays

  V2Instance instance;            // Per-frame buffers and constants
};
```

The V2Instance nested structure holds frame-sized working buffers. These buffers get reused every frame, keeping the total memory footprint bounded regardless of how long the synth runs. The frame size defaults to 128 samples at 44.1kHz, providing about 2.9 milliseconds of audio per processing cycle. The structure below shows these working buffers:

```cpp
struct V2Instance
{
  static const int MAX_FRAME_SIZE = 280;

  // Per-frame working buffers
  sF32 vcebuf[MAX_FRAME_SIZE];          // Voice mono buffer
  sF32 vcebuf2[MAX_FRAME_SIZE];         // Second voice buffer
  StereoSample chanbuf[MAX_FRAME_SIZE]; // Channel stereo buffer
  StereoSample mixbuf[MAX_FRAME_SIZE];  // Main mix buffer
  sF32 aux1buf[MAX_FRAME_SIZE];         // Reverb send
  sF32 aux2buf[MAX_FRAME_SIZE];         // Delay send
  StereoSample auxabuf[MAX_FRAME_SIZE]; // Aux bus A
  StereoSample auxbbuf[MAX_FRAME_SIZE]; // Aux bus B

  sInt SRcFrameSize;                    // Actual frame size
  sF32 SRfciframe;                      // 1.0 / frame size
};
```

The tracking room's musicians are the voices. Each voice represents a single sounding note, containing three oscillators, two filters, two envelopes, two LFOs, distortion, and DC filtering. V2 supports 64 simultaneous voices, though patches can limit polyphony to reduce CPU load. For a detailed trace of voice processing, see [modulation-update.md](code-traces/modulation-update.md).

## Tier 2: The Control Room (C API)

The control room provides observation and direction capabilities without interfering with the recording session. In V2, this takes the form of a pure C interface defined in `synth.h` and `libv2.h`. The C calling convention ensures compatibility with any language or host that can call C functions.

The API follows a deliberately opaque pattern. Hosts allocate memory for the synth state, but they never inspect or modify that memory directly. Every interaction goes through function calls, preserving encapsulation. This design allows the internal structure to change between versions without breaking host compatibility.

The control room window has a specific size, which hosts must respect. The following code shows the complete public interface:

```cpp
extern "C"
{
  // Memory management
  unsigned int __stdcall synthGetSize();

  // Initialization
  void __stdcall synthInit(void *pthis, const void *patchmap, int samplerate);
  void __stdcall synthSetGlobals(void *pthis, const void *ptr);

  // Audio generation
  void __stdcall synthRender(void *pthis, void *buf, int smp, void *buf2, int add);

  // MIDI input
  void __stdcall synthProcessMIDI(void *pthis, const void *ptr);

  // Monitoring
  void __stdcall synthGetChannelVU(void *pthis, int ch, float *l, float *r);
  void __stdcall synthGetMainVU(void *pthis, float *l, float *r);
}
```

The `pthis` parameter appears in every function. Hosts treat it as an opaque handle, but internally it points to a V2Synth structure. This pattern enables multiple independent synth instances without global state, which proves essential for multi-timbral setups or running multiple songs simultaneously.

The MIDI interface deserves special attention. Rather than exposing individual note-on and note-off functions, V2 accepts raw MIDI byte streams. The synthesizer handles running status, parses messages, and updates internal state. This approach matches how real MIDI hardware works and simplifies integration with sequencers that already produce MIDI streams.

## Tier 3: The Mixing Console (Plugin Interfaces)

Different recording studios use different mixing consoles. Some prefer analog warmth, others digital precision. V2 adapts to multiple plugin formats, each acting as a different console that presents V2's capabilities to a specific host environment.

The VST wrapper exposes V2 as a virtual instrument plugin for DAWs like Cubase, Ableton Live, or FL Studio. The Buzz wrapper integrates with Buzz, a modular tracker popular in the demoscene. The Winamp plugin allows V2 to power visualization in the classic media player.

Each wrapper translates host-specific conventions into V2's C API. VST provides audio buffers in a particular format and expects parameter automation; the wrapper converts these to synthRender calls and MIDI controller changes. Buzz uses a different callback structure; its wrapper adapts accordingly.

This tier handles buffer format conversion that the core ignores. Some hosts want interleaved stereo (LRLRLR), others want planar buffers (LLL...RRR). The synthRender function supports both through its buf2 parameter. When buf2 is NULL, output goes to buf as interleaved stereo. When buf2 is provided, left samples go to buf and right samples go to buf2.

## Frame-Based Processing: The Take

Recording studios think in takes. You do not record one sample at a time; you capture continuous performances. V2 similarly processes audio in frames rather than individual samples. A frame represents 128 samples at 44.1kHz (about 2.9 milliseconds), the atomic unit of audio generation.

Frame-based processing provides a critical optimization opportunity. Control-rate calculations (envelopes, LFOs, modulation) happen once per frame, not once per sample. At 44.1kHz, this reduces control-rate calculations by 128x while maintaining sufficient resolution for smooth parameter changes. The ear cannot perceive discontinuities at 344Hz update rates.

The rendering loop alternates between control updates and audio generation. Each frame begins with a "tick" that updates all modulators, then renders the actual audio samples. This structure keeps the inner audio loop tight and predictable.

```cpp
void tick()
{
  // Process all active voices
  for (sInt i=0; i < POLY; i++)
  {
    if (chanmap[i] < 0) continue;  // Skip inactive voices

    storeV2Values(i);    // Apply modulation matrix
    voicesw[i].tick();   // Update envelopes and LFOs

    // Check for voice termination
    if (voicesw[i].env[0].state == V2Env::OFF)
      chanmap[i] = -1;   // Release the voice
  }

  // Process all channels
  for (sInt i=0; i < CHANS; i++)
    storeChanValues(i);

  renderFrame();  // Generate audio for this frame
}
```

The tick function acts as the conductor, ensuring all musicians stay synchronized. Voice termination happens here too: when the amplitude envelope reaches OFF state, the voice returns to the free pool. This check occurs at control rate, not audio rate, keeping the cost minimal.

## Data Flow: Following a Note

To understand how these tiers interact, trace a single note from MIDI input to audio output. This journey reveals the data transformations and buffering strategies that make real-time synthesis possible.

When MIDI arrives, it enters through the control room window. The processMIDI function parses the byte stream, handling running status and dispatching messages. A Note On message triggers voice allocation, which searches the 64-voice pool for an available slot.

The voice allocator implements a priority scheme. It first seeks truly free voices. Failing that, it looks for voices in release phase (gate off but still sounding). As a last resort, it steals the oldest active voice. This allocation counter tracks "age" for fair stealing.

Once allocated, a voice receives its marching orders: the patch. A patch specifies oscillator modes, filter settings, envelope shapes, and the modulation matrix connecting sources to destinations. These parameters act as sheet music, telling the voice what to play and how to shape it.

Each frame, the modulation system recalculates voice parameters. The patch provides base values, then the modulation matrix adds contributions from velocity, envelopes, LFOs, and MIDI controllers. The result overwrites the working parameter set, ready for audio rendering.

Audio rendering proceeds through the voice signal chain: oscillators generate raw waveforms, filters shape the spectrum, distortion adds harmonics, and the amplitude envelope controls loudness. The voice outputs to the channel buffer, where multiple voices accumulate.

Channel processing adds another effect chain: compression, EQ boost, distortion, and chorus/flanger. Channel buffers also feed aux sends for global reverb and delay. Finally, all channels mix to the master bus where global effects and the master compressor apply.

## Threading: The Live Session

The tracking room never stops during a session. Tape keeps rolling, and every dropped sample becomes an audible artifact. V2's threading model respects this constraint absolutely.

The audio thread runs synthRender, which generates samples on demand. The host's audio driver typically calls this function from a high-priority thread with strict timing requirements. V2 never allocates memory, never blocks on locks, and never waits for external resources during this call.

Parameter changes from MIDI or host automation arrive between render calls. The processMIDI function updates internal state, but these updates happen atomically from the audio thread's perspective. MIDI bytes go into a buffer that processMIDI consumes; there is no lock contention.

The libv2.h header documents the threading contract for DirectSound output. These lock functions protect parameter modifications from non-audio threads:

```cpp
// From libv2.h:
// lock and unlock the sound thread's thread sync lock. If you want to modify
// any of your sound variables outside the render thread, encapsulate that
// part of code in between these two functions.
void __stdcall dsLock();
void __stdcall dsUnlock();
```

This explicit locking only applies to the DirectSound helper layer. The core synthesizer assumes single-threaded access during MIDI processing and rendering. Hosts using other audio APIs must provide equivalent synchronization.

## Patch Architecture: The Sheet Music

Patches define how a voice sounds. V2 stores patches as compact byte arrays, optimized for demoscene size constraints. Each parameter occupies a single byte (0-127 range, matching MIDI conventions), keeping patch data minimal.

The V2Sound structure separates voice parameters from channel parameters. Voice parameters control oscillators, filters, and envelopes. Channel parameters control effects that process multiple voices together. This separation enables efficient processing: voice parameters change per-voice while channel parameters change per-channel.

```cpp
struct V2Sound
{
  sU8 voice[sizeof(syVV2) / sizeof(sF32)];  // Voice params as bytes
  sU8 chan[sizeof(syVChan) / sizeof(sF32)]; // Channel params as bytes
  sU8 maxpoly;                               // Polyphony limit
  sU8 modnum;                                // Modulation routing count
  V2Mod modmatrix[1];                        // Variable-length array
};
```

The modulation matrix follows patch parameters. Each modulation routing requires only 3 bytes: source index, amount (with center at 64 for bipolar modulation), and destination parameter index. A typical patch might have 4-8 modulation routings; the matrix costs 12-24 bytes total.

This design achieves remarkable compression. A complete patch specification fits in roughly 100 bytes, yet provides deep synthesis capabilities. The demoscene demands this efficiency: demos often contain dozens of patches within a 64KB executable.

## Volume Ramping: Smooth Transitions

Abrupt parameter changes cause clicks. If a voice suddenly jumps from full volume to silence, the discontinuity appears as a click in the audio. The tracking room handles this through volume ramping: gradual transitions that span an entire frame.

Each frame, the tick function calculates a volume ramp slope. Rather than applying the new envelope value immediately, the audio loop interpolates between the old and new values across all samples in the frame.

```cpp
// In V2Voice::tick()
volramp = (env[0].out / 128.0f - curvol) * inst->SRfciframe;

// In V2Voice::render(), for each sample
sF32 out = voice[i] * cv;
cv += volramp;  // Smooth interpolation
```

The ramp slope equals (target - current) / framesize. Over 128 samples, this produces a linear fade that reaches the target exactly at frame end. The ear perceives this as a smooth volume change rather than a jarring step.

This pattern generalizes to any discontinuity-prone parameter. V2 applies similar smoothing to filter cutoff changes, preventing the "zipper noise" that plagues naive implementations.

## Architectural Insights for Rust

The V2 architecture offers several patterns that translate well to Rust synthesizer development.

Static allocation eliminates allocation in the audio path. Rust's ownership system makes this explicit: audio buffers can be pre-allocated and borrowed mutably during rendering. The borrow checker ensures exclusive access without runtime locks.

The parameter/working state separation maps to Rust's distinction between configuration and mutable state. Patches become immutable reference types while voice state remains mutable. The modulation system borrows parameters immutably and voice state mutably, which the borrow checker validates at compile time.

Frame-based processing enables efficient SIMD. When processing 128 samples at once, Rust's portable SIMD or explicit intrinsics can vectorize inner loops. The frame concept provides natural boundaries for these optimizations.

The three-tier separation suggests a library structure. The core synthesis goes in a `no_std` crate with no dependencies on audio infrastructure. A separate crate wraps this core for specific host APIs (CPAL, Jack, CoreAudio). Plugin wrappers become distinct crates depending on the core and host crates.

## Summary

V2's recording studio architecture separates concerns across three tiers. The tracking room (core synthesis) generates audio without interruption. The control room (C API) provides stable observation and direction interfaces. The mixing console (plugin wrappers) adapts to specific host environments.

Frame-based processing balances efficiency with responsiveness. Control-rate updates happen 344 times per second, fast enough for musical expression while reducing computation 128x compared to sample-rate processing.

Static allocation and careful threading ensure reliable real-time performance. The audio thread never blocks, never allocates, and never waits. Parameter updates from MIDI or automation occur atomically between render calls.

This architecture has proven itself across thousands of demoscene productions and commercial plugin deployments. Its patterns remain relevant for any real-time audio system, whether implemented in C++, Rust, or any other language with deterministic performance characteristics.

---

**See also:**
- [V2 Overview](README.md) - Introduction and key insights
- [Note to Sound Trace](code-traces/note-to-sound.md) - Complete walkthrough from MIDI to audio output
- [Modulation Update Trace](code-traces/modulation-update.md) - Deep dive into the modulation matrix
