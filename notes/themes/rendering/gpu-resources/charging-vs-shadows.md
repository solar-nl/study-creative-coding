# Charging vs. Shadow Buffers: Two Patterns for CPU-GPU Data Flow

> When should the CPU remember what the GPU knows? When can it forget?

---

## The Core Tension

Every GPU application faces the same uncomfortable question: what happens to your data after it reaches the GPU?

Consider a procedurally generated mesh. During creation, you compute thousands of vertices on the CPU. You upload them to the GPU. Now what? The GPU has its copy, sitting in fast video memory, ready for rendering. But the CPU still holds the original data, consuming system RAM, doing nothing. Should you keep it? Delete it? What if you need it later?

This question has no universal answer. It depends on your use case, your constraints, and your priorities. But two frameworks have developed particularly elegant solutions, each optimized for different ends of the spectrum.

**Farbrausch's Charging pattern** answers: "delete it as soon as safely possible." Born from the demoscene's brutal 64KB constraint, charging tracks when CPU data has fulfilled its purpose and can be discarded.

**OpenRNDR's Shadow Buffers pattern** answers: "keep it available, but only if needed." Coming from creative coding where reading pixels and modifying geometry are common operations, shadows provide on-demand CPU access without universal memory overhead.

These patterns are not competitors. They solve different problems. Understanding when to apply each is key to efficient GPU resource management.

---

## Charging: The One-Way Trip

### The Context

Imagine you must fit an entire audiovisual experience into 64 kilobytes. Not megabytes. Kilobytes. That's smaller than a typical JPEG image. Yet demos like "fr-041: debris" rendered photorealistic destruction scenes with this constraint.

The trick is procedural generation. Instead of storing textures, you store algorithms that generate textures. Instead of mesh files, you store equations that compute geometry. But this creates a problem: generated content exists first on the CPU. After uploading to the GPU, that CPU data is dead weight. In a world where every byte matters, dead weight is unacceptable.

### How Charging Works

Farbrausch's solution tracks two counts for each resource: `RefCount` (how many references exist) and `ChargeCount` (how many references have "charged"—uploaded to GPU and no longer need CPU data).

```cpp
void Wz4Mesh::Charge()
{
    ChargeCount++;
    ChargeBBox();                    // Upload bounding box
    ChargeSolid(sRF_TARGET_ZONLY);   // Upload depth-only geometry
    ChargeSolid(sRF_TARGET_MAIN);    // Upload main render geometry

    // When all references have charged, CPU data becomes unnecessary
    if (RefCount - ChargeCount == 1 && DontClearVertices == 0)
    {
        Vertices.Reset();  // Free CPU vertex data
        Faces.Reset();     // Free CPU face data
    }
}
```

The logic is subtle but elegant. `RefCount - ChargeCount == 1` means all references except the mesh's own internal reference have charged. Everyone who needs the mesh has their GPU copy. The CPU data has served its purpose.

The `DontClearVertices` flag handles edge cases. Some meshes need CPU data retained—perhaps for collision detection, or because they'll be modified later. The flag lets specific resources opt out of automatic cleanup.

### The Flow

Charging establishes a one-way flow: CPU to GPU, then forget.

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Generate   │     │    Upload    │     │    Render    │
│   on CPU     │────▶│    to GPU    │────▶│   from GPU   │
│              │     │              │     │              │
│  Vertices[]  │     │  GPU Buffer  │     │  Draw calls  │
│  Faces[]     │     │              │     │              │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │
       │                    ▼
       │             ChargeCount++
       │                    │
       │                    ▼
       │          if (all charged):
       ▼                    │
   [DELETED]◀───────────────┘
```

Once every user has charged, the CPU data evaporates. The mesh continues to exist, but only on the GPU. Memory pressure drops. The constraint is satisfied.

### When Charging Excels

Charging shines when:

- **Content is generated once and rendered many times.** Procedural textures, computed geometry, synthesized audio—create it, upload it, never touch it again.

- **Memory is severely constrained.** Mobile devices, embedded systems, or self-imposed limits like demoscene intros.

- **CPU data is reconstructable.** If you can regenerate the data from parameters, why store it? Regeneration is cheaper than memory.

- **The application has clear loading/runtime phases.** Generate everything during load, charge during first frame, render forever after.

---

## Shadow Buffers: The Optional Mirror

### The Context

Creative coding has different priorities. You're experimenting, iterating, exploring. You might want to read pixels back from the GPU—to analyze the result, to feed it into another algorithm, to save it to disk. You might want to modify geometry dynamically—physics simulations, procedural animation, real-time sculpting.

The CPU-GPU relationship isn't one-way. It's a conversation.

But most buffers don't need this conversation. A static background texture? Never touched after upload. A pre-computed mesh? Rendered unchanged every frame. Maintaining CPU copies of these buffers wastes memory for no benefit.

### How Shadows Work

OpenRNDR solves this with lazy allocation. Every buffer can have a shadow, but doesn't by default.

```kotlin
override val shadow: ColorBufferShadow
    get() {
        if (realShadow == null) {
            realShadow = ColorBufferShadowGL3(this)
        }
        return realShadow!!
    }
```

The first time you access `buffer.shadow`, the system allocates a CPU-side ByteBuffer matching the GPU buffer's dimensions. Until then, `realShadow` is null—no memory consumed.

The shadow provides explicit synchronization operations:

```kotlin
class ColorBufferShadowGL3(override val colorBuffer: ColorBufferGL3) : ColorBufferShadow {
    override val buffer: ByteBuffer = BufferUtils.createByteBuffer(elementSize * size)

    override fun download() {
        colorBuffer.read(buffer)  // GPU → CPU
    }

    override fun upload() {
        colorBuffer.write(buffer)  // CPU → GPU
    }
}
```

You control when data moves. `download()` pulls current GPU data to the CPU shadow—useful for reading render results or analyzing what the GPU computed. `upload()` pushes CPU modifications to the GPU—useful for dynamic geometry or procedural updates.

### The Flow

Shadows establish bidirectional flow: CPU to GPU, GPU to CPU, on demand.

```
┌──────────────┐         ┌──────────────┐
│     CPU      │         │     GPU      │
│              │         │              │
│   Shadow     │◀────────│   Buffer     │
│   Buffer     │ download│              │
│              │─────────▶│              │
│              │  upload │              │
└──────────────┘         └──────────────┘
      ▲                        ▲
      │                        │
      │    LAZY ALLOCATION     │
      │                        │
      │   Shadow created on    │
      │   first access, not    │
      │   buffer creation      │
      └────────────────────────┘
```

Most buffers never get shadows. The cost is zero. Only the buffers that actually need CPU access pay the memory price.

### When Shadows Excel

Shadows shine when:

- **You need to read GPU results.** Pixel readback for analysis, collision detection from depth buffers, GPU-computed data that feeds back into CPU algorithms.

- **Geometry changes dynamically.** Physics simulations, procedural animation, real-time modification. Change vertices on CPU, upload the changes.

- **The pattern of access is unknown in advance.** Interactive applications where user actions determine which buffers need CPU access.

- **Memory isn't the primary constraint.** Shadows double memory for buffers that use them. If you can afford it, the flexibility is valuable.

---

## Side-by-Side Comparison

| Aspect | Charging | Shadow Buffers |
|--------|----------|----------------|
| **Direction** | CPU → GPU, one-way | CPU ↔ GPU, bidirectional |
| **CPU data after upload** | Deleted when safe | Retained on demand |
| **Memory optimization** | Aggressive—shed weight early | Lazy—allocate only when needed |
| **Tracking mechanism** | RefCount vs ChargeCount | Nullable shadow reference |
| **Typical use case** | Demoscene, mobile, games | Creative coding, tools, interactive |
| **Best for** | Generated content, clear phases | Dynamic content, unknown access patterns |
| **Explicit operations** | `Charge()` | `download()`, `upload()` |
| **Handles GPU → CPU** | No (not designed for it) | Yes (`download()`) |
| **Memory cost** | Zero after charging | Double for shadowed buffers |

The patterns optimize for opposite ends of a spectrum. Charging minimizes memory by discarding. Shadows maximize flexibility by preserving.

---

## Combining the Patterns

These patterns are complementary. A sophisticated resource system could offer both.

Consider a hypothetical combined API:

```rust
// Configuration at resource creation
let mesh = Mesh::new()
    .vertices(vertex_data)
    .charging(ChargingPolicy::WhenAllUsersReady)  // Enable charging
    .shadow(ShadowPolicy::OnDemand);              // Enable lazy shadows

// Usage pattern 1: Pure rendering (like Farbrausch)
mesh.charge();  // Upload to GPU, potentially free CPU data

// Usage pattern 2: Read back results (like OpenRNDR)
let shadow = mesh.shadow();  // Lazy allocate if needed
shadow.download();           // GPU → CPU
let positions = shadow.vertices();

// Usage pattern 3: Dynamic modification
shadow.modify_vertex(index, new_position);
shadow.upload();  // CPU → GPU
```

The key insight: charging answers "when can I free CPU data?" while shadows answer "how do I access GPU data from CPU?" These are different questions with different answers.

A combined system would track:

1. **Do any users still need CPU data?** (Charging's concern)
2. **Does anyone need CPU access to GPU data?** (Shadow's concern)

If no one needs CPU data AND no one has requested a shadow, free the CPU memory. If someone requests a shadow later, reallocate it (or reload from the original source).

```rust
struct ResourceState {
    gpu_buffer: Buffer,
    cpu_data: Option<Vec<u8>>,       // Original CPU data
    shadow: Option<Shadow>,          // Lazily allocated mirror
    charge_count: u32,
    ref_count: u32,
    shadow_requested: bool,
}

impl ResourceState {
    fn maybe_free_cpu_data(&mut self) {
        // Charging logic
        let all_charged = self.ref_count - self.charge_count == 1;
        // But don't free if shadow exists—someone might need it
        let shadow_prevents = self.shadow.is_some();

        if all_charged && !shadow_prevents {
            self.cpu_data = None;
        }
    }

    fn shadow(&mut self) -> &mut Shadow {
        if self.shadow.is_none() {
            // Lazy allocation
            self.shadow = Some(Shadow::new(self.gpu_buffer.size()));
            // Download current GPU state into shadow
            self.shadow.as_mut().unwrap().download(&self.gpu_buffer);
        }
        self.shadow.as_mut().unwrap()
    }
}
```

---

## Implications for Flux

The Rust creative coding framework under development can learn from both patterns.

### Adopt Lazy Shadow Allocation

OpenRNDR's approach is the right default for creative coding. Most buffers don't need CPU access; those that do should get shadows on demand. Rust's type system can make this ergonomic:

```rust
impl Buffer {
    /// Returns a shadow for CPU access, allocating if necessary.
    pub fn shadow(&self) -> &BufferShadow {
        self.shadow.get_or_init(|| BufferShadow::new(self.size))
    }

    /// Returns the shadow if it exists, without allocating.
    pub fn shadow_if_exists(&self) -> Option<&BufferShadow> {
        self.shadow.get()
    }
}
```

The `OnceCell` pattern naturally expresses lazy allocation in Rust.

### Consider Charging for Procedural Content

Flux's node graph may generate substantial procedural content. For nodes that produce static geometry—computed once during graph evaluation—charging-style cleanup makes sense:

```rust
impl ProceduralMeshNode {
    fn evaluate(&mut self, ctx: &mut EvalContext) -> MeshHandle {
        let mesh = self.generate_mesh();
        let handle = ctx.upload_to_gpu(mesh);

        // In player mode, CPU data is no longer needed
        if ctx.is_player_mode() {
            // The handle keeps GPU data alive; CPU data can go
            handle.release_cpu_data();
        }

        handle
    }
}
```

The distinction between "editor mode" (keep CPU data for inspection and modification) and "player mode" (shed weight for performance) mirrors Farbrausch's approach.

### Provide Explicit Control

Both patterns give users explicit control over expensive operations. Neither silently moves data. This explicitness is valuable:

```rust
// User explicitly requests GPU → CPU sync
let shadow = render_target.shadow();
shadow.download();

// User explicitly requests CPU → GPU sync
shadow.upload();

// User explicitly releases CPU data
mesh.release_cpu_data();
```

Implicit synchronization hides costs and makes performance unpredictable. Creative coders need to understand where frame time goes.

### Document the Tradeoffs

The choice between patterns depends on use case. Flux's documentation should explain when to use each:

- **Procedural generation (one-time):** Enable charging, skip shadows
- **Dynamic geometry (every frame):** Keep shadows, skip charging
- **Render targets for readback:** Enable shadows on demand
- **Static meshes in player mode:** Enable aggressive charging

Making these tradeoffs visible helps users optimize for their specific needs.

---

## Conclusion

Charging and shadow buffers solve different problems in the CPU-GPU relationship. Charging asks "when can I forget?" and answers aggressively—as soon as everyone has what they need, shed the weight. Shadows ask "how do I remember?" and answer lazily—maintain mirrors only for those who request them.

The demoscene's extreme constraints birthed charging. Creative coding's experimental nature birthed shadows. Neither is better; they're optimized for different worlds.

A modern framework can offer both. The key is making the choice explicit: users should understand what data lives where, and when expensive operations occur. With that transparency, the patterns become tools rather than mysteries—applied deliberately to achieve specific goals.

For Flux, the recommendation is clear: lazy shadows as the default (creative coding's flexibility), with charging available for procedural content in performance-critical paths (demoscene's efficiency). The best of both worlds, applied where each excels.

---

## Related Documents

- [farbrausch.md](per-framework/farbrausch.md) — Complete analysis of Farbrausch's resource patterns
- [openrndr.md](per-framework/openrndr.md) — OpenRNDR's shadow and caching systems
- [reclamation-timing.md](reclamation-timing.md) — When to free GPU resources
- [flux-recommendations.md](flux-recommendations.md) — Concrete recommendations for Flux
