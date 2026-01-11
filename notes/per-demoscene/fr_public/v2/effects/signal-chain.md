# Signal Chain: Effects Processing in V2

When a synthesizer voice finishes rendering its oscillators and filters, the sound emerges raw and unpolished. It lacks the spatial depth of a real instrument in a room. Dynamics swing wildly between whisper-quiet passages and ear-splitting peaks. The signal might carry invisible DC bias that eats headroom and causes clicks on playback. V2 addresses all of these concerns through its effects chain.

Think of this stage as the mastering engineer's rack of outboard gear. Just as a mastering engineer receives a mixed track and runs it through a carefully ordered sequence of processors, V2 takes the raw voice output and routes it through distortion, filtering, compression, modulated delay, and reverb. The engineer has decades of experience knowing that you compress before reverb (so the reverb tail stays consistent) and that you remove DC offset before it cascades through nonlinear processors. V2 encodes this same wisdom into its fixed signal chain.

The order of effects matters enormously. Imagine running distortion after reverb: your beautiful room ambience would turn into a harsh, clipped mess. Or consider what happens if DC bias accumulates before hitting a compressor: the compressor responds to the wrong level and pumps erratically. V2 solves these problems by establishing a deliberate signal path that mirrors how professional audio engineers think about processing order.

Why does V2 need effects at the channel level rather than just on individual voices? The answer involves both efficiency and artistic intent. With 64 voices potentially active, running a full reverb on each would be computationally absurd. Instead, voices sum into channel buffers, and each channel runs its own effects chain. Voices can send different amounts to shared reverb and delay buses. This architecture lets a single reverb serve the entire mix while giving each channel its own character through distortion and compression. See [Voice Architecture](../synthesis-engine/voice-architecture.md) for how voices allocate and route to channels.

The design extends beyond mere efficiency. A synthesizer that sounds good in isolation often sounds lifeless in a mix. Raw oscillator output lacks the harmonic complexity of acoustic instruments. It sits unnaturally in stereo space with no sense of environment. Dynamics feel mechanical rather than musical. The effects chain transforms clinical synthesis into something that breathes.

## Post-Voice Processing: The Channel Strip

Each V2 channel implements a complete effects chain that processes the summed output of all voices assigned to that channel. The signal flows through DC filtering, compression, bass boost, distortion, and chorus/flanger in a configurable order.

The channel structure captures this processing chain.

```cpp
struct V2Chan {
  V2DCFilter dcf1;    // Pre-effects DC removal
  V2Comp comp;        // Dynamics compression
  V2Boost boost;      // Bass enhancement EQ
  V2Dist dist;        // Distortion/saturation
  V2DCFilter dcf2;    // Post-distortion DC removal
  V2ModDel chorus;    // Chorus/flanger effect

  sInt fxr;           // Routing: dist->chorus or chorus->dist
};
```

V2 offers two routing options for distortion and chorus. Some sounds benefit from distorting the dry signal before adding modulation; others want the modulated signal to hit the distortion. The mastering engineer analogy holds here too: sometimes you want the warmth of tape saturation before the chorus unit, sometimes after.

## Distortion: Harmonic Enhancement

Distortion in audio processing means deliberately adding harmonic content that was not in the original signal. The mastering engineer might use a tube preamp driven hot to add subtle warmth, or an aggressive clipper to make drums punch through a dense mix. V2 offers four distinct distortion characters, each serving different sonic goals.

Overdrive applies a soft saturation curve using the arctangent function. As input levels rise, the output asymptotically approaches a maximum value, gently compressing peaks while adding odd harmonics. The gain staging matters: the engineer dials in input gain to hit the sweet spot where harmonics bloom without harsh clipping. Hard clipping takes a more aggressive approach, flattening anything above the threshold. Bitcrushing reduces the signal to fewer amplitude levels, creating the characteristic lo-fi sound. Decimation reduces sample rate rather than bit depth, holding the previous value until a counter wraps.

Each mode implements a distinct transfer function.

```cpp
// Soft saturation: smooth limiting via arctangent
inline sF32 overdrive(sF32 in) {
  return gain2 * fastatan(in * gain1 + offs);
}

// Hard clipping: flat ceiling on peaks
inline sF32 clip(sF32 in) {
  return gain2 * clamp(in * gain1 + offs, -1.0f, 1.0f);
}

// Bit reduction: quantize to fewer levels
inline sF32 bitcrusher(sF32 in) {
  sInt t = (sInt)(in * crush1);
  t = clamp(t * crush2, -0x7fff, 0x7fff) ^ crxor;
  return (sF32)t / 32768.0f;
}

// Sample rate reduction: hold-and-sample
inline void decimator_tick(sF32 l, sF32 r) {
  dcount += dfreq;
  if (dcount < dfreq) {  // Counter wrapped
    dvall = l;
    dvalr = r;
  }
}
```

## Modulated Delay: Chorus and Flanger

The chorus effect works by mixing a signal with a slightly delayed copy of itself, where the delay time continuously varies. This creates the impression of multiple sound sources playing slightly out of time, like a string section where each player's timing differs by milliseconds. The flanger effect uses shorter delays and more feedback, producing the characteristic "jet plane" sweep.

V2 implements both effects with a single modulated delay structure. The modulation source generates a triangle wave that sweeps the delay time up and down within a configurable range. This modulation approach parallels the LFO techniques covered in [Modulation](../synthesis-engine/modulation.md).

```cpp
inline sF32 processChanSample(sF32 in, sInt ch, sF32 dry) {
  // Triangle wave modulation
  sU32 counter = mcnt + (ch ? mphase : 0);
  counter = (counter < 0x80000000u) ? counter*2 : 0xffffffffu - counter*2;

  // Interpolated delay line read
  sU64 offs32_32 = (sU64)counter * mmaxoffs;
  sU32 offs_int = sU32(offs32_32 >> 32) + dboffs[ch];
  sU32 index = dbptr - offs_int;

  sF32 delayed = lerp(delaybuf[(index - 0) & dbufmask],
                      delaybuf[(index - 1) & dbufmask],
                      utof23((sU32)(offs32_32 & 0xffffffffu)));

  // Feedback and mix
  delaybuf[dbptr] = in + delayed * fbval;
  return in * dry + delayed * wetout;
}
```

The left and right channels use different phase offsets for the modulation oscillator, creating stereo width. A phase offset of 90 degrees puts the channels in quadrature, maximizing the sense of movement across the stereo field.

## Compressor: Dynamics Control

The compressor acts like a mastering engineer riding the faders in real time. When the signal exceeds a threshold, the compressor reduces the gain to keep peaks under control. When the signal drops, the compressor backs off and lets the full dynamics through. The attack and release times determine how quickly the engineer's virtual hand moves.

V2's compressor offers two level detection modes: peak and RMS. Peak detection responds to instantaneous signal peaks, catching transients immediately. RMS detection averages the signal power over time, responding more to the sustained energy of a sound. Peak mode acts like an engineer watching the meters carefully; RMS mode feels more natural, responding to perceived loudness.

The compression ratio determines how aggressively to reduce gain. With a 2:1 ratio, every 2dB the input exceeds threshold results in only 1dB of output excess. With infinite ratio (limiting), nothing gets through above threshold.

```cpp
void render(StereoSample *buf, sInt nsamples) {
  // Step 1: Level detection
  for (sInt i=0; i < nsamples; i++)
    levels[i].l = levels[i].r = invol * doPeak(0.5f * (buf[i].l + buf[i].r), 0);

  // Step 2: Gain reduction with attack/release smoothing
  for (sInt ch=0; ch < 2; ch++) {
    sF32 gain = curgain[ch];
    for (sInt i=0; i < nsamples; i++) {
      // Lookahead delay
      sF32 v = outvol * dbuf[dbind].ch[ch];
      dbuf[dbind].ch[ch] = invol * buf[i].ch[ch];

      // Calculate target gain
      sF32 dgain = 1.0f;
      sF32 lvl = levels[i].ch[ch];
      if (lvl >= 1.0f)
        dgain = 1.0f / (1.0f + ratio * (lvl - 1.0f));

      // Smooth toward target (attack for decrease, release for increase)
      gain += (dgain < gain ? attack : release) * (dgain - gain);
      buf[i].ch[ch] = v * gain;
    }
    curgain[ch] = gain;
  }
}
```

The lookahead delay buffer lets the compressor "see into the future." By delaying the audio while processing the level detection in real time, the gain reduction can begin before the transient actually arrives. This prevents the initial attack from punching through before the compressor can react.

## Reverb: Creating Virtual Spaces

Reverb places sound in a virtual acoustic environment. The mastering engineer might add just a touch of room ambience to glue a mix together, or drench a snare in a massive hall. V2 implements reverb using a classic Schroeder topology: parallel comb filters feeding into series allpass filters.

Each comb filter creates a set of regularly-spaced echoes that decay over time. Four comb filters with carefully chosen prime-length delays (1309, 1635, 1811, 1926 samples for the left channel) produce a dense, complex echo pattern that avoids obvious repetition. The delays differ slightly between channels to create stereo width.

The allpass filters diffuse the comb filter output, smearing the echoes in time and creating a smoother decay tail. A damping filter in the feedback path simulates how high frequencies decay faster in real rooms. This damping filter shares its topology with the voice-level filters discussed in [Filters](../synthesis-engine/filters.md).

```cpp
void render(StereoSample *dest, sInt nsamples) {
  for (sInt i=0; i < nsamples; i++) {
    sF32 in = inbuf[i] * gainin + fcdcoffset;

    for (sInt ch=0; ch < 2; ch++) {
      // Parallel comb filters with alternating phase
      sF32 cur = 0.0f;
      for (sInt j=0; j < 4; j++) {
        sF32 dv = gainc[j] * combd[ch][j].fetch();
        sF32 nv = (j & 1) ? (dv - in) : (dv + in);
        sF32 lp = combl[ch][j] + damp * (nv - combl[ch][j]);
        combd[ch][j].feed(lp);
        cur += lp;
      }

      // Series allpass filters for diffusion
      for (sInt j=0; j < 2; j++) {
        sF32 dv = alld[ch][j].fetch();
        sF32 dz = cur + gaina[j] * dv;
        alld[ch][j].feed(dz);
        cur = dv - gaina[j] * dz;
      }

      // Low cut filter prevents bass buildup
      hpf[ch] += lowcut * (cur - hpf[ch]);
      dest[i].ch[ch] += cur - hpf[ch];
    }
  }
}
```

The reverb operates on an aux bus rather than inline with channel processing. All channels can send to the same reverb, which processes once and adds to the final mix. This "send effect" architecture mirrors how hardware mixing consoles work.

## DC Filtering: Preventing Bias Accumulation

DC offset is an invisible problem that causes audible consequences. If a signal has a constant bias component, the waveform floats above or below the zero line. This wastes headroom, causes clicks at edit points, and accumulates through nonlinear effects like distortion.

V2 applies DC filtering multiple times throughout the signal chain: after voice distortion, after channel distortion, and on the final mix. The filter is a simple high-pass with an extremely low cutoff frequency, removing only the static component while leaving all audible frequencies untouched.

```cpp
struct V2DCF {
  sF32 xm1;  // Previous input
  sF32 ym1;  // Previous output

  sF32 step(sF32 in, sF32 R) {
    // y(n) = x(n) - x(n-1) + R*y(n-1)
    sF32 y = (fcdcoffset + R*ym1 - xm1 + in) - fcdcoffset;
    xm1 = in;
    ym1 = y;
    return y;
  }
};
```

The filter implements a first-order high-pass where the R coefficient determines the cutoff frequency. V2 sets this coefficient very close to 1.0, resulting in a cutoff well below 20Hz. The filter removes DC without affecting any audible content.

## Signal Flow Summary

The complete effects signal path follows this sequence:

1. **Voice output** sums into channel buffer
2. **DC filter 1** removes voice-level bias
3. **Compressor** controls dynamics
4. **Bass boost** enhances low frequencies
5. **Distortion/Chorus** (order configurable)
6. **DC filter 2** removes distortion-induced bias
7. **Aux sends** route to reverb and delay buses
8. **Channel sum** accumulates into main mix
9. **Global reverb** processes aux1 bus
10. **Global delay** processes aux2 bus
11. **Master EQ** applies high and low cuts
12. **Master compressor** controls final dynamics

Each stage serves a specific purpose in the mastering engineer's toolkit. The chain transforms raw synthesis output into polished, professional audio that sits properly in a mix. V2 demonstrates that even a size-constrained demoscene synth can implement studio-grade effects processing.

## Related Documents

- [Voice Architecture](../synthesis-engine/voice-architecture.md) - How voices allocate and route to channels before effects processing
- [Oscillators](../synthesis-engine/oscillators.md) - The raw waveform sources that effects ultimately shape
- [Filters](../synthesis-engine/filters.md) - Filter topologies shared with reverb damping and DC removal
- [Modulation](../synthesis-engine/modulation.md) - LFO techniques paralleled in chorus/flanger modulation
- [Audio I/O](../integration/audio-io.md) - Where the processed signal exits to the audio hardware
- [Architecture](../architecture.md) - Overall V2 system structure and component relationships
