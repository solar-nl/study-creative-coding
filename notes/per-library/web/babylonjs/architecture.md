# Babylon.js Architecture

> How a production 3D engine organizes 2+ million lines of TypeScript

---

## The Problem: Scale Without Chaos

Building a 3D engine is one thing. Building a 3D engine that thousands of developers use in production, that runs on WebGL and WebGPU, that supports everything from simple spinning cubes to full AAA-style games — that's an organizational challenge as much as a technical one.

Babylon.js has been in active development since 2013. It now spans over 2 million lines of TypeScript across dozens of packages. How do you keep that manageable? How do you let teams work on physics independently from rendering, or add WebGPU support without breaking WebGL users?

The answer is a carefully layered architecture with clear boundaries. Think of it like a city: the core infrastructure (roads, power, water) is stable and rarely changes, while buildings can be added, modified, or replaced without digging up the streets.

---

## The Mental Model: Layered Cake

Babylon.js organizes code in layers, where each layer only depends on layers below it:

```
┌─────────────────────────────────────────────────────────────────┐
│  APPLICATIONS                                                     │
│  Your game, visualization, or experience                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  TOOLS LAYER                                                     │
│  Node Editor, Inspector, Playground                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  EXTENSION PACKAGES                                              │
│  GUI, Loaders, Materials, Procedural Textures, Serializers      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  CORE ENGINE                                                     │
│  Scene, Meshes, Materials, Lights, Cameras, Engines              │
└─────────────────────────────────────────────────────────────────┘
```

The key insight: the core engine has **zero external dependencies** except TypeScript itself. Everything — physics, GUI, loaders — lives in separate packages that import core, never the reverse.

---

## Repository Structure

The Babylon.js monorepo uses a package-based organization under `packages/`:

```
packages/
├── dev/
│   ├── core/                    # The heart of Babylon.js (~67KB minified)
│   │   └── src/
│   │       ├── Engines/         # WebGL and WebGPU backends
│   │       ├── scene.ts         # Scene graph orchestration
│   │       ├── Materials/       # Material system and Node Materials
│   │       ├── Meshes/          # Geometry and mesh handling
│   │       ├── Rendering/       # Render loop and passes
│   │       ├── Cameras/         # Camera types and controls
│   │       ├── Lights/          # Light types and shadows
│   │       ├── Animations/      # Animation system
│   │       └── Shaders/         # Shader includes and utilities
│   │
│   ├── gui/                     # 2D and 3D GUI system
│   ├── loaders/                 # glTF, OBJ, STL, etc.
│   ├── materials/               # Additional material library
│   ├── serializers/             # Export to glTF, OBJ, etc.
│   └── proceduralTextures/      # Generated textures
│
├── tools/
│   ├── nodeEditor/              # Visual shader editor
│   ├── inspector/               # Runtime debugging tool
│   ├── playground/              # Online code playground
│   └── guiEditor/               # Visual GUI editor
│
└── lts/                         # Long-term support builds
```

---

## Core Engine Internals

The core package is where rendering happens. Understanding its structure is essential for tracing how a frame gets drawn.

### Entry Points

Every Babylon.js application starts with two objects:

1. **Engine** — The GPU interface (WebGL or WebGPU)
2. **Scene** — The container for everything you render

Here's the relationship:

```typescript
// Engine talks to the GPU
const engine = new Engine(canvas);  // or WebGPUEngine

// Scene holds your world
const scene = new Scene(engine);

// Scene uses Engine to draw
scene.render();  // Internally calls engine.beginFrame(), draw commands, engine.endFrame()
```

### The Engine Hierarchy

Babylon.js supports multiple GPU backends through inheritance:

```
AbstractEngine (interface contract)
    │
    ├── ThinEngine (minimal WebGL implementation)
    │       │
    │       └── Engine (full WebGL + all features)
    │
    └── ThinWebGPUEngine (minimal WebGPU implementation)
            │
            └── WebGPUEngine (full WebGPU + all features)
```

The "Thin" variants provide just enough functionality for basic rendering. The full variants add convenience methods, post-processing, and advanced features. This split enables tree-shaking — if you only use basic features, you don't pay for the rest.

**Key source files:**

- `Engines/engine.ts` — Main WebGL engine
- `Engines/webgpuEngine.ts` — Main WebGPU engine (line 213)
- `Engines/thinEngine.ts` — Minimal WebGL base
- `Engines/thinWebGPUEngine.ts` — Minimal WebGPU base

### Scene: The Orchestrator

The `Scene` class (`scene.ts`, ~6000 lines) is the largest single file in Babylon.js. It manages:

- **Entity collections** — meshes, lights, cameras, materials, textures
- **Frame orchestration** — animation updates, camera updates, render loop
- **Culling** — frustum testing to skip invisible objects
- **Render dispatch** — sending work to the RenderingManager

A simplified view of scene.render():

```
scene.render()
├── Update animations
├── Update active camera
├── Evaluate active meshes (frustum culling)
├── Render custom render targets (shadows, reflections)
└── Render main view via RenderingManager
```

**Key source file:** `scene.ts` (line 5388 for `render()` entry point)

### RenderingManager: Grouping Draw Calls

The RenderingManager (`Rendering/renderingManager.ts`) solves a critical problem: you can't draw transparent objects in any order. They must be sorted back-to-front.

Babylon divides meshes into **rendering groups** (0-3 by default), and within each group into:

1. **Opaque** — Can be drawn in any order
2. **Alpha Test** — Binary transparency (discard or not)
3. **Transparent** — Sorted back-to-front

This organization minimizes state changes while ensuring correct blending.

---

## Material System Architecture

Materials define how surfaces look. Babylon.js has three levels of material abstraction:

### 1. Base Materials

`Material` is the abstract base class. It defines the interface every material must implement:

- `isReadyForSubMesh()` — Can this material render right now?
- `bindForSubMesh()` — Set up GPU state for a draw call
- `getEffect()` — Get the compiled shader program

### 2. Standard Materials

`StandardMaterial` and `PBRMaterial` are the workhorse materials. They handle:

- Diffuse, specular, emissive colors
- Normal mapping, parallax
- Shadows, fog, reflections
- PBR: metallic/roughness workflow, clear coat, sheen, anisotropy

### 3. Node Materials

Node Materials (`Materials/Node/`) let you build shaders visually. They compile a graph of blocks into GLSL or WGSL. This system has 124 block types covering everything from basic math to full PBR.

The Node Material Editor provides visual shader programming — drag blocks, connect wires, see results in real time.

**Key source files:**

- `Materials/material.ts` — Base class
- `Materials/standardMaterial.ts` — Classic Phong-like material
- `Materials/PBR/pbrMaterial.ts` — Physically-based rendering
- `Materials/Node/nodeMaterial.ts` — Visual shader system

---

## Mesh and Geometry

Geometry data flows through several classes:

```
VertexData (raw arrays)
    ↓
Geometry (indexed, shareable)
    ↓
Mesh (renderable entity with transform)
    ↓
SubMesh (portion of mesh with one material)
```

### Why SubMeshes?

A single mesh might have multiple materials. A character model might have skin, clothes, and metal armor — each needs different shaders. SubMeshes divide the geometry into sections, each with its own material.

### VertexData

The `VertexData` class holds raw vertex attributes:

- `positions` — Float32Array of XYZ coordinates
- `normals` — Float32Array of normal vectors
- `uvs` — Float32Array of texture coordinates
- `indices` — Uint32Array of triangle indices

You can build meshes programmatically:

```typescript
const vertexData = new VertexData();
vertexData.positions = [0, 0, 0, 1, 0, 0, 0.5, 1, 0];
vertexData.indices = [0, 1, 2];
vertexData.applyToMesh(mesh);
```

**Key source files:**

- `Meshes/mesh.ts` — Main mesh class
- `Meshes/subMesh.ts` — Material-specific mesh portions
- `Meshes/mesh.vertexData.ts` — Raw vertex data container

---

## Package Dependencies

The package architecture enforces clean dependencies:

```
core ←───────────────────────────────────────────────────────────┐
  ↑                                                               │
  ├── loaders (imports core for mesh/texture handling)            │
  ├── materials (imports core for material base)                  │
  ├── gui (imports core for scene integration)                    │
  ├── serializers (imports core + loaders)                        │
  │                                                               │
  └── tools (inspector, editor) ─────────────────────────────────┘
```

No circular dependencies. Tools can import anything. Everything else only imports core.

---

## Build System and Tree Shaking

Babylon.js uses ES modules throughout. This enables tree-shaking — your bundler can eliminate unused code.

The impact is significant:

| Import Style | Bundle Size |
|--------------|-------------|
| Full engine | ~2MB |
| Tree-shaken basic scene | ~150KB |
| Just core math utilities | ~10KB |

To enable tree-shaking, import specific modules:

```typescript
// Tree-shakeable
import { Engine } from "@babylonjs/core/Engines/engine";
import { Scene } from "@babylonjs/core/scene";

// Not tree-shakeable (imports everything)
import * as BABYLON from "@babylonjs/core";
```

---

## Comparison with [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) Architecture

| Aspect | Babylon.js | [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) |
|--------|------------|----------|
| Organization | Monorepo with packages | Single package |
| Core size | ~67KB (thin), ~2MB (full) | ~150KB |
| Tree-shaking | First-class | Improving, not complete |
| TypeScript | Native | Types added after |
| Backend abstraction | Class hierarchy | Backend pattern |
| Scene graph | Rich (groups, layers) | Minimal (Object3D tree) |
| Built-in tools | Inspector, Playground, NME | None |

Both approaches work. [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) optimizes for simplicity and size. Babylon.js optimizes for features and tooling.

---

## Key Patterns for [wgpu](https://github.com/gfx-rs/wgpu) Implementation

Several patterns from Babylon.js translate well to Rust:

### 1. Thin/Full Split

The ThinEngine/Engine split maps to Rust traits:

```rust
trait ThinEngine {
    fn create_buffer(&self, data: &[u8]) -> Buffer;
    fn draw(&self, count: u32);
}

trait Engine: ThinEngine {
    fn post_process(&self, effects: &[PostProcess]);
    fn render_to_texture(&self, target: &RenderTarget);
}
```

### 2. SubMesh Pattern

SubMesh enables heterogeneous materials per mesh:

```rust
struct SubMesh {
    material_index: usize,
    index_start: u32,
    index_count: u32,
}

struct Mesh {
    geometry: Geometry,
    submeshes: Vec<SubMesh>,
    materials: Vec<Arc<dyn Material>>,
}
```

### 3. RenderingGroup Separation

Opaque/alpha-test/transparent grouping is fundamental:

```rust
struct RenderingGroup {
    opaque: Vec<RenderItem>,
    alpha_test: Vec<RenderItem>,
    transparent: Vec<RenderItem>,  // Sorted by distance
}
```

---

## Key Source File Reference

| Purpose | Path |
|---------|------|
| Main WebGL engine | `Engines/engine.ts` |
| Main WebGPU engine | `Engines/webgpuEngine.ts` |
| Scene management | `scene.ts` |
| Rendering orchestration | `Rendering/renderingManager.ts` |
| Rendering groups | `Rendering/renderingGroup.ts` |
| Base material | `Materials/material.ts` |
| PBR material | `Materials/PBR/pbrMaterial.ts` |
| Node materials | `Materials/Node/nodeMaterial.ts` |
| Mesh class | `Meshes/mesh.ts` |
| SubMesh | `Meshes/subMesh.ts` |

All paths relative to: `packages/dev/core/src/`

---

## Next Steps

With the architecture understood, dive into:

- **[Rendering Pipeline](rendering-pipeline.md)** — How scene.render() becomes draw calls
- **[WebGPU Engine](webgpu-engine.md)** — How Babylon abstracts WebGPU
- **[Node Materials](node-materials.md)** — Visual shader compilation
