# PixiJS WebGPU Renderer Study

> Analyzing PixiJS's WebGPU rendering pipeline for potential wgpu patterns

## Why Study PixiJS?

PixiJS is one of the most battle-tested 2D renderers in the JavaScript ecosystem, with a recent WebGPU backend. Key aspects worth studying:

1. **Sophisticated Batching** - Automatic batching with texture/blend/topology awareness
2. **Pipeline Caching** - Composite state keys for pipeline reuse
3. **Instruction-Based Rendering** - Deferred command generation
4. **Clean WebGPU Abstraction** - Maps well to wgpu concepts

## Document Structure

| Document | Focus | wgpu Relevance |
|----------|-------|----------------|
| [architecture.md](architecture.md) | High-level system overview | Overall design patterns |
| [batching.md](batching.md) | Batching strategy and implementation | Draw call optimization |
| [pipeline-caching.md](pipeline-caching.md) | State-based pipeline management | Pipeline creation/reuse |
| [encoder-system.md](encoder-system.md) | Command encoding and submission | CommandEncoder patterns |
| [bind-groups.md](bind-groups.md) | Texture batching via bind groups | BindGroup management |
| [graphics-api.md](graphics-api.md) | Path/shape to geometry conversion | Graphics primitives |

## Key Source Files

```
libraries/pixijs/src/rendering/
├── renderers/gpu/
│   ├── WebGPURenderer.ts        # Main renderer, system composition
│   ├── GpuEncoderSystem.ts      # Command encoder management
│   └── pipeline/
│       └── PipelineSystem.ts    # Pipeline caching
├── batcher/
│   ├── gpu/
│   │   ├── GpuBatchAdaptor.ts   # WebGPU batch execution
│   │   └── generateGPULayout.ts # Bind group layouts
│   └── shared/
│       └── Batcher.ts           # Core batching logic
└── ...

libraries/pixijs/src/scene/
├── graphics/
│   ├── gpu/
│   │   └── GpuGraphicsAdaptor.ts # Graphics rendering
│   └── shared/
│       ├── Graphics.ts          # Graphics API
│       └── GraphicsPipe.ts      # Graphics-to-batch pipe
└── container/
    └── RenderGroupPipe.ts       # Scene graph integration
```

## wgpu Concept Mapping

| PixiJS | wgpu | Notes |
|--------|------|-------|
| `GpuEncoderSystem` | `CommandEncoder` | Command recording |
| `renderPassEncoder` | `RenderPass` | Draw call execution |
| `PipelineSystem` | `RenderPipeline` cache | State-based caching |
| `BindGroupSystem` | `BindGroup` management | Resource binding |
| `GpuBufferSystem` | `Buffer` management | Vertex/index/uniform |
| `GpuTextureSystem` | `Texture` + `TextureView` | Texture resources |
| `Batch` instruction | Draw call parameters | Batched draw info |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         WebGPURenderer                               │
├─────────────────────────────────────────────────────────────────────┤
│  Systems (12+)                                                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │ GpuEncoder  │ │  Pipeline   │ │ GpuBuffer   │ │ GpuTexture  │   │
│  │   System    │ │   System    │ │   System    │ │   System    │   │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │  BindGroup  │ │  GpuState   │ │  GpuShader  │ │   GpuUbo    │   │
│  │   System    │ │   System    │ │   System    │ │   System    │   │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │
├─────────────────────────────────────────────────────────────────────┤
│  Render Pipes                                                        │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                    │
│  │ BatcherPipe │ │GraphicsPipe │ │RenderGroup  │                    │
│  │             │ │             │ │    Pipe     │                    │
│  └─────────────┘ └─────────────┘ └─────────────┘                    │
├─────────────────────────────────────────────────────────────────────┤
│  Adaptors (GPU-specific execution)                                   │
│  ┌─────────────┐ ┌─────────────┐                                    │
│  │GpuBatch     │ │GpuGraphics  │                                    │
│  │  Adaptor    │ │  Adaptor    │                                    │
│  └─────────────┘ └─────────────┘                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Render Loop Flow

```
render(scene)
    │
    ├─► prerender         Setup frame
    ├─► renderStart       Create CommandEncoder
    ├─► render            Build InstructionSet
    │   │
    │   ├─► Traverse scene graph
    │   ├─► Pipes add renderables to batchers
    │   ├─► Batchers accumulate geometry
    │   └─► Break batches → Batch instructions
    │
    ├─► renderEnd         Execute instructions
    │   │
    │   ├─► For each Batch:
    │   │   ├─► setGeometry()
    │   │   ├─► setPipeline()
    │   │   ├─► setBindGroup()
    │   │   └─► drawIndexed()
    │   │
    │   └─► End render pass
    │
    └─► postrender        queue.submit()
```

## Key Patterns to Extract

1. **Instruction Set Pattern** - Deferred rendering via instruction objects
2. **Composite State Keys** - Multi-field pipeline cache keys
3. **Texture Batch Bind Groups** - Grouping textures into bind groups
4. **Dirty Flag Optimization** - Skip redundant GPU state changes
5. **FNV-1a Hashing** - Fast cache key generation for bind groups
