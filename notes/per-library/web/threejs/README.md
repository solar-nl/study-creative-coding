# [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) WebGPU Renderer Study

> How a JavaScript framework manages the complexity of two GPU backends without losing its mind

---

## Why Study [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) WebGPU?

The problem is not new, but the stakes are higher than ever. WebGPU is here, but WebGL is not going anywhere. Millions of devices still need the older API. If you are building a rendering engine today, you face a painful choice: maintain two separate codebases that slowly diverge, or find a way to share logic without drowning in abstraction.

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) chose the second path. Their WebGPU renderer is not a fork or a rewrite. It shares 89KB of core rendering logic with their WebGL fallback. The same scene traversal, the same frustum culling, the same render list sorting. Only the GPU communication layer differs.

This is the pattern we want to extract. Not the JavaScript details, but the architecture: how do you structure a renderer so that GPU-specific code stays isolated while high-level rendering logic remains unified? How do you cache pipelines, manage bindings, and compile shaders in a way that works across backends?

If you are building a [wgpu](https://github.com/gfx-rs/wgpu)-based engine that might someday target multiple backends, or if you simply want to understand how a mature production renderer handles this complexity, [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) offers a compelling case study.

---

## The Mental Model: A Universal Translator

Think of the [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) rendering architecture like a diplomatic corps with a universal translator.

The high-level renderer speaks one language. It talks about scenes, cameras, materials, and lights. It understands concepts like frustum culling, depth sorting, and render passes. This is the language of 3D graphics that applies regardless of which GPU API you target.

The GPU backends speak entirely different languages. WebGPU wants command encoders, bind groups, and pipeline layouts. WebGL wants VAOs, uniform blocks, and framebuffer objects. These languages share concepts but differ in syntax, capabilities, and idioms.

Between them sits the backend abstraction. Like a universal translator, it takes high-level rendering intentions and converts them into whatever dialect the current GPU speaks. The renderer says "draw this object." The translator figures out whether that means `setBindGroup()` or `gl.bindVertexArray()`.

The power of this architecture is that most of your code lives at the high level. Scene traversal, sorting algorithms, caching strategies, render list management—all of this is written once and works everywhere. Only the translator layer needs to understand GPU-specific details.

---

## Document Structure

This documentation set traces the [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) WebGPU renderer from high-level concepts down to GPU command generation. Each document focuses on one aspect of the architecture:

**[Rendering Pipeline](rendering-pipeline.md)** explores how a scene graph becomes GPU draw calls. It covers the five-phase render loop, explains why opaque and transparent objects need different sorting, and introduces the RenderObject pattern that makes caching possible. Start here if you want to understand the overall flow.

**[WebGPU Backend](webgpu-backend.md)** dives into the translator layer itself. How does initialization work? What happens during `beginRender()` and `finishRender()`? How are draw calls actually issued? This document traces the path from high-level intent to GPU commands.

**[Pipeline and Bindings](pipeline-bindings.md)** examines two of the trickiest aspects of GPU programming: pipeline caching and resource binding. Creating pipelines is expensive, so how do you cache them effectively? Bind groups are immutable, so how do you handle dynamic data? This document answers both questions.

**[Node System (TSL)](node-system.md)** covers [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js))'s approach to shader compilation. Instead of writing WGSL directly, you build shader graphs using a JavaScript API called TSL (Three Shading Language). The node system compiles these graphs to GPU code. This is particularly interesting for anyone considering a shader graph approach in their own engine.

---

## Architecture Overview

[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) uses a backend abstraction pattern that separates high-level rendering logic from GPU-specific code. The diagram below shows how the layers connect:

```
+---------------------------------------------------------------------+
|                        WebGPURenderer                                |
|  (thin wrapper, configures backend + node library)                  |
+---------------------------------------------------------------------+
                              |
                              v
+---------------------------------------------------------------------+
|                          Renderer                                    |
|  (common/Renderer.js - 89KB of shared logic)                        |
+---------------------------------------------------------------------+
|  Scene traversal and render list building                           |
|  Frustum culling                                                     |
|  Opaque/transparent sorting                                          |
|  RenderObject management                                             |
|  Animation, lighting, post-processing                               |
+---------------------------------------------------------------------+
                              |
                              v
+---------------------------------------------------------------------+
|                         Backend (abstract)                           |
|  (common/Backend.js - interface for GPU backends)                   |
+---------------------------------------------------------------------+
|  init()                    createProgram()                           |
|  beginRender()             createRenderPipeline()                   |
|  finishRender()            createComputePipeline()                  |
|  draw()                    createBindings()                          |
|  compute()                 updateBindings()                          |
+---------------------------------------------------------------------+
                              |
              +---------------+---------------+
              v                               v
+-------------------------+     +-------------------------+
|     WebGPUBackend       |     |    WebGLBackend         |
|  (webgpu/WebGPUBackend) |     |  (webgl-fallback/)      |
+-------------------------+     +-------------------------+
|  GPUDevice              |     |  WebGL2Context          |
|  CommandEncoder         |     |  Shader compilation     |
|  RenderPass             |     |  GL state management    |
|  WGSL shaders           |     |  GLSL shaders           |
+-------------------------+     +-------------------------+
```

The key insight: 89KB of rendering logic lives in the shared `Renderer` class. The WebGPU-specific `WebGPUBackend` adds another 67KB, but that is entirely GPU communication code. If you ever needed to add a third backend, you would not touch the shared layer at all.

---

## Key Source Files

If you want to follow along in the source code, here is where to look for each concept:

```
libraries/threejs/src/renderers/
+-- common/                          # Shared renderer infrastructure
|   +-- Renderer.js                  # If you want to understand scene traversal
|   |                                # and render list building, start here (89KB)
|   +-- Backend.js                   # If you want to see the abstract GPU interface,
|   |                                # this defines what backends must implement
|   +-- Pipelines.js                 # If you want to study pipeline caching,
|   |                                # this handles cache key generation
|   +-- Bindings.js                  # If you want to explore bind group management,
|   |                                # this coordinates uniform and texture bindings
|   +-- RenderObject.js              # If you want to understand per-draw state,
|   |                                # this bundles material + geometry + context
|   +-- RenderList.js                # If you want to see sorting algorithms,
|   |                                # this handles opaque/transparent ordering
|   +-- RenderContext.js             # If you want to understand render pass setup,
|   |                                # this manages attachments and clear values
|   +-- nodes/
|       +-- Nodes.js                 # Node system integration
|       +-- NodeLibrary.js           # Node type mapping
|
+-- webgpu/                          # WebGPU-specific code
|   +-- WebGPURenderer.js            # Entry point
|   +-- WebGPUBackend.js             # If you want to trace GPU command encoding,
|   |                                # this is where draw calls become WebGPU (67KB)
|   +-- nodes/
|   |   +-- WGSLNodeBuilder.js       # If you want to study shader compilation,
|   |   |                            # this compiles node graphs to WGSL (66KB)
|   |   +-- StandardNodeLibrary.js   # Material node mappings
|   +-- utils/
|       +-- WebGPUPipelineUtils.js   # Pipeline creation helpers
|       +-- WebGPUBindingUtils.js    # Bind group creation helpers
|       +-- WebGPUAttributeUtils.js  # Vertex buffer setup
|       +-- WebGPUTextureUtils.js    # Texture management
|
+-- webgl-fallback/                  # WebGL 2 fallback backend
    +-- WebGLBackend.js
```

---

## [wgpu](https://github.com/gfx-rs/wgpu) Concept Mapping

If you are coming from [wgpu](https://github.com/gfx-rs/wgpu) or Rust-based graphics programming, this table shows how [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) concepts translate:

| [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) Concept | [wgpu](https://github.com/gfx-rs/wgpu) Equivalent | Notes |
|------------------|-----------------|-------|
| `Backend` | Trait/interface | Abstract GPU operations |
| `WebGPUBackend` | `wgpu::Device` + helpers | WebGPU implementation |
| `Renderer` | Render loop coordinator | Scene traversal, sorting |
| `RenderObject` | Per-draw state bundle | Material + geometry + context |
| `Pipelines` | `RenderPipeline` cache | Cache by render state key |
| `Bindings` | `BindGroup` management | Resource binding |
| `RenderContext` | Render pass state | Attachments, clear values |
| `WGSLNodeBuilder` | Shader compiler | Node graph to WGSL |

The patterns are transferable even though the implementations differ. Pipeline caching in [Three.js](https://github.com/mrdoob/three.js)) uses a string-based cache key; in [wgpu](https://github.com/gfx-rs/wgpu) you might use a hash. Bind group management in [Three.js](https://github.com/mrdoob/three.js) uses WeakMaps; in Rust you would use something like `Arc<BindGroup>` with explicit invalidation.

---

## The Render Loop at a Glance

Before diving into the individual documents, here is the high-level flow of a single frame. This is the skeleton that everything else hangs on:

```
renderer.render(scene, camera)
    |
    +-- Update world matrices
    +-- Build render lists (opaque + transparent)
    |   +-- Frustum culling
    |   +-- Sort by material/depth
    |
    +-- backend.beginRender(renderContext)
    |   +-- Create CommandEncoder
    |   +-- Begin RenderPass
    |
    +-- For each render item:
    |   +-- Get/create RenderObject
    |   +-- Get/create Pipeline (cached by state)
    |   +-- Update Bindings (uniforms, textures)
    |   +-- backend.draw(renderObject)
    |       +-- setPipeline()
    |       +-- setBindGroup()
    |       +-- setVertexBuffer()
    |       +-- draw() / drawIndexed()
    |
    +-- backend.finishRender(renderContext)
        +-- End RenderPass
        +-- queue.submit()
```

The beauty of this flow is that most of the work is cached. On the first frame, RenderObjects are created, shaders are compiled, and pipelines are built. On subsequent frames, you are mostly just updating uniform buffers and issuing draw commands.

Let's trace what happens when rendering a single `MeshStandardMaterial` cube. The renderer encounters the cube during scene traversal and checks frustum culling—the cube is visible, so it goes into the opaque render list. When drawing begins, the renderer looks up (or creates) a RenderObject that bundles the cube's geometry, material, and current camera. The node system compiles the material's PBR shading into WGSL code. The pipeline cache checks if a matching pipeline exists for this material/geometry combination; if not, it creates one. Finally, the backend binds the pipeline, sets uniform buffers containing the model-view-projection matrix, binds textures (albedo, normal, roughness), and issues a `drawIndexed()` call. Next frame, everything is cached—only the uniform buffer updates.

---

## Key Patterns Worth Extracting

As you read through this documentation set, watch for these architectural patterns. They appear repeatedly and translate well to [wgpu](https://github.com/gfx-rs/wgpu):

**Backend Abstraction** separates GPU-agnostic logic from backend-specific code. The shared `Renderer` class handles traversal, sorting, and caching. The backend handles command encoding and resource management. This separation means you fix bugs once for all backends.

**RenderObject Bundling** groups all per-draw state into one cacheable unit. Instead of repeatedly looking up material, geometry, and camera for each draw call, you create a RenderObject once and reuse it across frames.

**Pipeline Cache Keys** encode every factor that affects GPU pipeline state. Same material but different blend mode? Different key. Same geometry but different vertex layout? Different key. The cache ensures you never accidentally reuse an incompatible pipeline.

**Node-Based Shaders** compile shader graphs to GPU code. Instead of string concatenation or templating, you build an abstract syntax tree of nodes and compile it. This enables features like automatic LOD, material combinations, and shader debugging.

**Render Context Isolation** keeps render pass configuration separate from draw logic. Whether you render to the main canvas, a shadow map, or a reflection probe, the same draw loop works because the context handles the differences.

**DataMap Pattern** uses WeakMap to associate [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) objects with their GPU resources. When the source object is garbage collected, the GPU resource mapping disappears automatically. No explicit cleanup required.

---

## Where to Start

If you are new to this documentation set, I recommend reading in this order:

1. **[Rendering Pipeline](rendering-pipeline.md)** — If you are wondering how a scene becomes draw calls, start here. It covers the five phases and the RenderObject pattern.
2. **[WebGPU Backend](webgpu-backend.md)** — If you want to understand how high-level intent becomes GPU commands, this traces the path from `draw()` to `queue.submit()`.
3. **[Pipeline and Bindings](pipeline-bindings.md)** — If you are curious about caching strategies or how dynamic data flows to shaders, this document explains both.
4. **[Node System (TSL)](node-system.md)** — If you are considering a shader graph approach for your own engine, this explores how [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) compiles JavaScript nodes to WGSL.

Each document builds on the previous ones. By the end, you will have a detailed mental model of how [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) manages the complexity of WebGPU rendering—and ideas for how to apply similar patterns in your own [wgpu](https://github.com/gfx-rs/wgpu)-based projects.
