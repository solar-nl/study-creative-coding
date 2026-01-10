# PixiJS WebGPU Renderer

> How a battle-tested 2D renderer approaches WebGPU's challenges

---

## Why Study PixiJS?

Building a fast 2D renderer sounds straightforward until you try it. Draw a thousand sprites the naive way - one GPU draw call each - and watch your frame rate collapse. The GPU sits idle while the CPU drowns in overhead.

PixiJS has spent years solving this problem. Originally a WebGL renderer, it recently added a WebGPU backend, giving us something valuable: a mature architecture translated into the modern graphics API we're targeting. Where a greenfield WebGPU renderer might make rookie mistakes, PixiJS brings decade-long wisdom about what actually matters for 2D performance.

Three patterns make PixiJS particularly worth studying:

**Automatic batching.** PixiJS examines your scene and groups compatible draw calls automatically. Sprites that share compatible textures, blend modes, and topology get merged into a single GPU call. This transforms thousands of conceptual draws into a handful of actual GPU commands.

Here's what happens when you render three sprites with the same texture:

1. The batcher sees Sprite A (texture atlas, additive blend, triangle list)
2. Sprite B arrives - same texture, same blend mode - batcher appends to current batch
3. Sprite C matches too - appended again
4. At flush time: one draw call renders all three sprites

**Deferred rendering.** Rather than issuing GPU commands immediately, PixiJS builds an instruction set first, then executes it. Think of it like a director blocking out an entire scene before calling "action" - you can rearrange, optimize, and merge before committing to the performance. This separation enables sorting and optimization before touching the GPU.

**Aggressive state caching.** Every GPU state change has overhead. PixiJS tracks what's already bound and skips redundant calls, reducing CPU work and command buffer bloat.

These aren't PixiJS-specific tricks. They're general patterns that any performant 2D renderer needs. PixiJS just happens to implement them clearly in a codebase we can study.

---

## Document Structure

Each document explores a specific aspect of the WebGPU renderer:

| Document | Focus |
|----------|-------|
| [architecture.md](architecture.md) | System composition and the instruction-based render loop |
| [batching.md](batching.md) | How sprites are grouped into minimal draw calls |
| [pipeline-caching.md](pipeline-caching.md) | Two-tier caching to avoid expensive pipeline creation |
| [encoder-system.md](encoder-system.md) | Command encoding with state change optimization |
| [bind-groups.md](bind-groups.md) | Resource binding with FNV-1a cache key hashing |
| [graphics-api.md](graphics-api.md) | The canvas-like API for vector drawing |

---

## Mapping PixiJS to wgpu

One of our goals is translating these patterns to Rust/wgpu. Here's how PixiJS concepts map:

| PixiJS | wgpu | Role |
|--------|------|------|
| `GpuEncoderSystem` | `CommandEncoder` | Records GPU commands |
| `renderPassEncoder` | `RenderPass` | Scopes a set of draw calls |
| `PipelineSystem` | `RenderPipeline` cache | Manages compiled pipeline states |
| `BindGroupSystem` | `BindGroup` management | Binds textures and buffers to shaders |
| `GpuBufferSystem` | `Buffer` management | Handles vertex, index, and uniform data |
| `Batch` instruction | Draw call parameters | Batched geometry ready for GPU |

---

## Source Navigation

The WebGPU renderer lives in the rendering subsystem:

```
libraries/pixijs/src/rendering/
├── renderers/gpu/
│   ├── WebGPURenderer.ts        # Main entry point, composes systems
│   ├── GpuEncoderSystem.ts      # Command encoding with state caching
│   └── pipeline/
│       └── PipelineSystem.ts    # Pipeline creation and caching
├── batcher/
│   ├── gpu/
│   │   └── GpuBatchAdaptor.ts   # Executes batches on WebGPU
│   └── shared/
│       └── Batcher.ts           # Core batching algorithm
```

The scene/graphics folder handles the canvas-like drawing API:

```
libraries/pixijs/src/scene/
├── graphics/
│   ├── gpu/
│   │   └── GpuGraphicsAdaptor.ts
│   └── shared/
│       └── Graphics.ts          # The user-facing API
```

---

## Key Patterns at a Glance

Five patterns recur throughout this codebase:

1. **Instruction Set** - Build a list of what to draw, then execute it
2. **Composite State Keys** - Combine multiple fields into a single cache key for pipeline lookup
3. **Texture Batching** - Group textures into bind groups, index them in the shader
4. **Dirty Flag Optimization** - Track what's changed, skip what hasn't
5. **FNV-1a Hashing** - Fast, collision-resistant hash function for cache keys

Each document explores one or more of these in depth.

---

## What's Next

Start with [Architecture](architecture.md) for the big picture - it covers how the systems compose together and introduces the instruction-based render loop. If draw call optimization is your primary focus, jump directly to [Batching](batching.md) to see how PixiJS merges thousands of sprites into minimal GPU commands.

For those implementing their own renderer, the [Pipeline Caching](pipeline-caching.md) and [Bind Groups](bind-groups.md) documents show specific techniques you can adapt to wgpu.
