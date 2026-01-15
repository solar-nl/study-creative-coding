# wgpu: GPU Resource Management Patterns

> The foundation - how wgpu handles buffers, textures, and command encoding

---

## Overview

wgpu provides the low-level GPU abstraction that higher-level frameworks build upon. Understanding its resource management patterns is essential for designing Flux's resource pool, because any abstraction we build must work within wgpu's ownership and lifetime model.

The key insight from studying wgpu: **resources are reference-counted handles with interior mutability managed through runtime state tracking**. This differs from OpenGL's integer IDs and from Vulkan's explicit lifetime management.

---

## Handle Design: Arc-Wrapped Dispatch

### The Pattern

Every GPU resource in wgpu follows the same structural pattern. A `Buffer` is not the GPU buffer itself - it's a handle containing metadata and a reference to the actual backend resource:

```rust
// From wgpu/src/api/buffer.rs:220-227
pub struct Buffer {
    pub(crate) inner: dispatch::DispatchBuffer,
    pub(crate) map_context: Arc<Mutex<MapContext>>,
    pub(crate) size: wgt::BufferAddress,
    pub(crate) usage: BufferUsages,
}
```

The `inner` field holds the actual backend connection through a dispatch enum that supports multiple backends (Vulkan, Metal, DX12, WebGPU). The outer struct stores convenience metadata (`size`, `usage`) that would otherwise require a backend call to retrieve.

### Why Arc-Wrapped?

Both `Buffer` and `Device` derive `Clone`. Cloning produces another handle to the same underlying resource:

```rust
// From wgpu/src/api/device.rs:19-22
#[derive(Debug, Clone)]
pub struct Device {
    pub(crate) inner: dispatch::DispatchDevice,
}
```

This enables patterns where multiple parts of the application hold handles to the same buffer. The underlying resource lives until all handles are dropped.

### Flux Implications

For Flux's resource pool, this suggests:
- **Handles should be cheap to clone** - `Arc<T>` rather than `T`
- **Metadata should be cached** - avoid backend calls for common queries
- **Dropping a handle doesn't necessarily free the resource** - reference counting handles shared ownership

---

## Buffer Mapping: The MapContext Pattern

### The Problem

Buffer mapping creates a CPU-accessible view of GPU memory. But multiple simultaneous mappings of overlapping regions would cause data races. wgpu solves this with `MapContext` - a runtime tracking system:

```rust
// From wgpu/src/api/buffer.rs:744-758
pub(crate) struct MapContext {
    /// The range of the buffer that is mapped (0..0 if not mapped)
    mapped_range: Range<BufferAddress>,

    /// Ranges covered by outstanding BufferView/BufferViewMut
    /// These are non-overlapping, contained within mapped_range
    sub_ranges: Vec<Subrange>,
}
```

### How It Works

1. **Map Request**: When you call `map_async()`, the `mapped_range` is set
2. **View Creation**: When you call `get_mapped_range()`, a new `Subrange` is added
3. **Overlap Check**: `validate_and_add()` ensures no overlapping views exist
4. **View Drop**: Dropping `BufferView` removes the `Subrange`
5. **Unmap**: `unmap()` clears `mapped_range` and panics if views remain

```rust
// From wgpu/src/api/buffer.rs:566-579
pub fn map_async(
    &self,
    mode: MapMode,
    callback: impl FnOnce(Result<(), BufferAsyncError>) + WasmNotSend + 'static,
) {
    let mut mc = self.buffer.map_context.lock();
    assert_eq!(mc.mapped_range, 0..0, "Buffer is already mapped");
    let end = self.offset + self.size.get();
    mc.mapped_range = self.offset..end;

    self.buffer
        .inner
        .map_async(mode, self.offset..end, Box::new(callback));
}
```

### The Async Dance

Buffer mapping is inherently asynchronous - the GPU might still be using the buffer. wgpu handles this through callbacks:

```rust
// Usage pattern from buffer.rs documentation
let capturable = buffer.clone();  // Clone for the callback
buffer.map_async(wgpu::MapMode::Write, .., move |result| {
    if result.is_ok() {
        let mut view = capturable.get_mapped_range_mut(..);
        // ... write to view ...
        drop(view);
        capturable.unmap();
    }
});
// Later: device.poll() to drive the callback
```

### Flux Implications

For Flux's buffer management:
- **Track mapped regions** - can't submit commands while mapped
- **Handle async completion** - mapping isn't instant
- **Consider staging buffers** - `Queue::write_buffer()` uses internal staging

---

## Resource Creation: Device Factory Methods

### The Pattern

All resources are created through the `Device`:

```rust
// From wgpu/src/api/device.rs:270-283
pub fn create_buffer(&self, desc: &BufferDescriptor<'_>) -> Buffer {
    let map_context = MapContext::new(desc.mapped_at_creation.then_some(0..desc.size));
    let buffer = self.inner.create_buffer(desc);

    Buffer {
        inner: buffer,
        map_context: Arc::new(Mutex::new(map_context)),
        size: desc.size,
        usage: desc.usage,
    }
}

pub fn create_texture(&self, desc: &TextureDescriptor<'_>) -> Texture {
    let texture = self.inner.create_texture(desc);
    Texture {
        inner: texture,
        descriptor: TextureDescriptor {
            label: None,
            view_formats: &[],
            ..desc.clone()
        },
    }
}
```

### Notable Details

1. **No allocator parameter** - wgpu manages memory internally
2. **Descriptors are borrowed** - no ownership transfer
3. **Immediate return** - creation is synchronous (unlike mapping)
4. **Metadata stored** - `Texture` stores a clone of its descriptor

### Flux Implications

Flux should consider:
- **Descriptor caching** - store descriptors alongside resources for introspection
- **Creation batching** - wgpu creates one at a time, but we could pool
- **Error handling** - wgpu panics on OOM; consider pre-validation

---

## Command Encoding: Deferred Execution

### The Pattern

Commands aren't executed immediately. They're recorded into a `CommandEncoder`, then batched into a `CommandBuffer` for submission:

```rust
// From wgpu/src/api/device.rs:200-210
pub fn create_command_encoder(&self, desc: &CommandEncoderDescriptor<'_>) -> CommandEncoder {
    let encoder = self.inner.create_command_encoder(desc);
    CommandEncoder {
        inner: encoder,
        actions: Default::default(),  // Deferred actions travel with the buffer
    }
}
```

The `actions` field is interesting - it allows wgpu to defer certain operations until the command buffer is submitted. This is the hook point for things like "map this buffer after these commands complete."

### Recording and Submission

```rust
// Typical usage pattern
let mut encoder = device.create_command_encoder(&Default::default());
{
    let mut pass = encoder.begin_render_pass(&render_pass_descriptor);
    pass.set_pipeline(&pipeline);
    pass.draw(0..3, 0..1);
}
queue.submit(Some(encoder.finish()));
```

### Flux Implications

For Flux's command batching:
- **Encoders are single-use** - finish() consumes the encoder
- **Multiple encoders** - can record in parallel, submit together
- **Deferred actions** - can schedule post-submission work

---

## Data Transfer Patterns

### The Options

wgpu provides multiple ways to get data into buffers, each with different tradeoffs:

| Method | Use Case | Characteristics |
|--------|----------|-----------------|
| `mapped_at_creation` | Initial data | Sync, direct write, unmap before use |
| `Queue::write_buffer()` | Dynamic updates | Async-ish, staging buffer, immediate |
| `map_async()` | Readback or controlled writes | Truly async, callback-based |
| `StagingBelt` | Many small updates | Pooled staging, manual management |
| Manual staging | Maximum control | Full ownership of staging buffers |

### Queue::write_buffer

The simplest pattern for dynamic data:

```rust
// From buffer.rs documentation comments
queue.write_buffer(&buffer, offset, &data);
```

Internally, this uses a staging buffer managed by wgpu. The data is copied to staging, then a copy command is recorded. The staging buffer is reused or freed later.

### StagingBelt

For many small uploads per frame:

```rust
// Usage pattern
let mut belt = StagingBelt::new(chunk_size);

// Each frame:
let mut encoder = device.create_command_encoder(&Default::default());
belt.write_buffer(&mut encoder, &target_buffer, offset, size, &device)
    .copy_from_slice(&data);
belt.finish();
queue.submit(Some(encoder.finish()));
belt.recall();  // Reclaim completed staging buffers
```

### Flux Implications

For Flux's buffer updates:
- **Prefer `Queue::write_buffer`** for simplicity unless profiling shows issues
- **Consider StagingBelt** for particle systems with many small updates
- **Avoid mapping** for per-frame data unless you need readback

---

## Thread Safety

### The Model

wgpu resources are `Send + Sync` (enforced by `static_assertions`):

```rust
// From wgpu/src/api/device.rs:23-24
#[cfg(send_sync)]
static_assertions::assert_impl_all!(Device: Send, Sync);
```

This means you can:
- Create resources on one thread, use on another
- Share handles across threads (they're `Arc`-based internally)
- Record commands in parallel (multiple encoders)

### What You Can't Do

- Map the same buffer region simultaneously from multiple threads
- Submit to the same queue from multiple threads without synchronization
- Use resources after the device is dropped

### Flux Implications

For Flux's threading model:
- **Safe to parallelize command recording** - each thread gets its own encoder
- **Queue submission needs coordination** - or use a dedicated submission thread
- **Resource creation can be threaded** - but all go through the same device

---

## Resource Cleanup

### Drop-Based

Resources are cleaned up when all handles are dropped:

```rust
// Implicit cleanup
{
    let buffer = device.create_buffer(&desc);
    // ... use buffer ...
}  // Buffer dropped here, GPU resource will be freed
```

### Explicit Destroy

For immediate cleanup (useful when you know you're done):

```rust
buffer.destroy();  // Marks for immediate destruction
```

### Deferred Cleanup

wgpu internally defers actual GPU memory reclamation until it's safe (no in-flight commands reference the resource). This happens during `device.poll()`.

### Flux Implications

For Flux's resource pool:
- **Reference counting is handled** - wgpu does this internally
- **Explicit destroy** - call when reusing pool slots
- **Poll regularly** - ensures timely cleanup

---

## Summary: Key Patterns for Flux

| Pattern | wgpu Approach | Flux Application |
|---------|---------------|------------------|
| **Handle design** | Arc-wrapped dispatch | Use `Arc<T>` for pool handles |
| **Metadata** | Stored alongside handle | Cache descriptors in pool entries |
| **Mapping** | MapContext tracks state | Track mapped regions, integrate with dirty flags |
| **Creation** | Device factory methods | Pool manages creation, expose simple API |
| **Commands** | Encoder → Buffer → Submit | Batch recording, single submission |
| **Data transfer** | Multiple options | Default to `Queue::write_buffer` |
| **Threading** | Send + Sync | Safe to parallelize recording |
| **Cleanup** | Drop-based + deferred | Rely on wgpu, call destroy for pool reuse |

---

## Source Files

| File | Purpose |
|------|---------|
| `wgpu/src/api/buffer.rs:220-227` | Buffer struct definition |
| `wgpu/src/api/buffer.rs:744-758` | MapContext tracking |
| `wgpu/src/api/device.rs:19-22` | Device struct definition |
| `wgpu/src/api/device.rs:200-210` | CommandEncoder creation |
| `wgpu/src/api/device.rs:270-300` | Resource creation methods |

---

## Related Documents

- [nannou.md](nannou.md) - How nannou builds on wgpu
- [rend3.md](rend3.md) - Advanced pooling patterns
- [../handle-designs.md](../handle-designs.md) - Cross-framework comparison
