# Version Counters vs. Reference/Target: Two Solutions to Multi-Consumer Staleness

> When multiple consumers need to track whether a resource has changed, how does each know what it has already processed?

---

## The Core Tension

A boolean dirty flag seems like the obvious solution to change tracking: set it when something changes, check it before using the resource, clear it after processing. But this simple model breaks down the moment you have multiple consumers.

Consider a texture used by two renderers—a preview canvas and a main viewport. The texture updates. Renderer A checks the flag, sees it dirty, uploads the texture, and clears the flag. Renderer B checks the flag a moment later and sees... nothing. The flag is already clear. Renderer B continues using stale data.

The fundamental flaw: clearing a boolean flag is a destructive operation. The first consumer to process the change erases the signal for everyone else. For single-consumer scenarios, booleans suffice. For anything more complex, you need a pattern where each consumer can track staleness independently.

Two patterns emerged from the frameworks we studied. Three.js uses version counters—a monotonically increasing integer that consumers cache and compare. tixl uses a reference/target pair with frame-based deduplication. Both solve the multi-consumer problem, but they optimize for different scenarios and offer different tradeoffs.

---

## Pattern A: Version Counters (Three.js)

### Context: Multi-Renderer Scenarios

Three.js operates in environments where the same scene might render to multiple targets simultaneously. An editor might show a small preview canvas updated at 30fps alongside a main viewport at 60fps. A VR application might render to two eyes plus a mirror display. Each renderer needs to know when resources have changed since *it* last processed them.

The version counter pattern addresses this directly. Each resource carries a version number that increments on modification. Each consumer caches the version it last processed. Comparison reveals staleness without destroying the signal.

### How It Works

The pattern centers on a version integer embedded in the resource:

```javascript
class Texture {
    constructor() {
        this.version = 0;
    }

    set needsUpdate(value) {
        if (value === true) this.version++;
    }
}
```

Setting `needsUpdate = true` increments the version. The semantic is "this resource has changed"—not "this resource needs processing." The distinction matters: the resource's state advances unconditionally, independent of who might be watching.

Each consumer maintains its own cache:

```javascript
class TextureCache {
    constructor() {
        this.cachedVersions = new Map();  // texture -> last seen version
    }

    needsUpload(texture) {
        const cached = this.cachedVersions.get(texture) ?? -1;
        return cached !== texture.version;
    }

    markProcessed(texture) {
        this.cachedVersions.set(texture, texture.version);
    }
}
```

The upload check is a simple inequality. If the cached version differs from the current version, something changed since last upload. After processing, the consumer updates its cache to reflect the current state.

### Data Flow

```
                    Texture (version: 5)
                           |
                           | texture.needsUpdate = true
                           v
                    Texture (version: 6)
                          /|\
                         / | \
                        /  |  \
                       v   v   v
                   +---+  +---+  +---+
                   | A |  | B |  | C |   <- Consumers
                   +---+  +---+  +---+
                    (5)    (5)    (6)     <- Cached versions

    Consumer A: cached=5, current=6, differs -> needs upload
    Consumer B: cached=5, current=6, differs -> needs upload
    Consumer C: cached=6, current=6, matches -> skip upload
```

Multiple consumers independently detect the change. Consumer C, having already processed version 6, correctly skips redundant work. No coordination is required between consumers.

### When It Excels

- **Global versioning**: The version number provides a total ordering of changes. "Version 5" means exactly one thing, regardless of who asks.

- **Multi-consumer scenarios**: Each consumer tracks independently. Add a third renderer tomorrow; it works automatically by starting with cached version -1.

- **Simple mental model**: One number per resource, one comparison per consumer check. Easy to debug, easy to reason about.

- **Minimal overhead**: One integer per resource, one integer per consumer per resource. For a thousand textures with three consumers, you store three thousand integers.

- **Overflow tolerance**: At 60fps with a change every frame, a 32-bit counter overflows in 2.2 years. A 64-bit counter lasts longer than the universe.

---

## Pattern B: Reference/Target (tixl)

### Context: Node Graph with Thousands of Nodes

tixl is a visual programming environment where users construct patches from interconnected nodes. A complex patch might have thousands of nodes, each with multiple inputs and outputs. When an upstream node changes, the change must propagate downstream—but only to nodes that actually depend on the changed value.

The reference/target pattern optimizes for this propagation scenario. It separates "current dirty state" from "last processed state" explicitly, and adds frame-aware deduplication to handle diamond dependencies efficiently.

### How It Works

Each node carries a dirty flag with two state integers:

```csharp
public class DirtyFlag
{
    public int Reference;           // Last known clean state
    public int Target = 1;          // Current dirty state
    public int InvalidatedWithRefFrame;  // Prevents double invalidation

    public bool IsDirty => Reference != Target;
}
```

The `Reference` records what the consumer last processed. The `Target` represents the current state. When they differ, the resource is dirty. This is functionally equivalent to version counters—`Reference` is the cached version, `Target` is the current version—but the naming emphasizes the comparison semantics.

The key innovation is frame-based deduplication:

```csharp
public int Invalidate()
{
    if (InvalidatedWithRefFrame == _globalTickCount)
        return Target;  // Already invalidated this frame

    InvalidatedWithRefFrame = _globalTickCount;
    Target++;
    return Target;
}
```

A global tick counter advances each frame. Each dirty flag remembers when it was last invalidated. If you try to invalidate twice in the same frame, the second call is a no-op.

### Frame Tick Spacing

The global tick counter increments by 100 each frame, not by 1:

```csharp
public static void IncrementGlobalTicks()
{
    _globalTickCount += GlobalTickDiffPerFrame;  // += 100
}
// Why 100? Leaves room for intra-frame events, 400K years to overflow
```

The spacing serves two purposes. First, it reserves room for sub-frame events or debugging markers without colliding with frame boundaries. Second, it enables diagnostic calculations:

```csharp
public int FramesSinceLastUpdate =>
    (_globalTickCount - _lastUpdateTick) / GlobalTickDiffPerFrame;
```

"This node hasn't updated in 47 frames" is immediately actionable debugging information.

### Data Flow with Diamond Deduplication

```
         Frame N: Node A changes
                    |
         +----------+-----------+
         |                      |
         v                      v
      Node B                 Node C
         |                      |
         +----------+-----------+
                    |
                    v
         Node D (receives two invalidation signals)

Without deduplication:
    - Path A->B->D: Target++ (now 2)
    - Path A->C->D: Target++ (now 3)
    - D thinks it was invalidated twice

With deduplication:
    - Path A->B->D: InvalidatedWithRefFrame = N, Target++ (now 2)
    - Path A->C->D: InvalidatedWithRefFrame == N, skip
    - D correctly knows it was invalidated once this frame
```

Diamond dependencies are common in node graphs. Without protection, every path through the diamond would increment the target, inflating the dirty count and potentially triggering redundant work.

### When It Excels

- **Node graphs**: The pattern was designed for graphs where diamond dependencies are the norm, not the exception.

- **Frame-aware deduplication**: Multiple invalidation paths converge gracefully. The first invalidation counts; subsequent ones in the same frame are no-ops.

- **Debugging information**: The difference between `Target` and `Reference` tells you how far behind processing has fallen. The `InvalidatedWithRefFrame` tells you when the last change occurred.

- **Propagation control**: Returning the new `Target` from `Invalidate()` enables downstream nodes to aggregate upstream changes, detecting how many inputs changed.

- **Overflow is a non-concern**: At 100 ticks per frame and 60fps, an int32 overflows in about 400,000 years.

---

## Side-by-Side Comparison

| Dimension | Version Counters | Reference/Target |
|-----------|------------------|------------------|
| Integers per resource | 1 (version) | 3 (reference, target, frame) |
| Comparison method | cached != current | reference != target |
| Per-frame deduplication | No | Yes (via frame counter) |
| Multi-consumer support | Yes (each caches version) | Yes (each has own reference) |
| Overflow concerns | Minimal | Minimal |
| Debugging info | Current version only | Target, reference, and frame |
| Best for | Flat resources | Graph dependencies |

The patterns solve the same fundamental problem—multi-consumer staleness detection—but optimize for different shapes of dependency. Version counters are simpler when resources are independent. Reference/target with frame deduplication shines when resources form a graph with shared dependencies.

---

## Combining the Patterns

The patterns are not mutually exclusive. A system can use version counters for GPU resources while using reference/target for node graph relationships.

Consider a texture node in a node graph. The texture itself (the GPU resource) carries a version counter. The node's output slot (the graph connection) carries a reference/target dirty flag. When the texture's version changes, the node invalidates its output slot. Downstream nodes see the slot's dirty flag, not the texture's version.

### Rust Example: GPU Resource Pool with Node Integration

```rust
/// GPU resource with version counter
pub struct TrackedTexture {
    pub texture: wgpu::Texture,
    pub version: u32,
}

impl TrackedTexture {
    pub fn mark_updated(&mut self) {
        self.version = self.version.wrapping_add(1);
    }
}

/// Consumer-side version cache
pub struct TextureVersionCache {
    versions: HashMap<TextureHandle, u32>,
}

impl TextureVersionCache {
    pub fn needs_upload(&self, handle: TextureHandle, current: u32) -> bool {
        self.versions.get(&handle).copied().unwrap_or(0) != current
    }

    pub fn mark_uploaded(&mut self, handle: TextureHandle, version: u32) {
        self.versions.insert(handle, version);
    }
}

/// Node graph dirty flag with frame deduplication
pub struct DirtyFlag {
    pub reference: u32,
    pub target: u32,
    pub invalidated_frame: u64,
}

impl DirtyFlag {
    pub const fn new() -> Self {
        Self {
            reference: 0,
            target: 1,  // Start dirty
            invalidated_frame: 0,
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.reference != self.target
    }

    pub fn invalidate(&mut self, current_frame: u64) -> u32 {
        if self.invalidated_frame == current_frame {
            return self.target;
        }
        self.invalidated_frame = current_frame;
        self.target = self.target.wrapping_add(1);
        self.target
    }

    pub fn clear(&mut self) {
        self.reference = self.target;
    }
}

/// Node that wraps a GPU texture
pub struct TextureNode {
    texture_handle: TextureHandle,
    output_dirty: DirtyFlag,
    last_texture_version: u32,
}

impl TextureNode {
    pub fn update(&mut self, pool: &GpuResourcePool, frame: u64) {
        let texture = pool.get_texture(self.texture_handle);

        // Compare texture version to detect external changes
        if texture.version != self.last_texture_version {
            self.last_texture_version = texture.version;
            self.output_dirty.invalidate(frame);
        }
    }

    pub fn output_is_dirty(&self) -> bool {
        self.output_dirty.is_dirty()
    }
}
```

The layering is natural: GPU resources use the simpler version counter pattern, while node graph connections use the richer reference/target pattern. Each pattern operates in its natural domain.

### When to Use Which

| Scenario | Recommended Pattern |
|----------|---------------------|
| Texture uploaded to GPU | Version counter |
| Buffer with partial updates | Version counter + update ranges |
| Shader recompilation | Version counter |
| Node graph slot | Reference/Target |
| Animation parameter | Reference/Target with trigger modes |
| Multi-renderer scene | Version counter per resource |
| Diamond dependency graph | Reference/Target with frame dedup |

---

## Implications for the GPU Resource Pool

### Recommendation 1: Version Counters for GPU Resources

For textures, buffers, and shaders—resources that live in GPU memory—version counters provide the right balance of simplicity and capability:

```rust
pub struct TrackedBuffer {
    buffer: wgpu::Buffer,
    version: u32,
    staged_data: Vec<u8>,
}

impl TrackedBuffer {
    pub fn write(&mut self, offset: usize, data: &[u8]) {
        self.staged_data[offset..offset + data.len()].copy_from_slice(data);
        self.version = self.version.wrapping_add(1);
    }
}
```

Each consumer (render pass, compute pass, readback operation) maintains its own version cache. When the cached version differs from the current version, the consumer knows to re-upload or re-bind.

### Recommendation 2: Reference/Target for Node Graph Integration

If the framework includes a node graph system, use reference/target dirty flags for graph connections:

```rust
pub struct OutputSlot<T> {
    value: T,
    dirty: DirtyFlag,
}

impl<T> OutputSlot<T> {
    pub fn set(&mut self, value: T, frame: u64) {
        self.value = value;
        self.dirty.invalidate(frame);
    }

    pub fn get_if_dirty(&mut self) -> Option<&T> {
        if self.dirty.is_dirty() {
            self.dirty.clear();
            Some(&self.value)
        } else {
            None
        }
    }
}
```

The frame deduplication ensures that diamond dependencies don't multiply invalidation signals. The reference/target semantics make debugging graph execution straightforward.

### Recommendation 3: Frame-Aware Invalidation for Deduplication

Whether using version counters or reference/target, frame awareness prevents redundant work:

```rust
pub struct FrameContext {
    current_frame: u64,
}

impl FrameContext {
    pub fn begin_frame(&mut self) {
        self.current_frame += 1;
    }

    pub fn current(&self) -> u64 {
        self.current_frame
    }
}
```

Pass the frame number to invalidation calls. Resources that were already invalidated this frame can skip redundant processing.

### Handling Diamond Dependencies

Diamond dependencies occur when multiple paths lead to the same downstream resource. Without deduplication, each path triggers separate invalidation, potentially multiplying upload work.

```
      Mesh Data
         |
    +----+----+
    |         |
    v         v
  Vertex   Normal
  Buffer   Buffer
    |         |
    +----+----+
         |
         v
    Bind Group
```

If the mesh data changes, both vertex and normal buffers update. The bind group depends on both. Without deduplication, the bind group would see two separate invalidation signals.

With frame-aware invalidation:

```rust
impl BindGroupNode {
    pub fn update(&mut self, vertex: &BufferNode, normal: &BufferNode, frame: u64) {
        let mut needs_rebuild = false;

        if vertex.dirty.is_dirty() {
            needs_rebuild = true;
        }
        if normal.dirty.is_dirty() {
            needs_rebuild = true;
        }

        if needs_rebuild {
            self.dirty.invalidate(frame);  // Only once per frame
            self.rebuild_bind_group();
        }
    }
}
```

The bind group checks both inputs, but its own dirty flag only increments once per frame regardless of how many inputs triggered the rebuild.

---

## Conclusion

Version counters and reference/target patterns both solve multi-consumer staleness detection, but they optimize for different scenarios. Version counters are simpler and sufficient for independent resources—textures, buffers, shaders that don't form complex dependency graphs. Reference/target with frame deduplication handles graph structures where diamond dependencies are common and debugging propagation matters.

For a GPU Resource Pool in a creative coding framework, the practical recommendation is straightforward: use version counters for GPU resources, use reference/target for node graph integration if applicable, and always pass frame context to invalidation calls to enable deduplication.

The patterns complement rather than compete. Version counters handle the "has this resource changed?" question. Reference/target handles the "has this node's output changed, considering all its inputs?" question. Together, they provide precise change tracking from raw GPU resources up through complex node graphs.

---

## Related Documents

- [per-framework/threejs.md](per-framework/threejs.md) - Version counter implementation details
- [per-framework/tixl.md](per-framework/tixl.md) - Reference/Target and frame deduplication
- [cache-invalidation.md](cache-invalidation.md) - Cross-framework comparison of dirty flag patterns
