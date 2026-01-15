# Allocation Strategies

> How frameworks allocate and grow GPU memory

---

## The Problem

GPU buffer creation has overhead - driver calls, memory allocation, internal tracking. For applications creating many buffers or frequently resizing, allocation strategy matters.

---

## Pattern Catalog

### 1. Per-Resource Allocation (wgpu default)

```rust
// Each buffer is independent
let buffer_a = device.create_buffer(&BufferDescriptor { size: 1024, .. });
let buffer_b = device.create_buffer(&BufferDescriptor { size: 2048, .. });
```

**Characteristics:**
- Simple, direct mapping to GPU
- No sharing or suballocation
- Each buffer has exact size needed

**When to use**: Low buffer count, varied sizes, simple applications.

### 2. Megabuffer + Suballocation (rend3)

```rust
// rend3 pattern
const STARTING_MESH_DATA: u64 = 1 << 25;  // 32MB

pub struct MeshManager {
    buffer: Arc<Buffer>,
    allocator: RangeAllocator<u64>,
}

impl MeshManager {
    fn allocate(&mut self, size: u64) -> Range<u64> {
        // Suballocate from megabuffer
        self.allocator.allocate_range(size)
            .expect("buffer full")
    }
}
```

**Characteristics:**
- One large buffer, many sub-regions
- Range allocator manages free space
- Reduces `create_buffer` calls dramatically

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Fewer driver calls | Fragmentation |
| Cache-friendly | Need growth strategy |
| Bindless-friendly | More complex management |

### 3. Exponential Growth (Processing)

```java
// Processing pattern
static protected int expandArraySize(int currSize, int newMinSize) {
    int newSize = currSize;
    while (newSize < newMinSize) {
        newSize <<= 1;  // Double
    }
    return newSize;
}
```

**Characteristics:**
- Size doubles until large enough
- Amortized O(1) growth cost
- Always power-of-two sizes

**Use case**: Unknown final size, frequent growth.

### 4. Exact Reallocation (Cinder)

```cpp
// Cinder pattern
void BufferObj::copyData(GLsizeiptr size, const GLvoid *data) {
    if (size <= mSize) {
        glBufferSubData(mTarget, 0, size, data);  // Fits
    } else {
        mSize = size;
        glBufferData(mTarget, mSize, data, mUsage);  // Reallocate
    }
}
```

**Characteristics:**
- Use existing if big enough
- Reallocate to exact size if not
- Minimal wasted space

**Trade-off**: More reallocations than exponential, less waste.

### 5. Tiered Pools (Common in games)

```rust
// Conceptual pattern
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

**Characteristics:**
- Pre-sized tiers reduce fragmentation
- Reuse buffers within tiers
- Oversized handled separately

---

## Comparison Matrix

| Strategy | Creation Overhead | Fragmentation | Memory Efficiency | Complexity |
|----------|------------------|---------------|-------------------|------------|
| Per-resource | High | None | Perfect | Simple |
| Megabuffer | Very low | Medium | Good | Medium |
| Exponential | Medium | None | Poor | Simple |
| Exact | Medium-High | None | Perfect | Simple |
| Tiered pools | Low | Low | Good | High |

---

## Growth Strategy Details

### When to Grow

| Trigger | Strategy | Example |
|---------|----------|---------|
| **Exact need** | Reallocate when full | Cinder |
| **2x current** | Double capacity | Processing |
| **1.5x current** | Grow by 50% | Common compromise |
| **Fixed increment** | Add 1MB | Predictable |

### Growth for Megabuffers

rend3's megabuffer growth (conceptual):

```rust
fn grow_megabuffer(&mut self, device: &Device, min_size: u64) {
    let new_size = (self.current_size * 2).max(min_size);

    // Create new larger buffer
    let new_buffer = device.create_buffer(&BufferDescriptor {
        size: new_size,
        usage: self.usage,
        ..
    });

    // Copy old data
    encoder.copy_buffer_to_buffer(
        &self.buffer, 0,
        &new_buffer, 0,
        self.used_size
    );

    // Replace
    self.buffer = new_buffer;
    self.allocator = RangeAllocator::new(0..new_size);
    // Re-add used ranges to allocator (complex!)
}
```

**Key issue**: Re-adding used ranges after growth is tricky. Some systems avoid this by never growing (allocate large upfront) or by using handles that abstract buffer identity.

---

## Flux Recommendation

### Phase 1: Simple Per-Resource

Start simple, measure, optimize if needed.

```rust
pub struct ResourcePool {
    buffers: Vec<wgpu::Buffer>,
}

impl ResourcePool {
    pub fn create_buffer(&mut self, device: &Device, desc: &BufferDescriptor) -> BufferHandle {
        let buffer = device.create_buffer(desc);
        let handle = BufferHandle(self.buffers.len());
        self.buffers.push(buffer);
        handle
    }
}
```

### Phase 2: Add Geometry Megabuffer (if needed)

If profiling shows buffer creation overhead for dynamic geometry:

```rust
pub struct GeometryPool {
    megabuffer: wgpu::Buffer,
    allocator: RangeAllocator<u64>,
    pending_uploads: Vec<PendingUpload>,
}

impl GeometryPool {
    pub fn allocate(&mut self, size: u64) -> MeshAllocation {
        let range = self.allocator.allocate_range(size)
            .expect("TODO: implement growth");
        MeshAllocation { range, pool: self }
    }
}
```

### Consider Starting Size

| Application Type | Initial Megabuffer |
|-----------------|-------------------|
| Simple 2D | 1-4 MB |
| Complex 2D | 8-16 MB |
| 3D scenes | 32-64 MB |
| Large 3D | 128+ MB |

Starting too small means early growth (copy overhead). Starting too large wastes memory.

---

## Related Documents

- [per-framework/rend3.md](per-framework/rend3.md) - Megabuffer implementation
- [per-framework/wgpu.md](per-framework/wgpu.md) - Per-resource baseline
