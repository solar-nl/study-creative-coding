# wgpu: The Foundation

> What does a safe, portable GPU abstraction look like from the inside?

---

## Why Start Here

wgpu is the bedrock. Every creative coding framework built on Rust—nannou today, new frameworks tomorrow—ultimately speaks wgpu's language. Understanding how wgpu manages GPU resources isn't optional; it shapes what's possible and what's efficient in everything built on top.

But wgpu isn't just an implementation detail. It embodies a philosophy: safety through abstraction, portability through backends, ergonomics through Rust idioms. The patterns wgpu chose—Arc-wrapped handles, interior mutability for mapping, deferred cleanup—aren't arbitrary. They're solutions to real problems that any GPU abstraction must face.

The question guiding this exploration: *how does wgpu balance safety, performance, and usability in its resource management?*

---

## Handles: Arc All The Way Down

### The Design Choice

Open `wgpu/src/api/buffer.rs` and you'll find this:

```rust
pub struct Buffer {
    pub(crate) inner: dispatch::DispatchBuffer,
    pub(crate) map_context: Arc<Mutex<MapContext>>,
    pub(crate) size: wgt::BufferAddress,
    pub(crate) usage: BufferUsages,
}
```

A `Buffer` isn't the GPU buffer itself—it's a handle containing a reference to backend-specific data (`inner`), some tracking state (`map_context`), and cached metadata (`size`, `usage`).

Both `Buffer` and `Device` derive `Clone`. Cloning creates another handle to the same underlying resource. This is `Arc` semantics without explicit `Arc`—the reference counting happens inside `DispatchBuffer`.

### Why This Matters

Consider the alternative: unique ownership. In a unique-ownership model, you'd need to carefully track who "owns" each buffer and pass references or indices around. Rust's borrow checker would enforce correctness, but the ergonomics would suffer.

Arc-wrapped handles offer a different tradeoff:
- **Sharing is trivial.** Pass a buffer to multiple render passes? Just clone the handle.
- **Cleanup is automatic.** Drop all handles, and the resource eventually frees.
- **Thread safety is built-in.** Arc is Send + Sync; share across threads safely.

The cost? Reference counting overhead on clone and drop. For most creative coding workloads—hundreds of resources, not millions—this overhead is negligible.

### The Metadata Cache

Notice that `Buffer` stores `size` and `usage` directly. Why not query these from the backend?

Because queries are expensive. The backend might be Vulkan, Metal, DX12, or WebGPU—each with its own API for retrieving buffer properties. Caching metadata avoids cross-API calls for common queries.

This pattern appears throughout wgpu: the handle stores what's frequently needed, delegates to the backend only for operations that must touch GPU state.

---

## Buffer Mapping: A Dance of States

### The Problem

GPU buffers live in GPU memory. CPU code can't just dereference a pointer to read them. You need to *map* the buffer—make a CPU-accessible view of its contents. But mapping has constraints:

- You can't map while the GPU is using the buffer
- You can't use the buffer while it's mapped
- Multiple simultaneous maps of overlapping regions would cause data races

wgpu must enforce these constraints at runtime, because Rust's compile-time borrow checker can't see into GPU scheduling.

### The MapContext Solution

Each buffer carries a `MapContext`:

```rust
pub(crate) struct MapContext {
    mapped_range: Range<BufferAddress>,  // What's mapped (0..0 if unmapped)
    sub_ranges: Vec<Subrange>,           // Outstanding views into mapped data
}
```

When you call `map_async()`, wgpu records the mapped range. When you call `get_mapped_range()`, it checks that your request falls within the mapped range and doesn't overlap existing views. When you drop a `BufferView`, it removes that subrange. When you call `unmap()`, it verifies no views remain, then clears the mapped range.

This is runtime borrow checking. The compiler can't help here—GPU operations are inherently dynamic—so wgpu implements the same safety guarantees through explicit tracking.

### The Async Dance

Mapping is asynchronous because the GPU might still be using the buffer:

```rust
buffer.map_async(MapMode::Read, .., move |result| {
    if result.is_ok() {
        let view = buffer.get_mapped_range(..);
        // ... read data ...
        drop(view);
        buffer.unmap();
    }
});
// Later: device.poll() drives the callback
```

The callback runs when mapping completes—potentially on a different thread, potentially many frames later. This dance is awkward but unavoidable; GPU work is fundamentally asynchronous.

For simpler cases, `Queue::write_buffer()` hides the complexity. It uses internal staging buffers, handling the map/copy/unmap dance invisibly. The tradeoff is an extra copy, but for most use cases, the ergonomic benefit outweighs the performance cost.

---

## Resource Creation: The Device as Factory

### The Pattern

All GPU resources come from the Device:

```rust
let buffer = device.create_buffer(&BufferDescriptor {
    label: Some("my buffer"),
    size: 1024,
    usage: BufferUsages::VERTEX | BufferUsages::COPY_DST,
    mapped_at_creation: false,
});
```

The descriptor pattern is everywhere in wgpu. You build a struct describing what you want, pass it to a creation method, get back a handle. This is deliberate:

- **Descriptors are data.** You can store them, serialize them, build them programmatically.
- **Creation is synchronous.** Unlike mapping, buffer creation returns immediately.
- **Errors are rare.** Out-of-memory panics; invalid parameters panic. No error handling clutter.

### What Creation Does

Looking at `device.rs:270-283`:

```rust
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
```

Creation initializes the map context (pre-mapped if `mapped_at_creation` is set), delegates to the backend for actual GPU allocation, then wraps everything in a handle with cached metadata.

Notice there's no allocator parameter. Unlike Vulkan, where you might integrate a custom memory allocator, wgpu manages memory internally. This simplifies the API at the cost of some flexibility.

---

## Command Encoding: Record Now, Execute Later

### The Model

GPU work isn't executed immediately. You record commands into an encoder, finish it into a command buffer, then submit:

```rust
let mut encoder = device.create_command_encoder(&Default::default());
{
    let mut pass = encoder.begin_render_pass(&render_pass_desc);
    pass.set_pipeline(&pipeline);
    pass.draw(0..3, 0..1);
}
let command_buffer = encoder.finish();
queue.submit([command_buffer]);
```

This separation—recording versus execution—is fundamental to modern GPU APIs. It enables:

- **Batching.** Many commands in one submit, reducing driver overhead.
- **Reordering.** The driver can optimize command order within a submit.
- **Parallelism.** Multiple threads can record simultaneously (multiple encoders).

### Deferred Actions

Looking at encoder creation in `device.rs:200-210`:

```rust
pub fn create_command_encoder(&self, desc: &CommandEncoderDescriptor<'_>) -> CommandEncoder {
    let encoder = self.inner.create_command_encoder(desc);
    CommandEncoder {
        inner: encoder,
        actions: Default::default(),  // Deferred actions travel with the buffer
    }
}
```

That `actions` field is intriguing. It allows wgpu to attach deferred operations—like "map this buffer after these commands complete"—to the command buffer. When you submit, those actions get scheduled appropriately.

This is the hook for advanced patterns like mapping a buffer only after a compute shader writes to it. User code sees a simple callback; wgpu handles the synchronization.

---

## Thread Safety: What's Actually Safe

### The Guarantees

wgpu enforces Send + Sync on its types:

```rust
#[cfg(send_sync)]
static_assertions::assert_impl_all!(Device: Send, Sync);
```

This means you can:
- Create a buffer on one thread, use it on another
- Share handles across threads (they're Arc-based internally)
- Record commands in parallel (one encoder per thread)

But "safe" doesn't mean "automatically parallel." You still need to coordinate:
- **Queue submission** should happen from one place, or be synchronized
- **Resource creation** goes through the device, which handles its own locking
- **Buffer mapping** has state that needs coordination

### The Practical Approach

For creative coding, single-threaded is usually fine. wgpu's thread safety means you *can* parallelize if profiling shows the need, but you don't pay complexity costs until then.

---

## Cleanup: Deferred by Design

### When Resources Die

Drop a buffer handle, and... nothing immediately happens to GPU memory. wgpu schedules cleanup, but actual deletion waits until:

1. All command buffers referencing the resource have completed
2. `device.poll()` runs to process completions

This is invisible to user code, but it matters for memory pressure. If you're churning through temporary buffers, they accumulate until the next poll. For most applications, this is fine—the driver manages memory intelligently. For memory-constrained scenarios, explicit `buffer.destroy()` marks the resource for immediate cleanup.

### The Safety Net

wgpu's deferred cleanup is a safety net. You can't accidentally use a freed resource, because the resource isn't actually freed until it's safe. This is a different model than OpenGL (immediate deletion, undefined behavior if used) or Vulkan (explicit fence management).

---

## Lessons for the GPU Resource Pool

wgpu's patterns suggest several approaches:

**Arc-wrapped handles for simplicity.** Until profiling shows overhead, reference-counted handles are the right default. They're safe, ergonomic, and thread-compatible.

**Metadata caching.** Store frequently-accessed data (size, format, usage) alongside handles. Don't query the backend for basic properties.

**Runtime state tracking.** Some invariants can't be checked at compile time. Buffer mapping state, dirty flags, dependency graphs—these need explicit tracking.

**Deferred cleanup.** Don't free resources immediately. Batch deletions, process at frame boundaries, let the system confirm safety.

**Single-threaded first.** Design for parallel compatibility, but implement single-threaded. Add complexity only when measurements demand it.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `wgpu/src/api/buffer.rs` | 220-227 | Buffer struct definition |
| `wgpu/src/api/buffer.rs` | 744-758 | MapContext tracking |
| `wgpu/src/api/buffer.rs` | 566-579 | map_async implementation |
| `wgpu/src/api/device.rs` | 19-22 | Device struct definition |
| `wgpu/src/api/device.rs` | 200-210 | CommandEncoder creation |
| `wgpu/src/api/device.rs` | 270-283 | Buffer creation |

---

## Related Documents

- [nannou.md](nannou.md) — How nannou builds creative coding ergonomics on wgpu
- [rend3.md](rend3.md) — Production-scale resource management over wgpu
- [../cache-invalidation.md](../cache-invalidation.md) — Dirty flag patterns that complement wgpu's model
