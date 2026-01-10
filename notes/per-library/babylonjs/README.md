# Babylon.js Study

> Microsoft's production-grade 3D engine with first-class WebGPU support and a TypeScript-first architecture

---

## Why Study Babylon.js?

Babylon.js is one of the most comprehensive 3D engines targeting the web. Unlike Three.js which evolved organically over a decade, Babylon.js was designed from the ground up with structure in mind. It is TypeScript-first, has extensive tooling (Playground, Inspector, Node Material Editor), and was one of the earliest engines to ship production WebGPU support.

For a Rust creative coding framework, Babylon.js offers insights into:

- **WebGPU Engine Architecture** — How a mature engine structures WebGPU integration alongside WebGL fallback
- **Scene Graph Patterns** — Hierarchical transformations, entity management, and component systems
- **Node Material System** — Visual shader programming with a graph-based approach
- **TypeScript API Design** — How static typing shapes a 3D API's ergonomics
- **Asset Pipeline** — glTF loading, texture compression, and resource management
- **Post-Processing** — Render pipeline architecture for effects chains

Babylon.js also has excellent documentation and a transparent development process, making it easier to understand design decisions through issues and discussions.

---

## Key Areas to Study

### WebGPU Implementation
Babylon was among the first major engines to ship WebGPU support. Their `WebGPUEngine` provides a complete WebGPU backend while maintaining API compatibility with the WebGL engine.

**Source locations:**
- `packages/dev/core/src/Engines/WebGPU/` — WebGPU engine implementation
- `packages/dev/core/src/Engines/webgpuEngine.ts` — Main WebGPU engine class

### Node Material System
The Node Material Editor is a visual shader programming tool. The underlying system compiles node graphs to shader code, similar to Unreal's material editor.

**Source locations:**
- `packages/dev/core/src/Materials/Node/` — Node material implementation
- `packages/dev/core/src/Materials/Node/Blocks/` — Individual shader blocks

### Scene Graph Architecture
Babylon's scene graph handles hierarchical transforms, parent-child relationships, and efficient updates.

**Source locations:**
- `packages/dev/core/src/scene.ts` — Scene management
- `packages/dev/core/src/Meshes/` — Mesh and transform hierarchies
- `packages/dev/core/src/node.ts` — Base node class

### Material System
Beyond node materials, Babylon has a rich standard material library with PBR support.

**Source locations:**
- `packages/dev/core/src/Materials/PBR/` — PBR materials
- `packages/dev/core/src/Materials/standardMaterial.ts` — Standard material

---

## Repository Structure

```
packages/
├── dev/
│   ├── core/                    # Core engine
│   │   └── src/
│   │       ├── Engines/         # WebGL/WebGPU backends
│   │       ├── Materials/       # Material system
│   │       ├── Meshes/          # Geometry and mesh handling
│   │       ├── Rendering/       # Render pipeline
│   │       └── Shaders/         # Shader sources
│   ├── gui/                     # 2D/3D GUI system
│   ├── loaders/                 # Asset loaders (glTF, OBJ, etc.)
│   └── materials/               # Additional material library
├── tools/
│   ├── nodeEditor/              # Visual node material editor
│   └── inspector/               # Debug inspector
└── lts/                         # Long-term support builds
```

---

## Comparison with Three.js

| Aspect | Babylon.js | Three.js |
|--------|------------|----------|
| Language | TypeScript-first | JavaScript with TS types |
| WebGPU | Full engine parity | Renderer-level |
| Tooling | Inspector, Playground, NME | Limited built-in |
| Size | Larger (~2MB core) | Smaller (~150KB core) |
| Scene Graph | Full hierarchical | Minimal Object3D tree |
| Materials | Node system + standard | Node system (TSL) |
| Documentation | Extensive official docs | Community-driven |

Both engines offer valuable patterns. Babylon's more structured approach may be easier to translate to Rust's type system.

---

## Documents to Create

- [ ] `architecture.md` — Package structure and module organization
- [ ] `rendering-pipeline.md` — Frame execution and render loop
- [ ] `webgpu-engine.md` — WebGPU-specific implementation details
- [ ] `node-materials.md` — Visual shader graph system
- [ ] `api-design.md` — API patterns and TypeScript ergonomics
