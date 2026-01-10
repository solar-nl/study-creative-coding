# PixiJS Pipeline Caching

> What if you could turn billions of possible cache keys into a handful of fast lookups?

## Key Insight

> **Pipeline caching's core idea:** Use a two-tier cache where rarely-changing global state (render target, stencil) selects which per-draw-call cache to search, making lookups fast and preventing cross-context pollution.

---

## The Problem: Pipeline Creation Is Expensive

Creating a GPU render pipeline is one of the most expensive operations in WebGPU. It involves compiling shaders, validating state combinations, and allocating GPU resources. You definitely do not want to do this every frame.

The obvious solution is caching: create each unique pipeline once, then reuse it. But "unique" is the tricky part. What combination of factors requires a different pipeline?

The answer is: quite a lot. Shader code, vertex buffer layout, blend mode, depth/stencil configuration, render target format, multisampling. Change any of these, and you need a different pipeline.

Now here is the catch. These factors do not all change at the same rate. Some change frequently (which shader are we using? what blend mode?). Others change rarely (is multisampling enabled? what is our stencil configuration?). And this observation leads to an elegant optimization.

---

## The Mental Model: A Library Catalog System

Think of pipeline caching like organizing a library's book catalog.

A naive approach would be one giant index of every book: "Building A, Floor 3, Section History, Shelf 12, Book 'Roman Empire'". Every lookup requires checking all five attributes. Every new book means updating one massive index.

But libraries are smarter than that. They use hierarchical organization:

```
Building A
├── Floor 1
│   ├── Fiction Section
│   │   ├── Shelf 1 → [Books...]
│   │   └── Shelf 2 → [Books...]
│   └── Non-Fiction Section
│       └── Shelf 1 → [Books...]
└── Floor 2
    └── Reference Section
        └── Shelf 1 → [Books...]
```

When you change buildings, you switch to an entirely different catalog. But once you are in the right building and floor, finding a specific shelf is fast because you are searching a smaller subset.

PixiJS applies this same insight to pipeline caching. It separates state into two tiers:

- **Tier 1 (Global State)**: The "building and floor" - render target configuration, stencil mode, multisampling. These change rarely, usually only when switching render targets.
- **Tier 2 (Graphics State)**: The "section and shelf" - shader, geometry layout, blend mode, topology. These change per draw call.

When global state changes, PixiJS switches to a different tier-2 cache. Within that cache, graphics state lookups are fast because they only search pipelines that share the same global configuration.

---

## How the Two-Tier Cache Works

Let's look at what actually goes into each tier.

### Tier 1: Global State (Changes Rarely)

Global state encompasses the "environment" of rendering. It includes:

| Factor | Bits | What It Controls |
|--------|------|------------------|
| Color mask | 4 | Which RGBA channels to write |
| Stencil mode | 3 | Stencil test configuration |
| Render target | 2 | Depth/stencil attachment presence |
| Color target count | 2 | Number of render targets (MRT) |
| Multisample | 1 | MSAA enabled or not |

The bit widths reflect each factor's range: 4 bits for color mask because there are 4 channels (RGBA), 3 bits for stencil because there are 8 stencil operations, 1 bit for multisample because it is just on or off.

These 12 bits create 4096 possible global configurations. In practice, most applications use far fewer. A typical game might use 3-5: the main framebuffer, a shadow pass, maybe a reflection pass.

### Tier 2: Graphics State (Changes Per Draw)

Graphics state captures what makes each draw call unique:

| Factor | Bits | What It Controls |
|--------|------|------------------|
| Geometry layout | 8 | Vertex buffer structure |
| Shader key | 8 | Which shader program |
| State flags | 6 | Depth test, write enables, etc. |
| Blend mode | 5 | How pixels combine |
| Topology | 3 | Points, lines, or triangles |

Again, the bit widths match practical limits: 8 bits for shader keys allows 256 unique shaders per global state, 5 bits for blend mode covers WebGPU's ~30 blend modes, 3 bits for topology handles the 5 primitive types with room to spare.

These 30 bits theoretically allow billions of combinations, but within a single global configuration, the actual number is manageable.

---

## The Cache Structure

Here is where it gets interesting. PixiJS does not use a single flat cache. It maintains a map of maps:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Tier 1: Global State → Tier 2 Cache                                │
│                                                                      │
│  globalKey=0 (main framebuffer, no stencil, MSAA off)               │
│      └─► { graphicsKey → pipeline, graphicsKey → pipeline, ... }    │
│                                                                      │
│  globalKey=1 (shadow pass, depth only)                              │
│      └─► { graphicsKey → pipeline, graphicsKey → pipeline, ... }    │
│                                                                      │
│  globalKey=2 (stencil masking active)                               │
│      └─► { graphicsKey → pipeline, ... }                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

The clever part is the pointer optimization. The system maintains a `_pipeCache` pointer that always references the current tier-2 cache. When global state changes, this pointer is updated. When looking up pipelines, only the pointer is used - no tier-1 lookup needed.

---

## Walking Through a Render Frame

Let us trace what happens during a typical frame:

**1. Frame begins, main framebuffer bound**

The system calculates the global key (say, 0 for standard rendering). It sets `_pipeCache` to point at the tier-2 cache for global key 0.

**2. Draw a sprite with normal blend mode**

The system calculates the graphics key from shader, geometry, blend mode, and topology. It checks `_pipeCache[graphicsKey]`. Cache hit - return the existing pipeline.

**3. Draw a sprite with additive blend mode**

Different blend mode means different graphics key. Check `_pipeCache[newKey]`. Perhaps a miss this time. Create the pipeline, store it, return it.

**4. Switch to a stencil-masked region**

Global state changed. Calculate new global key (say, 2 for stencil active). Update `_pipeCache` pointer to the stencil tier-2 cache. Now all subsequent lookups search only pipelines compatible with stencil mode.

**5. Draw inside the mask**

Back to per-draw lookups, but now in the stencil-specific cache. Any pipelines created here are automatically associated with stencil rendering.

**6. Exit stencil region, back to normal rendering**

Global key returns to 0. `_pipeCache` pointer switches back. All our previously cached main-framebuffer pipelines are still there.

---

## The Key Generation Functions

### Global State Key (12 bits)

```typescript
function getGlobalStateKey(
    stencilStateId: number,   // 3 bits
    multiSampleCount: number, // 1 bit
    colorMask: number,        // 4 bits
    renderTarget: number,     // 2 bits
    colorTargetCount: number, // 2 bits
): number {
    return (colorMask << 8)
         | (stencilStateId << 5)
         | (renderTarget << 3)
         | (colorTargetCount << 1)
         | multiSampleCount;
}
```

### Graphics State Key (30 bits)

```typescript
function getGraphicsStateKey(
    geometryLayout: number,   // 8 bits
    shaderKey: number,        // 8 bits
    state: number,            // 6 bits
    blendMode: number,        // 5 bits
    topology: number,         // 3 bits
): number {
    return (geometryLayout << 24)
         | (shaderKey << 16)
         | (state << 10)
         | (blendMode << 5)
         | topology;
}
```

Both functions use bit shifting to pack multiple fields into a single integer. This is key to performance: integer comparison is one CPU instruction. No string parsing, no hash table overhead - just a direct map lookup.

---

## The Pipeline Cache Implementation

Here is the core cache logic. Notice how `_pipeCache` acts as a pointer to the current tier-2 cache:

```typescript
class PipelineSystem {
    // Tier 1: Global state → Tier 2 cache
    private _pipeStateCaches: Record<number, PipeHash> = {};

    // Pointer to current tier 2 cache
    private _pipeCache: PipeHash = {};

    getPipeline(geometry, program, state, topology): GPURenderPipeline {
        const key = getGraphicsStateKey(
            geometry._layoutKey,
            program._layoutKey,
            state.data,
            state._blendModeId,
            topologyStringToId[topology]
        );

        // Fast path: check current cache
        if (this._pipeCache[key]) {
            return this._pipeCache[key];
        }

        // Miss: create and cache
        this._pipeCache[key] = this._createPipeline(geometry, program, state, topology);
        return this._pipeCache[key];
    }

    // Called when render target or stencil mode changes
    private _updatePipeHash() {
        const key = getGlobalStateKey(
            this._stencilMode,
            this._multisampleCount,
            this._colorMask,
            this._depthStencilAttachment,
            this._colorTargetCount
        );

        // Create tier 2 cache if needed
        if (!this._pipeStateCaches[key]) {
            this._pipeStateCaches[key] = {};
        }

        // Switch pointer to new cache
        this._pipeCache = this._pipeStateCaches[key];
    }
}
```

The visualization of this flow:

```
Global State Changes (setRenderTarget, setStencilMode, etc.)
    │
    ▼
_updatePipeHash() ──► Switch _pipeCache pointer
    │
    ▼
getPipeline(geometry, program, state, topology)
    │
    ▼
Check _pipeCache[graphicsKey]
    │
    ├─── Hit ───► Return cached pipeline
    │
    └─── Miss ──► Create, cache, return
```

---

## Additional Caching Layers

PixiJS does not stop at pipelines. Shader modules and buffer layouts are also cached.

### Shader Module Cache

Shader compilation is expensive. Modules are cached by source code:

```typescript
private _moduleCache: Record<string, GPUShaderModule> = {};

private _getModule(code: string): GPUShaderModule {
    return this._moduleCache[code] || this._createModule(code);
}
```

### Buffer Layout Cache

Vertex buffer layouts are cached by geometry-program combination:

```typescript
private _bufferLayoutsCache: Record<number, GPUVertexBufferLayout[]> = {};

private _createVertexBufferLayouts(geometry, program): GPUVertexBufferLayout[] {
    const key = (geometry._layoutKey << 16) | program._attributeLocationsKey;

    if (this._bufferLayoutsCache[key]) {
        return this._bufferLayoutsCache[key];
    }

    // Generate layouts...
    this._bufferLayoutsCache[key] = layouts;
    return layouts;
}
```

These caches feed into pipeline creation. When a pipeline cache miss occurs, these sub-caches often provide hits, making pipeline creation faster than it would be from scratch.

---

## Pipeline Creation (On Cache Miss)

When no cached pipeline exists, PixiJS assembles the full descriptor. Notice how it pulls from various caches and systems:

```typescript
private _createPipeline(geometry, program, state, topology): GPURenderPipeline {
    const descriptor: GPURenderPipelineDescriptor = {
        vertex: {
            module: this._getModule(program.vertex.source),    // From shader cache
            entryPoint: program.vertex.entryPoint,
            buffers: this._createVertexBufferLayouts(geometry, program),  // From layout cache
        },
        fragment: {
            module: this._getModule(program.fragment.source),  // From shader cache
            entryPoint: program.fragment.entryPoint,
            targets: this._renderer.state.getColorTargets(state, this._colorTargetCount),
        },
        primitive: {
            topology,
            cullMode: state.cullMode,
        },
        layout: this._renderer.shader.getProgramData(program).pipeline,
        multisample: {
            count: this._multisampleCount,
        },
        label: 'PIXI Pipeline',
    };

    // Add depth/stencil if render target has it
    if (this._depthStencilAttachment) {
        descriptor.depthStencil = {
            ...this._stencilState,
            format: 'depth24plus-stencil8',
            depthWriteEnabled: state.depthTest,
            depthCompare: state.depthTest ? 'less' : 'always',
        };
    }

    return device.createRenderPipeline(descriptor);
}
```

---

## wgpu Implementation

The Rust/wgpu version follows the same structure. The main difference is using `HashMap` instead of JavaScript objects:

```rust
use std::collections::HashMap;

struct PipelineCache {
    // Tier 1: global state → tier 2 cache
    global_caches: HashMap<u32, HashMap<u32, wgpu::RenderPipeline>>,
    // Current tier 2 cache key
    current_cache: u32,
}

impl PipelineCache {
    fn get_pipeline(
        &mut self,
        device: &wgpu::Device,
        geometry: &Geometry,
        shader: &Shader,
        state: &State,
        topology: wgpu::PrimitiveTopology,
    ) -> &wgpu::RenderPipeline {
        let graphics_key = Self::graphics_key(geometry, shader, state, topology);

        let cache = self.global_caches
            .get_mut(&self.current_cache)
            .unwrap();

        // entry() provides get-or-insert semantics
        cache.entry(graphics_key).or_insert_with(|| {
            Self::create_pipeline(device, geometry, shader, state, topology)
        })
    }

    fn set_global_state(&mut self, stencil: u8, msaa: u8, color_mask: u8, depth: u8) {
        let key = Self::global_key(stencil, msaa, color_mask, depth);

        if !self.global_caches.contains_key(&key) {
            self.global_caches.insert(key, HashMap::new());
        }

        self.current_cache = key;
    }

    fn graphics_key(
        geometry: &Geometry,
        shader: &Shader,
        state: &State,
        topology: wgpu::PrimitiveTopology,
    ) -> u32 {
        let topo_id = match topology {
            wgpu::PrimitiveTopology::PointList => 0,
            wgpu::PrimitiveTopology::LineList => 1,
            wgpu::PrimitiveTopology::LineStrip => 2,
            wgpu::PrimitiveTopology::TriangleList => 3,
            wgpu::PrimitiveTopology::TriangleStrip => 4,
        };

        (geometry.layout_key as u32) << 24
            | (shader.layout_key as u32) << 16
            | (state.data as u32) << 10
            | (state.blend_mode as u32) << 5
            | topo_id
    }

    fn global_key(stencil: u8, msaa: u8, color_mask: u8, depth: u8) -> u32 {
        ((color_mask as u32) << 8)
            | ((stencil as u32) << 5)
            | ((depth as u32) << 3)
            | (msaa as u32)
    }
}
```

The Rust version benefits from the `entry()` API, which atomically handles the get-or-insert pattern. In JavaScript, this requires an explicit check-and-insert.

---

## Why This Design Works

The two-tier approach provides several benefits:

**1. Fast common-case lookups**

Most draw calls within a frame share the same global state. They only need to check the current tier-2 cache, which contains only pipelines relevant to that state. No filtering needed.

**2. Memory efficiency**

Pipelines are grouped by compatibility. You never accidentally cache duplicate pipelines for different global states that happen to share a graphics key.

**3. Cache locality**

When rendering switches to a stencil pass and back, the main-pass pipelines are still warm. No re-creation needed.

**4. Predictable memory usage**

The number of tier-2 caches is bounded by the 12-bit global key space (4096 max). In practice, it is much smaller. You can reason about memory usage.

---

## Performance Impact

Consider a frame with 1000 sprites, 5 different shaders, 3 blend modes, rendering to 2 targets (main + shadow):

**Without tiered caching (flat cache):**
- Cache key includes all factors
- Every lookup searches all cached pipelines
- Duplicate pipelines possible for same shader/blend but different targets

**With tiered caching:**
- 2 tier-2 caches (one per render target)
- Each cache contains only pipelines for that target
- Lookups are local to current rendering context
- After warmup, 100% cache hit rate

The key insight: in real applications, pipeline reuse is extremely high. Most frames use identical pipelines to the previous frame. The two-tier structure optimizes for this reality.

---

## Connections to Other Systems

Pipeline caching interacts with several other PixiJS systems:

- **Encoder System** ([encoder-system.md](encoder-system.md)): Caches the currently bound pipeline to skip redundant `setPipeline()` calls
- **Bind Groups** ([bind-groups.md](bind-groups.md)): Pipeline layouts must match bind group layouts
- **Batching** ([batching.md](batching.md)): Batch breaks occur when pipeline state changes

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/pipeline/PipelineSystem.ts`

---

*Next: [Encoder System](encoder-system.md)*
