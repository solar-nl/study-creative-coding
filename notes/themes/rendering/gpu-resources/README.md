# GPU Resource Management

> How do you keep the GPU fed without drowning in bookkeeping?

---

## The Central Tension

Every frame, creative coding applications shuttle data to the GPU: vertex positions, texture pixels, transformation matrices, shader parameters. The naive approach—upload everything fresh each frame—works for simple sketches but collapses under complexity. A thousand particles, each with position and color? That's millions of bytes per second, most of it unchanged.

The solution seems obvious: track what changed, upload only that. But this simple idea spawns a thicket of questions. How do you know what changed? When is it safe to free GPU memory? What if multiple parts of your application reference the same buffer? How do you organize uploads to minimize driver overhead?

These questions led us to study eight frameworks, each with battle-tested answers. The patterns that emerged aren't arbitrary—they reflect the fundamental constraints of GPU programming and the specific demands of creative coding.

---

## The Cast of Frameworks

We studied frameworks spanning languages, eras, and design philosophies:

**The Rust Ecosystem**
- **wgpu** — The foundation. A safe, portable GPU abstraction that Flux will build upon.
- **nannou** — Creative coding on wgpu, with elegant device pooling for multi-window applications.
- **rend3** — A production 3D renderer showing how to scale resource management.

**The Visual Programming World**
- **tixl** — A node-based tool with a dirty flag system remarkably similar to what Flux needs.
- **OpenRNDR** — Kotlin creative coding with LRU caches and shadow buffers.

**The Web**
- **Three.js** — JavaScript's dominant 3D library, pioneering update range tracking.

**The Native Traditionalists**
- **Cinder** — C++ creative coding with RAII patterns.
- **Processing** — Java's approachable graphics, with context tracking for mobile.

Each framework solved the same fundamental problems, but their solutions reveal different priorities: safety versus performance, simplicity versus flexibility, immediate feedback versus batch efficiency.

---

## Seven Questions, Many Answers

### 1. What needs managing?

All frameworks manage the same core resources, though they name them differently:

| Resource | wgpu | Three.js | Cinder |
|----------|------|----------|--------|
| Vertex data | Buffer | BufferAttribute | VboMesh |
| Images | Texture | Texture | Texture2d |
| Shader programs | ShaderModule | ShaderMaterial | GlslProg |
| GPU state bundles | BindGroup | — | Batch |

The abstraction level varies—Three.js hides much of the GPU complexity, while wgpu exposes it directly—but the underlying resources are universal.

### 2. How do you reference GPU resources?

This is where frameworks diverge most sharply.

**wgpu wraps resources in Arc.** Clone a buffer handle? You get another reference to the same GPU memory. Drop all references? The resource eventually frees. This is safe and ergonomic, but carries reference-counting overhead.

**rend3 uses dense integer indices.** A mesh handle is just a number—an index into an array. Allocation is O(1), lookup is O(1), and freed indices go onto a freelist for reuse. Fast, but requires explicit lifetime management.

**nannou adds Weak references** for device pooling. The pool doesn't keep devices alive; when all windows using a device close, it cleans up automatically.

The lesson: match handle complexity to resource volume. Few textures? Arc is fine. Millions of particles? Consider indices.

### 3. When do you allocate GPU memory?

**Per-resource allocation** is simplest: each buffer gets its own GPU allocation. wgpu does this by default, and it's perfectly adequate for moderate resource counts.

**Megabuffer suballocation** shines at scale. rend3 allocates a 32MB buffer upfront, then carves out regions for individual meshes. One GPU allocation serves hundreds of meshes, dramatically reducing driver overhead.

**Exponential growth** handles unknown sizes. Processing doubles buffer capacity when it fills, amortizing reallocation cost. The alternative—exact reallocation each time—wastes less memory but costs more CPU.

### 4. How do you know what changed?

This question matters most for Flux, whose node graph must propagate changes efficiently.

**Boolean dirty flags** are the simplest approach: `needsUpdate = true`. But they have a flaw—if two systems check the flag, only the first sees it dirty.

**Version counters** solve this. Three.js increments a version number on each change; consumers cache the version they last processed. Multiple systems can independently track staleness.

**tixl's reference/target pattern** goes further. A "target" integer increments on invalidation; a "reference" integer records the last processed state. The flag is dirty when they differ. Combined with frame-based deduplication (don't invalidate twice in the same frame), this handles complex dependency graphs elegantly.

**Update ranges** add granularity. Instead of "this buffer changed," Three.js tracks "bytes 100-200 changed." For a 10,000-vertex buffer where only a few vertices moved, this means uploading kilobytes instead of megabytes.

### 5. When do you free GPU memory?

The GPU executes asynchronously. When your code says "delete this buffer," the GPU might still be using it for queued commands. Frameworks handle this tension differently:

**wgpu defers cleanup internally.** Drop a buffer, and wgpu schedules deletion for when it's safe. You don't see this complexity.

**rend3 uses an instruction queue.** Deletion becomes a queued operation, processed at frame boundaries after the GPU confirms completion.

**OpenRNDR groups resources into sessions.** End a session, and all its resources clean up together—perfect for scene boundaries or temporary render targets.

### 6. What about threads?

wgpu resources are Send + Sync, meaning you can share them across threads safely. But this doesn't mean everything is automatically parallel:

- **Resource creation** typically goes through a single device
- **Command recording** can parallelize (multiple encoders)
- **Queue submission** needs coordination

Most creative coding stays single-threaded, and that's fine. Design for single-threaded first; add parallelism only if profiling demands it.

### 7. How do you batch GPU commands?

GPU commands aren't executed immediately—they're recorded into command buffers, then submitted in batches. The organization matters:

**Single encoder per frame** is simplest. Record all your draws into one encoder, submit once.

**Multiple encoders** enable parallel recording. Each thread gets its own encoder; you collect and submit them together.

**Instruction queues** decouple user API from GPU work. rend3 lets you add a mesh and get a handle immediately, even though the actual GPU upload happens later. This simplifies user code while enabling sophisticated batching.

---

## What This Means for Flux

The research points toward a layered approach:

**Foundation: tixl-style dirty flags.** The reference/target pattern with frame deduplication handles node graph invalidation cleanly. This is already part of Flux's design.

**Addition: Three.js-style update ranges.** For large dynamic buffers (particle systems, dynamic meshes), tracking byte ranges enables efficient partial uploads.

**Structure: rend3-inspired resource pool.** Deferred operations mesh well with dirty flag processing—collect what's dirty, batch the uploads, process at frame boundaries.

**Simplicity first.** Start with per-resource allocation and single-threaded rendering. Add megabuffers or parallelism only if profiling shows the need.

The frameworks teach that there's no single correct approach—only tradeoffs appropriate to your constraints. Creative coding values rapid iteration and immediate feedback; optimize for those first.

---

## Document Map

### Per-Framework Deep Dives

| Document | Focus |
|----------|-------|
| [wgpu.md](per-framework/wgpu.md) | The foundation: Arc-wrapped handles, buffer mapping, command encoding |
| [nannou.md](per-framework/nannou.md) | Device pooling, Weak references, creative coding ergonomics |
| [rend3.md](per-framework/rend3.md) | Production patterns: megabuffers, instruction queues, bindless textures |
| [tixl.md](per-framework/tixl.md) | Dirty flag system, shader caching, node graph integration |
| [openrndr.md](per-framework/openrndr.md) | LRU caching, shadow buffers, session-based cleanup |
| [threejs.md](per-framework/threejs.md) | Update ranges, version tracking, backend abstraction |
| [cinder.md](per-framework/cinder.md) | RAII patterns, scoped bindings, texture pooling |
| [processing.md](per-framework/processing.md) | Context tracking, exponential growth, mobile resilience |
| [farbrausch.md](per-framework/farbrausch.md) | Demoscene efficiency: megabuffers, charging, render phases |

### Cross-Cutting Topics

| Document | Focus |
|----------|-------|
| [handle-designs.md](handle-designs.md) | Arc vs indices vs weak references |
| [allocation-strategies.md](allocation-strategies.md) | Per-resource vs megabuffer vs pools |
| [cache-invalidation.md](cache-invalidation.md) | Dirty flags, versions, update ranges |
| [reclamation-timing.md](reclamation-timing.md) | When and how to free GPU memory |
| [command-batching.md](command-batching.md) | Organizing GPU work efficiently |

### Synthesis

| Document | Focus |
|----------|-------|
| [flux-recommendations.md](flux-recommendations.md) | Concrete recommendations for Flux implementation |

---

## Related Documents

- [../README.md](../README.md) — Draw call batching strategies
- [../instance-rendering.md](../instance-rendering.md) — Instance buffer patterns
- [../../node-graphs/node-graph-architecture.md](../../node-graphs/node-graph-architecture.md) — Node graph execution models
