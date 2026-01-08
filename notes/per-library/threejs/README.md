# Three.js WebGPU Renderer Study

> Analyzing Three.js's WebGPU rendering pipeline for potential wgpu patterns

## Why Study Three.js WebGPU?

Three.js has a mature WebGPU renderer with several patterns relevant to wgpu:

1. **Backend Abstraction** - Clean separation of renderer logic from GPU-specific code
2. **Node-Based Shaders (TSL)** - Compile shader graphs to WGSL
3. **RenderObject Pattern** - Per-object render state management
4. **Pipeline Caching** - Cache key generation for pipelines
5. **Compute Shader Support** - First-class compute pipeline handling

## Document Structure

| Document | Focus | wgpu Relevance |
|----------|-------|----------------|
| [rendering-pipeline.md](rendering-pipeline.md) | High-level render loop | Overall architecture |
| [webgpu-backend.md](webgpu-backend.md) | WebGPU-specific implementation | Direct wgpu mapping |
| [pipeline-bindings.md](pipeline-bindings.md) | Pipeline and bind group management | Resource binding |
| [node-system.md](node-system.md) | TSL shader compilation | Shader graph patterns |

## Architecture Overview

Three.js uses a **backend abstraction pattern** that separates high-level rendering logic from GPU-specific code:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        WebGPURenderer                                │
│  (thin wrapper, configures backend + node library)                  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Renderer                                    │
│  (common/Renderer.js - 89KB of shared logic)                        │
├─────────────────────────────────────────────────────────────────────┤
│  • Scene traversal and render list building                         │
│  • Frustum culling                                                   │
│  • Opaque/transparent sorting                                        │
│  • RenderObject management                                           │
│  • Animation, lighting, post-processing                             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Backend (abstract)                           │
│  (common/Backend.js - interface for GPU backends)                   │
├─────────────────────────────────────────────────────────────────────┤
│  • init()                    • createProgram()                       │
│  • beginRender()             • createRenderPipeline()               │
│  • finishRender()            • createComputePipeline()              │
│  • draw()                    • createBindings()                      │
│  • compute()                 • updateBindings()                      │
└─────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│     WebGPUBackend       │     │    WebGLBackend         │
│  (webgpu/WebGPUBackend) │     │  (webgl-fallback/)      │
├─────────────────────────┤     ├─────────────────────────┤
│  • GPUDevice            │     │  • WebGL2Context        │
│  • CommandEncoder       │     │  • Shader compilation   │
│  • RenderPass           │     │  • GL state management  │
│  • WGSL shaders         │     │  • GLSL shaders         │
└─────────────────────────┘     └─────────────────────────┘
```

## Key Source Files

```
libraries/threejs/src/renderers/
├── common/                          # Shared renderer infrastructure
│   ├── Renderer.js                  # Main renderer (89KB)
│   ├── Backend.js                   # Abstract backend interface
│   ├── Pipelines.js                 # Pipeline caching
│   ├── Bindings.js                  # Bind group management
│   ├── RenderObject.js              # Per-object render state
│   ├── RenderList.js                # Render list sorting
│   ├── RenderContext.js             # Render pass context
│   └── nodes/
│       ├── Nodes.js                 # Node system integration
│       └── NodeLibrary.js           # Node type mapping
│
├── webgpu/                          # WebGPU-specific code
│   ├── WebGPURenderer.js            # Entry point
│   ├── WebGPUBackend.js             # Backend implementation (67KB)
│   ├── nodes/
│   │   ├── WGSLNodeBuilder.js       # Node → WGSL compiler (66KB)
│   │   └── StandardNodeLibrary.js   # Material node mappings
│   └── utils/
│       ├── WebGPUPipelineUtils.js   # Pipeline creation
│       ├── WebGPUBindingUtils.js    # Bind group creation
│       ├── WebGPUAttributeUtils.js  # Vertex buffer setup
│       └── WebGPUTextureUtils.js    # Texture management
│
└── webgl-fallback/                  # WebGL 2 fallback backend
    └── WebGLBackend.js
```

## wgpu Concept Mapping

| Three.js | wgpu | Notes |
|----------|------|-------|
| `Backend` | Trait/interface | Abstract GPU operations |
| `WebGPUBackend` | `wgpu::Device` + helpers | WebGPU implementation |
| `Renderer` | Render loop coordinator | Scene traversal, sorting |
| `RenderObject` | Per-draw state bundle | Material + geometry + context |
| `Pipelines` | `RenderPipeline` cache | Cache by render state key |
| `Bindings` | `BindGroup` management | Resource binding |
| `RenderContext` | Render pass state | Attachments, clear values |
| `WGSLNodeBuilder` | Shader compiler | Node graph → WGSL |

## Render Loop Flow

```
renderer.render(scene, camera)
    │
    ├─► Update world matrices
    ├─► Build render lists (opaque + transparent)
    │   └─► Frustum culling
    │   └─► Sort by material/depth
    │
    ├─► backend.beginRender(renderContext)
    │   └─► Create CommandEncoder
    │   └─► Begin RenderPass
    │
    ├─► For each render item:
    │   ├─► Get/create RenderObject
    │   ├─► Get/create Pipeline (cached by state)
    │   ├─► Update Bindings (uniforms, textures)
    │   └─► backend.draw(renderObject)
    │       └─► setPipeline()
    │       └─► setBindGroup()
    │       └─► setVertexBuffer()
    │       └─► draw() / drawIndexed()
    │
    └─► backend.finishRender(renderContext)
        └─► End RenderPass
        └─► queue.submit()
```

## Key Patterns to Extract

1. **Backend Abstraction** - Separate GPU-agnostic logic from backend-specific code
2. **RenderObject** - Bundle all per-draw state for efficient lookup
3. **Pipeline Cache Keys** - Generate unique keys from render state
4. **Node-Based Shaders** - Compile shader graphs to GPU code
5. **Render Context** - Encapsulate render pass configuration
6. **DataMap Pattern** - WeakMap-based caching for GPU resources

## Node System (TSL)

Three.js uses a node-based shader system called TSL (Three Shading Language):

```javascript
// TSL example - compiles to WGSL
import { uniform, vec3, mix } from 'three/tsl';

const colorA = uniform(new Color(0xff0000));
const colorB = uniform(new Color(0x0000ff));
const mixFactor = uniform(0.5);

material.colorNode = mix(colorA, colorB, mixFactor);
```

This compiles to WGSL via `WGSLNodeBuilder`.

## Study Questions

- [x] How does the backend abstraction work?
- [ ] How are pipelines cached and invalidated?
- [ ] How does RenderObject manage per-draw state?
- [ ] How does WGSLNodeBuilder compile node graphs to WGSL?
- [ ] How are bind groups structured and updated?
- [ ] How does the render bundle system work?

## Related Documents

- [Rendering Pipeline](./rendering-pipeline.md)
- [WebGPU Backend](./webgpu-backend.md)
- [Pipeline & Bindings](./pipeline-bindings.md)
- [Node System (TSL)](./node-system.md)
