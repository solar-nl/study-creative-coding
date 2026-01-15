# Cache Invalidation Patterns

> How frameworks track when GPU data needs updating

---

## The Problem

GPU resources shouldn't be re-uploaded every frame. But when do they need updating? This is cache invalidation - knowing when cached GPU state is stale.

---

## Pattern Catalog

### 1. Boolean Dirty Flag (Simple)

```javascript
// Three.js simplified
texture.needsUpdate = true;  // Mark dirty
// During render:
if (texture.needsUpdate) {
    uploadTexture(texture);
    texture.needsUpdate = false;
}
```

**Characteristics:**
- O(1) check and set
- Binary: dirty or clean
- No history

**Problem**: If two systems check the flag, only one sees it dirty.

### 2. Version Counter (Three.js)

```javascript
// Three.js actual pattern
set needsUpdate(value) {
    if (value === true) this.version++;
}

// Renderer caches version:
if (cachedVersion !== texture.version) {
    uploadTexture(texture);
    cachedVersion = texture.version;
}
```

**Characteristics:**
- Multiple consumers can independently track
- Never decreases → always know if changed since last check
- Monotonically increasing

**Trade-off**: Integer overflow (unlikely in practice).

### 3. Reference/Target (tixl)

```csharp
// tixl pattern
public class DirtyFlag {
    public int Reference;  // Last clean state
    public int Target = 1; // Current state

    public bool IsDirty => Reference != Target;

    public void Invalidate() {
        Target++;
    }

    public void Clear() {
        Reference = Target;
    }
}
```

**Characteristics:**
- Like version counter but with explicit clean state
- `IsDirty` is a comparison, not a flag read
- Can detect "changed N times" (if needed)

**Key insight**: Separating "what we've processed" (Reference) from "current state" (Target) enables clean semantics.

### 4. Frame-Based Deduplication (tixl)

```csharp
// tixl enhancement
public int InvalidatedWithRefFrame;  // Last frame invalidated

public int Invalidate() {
    if (InvalidatedWithRefFrame == _globalTickCount)
        return Target;  // Already invalidated this frame

    InvalidatedWithRefFrame = _globalTickCount;
    Target++;
    return Target;
}
```

**Characteristics:**
- Prevents double-invalidation in same frame
- Global tick counter advances per frame
- Multiple invalidation paths converge

**This solves**: Node A and B both connect to C. If A changes, C is invalidated. If B also changes same frame, C shouldn't invalidate again.

### 5. Update Ranges (Three.js)

```javascript
// For large buffers
buffer.addUpdateRange(100, 50);  // Start: 100, Count: 50
buffer.addUpdateRange(5000, 100);

// During upload:
for (range of buffer.updateRanges) {
    uploadSubBuffer(range.start, range.count);
}
buffer.clearUpdateRanges();
```

**Characteristics:**
- Sub-resource granularity
- Multiple disjoint regions
- Cleared after processing

**Use case**: 10,000 vertex buffer, only vertices 100-150 changed.

### 6. LRU with Force (OpenRNDR)

```kotlin
// OpenRNDR pattern
cache.getOrSet(key, forceSet = shadeStyle?.dirty ?: false) {
    shadeStyle?.dirty = false
    // ... compute value
}
```

**Characteristics:**
- Cache lookup first
- `forceSet` bypasses cache when dirty
- Combines caching with invalidation

---

## Comparison Matrix

| Pattern | Granularity | Multiple Consumers | Deduplication | Complexity |
|---------|-------------|-------------------|---------------|------------|
| Boolean | Resource | No | No | Simple |
| Version | Resource | Yes | No | Simple |
| Ref/Target | Resource | Yes | Per-frame | Medium |
| Update Ranges | Byte ranges | N/A | No | Medium |
| LRU + Force | Cache entry | N/A | N/A | Medium |

---

## Integration with Node Graphs

### Propagation Strategies

**Push**: When input changes, immediately mark downstream dirty
```
A changes → mark B dirty → mark C dirty → ...
```

**Pull**: Check upstream when accessed
```
Request C → is B dirty? → is A dirty? → ...
```

**Hybrid (tixl)**: Push invalidation, pull values
```
A changes → mark B, C dirty (push)
Request C → if dirty, compute (pull)
```

### Deduplication Matters

In a diamond dependency:
```
    A
   / \
  B   C
   \ /
    D
```

When A changes:
1. B invalidates D
2. C invalidates D (again?)

With frame-based deduplication, D only invalidates once.

---

## Flux Recommendation

### Primary: Reference/Target with Frame Dedup

```rust
pub struct DirtyFlag {
    reference: u32,
    target: u32,
    invalidated_frame: u64,
}

impl DirtyFlag {
    pub fn is_dirty(&self) -> bool {
        self.reference != self.target
    }

    pub fn invalidate(&mut self, frame: u64) -> u32 {
        if self.invalidated_frame == frame {
            return self.target;
        }
        self.invalidated_frame = frame;
        self.target = self.target.wrapping_add(1);
        self.target
    }

    pub fn clear(&mut self) {
        self.reference = self.target;
    }
}
```

### Secondary: Update Ranges for Large Buffers

```rust
pub struct TrackedBuffer {
    buffer: wgpu::Buffer,
    data: Vec<u8>,
    dirty_ranges: Vec<Range<u64>>,
}

impl TrackedBuffer {
    pub fn write(&mut self, offset: u64, data: &[u8]) {
        let range = offset..offset + data.len() as u64;
        self.data[range.clone()].copy_from_slice(data);
        self.dirty_ranges.push(range);
    }

    pub fn flush(&mut self, queue: &wgpu::Queue) {
        // Optionally merge adjacent ranges
        for range in self.dirty_ranges.drain(..) {
            queue.write_buffer(&self.buffer, range.start, &self.data[range]);
        }
    }
}
```

---

## Related Documents

- [per-framework/tixl.md](per-framework/tixl.md) - Reference/Target deep dive
- [per-framework/threejs.md](per-framework/threejs.md) - Update ranges deep dive
- [per-framework/openrndr.md](per-framework/openrndr.md) - LRU with dirty integration
