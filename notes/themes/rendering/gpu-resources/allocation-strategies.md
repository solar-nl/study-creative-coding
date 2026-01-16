# Allocation Strategies: How Memory Flows to the GPU

> Creating a GPU buffer isn't free. How do you minimize the overhead?

---

## The Allocation Overhead

Every `device.create_buffer()` call involves driver overhead: syscalls, memory mapping, internal tracking, potential GPU command submission. For a single buffer, this overhead is negligible. For ten thousand buffers, it dominates your frame time.

Creative coding often creates many small resources. Each particle might have a position buffer. Each text glyph might have a texture. Each effect might have uniform buffers. Without care, you spend more time allocating than rendering.

The question guiding this exploration: *when does allocation strategy matter, and what strategies work?*

---

## Per-Resource Allocation: The Simple Baseline

wgpu's default approach allocates each buffer independently:

```rust
let buffer_a = device.create_buffer(&BufferDescriptor { size: 1024, .. });
let buffer_b = device.create_buffer(&BufferDescriptor { size: 2048, .. });
```

This is straightforward. Each buffer exists in its own allocation. Sizes are exactly what you need—no waste. Lifetimes are independent—free one without affecting others.

For most creative coding, this is fine. If you have dozens of textures and a few dozen buffers, allocation overhead is negligible. The driver amortizes its internal costs, and you get simplicity in return.

The warning sign: allocation shows up in profiling. If you're creating hundreds of buffers per frame, or if buffer creation dominates your startup time, it's time to consider alternatives.

---

## The Megabuffer: One Allocation to Rule Them All

rend3 allocates one large buffer upfront and suballocates from it:

```rust
const STARTING_MESH_DATA: u64 = 1 << 25;  // 32MB

pub struct MeshManager {
    buffer: Arc<Buffer>,
    allocator: RangeAllocator<u64>,
}

impl MeshManager {
    fn allocate(&mut self, size: u64) -> Range<u64> {
        self.allocator.allocate_range(size).expect("buffer full")
    }
}
```

Create one 32MB buffer. When you need space for a mesh, the `RangeAllocator` finds a free region and returns its byte range. The mesh doesn't have its own buffer—it has a range within the shared buffer.

The benefits are dramatic at scale. Ten thousand meshes require one `create_buffer` call, not ten thousand. All mesh data lives in contiguous memory, improving cache behavior. And bindless rendering becomes natural—the shader indexes into one buffer, selecting meshes by offset.

The costs are real. Fragmentation happens: as meshes are freed, holes appear that may be too small for new allocations. Growth requires copying: if the megabuffer fills, you must create a larger one and copy everything. And debugging becomes harder: "buffer at offset 84392" is less clear than "vertex_buffer_for_cube."

---

## Growth Strategies: When Buffers Fill Up

When a buffer is too small, you have choices.

**Exact reallocation**: Create a new buffer exactly large enough for the new data. Minimal waste, but frequent reallocations if data grows incrementally.

```cpp
// Cinder pattern
void copyData(size_t size, const void* data) {
    if (size <= mSize) {
        glBufferSubData(mTarget, 0, size, data);
    } else {
        mSize = size;
        glBufferData(mTarget, mSize, data, mUsage);
    }
}
```

**Exponential growth**: Double the capacity when it fills. Amortized O(1) growth cost, but potentially significant wasted space.

```java
// Processing pattern
static int expandArraySize(int currSize, int newMinSize) {
    int newSize = currSize;
    while (newSize < newMinSize) {
        newSize <<= 1;
    }
    return newSize;
}
```

**Fixed increments**: Add a constant amount (e.g., 1MB) on each growth. Predictable, but neither optimal for small nor large allocations.

For megabuffers, growth is particularly expensive. You can't resize in place; you must allocate a new buffer, copy all data, and update all references. This argues for generous initial sizing—better to waste memory than to trigger growth mid-session.

---

## Tiered Pools: Compromise at Scale

Game engines often use tiered pools:

```rust
struct BufferPool {
    small: Vec<Buffer>,   // 1KB-16KB
    medium: Vec<Buffer>,  // 16KB-256KB
    large: Vec<Buffer>,   // 256KB-4MB
    oversized: Vec<Buffer>, // 4MB+
}

impl BufferPool {
    fn allocate(&mut self, size: u64) -> BufferHandle {
        let tier = match size {
            0..=16_384 => &mut self.small,
            16_385..=262_144 => &mut self.medium,
            262_145..=4_194_304 => &mut self.large,
            _ => &mut self.oversized,
        };
        // Find or create buffer in tier
    }
}
```

Each tier contains buffers of similar sizes. When you need a buffer, you look in the appropriate tier. If one's available, reuse it. If not, create a new one at tier size (not exact size).

This balances allocation overhead against fragmentation. Tiers limit internal fragmentation (a 100KB request from the medium tier wastes at most 156KB). Reuse within tiers avoids repeated allocation. But the complexity cost is real—you're maintaining multiple pools with their own reuse logic.

---

## Sizing for Your Use Case

Different applications have different needs:

| Application Type | Initial Megabuffer | Rationale |
|-----------------|-------------------|-----------|
| Simple 2D | 1-4 MB | Few shapes, small textures |
| Complex 2D | 8-16 MB | Many shapes, effects |
| 3D scenes | 32-64 MB | Meshes, materials |
| Large 3D | 128+ MB | Detailed environments |

Starting too small triggers early growth (copy overhead). Starting too large wastes memory. Profile your typical workloads and size accordingly.

For creative coding specifically, memory is usually abundant and allocation overhead matters more than memory waste. Err on the side of larger initial allocations.

---

## When to Use Which Strategy

**Per-resource allocation** when:
- Resource count is moderate (tens to hundreds)
- Resources have varied, unpredictable sizes
- Lifetimes are independent and varied
- Simplicity matters more than performance

**Megabuffer** when:
- Resource count is large (thousands)
- Resources have similar sizes (mesh vertices, instance data)
- Bindless rendering is a goal
- Allocation overhead shows in profiling

**Exponential growth** when:
- Final size is unknown at creation
- Growth is common and incremental
- Memory waste is acceptable

**Tiered pools** when:
- Large resource counts with varied sizes
- High allocation/deallocation churn
- Memory waste is a concern

---

## Lessons for the GPU Resource Pool

The allocation research suggests a phased approach:

**Start with per-resource allocation.** It's simple, it works, and creative coding workloads rarely stress allocation. The optimization target is clarity, not throughput.

**Add megabuffers if profiling shows need.** If particle systems, instanced rendering, or complex meshes dominate, suballocating from large buffers will help. But defer until measurements prove the need.

**Use exponential growth for dynamic data.** When you don't know the final size—dynamic text, procedural geometry, growing collections—doubling beats exact reallocation.

**Don't over-engineer upfront.** Sophisticated allocation strategies have maintenance costs. The simplest strategy that works is the right choice. Add complexity only when simple isn't enough.

---

## Related Documents

- [per-framework/rend3.md](per-framework/rend3.md) — Megabuffer implementation
- [per-framework/wgpu.md](per-framework/wgpu.md) — Per-resource baseline
