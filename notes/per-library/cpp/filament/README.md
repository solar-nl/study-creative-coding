# Filament

A real-time physically based rendering engine for Android, iOS, Linux, macOS, Windows, and WebGL.

## Why Study This

Filament represents Google's production-quality approach to cross-platform physically based rendering. Unlike creative coding frameworks that prioritize ease of use, or research engines that explore novel techniques, Filament focuses on delivering predictable, physically accurate rendering across a wide range of platforms—from mobile devices to desktop to the web.

What makes Filament particularly valuable for this study is its architectural approach to cross-platform rendering. The engine targets multiple backends (Vulkan, Metal, OpenGL ES, WebGL) through a unified Material System that compiles materials once and generates backend-specific shaders. This abstraction strategy offers a compelling alternative to the runtime backend selection approach used by wgpu or the JavaScript abstraction layer in three.js.

Filament's material system is its standout feature. Materials are defined using a custom domain-specific language (similar to MaterialX or MDL) and compiled ahead-of-time by the matc compiler. The compiler generates optimized shaders for each backend, performing material-specific optimizations that would be difficult to achieve with runtime compilation. For a future Rust framework considering shader compilation strategies, Filament demonstrates the tradeoffs between ahead-of-time compilation (better optimization, longer build times) versus runtime compilation (more flexible, limited optimization).

The engine's commitment to physical accuracy extends beyond just PBR shading. Filament includes a complete physically based camera model with depth of field, motion blur, and bloom. Its light units use real-world photometric values (lumens, candelas). The color pipeline respects color spaces and applies proper tone mapping. This attention to physical correctness makes Filament code more portable—what works in Filament should approximate real-world behavior.

## Key Areas to Study

| Area | Relevance to Flux |
|------|-------------------|
| Material System | Ahead-of-time material compilation, DSL design, multi-backend shader generation |
| Backend Abstraction | How a single API targets Vulkan/Metal/OpenGL/WebGL |
| Scene Graph | Entity-component-system (ECS) design for scene management |
| Rendering Pipeline | Frame graph architecture, render pass organization |
| Resource Management | Handle-based resources, lifetime management in C++ |
| Physical Camera Model | DOF, motion blur, exposure, tone mapping |
| IBL System | Image-based lighting pipeline, environment map processing |
| Mobile Optimization | How to maintain quality on resource-constrained devices |

## Repository Structure

```
filament/
├── filament/              # Core rendering library
│   ├── backend/           # Abstract backend interface
│   ├── include/           # Public API headers
│   └── src/               # Implementation
├── libs/
│   ├── filamat/           # Material compiler library
│   ├── filaflat/          # Material binary format
│   ├── image/             # Image loading/processing
│   ├── math/              # Math utilities (vectors, matrices)
│   └── utils/             # General utilities
├── shaders/               # GLSL/MSL/SPIRV shader code
│   └── src/               # Shader source
├── tools/
│   ├── matc/              # Material compiler
│   ├── cmgen/             # Environment map preprocessing
│   └── filamesh/          # Mesh converter
├── android/               # Android integration
├── ios/                   # iOS integration
└── web/                   # WebAssembly/WebGL build
```

## Material System Overview

Filament materials are defined in `.mat` files using a custom DSL:

```glsl
material {
    name : MyMaterial,
    shadingModel : lit,
    parameters : [
        { type : float, name : roughness },
        { type : float3, name : baseColor }
    ]
}

fragment {
    void material(inout MaterialInputs material) {
        prepareMaterial(material);
        material.baseColor = materialParams.baseColor;
        material.roughness = materialParams.roughness;
    }
}
```

The `matc` compiler generates optimized shaders for each backend, handling:
- Parameter binding and uniform buffer layout
- Texture sampling code generation
- Backend-specific shader language translation (GLSL/MSL/SPIRV)
- Dead code elimination for unused features

This approach differs significantly from runtime shader compilation (as seen in three.js TSL) or shader templates (common in game engines). The tradeoff is flexibility versus optimization.

## Backend Architecture

Filament's backend abstraction uses a command buffer pattern similar to modern GPU APIs:

```
Application → Driver (abstract) → Backend (Vulkan/Metal/OpenGL/WebGL)
                  ↓
             CommandStream (records commands)
                  ↓
             Backend consumes commands
```

Unlike three.js which maintains separate WebGL and WebGPU backends, Filament's backends share significantly more code through the Driver abstraction. The command stream is agnostic to the backend, allowing backend selection at runtime (though most apps pick one at compile time for size optimization).

## Documents to Create

- [ ] `architecture.md` — Overall structure, backend abstraction, ECS design
- [ ] `material-system.md` — Material DSL, compilation pipeline, shader generation
- [ ] `rendering-pipeline.md` — Frame graph, render passes, view/scene/renderable flow
- [ ] `backend-abstraction.md` — Command stream, driver interface, backend implementations
- [ ] `physical-rendering.md` — PBR implementation, IBL, lighting units
- [ ] `resource-management.md` — Handle system, GPU resource lifecycle
- [ ] `mobile-optimizations.md` — How Filament maintains quality on mobile
- [ ] `comparison-with-wgpu.md` — Architecture patterns applicable to Rust
- [ ] `code-traces/` — Annotated walkthroughs
  - [ ] `simple-triangle.md` — Minimal rendering setup
  - [ ] `material-compilation.md` — From .mat file to GPU shader
  - [ ] `frame-rendering.md` — One complete frame trace

## Cross-Platform Strategy

Filament's approach to cross-platform rendering differs from both wgpu (runtime backend selection) and three.js (separate implementations):

| Aspect | Filament | wgpu | three.js |
|--------|----------|------|----------|
| Backend Selection | Compile-time or runtime | Runtime | Runtime |
| Shader Compilation | Ahead-of-time (matc) | Ahead-of-time (naga) | Runtime (node system) |
| Code Sharing | Command stream abstraction | Hardware abstraction layer | Backend class hierarchy |
| Material Definition | Custom DSL (.mat files) | WGSL/GLSL/HLSL/MSL | JavaScript (TSL nodes) |
| Optimization | Per-material, per-backend | Per-shader, cross-backend | Runtime, cross-backend |

## Physical Correctness

Filament's commitment to physical accuracy manifests in several design decisions:

- **Light Units**: Lights use real-world units (lumens for directional, candelas for point/spot)
- **Color Spaces**: sRGB input, linear internal processing, proper tone mapping output
- **Camera Model**: Physically based exposure (ISO, shutter speed, aperture)
- **Material Values**: Roughness and metallic follow measured real-world ranges
- **IBL**: Environment maps use proper spherical harmonics for diffuse

This makes Filament code more predictable and portable across platforms. A scene that renders correctly on desktop should look identical on mobile, accounting for precision differences.

## References

- [Filament GitHub](https://github.com/google/filament)
- [Filament Documentation](https://google.github.io/filament/)
- [Physically Based Rendering in Filament](https://google.github.io/filament/Filament.html) — The technical whitepaper
- [Material Guide](https://google.github.io/filament/Materials.html)
- [Filament API Reference](https://google.github.io/filament/reference.html)
