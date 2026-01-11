# Audio I/O: The DirectSound Streaming Layer

Audio hardware operates under an unforgiving constraint that shapes every design decision in real-time sound systems. Speakers expect a continuous stream of samples at precisely 44,100 per second. Miss a deadline, and you hear it immediately as a click, pop, or silence. The audio thread cannot pause to wait for your synthesizer to think harder about a difficult passage.

Think of a factory assembly line that produces audio samples. The line runs continuously at a fixed speed, and boxes move along a conveyor belt whether workers have filled them or not. If a worker station falls behind, empty boxes reach the end of the line and the customer hears silence. The V2 synthesizer's DirectSound layer orchestrates this production line, ensuring samples reach the speakers without interruption regardless of what else the CPU might be doing.

The challenge grows more complex when you consider that the main thread wants to interact with the synthesizer. MIDI events arrive, parameters change, the demo engine requests synchronization data. These interactions must occur without disrupting the relentless march of samples toward the audio hardware. The solution involves careful choreography between threads, with a circular buffer serving as the intermediary that absorbs timing variations.

For the broader architectural context of how this I/O layer fits into V2's three-tier design, see the [V2 Architecture](../architecture.md) document.

## The Assembly Line Architecture

The factory analogy maps directly to the V2 audio architecture. A dedicated audio thread acts as the assembly line itself, running in an endless loop that fills sample buffers. The DirectSound circular buffer serves as the conveyor belt, a ring of memory that loops around so the hardware can continuously consume samples while the software continuously produces them. Frame rendering happens at worker stations along the line, where the synthesizer produces batches of samples. Critical sections act as traffic lights at intersections, preventing collisions when multiple threads need to access shared state.

Latency in this system measures the distance between production and delivery. Samples sit in the circular buffer for some time before reaching the speakers. A larger buffer provides more margin for the worker stations to catch up if they fall behind, but increases the delay between a note trigger and when you hear it. A smaller buffer reduces latency but demands that rendering never misses its deadline.

## Callback-Based Rendering

The DirectSound layer uses a callback pattern to decouple audio production from the I/O machinery. When initializing the system, the caller provides a function pointer that the audio thread will invoke whenever it needs more samples. This callback receives a buffer to fill and a sample count to produce.

The callback signature tells the whole story of this contract:

```c
typedef void (__stdcall DSIOCALLBACK)(void *parm, sF32 *buf, sU32 len);
```

The `parm` parameter carries user data, typically a pointer to the synthesizer instance. The `buf` parameter points to a mixing buffer where the callback should write interleaved stereo samples as 32-bit floats. The `len` parameter specifies how many stereo sample pairs the thread needs. Note that samples arrive as floats but DirectSound expects 16-bit integers, so the layer handles conversion and clamping internally.

The callback model keeps the audio thread simple: it manages the DirectSound buffer, calculates how many samples the hardware consumed, calls your function to fill the gap, then copies the result into the ring buffer. Your synthesizer code never touches DirectSound directly.

## The Circular Buffer Dance

DirectSound provides a circular buffer that the hardware reads from continuously. Picture the conveyor belt as a loop of memory that wraps around on itself. The hardware maintains a "play cursor" indicating where it is currently reading. Software maintains a "write cursor" tracking where it last wrote samples. The gap between these cursors represents the latency.

The audio thread's primary job involves calculating how much the play cursor advanced since the last check, then filling that many new samples:

```c
// Inside the audio thread loop
DWORD curpos;
g_dsound.sbuf->GetCurrentPosition(&curpos, 0);

// Calculate how many bytes to write
curpos &= ~31u;  // Align to 32-byte boundary
sInt nwrite = curpos - g_dsound.lastpos;
if (nwrite < 0)
    nwrite += BUFFERLEN;  // Handle wraparound
```

The modular arithmetic handles the circular nature of the buffer. When the play cursor wraps from the end back to the start, the subtraction goes negative, so adding the buffer length gives the correct positive distance. The 32-byte alignment ensures samples stay aligned to hardware expectations and prevents partial writes from causing glitches.

## Buffer Locking Protocol

DirectSound does not allow direct writes to the sound buffer. The thread must lock a region, receive pointers to the underlying memory, write samples, then unlock. Because the buffer is circular, a single logical region might map to two physical regions when it spans the wraparound point.

The lock operation returns up to two pointer-length pairs. If the region fits entirely before the buffer wraps, only the first pair contains data. If it spans the boundary, both pairs contain portions of the requested region:

```c
void *buf1, *buf2;
DWORD len1, len2;

HRESULT hr = g_dsound.sbuf->Lock(
    g_dsound.lastpos,  // Start position
    nwrite,            // Bytes to lock
    &buf1, &len1,      // First region
    &buf2, &len2,      // Second region (if wrapping)
    0                  // Flags
);

// Render to float mixing buffer
g_dsound.callback(g_dsound.cbparm, g_dsound.mixbuffer, nwrite / 4);

// Convert and copy to each region
if (buf1)
    clamp(buf1, g_dsound.mixbuffer, len1/2);
if (buf2)
    clamp(buf2, g_dsound.mixbuffer + len1/2, len2/2);

g_dsound.sbuf->Unlock(buf1, len1, buf2, len2);
```

The callback writes to an intermediate float buffer, then the clamp function converts to 16-bit integers with saturation. This separation keeps the synthesizer working in its natural floating-point domain while meeting DirectSound's integer format requirements. The division by 4 in the callback argument converts byte counts to stereo sample pair counts (2 channels times 2 bytes per sample).

## Thread Synchronization

The assembly line analogy extends to thread coordination. Other threads want to interact with the synthesizer: the main thread might send MIDI events or query the current playback position. Without synchronization, these threads could corrupt shared state by reading and writing simultaneously.

V2 uses Windows critical sections as traffic lights at the intersection where threads meet. A thread entering the critical section blocks all others until it leaves. The audio thread holds the critical section while rendering, preventing the main thread from modifying synthesizer state mid-frame:

```c
void __stdcall dsLock()
{
    EnterCriticalSection(&g_dsound.crsec);
}

void __stdcall dsUnlock()
{
    LeaveCriticalSection(&g_dsound.crsec);
}
```

The main thread calls `dsLock` before sending MIDI or reading synchronization data, then `dsUnlock` when finished. This creates a window where the main thread has exclusive access. The audio thread similarly wraps its entire render-and-copy sequence in the critical section, ensuring atomic updates to buffer positions and sample counts.

The tradeoff with this approach: if the main thread holds the lock too long, the audio thread stalls waiting for access, potentially causing underruns. Keep locked regions as brief as possible.

This threading model connects directly to the broader V2 architecture. The [architecture document](../architecture.md#threading-the-live-session) discusses how the core synthesis engine assumes single-threaded access during rendering, with this DirectSound layer providing the necessary synchronization when multiple threads are involved.

## Sample Position Tracking

Demo synchronization requires knowing exactly which sample the speakers are currently playing. The demo engine needs to match visuals to the beat, trigger effects on specific notes, or synchronize multiple media streams. The `dsGetCurSmp` function provides this information.

The implementation queries the DirectSound play cursor and converts it to a cumulative sample count. The circular buffer complicates this because the play cursor position alone does not indicate how many times the buffer has wrapped around. The code maintains running totals to reconstruct absolute position:

```c
sS32 __stdcall dsGetCurSmp()
{
    DWORD gppos;

    EnterCriticalSection(&g_dsound.crsec);
    g_dsound.sbuf->GetCurrentPosition(&gppos, 0);

    sInt ndiff = gppos - g_dsound.lastpos;
    if (ndiff < 0)
        ndiff += BUFFERLEN;

    // Sanity check: reject implausible jumps
    if (ndiff < BUFFERLEN/4)
        g_dsound.ltg = g_dsound.bufcnt + ndiff;

    LeaveCriticalSection(&g_dsound.crsec);
    return g_dsound.ltg;
}
```

The `bufcnt` field accumulates total bytes written to the buffer. Adding the current cursor offset relative to the last write position gives the absolute playback position. The sanity check (`ndiff < BUFFERLEN/4`) guards against spurious cursor values that occasionally occur during buffer restoration. If the reported position seems too far ahead, the function returns the last known good value rather than jumping erratically.

## Latency Trade-offs

The buffer length constant `BUFFERLEN` (0x10000 bytes, or 64KB) directly controls latency. At 44,100 Hz stereo 16-bit, this provides about 370 milliseconds of buffering. The audio thread wakes periodically and fills however much the hardware consumed since the last check.

Larger buffers provide more safety margin. If the system gets busy and the audio thread does not run for a while, a large buffer ensures samples remain available. The cost is increased latency between triggering a note and hearing it, which matters for interactive applications but less so for pre-sequenced demo playback.

V2 addresses this by setting the audio thread to `THREAD_PRIORITY_ABOVE_NORMAL`. Elevated priority ensures the audio thread gets CPU time even when other threads are busy. This allows smaller buffers without risking underruns, reducing latency at the cost of less predictable scheduling for other work.

## Buffer Lost Recovery

DirectSound buffers can be "lost" when another application takes exclusive access to the audio hardware or the system enters a power-saving state. The audio thread must detect this condition and restore the buffer before continuing.

The thread checks for `DSERR_BUFFERLOST` on both `GetCurrentPosition` and `Lock` calls. Upon detecting loss, it calls `Restore` and retries the operation. This loop continues until either the operation succeeds or a different error occurs:

```c
for (;;)
{
    HRESULT hr = g_dsound.sbuf->GetCurrentPosition(&curpos, 0);
    // ... calculate nwrite ...

    hr = g_dsound.sbuf->Lock(g_dsound.lastpos, nwrite, &buf1, &len1, &buf2, &len2, 0);

    if (hr == S_OK)
        break;
    else if (hr == DSERR_BUFFERLOST)
        g_dsound.sbuf->Restore();  // Try again
    else
        goto done;  // Unrecoverable error
}
```

The recovery mechanism ensures the demo continues playing even when external events disrupt audio. Users might alt-tab to another application, or the system might briefly suspend audio for a notification sound. Without recovery, such events would kill playback permanently.

## Rust Considerations

Modern Rust audio typically uses CPAL (Cross-Platform Audio Library) rather than DirectSound directly. CPAL provides the same callback model, invoking your function when the hardware needs samples:

```rust
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

let host = cpal::default_host();
let device = host.default_output_device().unwrap();
let config = device.default_output_config().unwrap();

let stream = device.build_output_stream(
    &config.into(),
    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
        // Fill the buffer with samples - this is your "callback"
        for sample in data.iter_mut() {
            *sample = synthesizer.next_sample();
        }
    },
    |err| eprintln!("Stream error: {}", err),
    None,
).unwrap();

stream.play().unwrap();
```

The synchronization concerns translate directly, though the platform abstraction handles buffer management internally.

The critical section pattern maps to Rust's `Mutex` or `RwLock`. A more idiomatic approach uses lock-free ring buffers for communication between threads, avoiding the blocking that critical sections impose. The [`ringbuf`](https://docs.rs/ringbuf) crate provides a suitable single-producer, single-consumer implementation.

Sample position tracking could use atomic integers rather than mutex-protected counters. The audio callback increments the position atomically, and the main thread reads it without locking. This eliminates the risk of audio thread stalls from main thread lock contention:

```rust
use std::sync::atomic::{AtomicU64, Ordering};

struct AudioPosition {
    samples_rendered: AtomicU64,
}

impl AudioPosition {
    fn advance(&self, count: u64) {
        self.samples_rendered.fetch_add(count, Ordering::Release);
    }

    fn current(&self) -> u64 {
        self.samples_rendered.load(Ordering::Acquire)
    }
}
```

The circular buffer concept remains essential in any real-time audio system. The assembly line runs whether or not you have samples ready, so you must buffer enough to absorb variations in rendering time. Understanding this fundamental constraint helps you design systems that deliver glitch-free playback across platforms.

---

**See also:**
- [V2 Architecture](../architecture.md) - Three-tier system overview and threading model
- [Voice Architecture](../synthesis-engine/voice-architecture.md) - How voices generate the samples this layer delivers
- [Note to Sound Trace](../code-traces/note-to-sound.md) - Complete signal flow from MIDI to audio output
- [V2 Overview](../README.md) - Introduction and key insights
