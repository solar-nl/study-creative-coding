# Immediate vs Queued GPU Resource Deletion

When should a GPU resource actually be destroyed? The moment user code requests it,
at the end of the current frame, or only after multiple frames have passed? Each
approach carries distinct tradeoffs in safety, complexity, and memory pressure.

---

## The Core Tension

GPU command execution is fundamentally asynchronous. When user code calls `draw()`,
the GPU doesn't execute immediately—commands are recorded into a command buffer,
submitted to a queue, and executed at some indeterminate future time. This creates
a dangerous window:

```
CPU Timeline:  [record draw] [delete texture] [continue...]
GPU Timeline:  .............. [executing draw - TEXTURE GONE!]
```

If the CPU deletes a resource while the GPU is still using it, the result is
undefined behavior: visual corruption, driver crashes, or silent data races.
The fundamental question every framework must answer: **how long must we wait
before deletion is safe?**

Three distinct patterns emerge across the frameworks studied:
1. **Immediate deletion** with guards against known-dangerous states
2. **Frame-end deferred** deletion after current frame completes
3. **Multi-frame delay** ensuring all in-flight frames have finished

---

## Pattern A: Immediate Deletion (cables.gl)

### Context

cables.gl operates in WebGL within a visual programming environment. Patches can
be rewired at any moment, operators connected and disconnected rapidly during
live editing. Memory pressure in browsers is significant—holding onto unused
textures degrades performance quickly.

### How It Works

Resources are deleted immediately upon request, but with explicit guards against
known-dangerous states:

```javascript
export class Texture extends CgTexture {
    constructor(__cgl, options = {}) {
        this.tex = this._cgl.gl.createTexture();
        this.deleted = false;
    }

    delete() {
        if (this.loading) {
            return;  // Guard against deleting while async loading
        }

        this.deleted = true;
        this.width = 0;
        this.height = 0;
        this._cgl.profileData.profileTextureDelete++;
        this._cgl.gl.deleteTexture(this.tex);
        this.image = null;
        this.tex = null;
    }
}
```

The `deleted` flag serves as a tombstone, allowing subsequent code to detect
use-after-free attempts:

```javascript
export class Framebuffer2 {
    _disposed = false;

    dispose() {
        this._disposed = true;
        // ... delete all attachments
        this._cgl.gl.deleteFramebuffer(this._frameBuffer);
    }

    renderStart() {
        if (this._disposed) {
            return this._log.warn("disposed framebuffer renderStart...");
        }
    }
}
```

### When It Excels

- **Interactive editing**: Patches change rapidly; immediate cleanup prevents
  resource accumulation during experimentation
- **Memory-constrained environments**: Browsers enforce strict limits; holding
  resources "just in case" isn't viable
- **Single-threaded execution**: WebGL's synchronous API means the GPU queue
  is typically drained before JavaScript regains control
- **Explicit ownership**: Visual programming makes resource lifetimes visible
  in the graph structure itself

The tradeoff: relies on WebGL's implicit synchronization and careful guard
placement. Works because the browser's event loop naturally creates sync points.

---

## Pattern B: Frame-End Deferred (Babylon.js)

### Context

Babylon.js targets production applications with WebGPU, where command buffers
are explicitly submitted and GPU execution is truly asynchronous. The engine
must handle complex scenes with shared resources, dynamic loading, and
reference-counted materials.

### How It Works

Deletion requests are collected throughout the frame, then processed in batch
after the frame's command buffer has been submitted:

```typescript
export class WebGPUBufferManager {
    private _deferredReleaseBuffers: Array<GPUBuffer> = [];

    public releaseBuffer(buffer: DataBuffer | GPUBuffer): boolean {
        if (WebGPUBufferManager._IsGPUBuffer(buffer)) {
            this._deferredReleaseBuffers.push(buffer);
            return true;
        }

        buffer.references--;
        if (buffer.references === 0) {
            this._deferredReleaseBuffers.push(buffer.underlyingResource);
            return true;
        }
        return false;
    }

    // Called at frame end
    public destroyDeferredBuffers(): void {
        for (let i = 0; i < this._deferredReleaseBuffers.length; ++i) {
            this._deferredReleaseBuffers[i].destroy();
        }
        this._deferredReleaseBuffers.length = 0;
    }
}
```

The pattern combines two mechanisms:
1. **Reference counting** prevents deletion while multiple systems hold handles
2. **Deferred batching** ensures deletion happens after frame submission

### When It Excels

- **Shared resources**: Materials, textures, and buffers referenced by multiple
  meshes need reference tracking before deletion is safe
- **WebGPU's explicit model**: Command buffers are submitted explicitly; frame
  boundaries provide natural synchronization points
- **Batched operations**: Collecting deletions reduces API call overhead
- **Predictable timing**: All cleanup happens at a known point in the frame loop

The tradeoff: resources live one frame longer than strictly necessary. Memory
pressure can build during frames with heavy churn. Works well because WebGPU
provides implicit synchronization when the next frame begins.

---

## Pattern C: Multi-Frame Delay (rend3)

### Context

rend3 is a Rust rendering framework for games, where multiple frames may be
in-flight simultaneously. Triple buffering means frame N might still be
executing on the GPU while frame N+2 is being recorded on the CPU. Deletion
must wait until all potentially-using frames have completed.

### How It Works

Resource operations are expressed as instructions queued for later processing:

```rust
pub enum InstructionKind {
    DeleteMesh { handle },
    DeleteTexture { handle },
    // ...
}

// User code queues deletion
fn delete_mesh(handle: MeshHandle) {
    instructions.push(InstructionKind::DeleteMesh { handle });
}

// Processed between frames, after GPU confirms completion
fn process_instructions(&mut self) {
    for instruction in self.instructions.drain(..) {
        match instruction {
            DeleteMesh { handle } => {
                self.mesh_manager.remove(handle);
            }
        }
    }
}
```

The instruction queue pattern decouples the deletion request from execution:

1. User code issues deletion intent during frame N
2. Frame N completes recording and submits
3. System waits for frame N-2 (or earlier) to finish on GPU
4. Only then are queued deletions processed

This typically means a 2-3 frame delay between requesting deletion and
actual resource destruction.

### When It Excels

- **Multi-buffered rendering**: When 2-3 frames are in-flight simultaneously,
  single-frame deferral isn't sufficient
- **GPU timeline uncertainty**: Without explicit fence queries, assuming
  "previous frame finished" is unsafe
- **Rust's ownership model**: Instruction queues integrate naturally with
  Rust's move semantics—handles are consumed on queue insertion
- **Deterministic cleanup**: Processing happens at explicit sync points,
  making debugging and profiling tractable

The tradeoff: memory lingers for multiple frames. Fast resource churn can
cause significant memory growth. Works because game engines control the
frame loop and can insert explicit synchronization.

---

## Side-by-Side Comparison

| Aspect | cables.gl | Babylon.js | rend3 |
|--------|-----------|------------|-------|
| **Deletion Timing** | Immediate | Frame-end | Multi-frame |
| **Safety Mechanism** | State guards | Reference counting + defer | Instruction queue |
| **Memory Overhead** | Minimal | One frame | 2-3 frames |
| **Complexity** | Low | Medium | Higher |
| **Threading Model** | Single-threaded | Single-threaded | Multi-threaded safe |
| **Best For** | Interactive editing | Production apps | Game engines |
| **Risk Profile** | Use-after-free possible | Safe within frame | Fully synchronized |
| **GPU API** | WebGL | WebGPU | wgpu/Vulkan |

---

## Combining the Patterns

Real-world frameworks often combine these approaches in a tiered strategy:

### Tiered Deletion Strategy

```rust
pub struct ResourceManager {
    // Tier 1: Immediate deletion for CPU-only resources
    cpu_metadata: HashMap<Handle, Metadata>,

    // Tier 2: Frame-end deletion for non-shared GPU resources
    frame_pending_deletes: Vec<GpuResourceHandle>,

    // Tier 3: Multi-frame delay for shared/in-flight resources
    delayed_deletes: VecDeque<(FrameNumber, GpuResourceHandle)>,

    current_frame: FrameNumber,
    frames_in_flight: u32,  // Typically 2-3
}

impl ResourceManager {
    pub fn delete(&mut self, handle: Handle, resource_type: ResourceType) {
        // Always immediate: CPU metadata
        self.cpu_metadata.remove(&handle);

        match resource_type {
            // Tier 1: CPU-only, delete now
            ResourceType::CpuOnly => { /* already done above */ }

            // Tier 2: GPU resource, single user, defer to frame end
            ResourceType::GpuExclusive => {
                self.frame_pending_deletes.push(handle.gpu_handle());
            }

            // Tier 3: Shared or in command buffer, multi-frame delay
            ResourceType::GpuShared | ResourceType::InFlight => {
                let delete_at = self.current_frame + self.frames_in_flight;
                self.delayed_deletes.push_back((delete_at, handle.gpu_handle()));
            }
        }
    }

    pub fn end_frame(&mut self) {
        // Process Tier 2: frame-end deletions
        for handle in self.frame_pending_deletes.drain(..) {
            self.destroy_gpu_resource(handle);
        }

        // Process Tier 3: deletions that have waited long enough
        while let Some((frame, handle)) = self.delayed_deletes.front() {
            if *frame <= self.current_frame {
                let (_, handle) = self.delayed_deletes.pop_front().unwrap();
                self.destroy_gpu_resource(handle);
            } else {
                break;
            }
        }

        self.current_frame += 1;
    }
}
```

This tiered approach applies the minimum necessary delay for each resource type,
balancing safety against memory pressure.

---

## Implications for the GPU Resource Pool

### Recommendation 1: Leverage wgpu's Internal Deferral

wgpu already handles deferred cleanup internally. When `drop()` is called on a
wgpu resource, the actual GPU deletion is deferred until safe:

```rust
// This is safe in wgpu - deletion is internally deferred
let texture = device.create_texture(&desc);
// ... use texture in command buffer ...
drop(texture);  // wgpu tracks reference, defers actual deletion
```

For a Rust framework, this means immediate `drop()` semantics can be exposed
to users while wgpu handles the complexity underneath.

### Recommendation 2: Add Application-Level Tracking When Needed

wgpu's deferral handles GPU safety, but application-level concerns may require
additional tracking:

```rust
pub struct TextureHandle {
    inner: Arc<wgpu::Texture>,
    // Application metadata that should outlive GPU resource
    debug_name: String,
    created_frame: u64,
}

impl Drop for TextureHandle {
    fn drop(&mut self) {
        // Log for debugging
        log::trace!("Releasing texture '{}' created at frame {}",
                    self.debug_name, self.created_frame);
        // wgpu::Texture's drop handles actual GPU cleanup
    }
}
```

### Recommendation 3: Explicit Pools for High-Churn Resources

For resources created and destroyed frequently (particle system buffers,
transient render targets), pooling avoids the deletion question entirely:

```rust
pub struct TransientBufferPool {
    available: Vec<wgpu::Buffer>,
    in_use: HashMap<BufferHandle, wgpu::Buffer>,
    frame_returns: Vec<BufferHandle>,  // Return at frame end
}

impl TransientBufferPool {
    pub fn acquire(&mut self, size: u64) -> BufferHandle {
        let buffer = self.available.pop()
            .unwrap_or_else(|| self.create_buffer(size));
        let handle = BufferHandle::new();
        self.in_use.insert(handle, buffer);
        handle
    }

    pub fn release(&mut self, handle: BufferHandle) {
        // Don't delete - mark for return to pool at frame end
        self.frame_returns.push(handle);
    }

    pub fn end_frame(&mut self) {
        for handle in self.frame_returns.drain(..) {
            if let Some(buffer) = self.in_use.remove(&handle) {
                self.available.push(buffer);
            }
        }
    }
}
```

### Recommendation 4: Document the Contract

Whatever strategy is chosen, document the deletion timing explicitly:

```rust
/// GPU resource handle with deferred deletion semantics.
///
/// # Deletion Timing
///
/// When dropped, the underlying GPU resource is not immediately destroyed.
/// Actual deletion occurs after all in-flight frames that may reference
/// this resource have completed (typically 2-3 frames).
///
/// For immediate cleanup (e.g., at application shutdown), use
/// `device.poll(wgpu::Maintain::Wait)` to flush the GPU queue.
pub struct ManagedTexture { ... }
```

---

## Conclusion

The three patterns represent points on a spectrum trading memory overhead
against safety guarantees:

- **Immediate** (cables.gl): Minimal overhead, relies on implicit sync points
- **Frame-end** (Babylon.js): One-frame delay, handles async submission safely
- **Multi-frame** (rend3): Maximum safety for multi-buffered rendering

For a wgpu-based Rust framework, the recommendation is to embrace Rust's
`Drop` trait with wgpu's internal deferral handling the GPU timing concerns,
while adding application-level pooling for high-churn resources and clear
documentation of the deletion contract.

---

## Related Documents

- [Resource Pooling Strategies](./resource-pooling.md)
- [Buffer Management Patterns](./buffer-management.md)
- [wgpu Resource Lifecycle](../../per-library/wgpu/resource-lifecycle.md)
- [Frame Synchronization](../synchronization/frame-pacing.md)
